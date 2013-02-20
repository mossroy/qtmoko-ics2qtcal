#!/usr/bin/perl

use strict;

use Getopt::Long;
use Pod::Usage;

use vars qw/$verbose $icsFile $destDb $notesDirectory $help/;
BEGIN {
	if (
		!GetOptions(
			'ical|i=s' => \$icsFile,
			'qtopiadb|q=s' => \$destDb,
			'verbose|v' => \$verbose,
			'notesdirectory=s' => \$notesDirectory,
			'help|?' => \$help,
		) || 
		$help ||
		!defined $icsFile ||
		!defined $destDb
	) {
		pod2usage(-verbose => 2);
		exit;
	}	
}



use DBI;
use Tie::iCal;
use DateTime;
use DateTime::Format::ICal;
use DateTime::Event::ICal;
use DBD::SQLite;
use Encode;
use File::Spec;
# Seems to be necessary for the insert statement in APPOINTMENTCUSTOM
$DBD::SQLite::COLLATION{NOCASE} = sub { $_[0] cmp $_[1] };


# Print a debug message if the verbose mode is on
sub debug {
	print STDERR $_[0]."\n" if $verbose;
}


# This function reformats a datetime in ICS format to a valid SQLite timestamp
sub reformatICSDateTimeToSQLiteTimestamp {
	my $date = $_[0];
	$date =~ s/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})/$1-$2-$3T$4:$5:$6/ ;
	return $date;
}

# Create a file in the format expected by QtMoko (normally generated by Annotator) in a temp directory, containing the text in parameter
# This is reverse-engineered by looking at the content of the files : it's probably incorrect/incomplete/badly coded. But I did not find any spec on it
sub createNoteFile {
	my $id = $_[0];
	my $text = $_[1];
	my $notesDirectory = $_[2];
	# Compute the lengths that need to be placed in the file
	my $first_length = 922 + 2 * length($text);
	my $second_length = $first_length - 4;
	my $prefix = "\x00\x00\x00\x12\x00\x74\x00\x65\x00\x78\x00\x74\x00\x2f\x00\x68\x00\x74\x00\x6d\x00\x6c\x00\x00";
	# Encode the lengths in 16-bit, big endian
	$prefix .= pack("n",$first_length);
	$prefix .= "\x00\x00";
	$prefix .= pack("n",$second_length);
	my $htmlprefix .= "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.0//EN\" \"http://www.w3.org/TR/REC-html40/strict.dtd\">\n<html><head><meta name=\"qrichtext\" content=\"1\" /><style type=\"text/css\">\np, li { white-space: pre-wrap; }\n</style></head><body style=\" font-family:'dejavu_sans_condensed'; font-size:6.4pt; font-weight:400; font-style:normal;\">\n<p style=\" margin-top:0px; margin-bottom:0px; margin-left:0px; margin-right:0px; -qt-block-indent:0; text-indent:0px;\">";
	my $htmlsuffix .= "</p></body></html>";
	my $html = $htmlprefix . $text . $htmlsuffix;
	# Add a \x00 before every caracter
	$html =~ s/(.)/\x00$1/g;
	$html =~ s/\n/\x00\n/g;
	# Create a file with the id as the name, in notesDirectory
	my $filePath = File::Spec->catfile($notesDirectory, "0-" . $id);
	debug ("Create Note file ".$filePath);
	open FILE, ">". $filePath;
	print FILE $prefix . $html;
	close FILE;
}

