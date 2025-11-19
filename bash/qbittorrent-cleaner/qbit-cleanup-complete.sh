#!/usr/bin/env bash

DEBUG=true

if $DEBUG; then
    set -x
fi

yell() { echo "$0: $*" >&2; }
die() { yell "$1"; exit $2; }
try() { "$@" || die "cannot $*"; }


# File containing qBittorrent instance definitions (one per line: URL USER PASSWORD)
QB_INSTANCES_FILE="qb_instances.lst"

if [[ ! -f "$QB_INSTANCES_FILE" ]]; then
  echo "Missing qb_instances.lst file"
  exit 1
fi

# Output file location
OUTPUT_DIRECTORY="/tmp/qb-script"
OUTPUT_FILENAME_SAVE_PATHS="qb-save-paths.txt"    # qBittorrent base save paths for existing torrents
OUTPUT_FILENAME_ALL_FILES="save-path-all-files.txt"    # All files recursively from OUTPUT_FILENAME_SAVE_PATHS
OUTPUT_FILENAME_ALL_DIRECTORIES="save-path-all-directories.txt"    # All directories recursively from OUTPUT_FILENAME_SAVE_PATHS
OUTPUT_FILENAME_QB="qb-files.txt"    # List of files in qBittorrent's database of currently managed files
FILE_LIST_MISSING_FILENAME="qb-files-missing.txt"    # OUTPUT_FILENAME_QB files that do not exist in the file system 
FILE_LIST_EXISTING_FILENAME="qb-files-existing.txt"    # OUTPUT_FILENAME_QB files that exist in the file system
OUTPUT_FILENAME_FILTERED_FILE_LIST="filtered-file-list.txt"    # Final filtered list of files to remove
OUTPUT_FILENAME_FILTERED_DIRECTORY_LIST="filtered-directory-list.txt"    # Final filtered list of directories to remove
OUTPUT_FILENAME_FILTERED_COMPLETE_LIST="filtered-files-and-directories-list.txt"
OUTPUT_MINIMUM_AGE_DAYS=14    #Minimum age of files to add to output

try mkdir -p "$OUTPUT_DIRECTORY"


#
# Begin export of file system contents for paths managed by qBittorrent
# 

OUTPUT_MINIMUM_AGE_MINUTES=$(( OUTPUT_MINIMUM_AGE_DAYS*60*24 ))

if $DEBUG; then
    echo "Minimum Age is $OUTPUT_MINIMUM_AGE_MINUTES minutes" >> "$OUTPUT_DIRECTORY"/minimum-age.txt
fi


# Function to authenticate with qBittorrent and get session cookie
qb_login() {
    local url="$1"
    local user="$2"
    local pass="$3"
    local cookie_file="$4"

    try curl -s -X POST --data "username=$user&password=$pass" "$url/api/v2/auth/login" -c "$cookie_file" > /dev/null
}

# Function to get list of files from a qBittorrent instance
get_qbittorrent_save_paths() {
    local url="$1"
    local cookie_file="$2"

    # Get torrents info (hash, save_path, content_path)
    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$cookie_file" "${url}/api/v2/torrents/info")
     if [[ -z "$cookie_file" ]]; then
        echo "Failed to log in to qBittorrent at $url" >&2
        return 1
    fi

    # associative arrays for uniqueness
    declare -A SAVE_PATHS=()
    declare -A ALL_FILES=()
    declare -A ALL_DIRS=()

    # Get torrents info JSON
    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$cookie_file" "${url%/}/api/v2/torrents/info" || echo "[]")

    # Iterate torrents without creating subshells
    while IFS= read -r torrent; do
        local HASH SAVE_PATH CONTENT_PATH FILES_JSON FILE_COUNT
        HASH=$(jq -r '.hash' <<<"$torrent")
        SAVE_PATH=$(jq -r '.save_path' <<<"$torrent")

        # normalize (remove trailing slash)
        SAVE_PATH="${SAVE_PATH%/}"
        CONTENT_PATH="${CONTENT_PATH%/}"

        # record unique save_path
        SAVE_PATHS["$SAVE_PATH"]=1

    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")

    # Output: save_paths
    {
        for sp in "${!SAVE_PATHS[@]}"; do printf '%s\n' "$sp"; done
    }
}
# END get_qbittorrent_files()

echo "Processing qBittorrent instances..."
try > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"  # clear the output file

