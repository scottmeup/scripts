set -x

DOWNLOADS_DIRECTORY="/mnt/sdb2/common/downloads"    # Path to search for files
OUTPUT_DIRECTORY="/tmp/qb-script"
OUTPUT_FILENAME="download-file.txt"
MINIMUM_AGE_TO_DELETE=$((7 * 24 * 60))    # Minimum Age of Files to be deleted in minutes
MINIMUM_AGE_TO_DELETE_ESCALATED=$(( 60 ))    # Minimum Age of Files to be deleted in minutes when disk space is low
MINIMUM_FREE_SPACE_BEFORE_ESCALATION=$((1024 * 1024 * 10))    # Minimum free kilobytes before increasing cleanup actions. Example is 10 GiB
MINIMUM_FREE_SPACE_BEFORE_ESCALATION_PERCENT=$(( 1 ))    # Minimum free percentage before increasing cleanup actions.
FREE_SPACE_USE_PERCENTAGE=true   # true / false - use percentage of volume for free space escalation calculation instead of kilobytes if true

IF [ $FREE_SPACE_USE_PERCENTAGE ]; then
    FREE_SPACE=`df -P "$DOWNLOADS_DIRECTORY" | tail -1 | awk '{print $5}' | cut -f1 -d%`    # Caclulate free space as %
    MINIMUM_FREE_SPACE_BEFORE_ESCALATION=MINIMUM_FREE_SPACE_BEFORE_ESCALATION_PERCENT
else
    FREE_SPACE=`df -P "$DOWNLOADS_DIRECTORY" | tail -1 | awk '{print $4}'`    # Calculate free space in kilobytes
fi

echo "$MINIMUM_AGE_TO_DELETE"
echo "$MINIMUM_FREE_SPACE_BEFORE_ESCALATION"
echo "$FREE_SPACE"

if [ $FREE_SPACE -le $MINIMUM_FREE_SPACE_BEFORE_ESCALATION ]; then
    MINIMUM_AGE_TO_DELETE=$MINIMUM_AGE_TO_DELETE_ESCALATED    # Escalate deletion methods if disk space is running low
fi

mkdir -p "$OUTPUT_DIRECTORY"
find -P "$DOWNLOADS_DIRECTORY" -mmin +"$MINIMUM_AGE_TO_DELETE" -type f > "$OUTPUT_DIRECTORY"/$"OUTPUT_FILENAME"
