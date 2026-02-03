#!/usr/bin/env bash

# Look at file timestamps - something seems to be not working correctly according to the output

DEBUG=true
set -x

# Parameters
MAX_GAP_SECONDS=3600   # 1 hour
MIN_AGE_SECONDS=7200   # 2 hours
SOURCE_DIR="/mnt/sdc1/temp/cycle_videos"
OUTPUT_DIR="/mnt/sdc1/temp/joined_cycle_videos"
DEBUG_LOG="${OUTPUT_DIR}/debug.log"
DRY_RUN_LOG="${OUTPUT_DIR}/dry_run.log"

# Processing options
DELETE_INPUT_FILES=false     # Set to true to delete original files after processing
PROCESS_WITH_FFMPEG=false     # Set to false to skip ffmpeg processing
FFMPEG_INPUT_ARGS="-y -fflags +igndts"  # FFmpeg input arguments (before -i)
FFMPEG_OUTPUT_ARGS="-c copy -metadata:s:v:0 rotate=180"  # FFmpeg output arguments (after input files)

# Filename timestamp format configuration
# Use the following placeholders in the order they appear in your filename:
#   YYYY or YY   = year (4 or 2 digits)
#   MM or M      = month (2 digits with leading zero, or 1-2 digits)
#   DD or D      = day of month (2 digits with leading zero, or 1-2 digits)
#   HH or H      = hour (2 digits with leading zero, or 1-2 digits)
#   mm or m      = minute (2 digits with leading zero, or 1-2 digits)
#   SS or s      = second (2 digits with leading zero, or 1-2 digits)
# Separate with any delimiter character (e.g., _, -, etc.)
# Example: "YYYY_MMDD_HHmmSS" for filenames like 2025_0630_224951_006.MOV
FILENAME_TIMESTAMP_PATTERN="YYYY_MMDD_HHmmSS"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Initialize log files
echo "=== Script run started at $(date) ===" > "$DEBUG_LOG"
if [ "$PROCESS_WITH_FFMPEG" = false ]; then
    echo "=== Dry-run mode started at $(date) ===" > "$DRY_RUN_LOG"
fi
if [ "$DELETE_INPUT_FILES" = false ]; then
    echo "Note: DELETE_INPUT_FILES=false - original files will be kept" >> "$DEBUG_LOG"
fi

# Get current UNIX time
now=$(date +%s)