# Read qBittorrent instances from the file
while IFS=" " read -r url user pass; do
    if [[ -z "$url" || -z "$user" || -z "$pass" ]]; then
        continue
    fi

    cookie_file="$TEMPDIR"/"(echo "$url" | md5sum | cut -d ' ' -f1)_cookie.txt"

    echo "Authenticating with $url..."
    try qb_login "$url" "$user" "$pass" "$cookie_file"

    echo "Fetching save paths from $url..."
    try get_qbittorrent_save_paths "$url" "$cookie_file" >> "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"
done < <(try grep -v "^#\|^$" "$QB_INSTANCES_FILE")

# This method overwrites the existing file. Consider using a temporary intermediary file
try sort -u "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS" -o "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"

# Prune the directory list

# Use a temporary file for safe overwrite
TMP_FILE="$(mktemp)"

# Read and sort directories
mapfile -t dirs < "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"
IFS=$'\n' dirs=($(printf "%s\n" "${dirs[@]}" | sort))

pruned=()

for dir in "${dirs[@]}"; do
    skip=false
    for kept in "${pruned[@]}"; do
        if [[ "$dir" == "$kept/"* ]]; then
            skip=true
            break
        fi
    done
    if ! $skip; then
        pruned+=("$dir")
    fi
done

# Write pruned list to temporary file
printf "%s\n" "${pruned[@]}" > "$TMP_FILE"

# Replace the original file
mv "$TMP_FILE" "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"

# Get listing of files and directories within search paths
ALL_FILES=()
ALL_DIRECTORIES=()

for dir in "${pruned[@]}"; do
    # Check directory exists before trying to list
    if [[ -d "$dir" ]]; then
        # Use command substitution to capture find output into array
        while IFS= read -r file; do
            ALL_FILES+=("$file")
        done < <(find "$dir" -type f -mmin +$OUTPUT_MINIMUM_AGE_MINUTES 2>/dev/null)
        while IFS= read -r directory; do
            ALL_DIRECTORIES+=("$directory")
        done < <(find "$dir" -type d -mmin +$OUTPUT_MINIMUM_AGE_MINUTES 2>/dev/null)
    else
        echo "Warning: '$dir' is not a valid directory" >&2
    fi
done


# Sort directories from deepest to shallowest
tmp=()

for dir in "${ALL_DIRECTORIES[@]}"; do
    depth=$(grep -o "/" <<< "$dir" | wc -l)
    tmp+=("$depth:$dir")
done

# Sort numerically by depth (descending)
sorted_tmp=$(printf "%s\n" "${tmp[@]}" | sort -t: -k1,1nr)

# Extract the directory names back into an array
SORTED_DIRECTORIES=()
while IFS= read -r line; do
    SORTED_DIRECTORIES+=("${line#*:}")
done <<< "$sorted_tmp"

printf "%s\n" "${ALL_FILES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_FILES"
printf "%s\n" "${SORTED_DIRECTORIES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_DIRECTORIES"

if $DEBUG; then
    NUMBER_OF_SAVE_PATHS=`wc -l "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS" | cut -f 1 -d ' '`
    NUMBER_OF_FILES=`wc -l "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_FILES" | cut -f 1 -d ' '`
    NUMBER_OF_DIRECTORIES=`wc -l "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_DIRECTORIES" | cut -f 1 -d ' '`
    echo "Found $NUMBER_OF_SAVE_PATHS save paths, $NUMBER_OF_FILES files, $NUMBER_OF_DIRECTORIES directories:"
    if [ $NUMBER_OF_FILES -gt 0 ]; then
        echo "3"
        sleep 1
        echo "2"
        sleep 1
        echo "1"
        sleep 1
        cat "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_FILES"  #| more
    fi
fi

#
# End export of file system contents for paths managed by qBittorrent
# 



#
# Begin export of qBittorrent file database
# 


