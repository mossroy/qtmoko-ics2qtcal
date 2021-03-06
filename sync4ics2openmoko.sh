#!/bin/sh
# Interpret command line options
while getopts vu:p:s: option
do	case "$option" in
	u)	user="$OPTARG";;
	p)	password="$OPTARG";;
	v)	verbose="-v";;
	s)	server="$OPTARG";;
	[?])	print >&2 "Usage: $0 [-v] [-u user] [-p password] [-s serverurl] fileurl1 fileurl2 ..."
		exit 1;;
	esac
done
shift `expr $OPTIND - 1`

# Work in tmpdir
mytmp="/tmp/ics2qtcal-`date +%H%M%S`"
mkdir $mytmp
cd $mytmp

icaldb="/home/root/Applications/Qtopia/qtopia_db.sqlite"
tmpnotes="./Annotator-tmp"
notes="/home/root/Applications/Annotator/"

echo "Creating a backup copy of qtopia_db.sqlite"
cp "$icaldb" ./qtopia_db.sqlite.bak

echo "Fetching files"
for fileurl in $*
do
    # We force the output to have .ics extension to simplify next for loop
    if [ -z "$server" ]; then
	    wget --no-check-certificate --user="$user" --password="$password" "$fileurl" -O "`basename ${fileurl%%.ics}`_`date +%Y%m%d_%H%M%S`.ics"
	else
	    wget --no-check-certificate --user="$user" --password="$password" ${server}/${fileurl} -O "`basename ${fileurl%%.ics}`_`date +%Y%m%d_%H%M%S`.ics"
	fi
done

#echo "Deleting appointments of qtopia_db"
#perl deleteqtcalappointments.pl "$icaldb"

echo "Deleting temporary Notes files from a previous execution"
rm "${tmpnotes}"/*
mkdir -p "${tmpnotes}"

echo "Transferring events to qtopia_db"
for filename in ./*.ics
do
    echo "Creating temporary copy of $filename with valid lines into db $caldb"
    # Create a copy and remove X-MOZ-LASTACK lines that are not understood by Tie::iCal
    # FIXME Check if really needed with latest scripts
    grep -v X-MOZ-LASTACK "${filename}" > "${filename}.tmp"

    if [ -n "$verbose" ] ; then
        ics2qtcal.pl -- -v --ical "${filename}.tmp" --qtopiadb "$icaldb" --notesdirectory "$tmpnotes"
    else
        ics2qtcal.pl -- --ical "${filename}.tmp" --qtopiadb "$icaldb" --notesdirectory "$tmpnotes"
    fi
done;

echo "Removing existing Note files"
rm -f "${notes}"/0-*

echo "Copying Note files"
cp "${tmpnotes}"/* "${notes}"

echo "Removing *.ics local files and *.ics.tmp temporary files"
rm *.ics
rm *.ics.tmp

echo "Done"