# Function to extract timestamp from filename based on pattern
extract_timestamp_from_filename() {
    local filename=$(basename "$1")
    local name_no_ext="${filename%.*}"
    
    echo "DEBUG: Parsing filename: $filename" >> "$DEBUG_LOG"
    echo "DEBUG: Name without ext: $name_no_ext" >> "$DEBUG_LOG"
    
    # Remove trailing _NNN pattern (file sequence number)
    local timestamp_part=$(echo "$name_no_ext" | sed -E 's/_[0-9]+$//')
    echo "DEBUG: After removing sequence: $timestamp_part" >> "$DEBUG_LOG"
    
    # Build regex from pattern
    local pattern="$FILENAME_TIMESTAMP_PATTERN"
    local regex=""
    local year_pos="" month_pos="" day_pos="" hour_pos="" minute_pos="" second_pos=""
    local pos=1
    
    # Replace pattern placeholders with regex capture groups
    while [ -n "$pattern" ]; do
        case "$pattern" in
            YYYY*)
                regex="${regex}([0-9]{4})"
                year_pos=$pos
                pattern="${pattern#YYYY}"
                ((pos++))
                ;;
            YY*)
                regex="${regex}([0-9]{2})"
                year_pos=$pos
                pattern="${pattern#YY}"
                ((pos++))
                ;;
            MM*)
                regex="${regex}([0-9]{2})"
                month_pos=$pos
                pattern="${pattern#MM}"
                ((pos++))
                ;;
            M*)
                regex="${regex}([0-9]{1,2})"
                month_pos=$pos
                pattern="${pattern#M}"
                ((pos++))
                ;;
            DD*)
                regex="${regex}([0-9]{2})"
                day_pos=$pos
                pattern="${pattern#DD}"
                ((pos++))
                ;;
            D*)
                regex="${regex}([0-9]{1,2})"
                day_pos=$pos
                pattern="${pattern#D}"
                ((pos++))
                ;;
            HH*)
                regex="${regex}([0-9]{2})"
                hour_pos=$pos
                pattern="${pattern#HH}"
                ((pos++))
                ;;
            H*)
                regex="${regex}([0-9]{1,2})"
                hour_pos=$pos
                pattern="${pattern#H}"
                ((pos++))
                ;;
            mm*)
                regex="${regex}([0-9]{2})"
                minute_pos=$pos
                pattern="${pattern#mm}"
                ((pos++))
                ;;
            m*)
                regex="${regex}([0-9]{1,2})"
                minute_pos=$pos
                pattern="${pattern#m}"
                ((pos++))
                ;;
            SS*)
                regex="${regex}([0-9]{2})"
                second_pos=$pos
                pattern="${pattern#SS}"
                ((pos++))
                ;;
            s*)
                regex="${regex}([0-9]{1,2})"
                second_pos=$pos
                pattern="${pattern#s}"
                ((pos++))
                ;;
            *)
                # Non-pattern character (delimiter)
                regex="${regex}${pattern:0:1}"
                pattern="${pattern:1}"
                ;;
        esac
    done
    
    echo "DEBUG: Generated regex: ^${regex}$" >> "$DEBUG_LOG"
    echo "DEBUG: Positions - year:$year_pos month:$month_pos day:$day_pos hour:$hour_pos min:$minute_pos sec:$second_pos" >> "$DEBUG_LOG"
    
    # Match against the constructed regex
    if [[ $timestamp_part =~ ^${regex}$ ]]; then
        local year="${BASH_REMATCH[$year_pos]}"
        local month="${BASH_REMATCH[$month_pos]}"
        local day="${BASH_REMATCH[$day_pos]}"
        local hour="${BASH_REMATCH[$hour_pos]:-00}"
        local minute="${BASH_REMATCH[$minute_pos]:-00}"
        local second="${BASH_REMATCH[$second_pos]:-00}"
        
        echo "DEBUG: Matched! year=$year month=$month day=$day hour=$hour minute=$minute second=$second" >> "$DEBUG_LOG"
        
        # Handle 2-digit year
        if [ ${#year} -eq 2 ]; then
            if [ $year -ge 70 ]; then
                year="19${year}"
            else
                year="20${year}"
            fi
        fi
        
        # Pad single digits with leading zeros
        month=$(printf "%02d" $month)
        day=$(printf "%02d" $day)
        hour=$(printf "%02d" $hour)
        minute=$(printf "%02d" $minute)
        second=$(printf "%02d" $second)
        
        # Convert to Unix timestamp
        local result=$(date -d "${year}-${month}-${day} ${hour}:${minute}:${second}" +%s 2>/dev/null)
        echo "DEBUG: Final timestamp: $result" >> "$DEBUG_LOG"
        echo "$result"
    else
        echo "DEBUG: NO MATCH for regex!" >> "$DEBUG_LOG"
        echo "0"
    fi
}

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

# Get sorted list of MOV files
# Extract timestamp from filename for grouping, but use mtime for age checking
declare -a files
declare -a file_timestamps

while IFS= read -r -d '' file; do
    filename_timestamp=$(extract_timestamp_from_filename "$file")
    if [ "$filename_timestamp" != "0" ]; then
        files+=("$file")
        file_timestamps+=("$filename_timestamp")
    fi
done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -iname "*.mov" -print0)