# Function to get list of files from a qBittorrent instance
get_qbittorrent_files() {
    local url="$1"
    local cookie_file="$2"

    # Get torrents info (hash, save_path, content_path)
    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$cookie_file" "${url}/api/v2/torrents/info")
     if [[ -z "$cookie_file" ]]; then
        echo "Failed to log in to qBittorrent at $url" >&2
        return 1
    fi

    # associative arrays for uniqueness
    declare -A SAVE_PATHS=()
    declare -A ALL_FILES=()
    declare -A ALL_DIRS=()

    # Get torrents info JSON
    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$cookie_file" "${url%/}/api/v2/torrents/info" || echo "[]")

    # Iterate torrents without creating subshells
    while IFS= read -r torrent; do
        local HASH SAVE_PATH CONTENT_PATH FILES_JSON FILE_COUNT
        HASH=$(jq -r '.hash' <<<"$torrent")
        SAVE_PATH=$(jq -r '.save_path' <<<"$torrent")
        CONTENT_PATH=$(jq -r '.content_path' <<<"$torrent")

        # normalize (remove trailing slash)
        SAVE_PATH="${SAVE_PATH%/}"
        CONTENT_PATH="${CONTENT_PATH%/}"

        # record unique save_path
        SAVE_PATHS["$SAVE_PATH"]=1

        # get files json for this torrent
        FILES_JSON=$(curl -s --cookie "$cookie_file" "${url%/}/api/v2/torrents/files?hash=${HASH}" || echo "[]")
        # safe file count
        FILE_COUNT=$(jq 'length' <<<"$FILES_JSON" 2>/dev/null || echo 0)

        if [[ "$FILE_COUNT" -le 1 ]]; then
            # single-file torrent: content_path should be full file path
            if [[ -n "$CONTENT_PATH" && "$CONTENT_PATH" != "null" ]]; then
                ALL_FILES["$CONTENT_PATH"]=1
            else
                # fallback: use files[0].name appended to save_path
                local SINGLE_NAME
                SINGLE_NAME=$(jq -r '.[0].name // ""' <<<"$FILES_JSON")
                if [[ -n "$SINGLE_NAME" ]]; then
                    local FULL="${SAVE_PATH}/${SINGLE_NAME}"
                    FULL="${FULL//\/\//\/}"
                    ALL_FILES["$FULL"]=1
                fi
            fi
        else
            # multi-file torrent: get list of relative names without subshell
            mapfile -t rels < <(jq -r '.[] | .name' <<<"$FILES_JSON")
            for REL_NAME in "${rels[@]}"; do
                # remove any leading slash from REL_NAME and join
                REL_NAME="${REL_NAME#/}"
                #
                # Pretty sure bug is here: CONTENT_PATH and REL_NAME both contain the base folder of the data
                #
                #local FULL="${CONTENT_PATH}/${REL_NAME}"
                local FULL="${SAVE_PATH}/${REL_NAME}"
                FULL="${FULL//\/\//\/}"
                ALL_FILES["$FULL"]=1
            done
        fi
    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")

    # Build parent directories up to but NOT including the matching save_path
    for file_path in "${!ALL_FILES[@]}"; do
        # normalize
        file_path="${file_path%/}"

        # find the longest matching save_path (handles nested save_paths)
        local matching_save=""
        local longest_len=0
        for sp in "${!SAVE_PATHS[@]}"; do
            [[ -z "$sp" ]] && continue
            if [[ "$file_path" == "$sp" ]] || [[ "$file_path" == "$sp/"* ]]; then
                local l=${#sp}
                if (( l > longest_len )); then
                    longest_len=$l
                    matching_save="$sp"
                fi
            fi
        done

        [[ -z "$matching_save" ]] && continue

        local dirpath
        dirpath=$(dirname "$file_path")
        while [[ -n "$dirpath" && "$dirpath" != "/" && "$dirpath" != "$matching_save" ]]; do
            ALL_DIRS["${dirpath%/}/"]=1
            dirpath=$(dirname "$dirpath")
        done
    done

    # Output: save_paths, directories, files (unique)
    {
        for sp in "${!SAVE_PATHS[@]}"; do printf '%s\n' "$sp"; done
        for d in "${!ALL_DIRS[@]}"; do printf '%s\n' "$d"; done
        for f in "${!ALL_FILES[@]}"; do printf '%s\n' "$f"; done
    }
}
# END get_qbittorrent_files()

echo "Processing qBittorrent instances..."
try > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"  # clear the output file


# Read qBittorrent instances from the file
while IFS=" " read -r url user pass; do
    if [[ -z "$url" || -z "$user" || -z "$pass" ]]; then
        continue
    fi

    cookie_file="$TEMPDIR"/"(echo "$url" | md5sum | cut -d ' ' -f1)_cookie.txt"

    echo "Authenticating with $url..."
    try qb_login "$url" "$user" "$pass" "$cookie_file"

    echo "Fetching files from $url..."
    try get_qbittorrent_files "$url" "$cookie_file" >> "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"
done < <(try grep -v "^#\|^$" "$QB_INSTANCES_FILE")

try sort -u "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB" -o "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"


# Check files in the list exist, create a list of missing files and existing files

if [[ -e "$OUTPUT_DIRECTORY"/"$FILE_LIST_MISSING_FILENAME" ]]; then
    try rm "$OUTPUT_DIRECTORY"/"$FILE_LIST_MISSING_FILENAME"
fi
if [[ -e "$OUTPUT_DIRECTORY"/"$FILE_LIST_EXISTING_FILENAME" ]]; then
        try rm "$OUTPUT_DIRECTORY"/"$FILE_LIST_EXISTING_FILENAME"
fi

declare -A FILES_EXISTING=()
declare -A FILES_MISSING=()
declare -A QBITTORRENT_UNMANAGED_FILES=()
declare -A QBITTORRENT_UNMANAGED_DIRECTORIES=()

while IFS= read -r file; do
    if ! [[ -e $file ]]; then
        if $DEBUG; then
            printf '%s does not exist\n' "$file"
        fi
        #printf '%s\n' "$file" >> "$OUTPUT_DIRECTORY"/"$FILE_LIST_MISSING_FILENAME"
        FILES_MISSING["$file"]=1
        else
        #printf '%s\n' "$file" >> "$OUTPUT_DIRECTORY"/"$FILE_LIST_EXISTING_FILENAME"
        FILES_EXISTING["$file"]=1
    fi
done < <(try cat "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB")

# try to make this more generic to cut down code duplication
output_file_list_qbittorrent_existing(){
     for file in "${!FILES_EXISTING[@]}"; do printf '%s\n' "$file"; done
}

# try to make this more generic to cut down code duplication
output_file_list_qbittorrent_missing(){
     for file in "${!FILES_MISSING[@]}"; do printf '%s\n' "$file"; done
}


# Function to find common elements using associative arrays
find_common_elements_associative() {
    local -n _all="$1"       # nameref to input array 1
    local -n _qb="$2"        # nameref to input array 2
    local -n _out="$3"       # nameref to output array

    declare -A qb_lookup     # associative array for fast membership test
    _out=()                  # initialize output array

    # Load all qb_files entries into associative array
    for item in "${_qb[@]}"; do
        qb_lookup["$item"]=1
    done

    # Append only entries NOT found in qb_lookup
    for item in "${_all[@]}"; do
        if [[ -z "${qb_lookup[$item]}" ]]; then
            _out+=("$item")
        fi
    done
}

# Function to find unique elements using associative arrays
find_non_common_elements_associative() {
    local -n _all="$1"       # nameref to input array 1
    local -n _qb="$2"        # nameref to input array 2
    local -n _out="$3"       # nameref to output array

    declare -A qb_lookup     # associative array for fast membership test
    _out=()                  # initialize output array

    # Load all qb_files entries into associative array
    for item in "${_qb[@]}"; do
        qb_lookup["$item"]=1
    done

    # Append only entries found in qb_lookup
    for item in "${_all[@]}"; do
        if [[ -n "${qb_lookup[$item]}" ]]; then
            _out+=("$item")
        fi
    done
}


find_common_elements_associative ALL_FILES[@] FILES_EXISTING[@] QBITTORRENT_UNMANAGED_FILES
find_common_elements_associative ALL_FILES[@] ALL_DIRS[@] QBITTORRENT_UNMANAGED_DIRECTORIES

output_file_list_filtered_files(){
    for file in "${!QBITTORRENT_UNMANAGED_FILES[@]}"; do printf '%s\n' "$file" 
         if $DEBUG; then
            printf '%s\n' "$file" > "$OUTPUT_DIRECTORY"/debug_directory_output.txt
         fi;
    done 
}


output_file_list_filtered_directories(){
    for file in "${!QBITTORRENT_UNMANAGED_DIRECTORIES[@]}"; do printf '%s\n' "$file" 
         if $DEBUG; then
            printf '%s\n' "$file" > "$OUTPUT_DIRECTORY"/debug_directory_output.txt
         fi;
    done 
}



# output result files
try output_file_list_qbittorrent_existing > "$OUTPUT_DIRECTORY"/"$FILE_LIST_EXISTING_FILENAME"
try output_file_list_qbittorrent_missing > "$OUTPUT_DIRECTORY"/"$FILE_LIST_MISSING_FILENAME"
#try output_file_list_filtered_files > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_FILTERED_COMPLETE_LIST"
#try output_file_list_filtered_directories >> "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_FILTERED_COMPLETE_LIST"


{
    output_file_list_filtered_files
    output_file_list_filtered_directories
} > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_FILTERED_COMPLETE_LIST"


if $DEBUG; then
        NUMBEROFFILES=`wc -l "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB" | cut -f 1 -d ' '`
        echo "Found $NUMBEROFFILES files:"
        if [ $NUMBEROFFILES -gt 0 ]; then
            echo "3"
            sleep 1
            echo "2"
            sleep 1
            echo "1"
            sleep 1
            cat "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB" # | more
        fi
fi


#
# End export of qBittorrent file database
# 

