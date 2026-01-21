#!/usr/bin/env bash

set -x

# Parameters
MAX_GAP_SECONDS=3600   # 1 hour
MIN_AGE_SECONDS=7200   # 2 hours
SOURCE_DIR="/mnt/sdc1/temp/cycle_videos"
OUTPUT_DIR="/mnt/sdc1/temp/joined_cycle_videos"
FILENAME_TIMESTAMP_FORMAT="%Y_%m%d_%H%M%S"  # Format: YYYY_MMDD_HHMMSS (e.g., 2025_0630_224951)

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Get current UNIX time
now=$(date +%s)

# Function to extract timestamp from filename
extract_timestamp_from_filename() {
    local filename=$(basename "$1")
    # Remove extension
    local name_no_ext="${filename%.*}"
    # Extract the timestamp portion (before the last underscore and number)
    # Expected format: YYYY_MMDD_HHMMSS_NNN.MOV
    local timestamp_part=$(echo "$name_no_ext" | sed -E 's/_[0-9]{3}$//')
    
    # Parse based on format
    if [[ $timestamp_part =~ ^([0-9]{4})_([0-9]{4})_([0-9]{6})$ ]]; then
        local year="${BASH_REMATCH[1]}"
        local month_day="${BASH_REMATCH[2]}"
        local time="${BASH_REMATCH[3]}"
        
        local month="${month_day:0:2}"
        local day="${month_day:2:2}"
        local hour="${time:0:2}"
        local minute="${time:2:2}"
        local second="${time:4:2}"
        
        # Convert to Unix timestamp
        date -d "${year}-${month}-${day} ${hour}:${minute}:${second}" +%s 2>/dev/null
    else
        echo "0"
    fi
}

# Get sorted list of MOV files
# Extract timestamp from filename for grouping, but use mtime for age checking
mapfile -t files < <(
    find "$SOURCE_DIR" -maxdepth 1 -type f -iname "*.mov" -print0 |
    while IFS= read -r -d '' file; do
        filename_timestamp=$(extract_timestamp_from_filename "$file")
        if [ "$filename_timestamp" != "0" ]; then
            echo "$filename_timestamp $file"
        fi
    done |
    sort -n | cut -d' ' -f2-
)

if [ "${#files[@]}" -eq 0 ]; then
    echo "No eligible MOV files (present > 2 hrs) found."
    exit 0
fi

group=()
first_time=0
last_time=0

# Function to format seconds into human-readable time
format_time() {
    local total_seconds=$1
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    
    if [ $hours -gt 0 ]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [ $minutes -gt 0 ]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

join_group() {
    if [ "${#group[@]}" -ge 1 ]; then
        # Find the most recent file in the group (highest mtime)
        max_mtime=0
        for f in "${group[@]}"; do
            file_mtime=$(stat -c %Y "$f")
            if [ "$file_mtime" -gt "$max_mtime" ]; then
                max_mtime=$file_mtime
            fi
        done
        
        # Calculate age of most recent file
        min_age=$(( now - max_mtime ))
        
        # Only process if the youngest file is old enough
        if [ "$min_age" -lt "$MIN_AGE_SECONDS" ]; then
            echo "Skipping group - youngest file is only $(format_time $min_age) old (need $(format_time $MIN_AGE_SECONDS))"
            group=()
            return
        fi
        
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
                echo "Dry run, not running rm -v -- $f"
            done
        else
            echo "Processing failed with status $ffmpeg_status. Keeping original files."
        fi
    fi
    group=()
}

for f in "${files[@]}"; do
    # Use filename timestamp for grouping
    file_time=$(extract_timestamp_from_filename "$f")
    
    if [ "$file_time" == "0" ]; then
        echo "Warning: Could not parse timestamp from filename: $f"
        continue
    fi

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