# This function extracts the date from an ical start or end date
# first parameter : the array given by Tie::iCal
# second parameter : is this an end date (1) or start date (0) ?
sub extractDateFromIcalLine {
	my $date;
	my $end = $_[1];
	
	# There's only one element, so it's the date
    if (ref(\$_[0]) eq 'SCALAR') {
        $date = $_[0];
    }
    elsif (ref($_[0]) eq 'ARRAY') { #This array should contain an hash with TZID and a scalar with date-time
        if(ref(\$_[0][0]) eq 'SCALAR'){
            $date = $_[0][0];
        }
        elsif (ref(\$_[0][1]) eq 'SCALAR') {
            $date = $_[0][1];
        }
    }else {
		print ("Unrecognized ical date format");
		return undef;
	}
    debug("Found date : $date");
	
	if (length($date) == 8) {
		if ($end == 0) {
			# It is a start date : it starts at midnight
			return $date . "T000000";
		}
		else {
            # It is an end date : it ends just before midnight of the day before
            my $dt = DateTime::Format::ICal->parse_datetime($date."T235900");
            my $yesterday = $dt;
            $yesterday->set_day($dt->day-1);
            $yesterday->set_time_zone("local");
            return DateTime::Format::ICal->format_datetime($yesterday);
		}
	}
	else {
		# Remove the trailing Z
		$date =~ s/Z$//;
		return $date;
	}
}


# This function extracts the timezone from an ical start or end date
# Currently, it only supports the distinction between local time and UTC
# TODO : check which time zones are good values for qtmoko database
# first parameter : the array given by Tie::iCal
sub extractTimeZoneFromIcalLine {
    my $date;
    my $tz;

    # There's only one element, so the timezone is specified by the last character
    if (ref(\$_[0]) eq 'SCALAR') {
        $date = $_[0];

        # Timezone is UTC if date ends with Z, otherwise it's a local timezone
        if ($date =~ /Z$/) {
            $tz = "UTC";
        }
    }
    elsif (ref($_[0]) eq 'ARRAY') {
        if(ref($_[0][0]) eq 'HASH'){
            $tz = $_[0][0]->{TZID};
        }
        elsif (ref($_[0][1]) eq 'HASH') {
            $tz = $_[0][1]->{TZID};
        }   
    }
    debug("Found timezone (empty for local timezone) : $tz");
    return $tz;
}

# This function unescapes the escaped commas, and converts the \n to <br/>
sub convertICalStringToHTMLNote {
	my $string = $_[0];
	# Convert \n string into <br/>
	$string =~ s/\\n/<br\/>/g;
	# Remove backslashes before commas
	$string =~ s/\\,/,/g;
	return $string;
}

# This function return the number to add to repeatweekflags for the day given in parameter
# parameter : day of week
sub repeatWeekFlagFromDayOfWeek {
	my $day_of_week = $_[0];
	my $repeatweekflags = 0;
	if ($day_of_week eq "MO") {
		$repeatweekflags = 1;
	}
	elsif ($day_of_week eq "TU") {
		$repeatweekflags = 2;
	}
	elsif ($day_of_week eq "WE") {
		$repeatweekflags = 4;
	}
	elsif ($day_of_week eq "TH") {
		$repeatweekflags = 8;
	}
	elsif ($day_of_week eq "FR") {
		$repeatweekflags = 16;
	}
	elsif ($day_of_week eq "SA") {
		$repeatweekflags = 32;
	}
	elsif ($day_of_week eq "SU") {
		$repeatweekflags = 64;
	}
	return $repeatweekflags;
}