# Sort files by their filename timestamps
if [ ${#files[@]} -eq 0 ]; then
    echo "No eligible MOV files found."
    exit 0
fi

# Create sorted indices
sorted_indices=($(
    for i in "${!file_timestamps[@]}"; do
        echo "$i ${file_timestamps[$i]}"
    done | sort -k2 -n | cut -d' ' -f1
))

group=()
first_time=0
last_time=0

join_group() {
    if [ "${#group[@]}" -ge 1 ]; then
        # Debug: show first_time value
        echo "DEBUG: join_group called with ${#group[@]} files, first_time = $first_time" >> "$DEBUG_LOG"
        echo "DEBUG: Group files:" >> "$DEBUG_LOG"
        for f in "${group[@]}"; do
            echo "  - $f" >> "$DEBUG_LOG"
        done
        
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
            echo "DEBUG: Skipping group - too young (min_age=$min_age, need=$MIN_AGE_SECONDS)" >> "$DEBUG_LOG"
            group=()
            return
        fi
        
        # Format output file name based on first file's timestamp
        if [ "$first_time" -gt 0 ] 2>/dev/null; then
            timestamp=$(date -d @"$first_time" +"%Y-%m-%d_%H-%M-%S")
            echo "DEBUG: Generated timestamp: $timestamp" >> "$DEBUG_LOG"
        else
            echo "ERROR: first_time is not set or invalid: $first_time" | tee -a "$DEBUG_LOG"
            timestamp="unknown"
        fi
        
        if [ "$PROCESS_WITH_FFMPEG" = false ]; then
            echo "Dry-run mode: Would process ${#group[@]} file(s) into ${OUTPUT_DIR}/${timestamp}_*.mov"
            echo "=== Dry-run: Would process ${#group[@]} file(s) ===" >> "$DRY_RUN_LOG"
            echo "Output: ${OUTPUT_DIR}/${timestamp}_*.mov" >> "$DRY_RUN_LOG"
            for f in "${group[@]}"; do
                echo "  - $f"
                echo "  - $f" >> "$DRY_RUN_LOG"
            done
            echo "" >> "$DRY_RUN_LOG"
            group=()
            return
        fi
        
        if [ "${#group[@]}" -eq 1 ]; then
            # Single file - just move it with rotation metadata
            output_file="${OUTPUT_DIR}/${timestamp}_single.mov"
            echo "Moving single file to $output_file"
            echo "DEBUG: Processing single file: $output_file" >> "$DEBUG_LOG"
            
            ffmpeg_cmd="ffmpeg $FFMPEG_INPUT_ARGS -i \"${group[0]}\" $FFMPEG_OUTPUT_ARGS \"$output_file\""
            echo "DEBUG: Command: $ffmpeg_cmd" >> "$DEBUG_LOG"
            
            ffmpeg $FFMPEG_INPUT_ARGS -i "${group[0]}" $FFMPEG_OUTPUT_ARGS "$output_file"
            ffmpeg_status=$?
        else
            # Multiple files - join them
            concat_list=$(mktemp)
            for f in "${group[@]}"; do
                echo "file '$f'" >> "$concat_list"
            done

            output_file="${OUTPUT_DIR}/${timestamp}_joined.mov"
            echo "Joining ${#group[@]} files into $output_file"
            echo "DEBUG: Processing joined file: $output_file" >> "$DEBUG_LOG"
            
            ffmpeg_cmd="ffmpeg $FFMPEG_INPUT_ARGS -f concat -safe 0 -i \"$concat_list\" $FFMPEG_OUTPUT_ARGS \"$output_file\""
            echo "DEBUG: Command: $ffmpeg_cmd" >> "$DEBUG_LOG"
            echo "DEBUG: Concat list contents:" >> "$DEBUG_LOG"
            cat "$concat_list" >> "$DEBUG_LOG"
            
            ffmpeg $FFMPEG_INPUT_ARGS -f concat -safe 0 -i "$concat_list" $FFMPEG_OUTPUT_ARGS "$output_file"
            ffmpeg_status=$?
            rm -f "$concat_list"
        fi

        if [ $ffmpeg_status -eq 0 ]; then
            if [ "$DELETE_INPUT_FILES" = true ]; then
                echo "Processing succeeded. Deleting original files..."
                echo "DEBUG: Processing succeeded. Deleting input files." >> "$DEBUG_LOG"
                for f in "${group[@]}"; do
                    rm -v -- "$f"
                    echo "  Deleted: $f" >> "$DEBUG_LOG"
                done
            else
                echo "Processing succeeded. Keeping original files (DELETE_INPUT_FILES=false)"
                echo "DEBUG: Processing succeeded. Keeping input files (DELETE_INPUT_FILES=false)" >> "$DEBUG_LOG"
                echo "=== Files NOT deleted (DELETE_INPUT_FILES=false) ===" >> "$DRY_RUN_LOG"
                echo "Would have deleted:" >> "$DRY_RUN_LOG"
                for f in "${group[@]}"; do
                    echo "  - $f" >> "$DRY_RUN_LOG"
                done
                echo "" >> "$DRY_RUN_LOG"
            fi
        else
            echo "Processing failed with status $ffmpeg_status. Keeping original files."
            echo "ERROR: Processing failed with status $ffmpeg_status" >> "$DEBUG_LOG"
        fi
    fi
    group=()
}

for idx in "${sorted_indices[@]}"; do
    f="${files[$idx]}"
    file_time="${file_timestamps[$idx]}"
    
    echo "DEBUG: Processing file $f with timestamp $file_time" >> "$DEBUG_LOG"
    
    if [ "$file_time" == "0" ] || [ -z ${file_time+x} ]; then
        echo "Warning: Could not parse timestamp from filename: $f"
        echo "WARNING: Could not parse timestamp from filename: $f" >> "$DEBUG_LOG"
        continue
    fi

    if [ ${#group[@]} -eq 0 ]; then
        group=("$f")
        first_time=$file_time
        echo "DEBUG: Starting new group with first_time=$first_time" >> "$DEBUG_LOG"
    else
        gap=$(( file_time - last_time ))
        echo "DEBUG: Gap between files: $(format_time $gap)" >> "$DEBUG_LOG"
        if [ "$gap" -le "$MAX_GAP_SECONDS" ]; then
            group+=("$f")
            echo "DEBUG: Added to group (gap <= MAX_GAP_SECONDS)" >> "$DEBUG_LOG"
        else
            echo "DEBUG: Gap too large, finalizing current group" >> "$DEBUG_LOG"
            join_group
            group=("$f")
            first_time=$file_time
            echo "DEBUG: Starting new group with first_time=$first_time" >> "$DEBUG_LOG"
        fi
    fi
    last_time=$file_time
done

join_group

echo "=== Script completed at $(date) ===" >> "$DEBUG_LOG"

if $debug; then
    out=$OUTPUT_DIR
    printf '%s\n' "${files[@]}"  > "$out/files.txt"           
    printf '%s\n' "${file_timestamps[@]}"  > "$out/file_timestamps.txt"
    printf '%s\n' "${group[@]}"  > "$out/group.txt" 
fi