#!/usr/bin/env bash

set -x

# Parameters
MAX_GAP_SECONDS=3600   # 1 hour
MIN_AGE_SECONDS=7200   # 2 hours
SOURCE_DIR="/foo"
REFERENCE_FILE="/foo/.dir_monitor_timestamp_mov"
OUTPUT_DIR="/bar"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Create reference timestamp file if missing
if [ ! -f "$REFERENCE_FILE" ]; then
    touch -d "2 hours ago" "$REFERENCE_FILE"
    echo "Created reference file: $REFERENCE_FILE"
fi

# Get reference time
ref_time=$(stat -c %Y "$REFERENCE_FILE")

# Get current UNIX time
now=$(date +%s)

# Get current year
current_year=$(date +%Y)
previous_year=$((current_year - 1))

# Get sorted list of MOV files by directory presence age
# Reconstruct timestamps: use current year unless that makes it future, then use previous year
mapfile -t files < <(
    find "$SOURCE_DIR" -maxdepth 1 -type f -iname "*.mov" -printf "%T@ %p\n" |
    awk -v ref="$ref_time" -v min_age="$MIN_AGE_SECONDS" -v now="$now" -v cur_year="$current_year" -v prev_year="$previous_year" '
    {
        file_time = $1
        filepath = $0
        sub(/^[^ ]+ /, "", filepath)
        
        # Extract date components from file timestamp
        cmd = "date -d @" file_time " +\"%m %d %H %M %S\""
        cmd | getline date_parts
        close(cmd)
        
        split(date_parts, parts, " ")
        month = parts[1]
        day = parts[2]
        hour = parts[3]
        minute = parts[4]
        second = parts[5]
        
        # Try with current year first
        test_date = cur_year "-" month "-" day " " hour ":" minute ":" second
        cmd2 = "date -d \"" test_date "\" +%s"
        cmd2 | getline test_time
        close(cmd2)
        
        # If that would be in the future, use previous year instead
        if (test_time > now) {
            new_date = prev_year "-" month "-" day " " hour ":" minute ":" second
            cmd3 = "date -d \"" new_date "\" +%s"
            cmd3 | getline file_time
            close(cmd3)
        } else {
            file_time = test_time
        }
        
        # Check if file is old enough
        if (file_time <= (ref - min_age)) {
            print file_time " " filepath
        }
    }' |
    sort -n | cut -d' ' -f2-
)

if [ "${#files[@]}" -eq 0 ]; then
    echo "No eligible MOV files (present > 2 hrs) found."
    exit 0
fi

group=()
first_time=0

join_group() {
    if [ "${#group[@]}" -ge 1 ]; then
        # Format output file name
        timestamp=$(date -d @"$first_time" +"%Y-%m-%d_%H-%M-%S")
        
        if [ "${#group[@]}" -eq 1 ]; then
            # Single file - just move it with rotation metadata
            output_file="${OUTPUT_DIR}/${timestamp}_single.mov"
            echo "Moving single file to $output_file"
            ffmpeg -y -fflags +igndts -i "${group[0]}" -c copy -metadata:s:v:0 rotate=180 "$output_file"
            ffmpeg_status=$?
        else
            # Multiple files - join them
            concat_list=$(mktemp)
            for f in "${group[@]}"; do
                echo "file '$f'" >> "$concat_list"
            done

            output_file="${OUTPUT_DIR}/${timestamp}_joined.mov"
            echo "Joining ${#group[@]} files into $output_file"
            ffmpeg -y -fflags +igndts -f concat -safe 0 -i "$concat_list" -c copy -metadata:s:v:0 rotate=180 "$output_file"
            ffmpeg_status=$?
            rm -f "$concat_list"
        fi

        if [ $ffmpeg_status -eq 0 ]; then
            echo "Processing succeeded. Deleting original files..."
            for f in "${group[@]}"; do
                #rm -v -- "$f"
            done
        else
            echo "Processing failed with status $ffmpeg_status. Keeping original files."
        fi
    fi
    group=()
}

for f in "${files[@]}"; do
    file_time=$(stat -c %Y "$f")

    if [ ${#group[@]} -eq 0 ]; then
        group=("$f")
        first_time=$file_time
    else
        gap=$(( file_time - last_time ))
        if [ "$gap" -le "$MAX_GAP_SECONDS" ]; then
            group+=("$f")
        else
            join_group
            group=("$f")
            first_time=$file_time
        fi
    fi
    last_time=$file_time
done

# Final group
join_group