main:
{
	# Read the iCal file
	debug ("Read the iCal file $icsFile");
	open FILE, "<$icsFile" or die "Failed to tie file $icsFile !\n";
	my @lines = <FILE> ;
	# Remove end of lines
	chomp @lines;

	# Check that the notesdirectory parameter is a real directory
	if ($notesDirectory ne '') {
		if (!(-d $notesDirectory)) {
			die "Incorrect directory : ".$notesDirectory . "\n";
		}
		debug ("Directory for notes : ".$notesDirectory);
	}

	debug ("Initialize the Tie::iCal structure");
	my $ical = {};
	bless $ical, "Tie::iCal";	
	$ical->{A} = \@lines;
	# Put Tie::iCal in debug mode if verbose mode is set
	$ical->{debug} = $verbose;

	# Connect to the Qtopia database
	debug ("Connect to database $destDb");
	my $dbargs = {AutoCommit => 0,
			PrintError => 1};
	my $dbh = DBI->connect("dbi:SQLite:dbname=$destDb","","",$dbargs);
	if ($dbh->err()) { die "$DBI::errstr\n"; }

	# Looks for the maximum recid of existing appointments
	debug ("Look for the maximum recid in the appointments table of the existing database");
	my $recid = 1;
	my ($maxrecid) = $dbh->selectrow_array("SELECT max(recid) from APPOINTMENTS");
	if (defined($maxrecid)) {
		$recid = $maxrecid + 1;
	}

	# Prepare SQL insert statement
	debug ("Prepare the SQL insert statements");
	my $sth = $dbh->prepare("INSERT INTO APPOINTMENTS (recid,description,location,start,end,allday,starttimezone,endtimezone,alarm,alarmdelay,repeatrule,repeatfrequency,repeatenddate,repeatweekflags,context) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);");

	my $sthNote = $dbh->prepare("INSERT INTO APPOINTMENTCUSTOM (recid,fieldname,fieldvalue) VALUES (?,?,?);");

	my $time = time;
	
	# Loop through ical Events
	my $indexInFile = 0;
	for my $line (@lines) {
		if (substr($line, 0, 3) eq 'UID') {
			if ($ical->unfold($indexInFile) =~ /^UID.*:(.*)$/) {
				my $uid = $1;
				debug ("uid found : $uid - Reading the ical event");
				my $event = $ical->toHash($indexInFile);
				debug ("Prepare the appointment recid=$recid");

				# Description
				my $description = $event->[1]->{SUMMARY};
				# Ignore the possible language given in this line
				if (ref($description) eq 'ARRAY') {
					debug ("Ignoring the HASHes in the Summary line");
					my $indexInDescription = 0;
					# Take the first string in the line (ignoring all the HASHes)
					while (ref($description->[$indexInDescription]) eq 'HASH') {
						$indexInDescription ++;
					}
					$description = $description->[$indexInDescription];
				}
				$description = convertICalStringToHTMLNote ($description);
				debug ("description=$description");

				# Process start date
				my $startDate = reformatICSDateTimeToSQLiteTimestamp(extractDateFromIcalLine($event->[1]->{DTSTART},0));
				debug ("startDate=$startDate");

				# Extract the TimeZone of start date
				my $startDateTimeZone = extractTimeZoneFromIcalLine($event->[1]->{DTSTART});
				debug ("startDateTimeZone=$startDateTimeZone");

				# Process end date
				my $endDate = reformatICSDateTimeToSQLiteTimestamp(extractDateFromIcalLine($event->[1]->{DTEND},1));
				debug ("endDate=$endDate");

				# Extract the TimeZone of end date
				my $endDateTimeZone = extractTimeZoneFromIcalLine($event->[1]->{DTEND});
				debug ("endDateTimeZone=$endDateTimeZone");

				# Process location
				my $location = $event->[1]->{LOCATION};
				# Ignore the possible language given in this line
				if (ref($location) eq 'ARRAY') {
					debug ("Ignoring the HASHes in the Location line");
					my $indexInLocation = 0;
					# Take the first string in the line (ignoring all the HASHes)
					while (ref($location->[$indexInLocation]) eq 'HASH') {
						$indexInLocation ++;
					}
					$location = $location->[$indexInLocation];
				}
				$location = convertICalStringToHTMLNote ($location);
				debug ("location=$location");

				# Check if it's an all-day event
				my $allday;
				if ( (ref($event->[1]->{DTSTART}) eq 'ARRAY') && ($event->[1]->{DTSTART}->[0]{'VALUE'} eq "DATE") ) {
					$allday = "true";
				} else {
					$allday = "false";
				}
				debug ("allday=$allday");

				# Process repeat rules
				# TODO probable fixes needed to implement the complete RFC
				my $repeatrule = 0;
				my $repeatfrequency = 1;
				my $repeatenddate = undef;
				my $repeatweekflags = 0;
				if ($event->[1]->{RRULE}{'FREQ'} ne '') {
					$repeatrule = 1;
					if ($event->[1]->{RRULE}{'FREQ'} eq "DAILY") {
						$repeatrule = 1;
					}
					elsif ($event->[1]->{RRULE}{'FREQ'} eq "WEEKLY") {
						$repeatrule = 2;
					}
					elsif ($event->[1]->{RRULE}{'FREQ'} eq "MONTHLY") {
						$repeatrule = 4;  # which can be replaced by 4 or 6 depending on the BYDAY value
					}
					elsif ($event->[1]->{RRULE}{'FREQ'} eq "YEARLY") {
						$repeatrule = 5;
					}
					debug ("frequency=".$event->[1]->{RRULE}{'FREQ'}." => repeatrule=$repeatrule");
					if ($event->[1]->{RRULE}{'UNTIL'} ne '') {
						$repeatenddate = $event->[1]->{RRULE}{'UNTIL'};
						$repeatenddate =~ s/^(\d{4})(\d{2})(\d{2}).*/$1-$2-$3/ ;
						debug ("repeatenddate=$repeatenddate");
					}
					elsif ($event->[1]->{RRULE}{'COUNT'} ne '') {
						my $count = $event->[1]->{RRULE}{'COUNT'};
						# Compute the ical date corresponding to the start date
						my $icaldate = DateTime::Format::ICal->parse_datetime(extractDateFromIcalLine($event->[1]->{DTSTART},0));
						my $icallastdateaftercount;
						if ($repeatrule == 1) {
						    my $icalrec = DateTime::Event::ICal->recur(
						        dtstart => $icaldate,
						        freq => "daily",
						        count => $count
						    );
							$icallastdateaftercount = $icalrec->max;
						}
						if ($repeatrule == 2) {
						    my $icalrec = DateTime::Event::ICal->recur(
						        dtstart => $icaldate,
						        freq => "weekly",
						        count => $count
						    );
							$icallastdateaftercount = $icalrec->max;
						}
						if ($repeatrule == 4) {
						    my $icalrec = DateTime::Event::ICal->recur(
						        dtstart => $icaldate,
						        freq => "monthly",
						        count => $count
						    );
							$icallastdateaftercount = $icalrec->max;
						}
						if ($repeatrule == 5) {
						    my $icalrec = DateTime::Event::ICal->recur(
						        dtstart => $icaldate,
						        freq => "yearly",
						        count => $count
						    );
							$icallastdateaftercount = $icalrec->max;
						}
						$repeatenddate = DateTime::Format::ICal->format_datetime($icallastdateaftercount);
						$repeatenddate =~ s/^(\d{4})(\d{2})(\d{2}).*/$1-$2-$3/ ;
						debug ("count=$count => repeatenddate=$repeatenddate");
					}
					if ($event->[1]->{RRULE}{'INTERVAL'} ne '') {
						$repeatfrequency = $event->[1]->{RRULE}{'INTERVAL'};
						debug ("repeatfrequency=$repeatfrequency");
					}
					if ($event->[1]->{RRULE}{'BYDAY'} ne '') {
						# Compute the repeatweekflags from the days of week where the event occurs
						if (ref($event->[1]->{RRULE}{'BYDAY'}) eq 'ARRAY') {
							# There is more than one item in the list
							my $i = 0;
							while ((my $day_of_week = $event->[1]->{RRULE}->{BYDAY}[$i]) ne '') {
								debug ("day_of_week=$day_of_week");
								$repeatweekflags += repeatWeekFlagFromDayOfWeek ($day_of_week);
								$i++;
							}
							debug ("repeatweekflags=$repeatweekflags");
						}
						else {
							# There is only one item in the list
							my $day_of_week = $event->[1]->{RRULE}->{BYDAY};
							if ($day_of_week =~ m/[0-9]/) {
								# Cases where the day of week is preceeded by a number (positive or negative)
								if ($day_of_week =~ m/\-/) {
									# The event must repeat every nth day of week from the end of every month
									$repeatrule = 6;
									debug("repeatrule=6");
								}
								else {
									# The event must repeat every nth day of week of every month
									$repeatrule = 3;
									debug("repeatrule=3");
								}
							}
							else {
								# There is one simple day
								$repeatweekflags = repeatWeekFlagFromDayOfWeek ($day_of_week);
								debug ("day_of_week=$day_of_week => repeatweekflags=$repeatweekflags");
							}
						}
					}
				}

				# Process note : if there is one, we must create a specially encoded file with its content, and add a line in APPOINTMENTCUSTOM table
				if ($notesDirectory ne '') {
					my $note = $event->[1]->{DESCRIPTION};
					if (ref($note) eq 'ARRAY') {
						# In case there is an unescaped comma in the string (that should not happen) : take the string before the comma
						$note = $note->[0];
					}
					# TODO : add attendees to the description
					if ($note ne '') {
						# Use an encoding suitable for a QtMoko Note
						$note = encode ("iso-8859-15",decode("utf8",$note));
						$note = convertICalStringToHTMLNote ($note);
						debug ("Create a note file for the description of appointment $recid");
						createNoteFile ($recid,$note,$notesDirectory);
						debug ("Insert the note link in the database");
						$sthNote->execute($recid,'qdl-private-client-data','AAAAAQAAABAAZQBkAGkAdABuAG8AdABlAAAAAA==');
					}
				}

				debug ("Insert the new appointment in the database");
				# Insert new appointment
				$sth->execute(
					# Recid
					$recid,
					# Description
					$description,
					# Location
					$location,
					# Start date
					$startDate,
					# End date
					$endDate,
					# All day
					$allday,
					# Start timezone
					$startDateTimeZone,
					# End timezone
					$endDateTimeZone,
					# TODO : handle alarms
					# Alarm
					0,
					# Alarmdelay
					0,
					# Repeat rule
					$repeatrule,
					# Repeat frequency
					$repeatfrequency,
					# Repeat End Date
					$repeatenddate,
					# Repeat week flags
					$repeatweekflags,
					# Context
					2
					);
				if ($dbh->err()) { die "$DBI::errstr\n"; }

				$recid++;

				debug ("Appointment inserted");

				# TODO : handle the category through the table APPOINTMENTCATEGORIES

				# Commit every 100 events
				if ($recid % 100 == 0) {
					$dbh->commit();
					debug ("elapsed for last 100 events=". (time - $time)." seconds");
					$time = time;
				}
			}
		}
		$indexInFile++;
	}

	# Commit and close Qtopia database
	$dbh->commit();
	# Workaround to avoid warnings from $dbh->disconnect()
	# See http://www.perlmonks.org/?node_id=665714
	undef $dbh;
}

__END__

=head1 NAME

ics2qtcal
version 0.6

=head1 DESCRIPTION
This program inserts in an existing Qtopia database the events of an ical (.ics) file
 
Idea and guidelines taken from http://wiki.openmoko.org/wiki/PIM_Storage#Import.2FExport_of_Calendar_Data_for_PIM-Storage by Niebert. 
Some code inspired or copied from http://cpansearch.perl.org/src/BSDZ/Tie-iCal-0.14/samples/outlooksync.pl .
The iCal RFC implementation (http://www.faqs.org/rfcs/rfc2445.html) is quite incomplete in this script, but it covers the most common options

=head1 USAGE

ics2qtcal.pl [--help] [--verbose] --ical <ics file path> --qtopiadb <dest qtopia_db.sqlite> [--notesdirectory <directory>]

=head1 OPTIONS

=over 4

=item B<--help|-?>

Print this message.

=item B<--verbose|-v>

Enable debugging messages

=item B<--notesdirectory>

Defines where the Note files should be generated.
If this option is omitted, the program will not create any Note file :
the events will have no description, and the program will only modify
the sqlite file

=item B<--ical|-i>

Specify source RFC2445 iCalendar file to be synchronised, This option
is mandatory.

=item B<--qtopiadb|-q>

Specify existing SQLite database, in the format expected by Qtopia,
in which the new appointments will be inserted.
This option is mandatory

=back

=head1 LICENSE

ics2qtcal is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, version 3 of the License.

ics2qtcal is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You can have a copy of the GNU General Public License at :
<http://www.gnu.org/licenses/>.

=cut

