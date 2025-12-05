#!/usr/bin/env bash

DEBUG=true
RUN_GET_QBITTORRENT_SAVE_PATHS=true
RUN_GET_QBITTORRENT_FILES=true

IFS_ORIGINAL=$IFS

if $DEBUG; then
    export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    clear
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
OUTPUT_DIRECTORY="./output"
OUTPUT_FILENAME_SAVE_PATHS="qb-save-paths.txt"    # qBittorrent base save paths for existing torrents
OUTPUT_FILENAME_FILE_SYSTEM_ALL_FILES="save-path-all-files.txt"    # All files recursively from OUTPUT_FILENAME_SAVE_PATHS
OUTPUT_FILENAME_ALL_DIRECTORIES="save-path-all-directories.txt"    # All directories recursively from OUTPUT_FILENAME_SAVE_PATHS
OUTPUT_FILENAME_QB="qb-files.txt"    # List of files in qBittorrent's database of currently managed files
FILE_LIST_MISSING_FILENAME="qb-files-missing.txt"    # OUTPUT_FILENAME_QB files that do not exist in the file system 
FILE_LIST_EXISTING_FILENAME="qb-files-existing.txt"    # OUTPUT_FILENAME_QB files that exist in the file system
OUTPUT_FILENAME_FILTERED_FILE_LIST="filtered-file-list.txt"    # Final filtered list of files to remove
OUTPUT_FILENAME_FILTERED_DIRECTORY_LIST="filtered-directory-list.txt"    # Final filtered list of directories to remove
OUTPUT_FILENAME_FILTERED_COMPLETE_LIST="filtered-files-and-directories-list.txt"
OUTPUT_MINIMUM_AGE_DAYS=14    #Minimum age of files to add to output

try mkdir -p "$OUTPUT_DIRECTORY"

ALL_DIRECTORIES_SORTED=()
FILE_SYSTEM_ALL_FILES=()    # All regular files in the file system, recursively from qBittorrent save paths
ALL_DIRECTORIES=()   # All directories in the file system, recursively from qBittorrent save paths
QBIT_MANAGED_FILES=()
QBIT_MANAGED_DIRECTORIES=()
UNMANAGED_FILES=()    # Regular files found in save paths recursively that are not currently managed by qBittorrent
UNMANAGED_DIRECTORIES=()    # Directories found in save paths recursively that are not currently managed by qBittorrent
# associative arrays for uniqueness
declare -A SAVE_PATHS=()    # Base save directories for qBittorrent Categories
declare -A QBIT_ALL_SAVE_PATHS=()    
declare -A PRUNED=()

OUTPUT_MINIMUM_AGE_MINUTES=$(( OUTPUT_MINIMUM_AGE_DAYS*60*24 ))

if $DEBUG; then
    echo "Minimum Age is $OUTPUT_MINIMUM_AGE_MINUTES minutes" >> "$OUTPUT_DIRECTORY"/minimum-age.txt
fi


# Function to authenticate with qBittorrent and get session cookie
qb_login() {
    local URL="$1"
    local USER="$2"
    local PASS="$3"
    local COOKIE_FILE="$4"

    try curl -s -X POST --data "username=$USER&password=$PASS" "$URL/api/v2/auth/login" -c "$COOKIE_FILE" > /dev/null
}

get_qbittorrent_save_paths() {
# Function to get list of files from a qBittorrent instance
    local URL="$1"
    local COOKIE_FILE="$2"

    # Get torrents info (hash, save_path, content_path)
    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL}/api/v2/torrents/info")
     if [[ -z "$COOKIE_FILE" ]]; then
        echo "Failed to log in to qBittorrent at $URL" >&2
        return 1
    fi

    # Get torrents info JSON
    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/info" || echo "[]")

    # Iterate torrents without creating subshells
    while IFS= read -r TORRENT; do
        local HASH SAVE_PATH CONTENT_PATH FILES_JSON FILE_COUNT
        HASH=$(jq -r '.hash' <<<"$TORRENT")
        SAVE_PATH=$(jq -r '.save_path' <<<"$TORRENT")

        # normalize (remove trailing slash)
        SAVE_PATH="${SAVE_PATH%/}"
        CONTENT_PATH="${CONTENT_PATH%/}"

        # record unique save_path
        SAVE_PATHS["$SAVE_PATH"]=1

    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")

    # Output: save_paths
    {
        for SP in "${!SAVE_PATHS[@]}"; do printf '%s\n' "$SP"; done
    }
}
# END get_qbittorrent_save_paths()

get_qbittorrent_files() {
    # Function to get list of files from a qBittorrent instance
    # Output populates FILE_SYSTEM_ALL_FILES QBIT_ALL_SAVE_PATHS
    #
    # To do: confirm the above are being populated correctly
    #
    local URL="$1"
    local COOKIE_FILE="$2"

    # Get torrents info (hash, save_path, content_path)
    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL}/api/v2/torrents/info")
     if [[ -z "$COOKIE_FILE" ]]; then
        echo "Failed to log in to qBittorrent at $URL" >&2
        return 1
    fi

    # Get torrents info JSON
    #local TORRENTS_JSON
    #TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/info" || echo "[]")

    # Iterate torrents without creating subshells
    while IFS= read -r TORRENT; do
        local HASH SAVE_PATH CONTENT_PATH FILES_JSON FILE_COUNT
        HASH=$(jq -r '.hash' <<<"$TORRENT")
        SAVE_PATH=$(jq -r '.save_path' <<<"$TORRENT")
        CONTENT_PATH=$(jq -r '.content_path' <<<"$TORRENT")

        # normalize (remove trailing slash)
        SAVE_PATH="${SAVE_PATH%/}"
        CONTENT_PATH="${CONTENT_PATH%/}"

        # record unique save_path
        SAVE_PATHS["$SAVE_PATH"]=1

        # get files json for this torrent
        FILES_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/files?hash=${HASH}" || echo "[]")
        # safe file count
        FILE_COUNT=$(jq 'length' <<<"$FILES_JSON" 2>/dev/null || echo 0)

        if [[ "$FILE_COUNT" -le 1 ]]; then
            # single-file torrent: content_path should be full file path
            if [[ -n "$CONTENT_PATH" && "$CONTENT_PATH" != "null" ]]; then
                FILE_SYSTEM_ALL_FILES["$CONTENT_PATH"]=1
            else
                # fallback: use files[0].name appended to save_path
                local SINGLE_NAME
                SINGLE_NAME=$(jq -r '.[0].name // ""' <<<"$FILES_JSON")
                if [[ -n "$SINGLE_NAME" ]]; then
                    local FULL="${SAVE_PATH}/${SINGLE_NAME}"
                    FULL="${FULL//\/\//\/}"
                    QBIT_MANAGED_FILES["$FULL"]=1
                fi
            fi
        else
            # multi-file torrent: get list of relative names without subshell
            mapfile -t RELS < <(jq -r '.[] | .name' <<<"$FILES_JSON")
            for REL_NAME in "${RELS[@]}"; do
                # remove any leading slash from REL_NAME and join
                REL_NAME="${REL_NAME#/}"

                local FULL="${SAVE_PATH}/${REL_NAME}"
                FULL="${FULL//\/\//\/}"
                QBIT_MANAGED_FILES["$FULL"]=1
            done
        fi
    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")

    # Build parent directories up to but NOT including the matching save_path
    for FILE_PATH in "${!FILE_SYSTEM_ALL_FILES[@]}"; do
        # normalize
        FILE_PATH="${FILE_PATH%/}"

        # find the longest matching save_path (handles nested save_paths)
        local MATCHING_SAVE=""
        local LONGEST_LEN=0
        for S_P in "${!SAVE_PATHS[@]}"; do
            [[ -z "$S_P" ]] && continue
            if [[ "$FILE_PATH" == "$S_P" ]] || [[ "$FILE_PATH" == "$S_P/"* ]]; then
                local L=${#S_P}
                if (( L > LONGEST_LEN )); then
                    LONGEST_LEN=$L
                    MATCHING_SAVE="$S_P"
                fi
            fi
        done

        [[ -z "$MATCHING_SAVE" ]] && continue

        local DIR_PATH
        DIR_PATH=$(dirname "$FILE_PATH")
        while [[ -n "$DIR_PATH" && "$DIR_PATH" != "/" && "$DIR_PATH" != "$MATCHING_SAVE" ]]; do
            QBIT_ALL_SAVE_PATHS["${DIR_PATH%/}/"]=1
            DIR_PATH=$(dirname "$DIR_PATH")
        done
    done

    # Output: save_paths, directories, files (unique)
    #{
        #for S_P in "${!SAVE_PATHS[@]}"; do printf '%s\n' "$S_P"; done
        #for D in "${!QBIT_ALL_SAVE_PATHS[@]}"; do printf '%s\n' "$D"; done
        #for F in "${!FILE_SYSTEM_ALL_FILES[@]}"; do printf '%s\n' "$F"; done
    #}
}
# END get_qbittorrent_files()


prune_save_paths()
{
    # Prune the directory list to remove nested subfolders
    # Outputs to PRUNED

    #mapfile -t DIRS < "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"
    #IFS=$'\n' DIRS=($(printf "%s\n" "${DIRS[@]}" | sort))
    mapfile -t -d '' DIRS  < <(printf '%s\0' "${!SAVE_PATHS[@]}" | sort -z)

    if $DEBUG; then
        for S_P in "${!SAVE_PATHS[@]}"; do printf '%s\n' "$S_P"; done
        printf '%s\n' "${!SAVE_PATHS[@]}"
        echo "*********"
        for D in "${DIRS[@]}"; do printf '%s\n' "$D"; done

    fi

    for DIR in "${DIRS[@]}"; do
        SKIP=false
        for KEPT in "${PRUNED[@]}"; do
            if [[ "$DIR" == "$KEPT/"* ]]; then
                SKIP=true
                break
            fi
        done
        if ! $SKIP; then
            PRUNED+=("$DIR")
        fi
    done
}


get_save_path_file_and_directory_contents(){
    # Get listing of files and directories within search paths
    # Outputs to FILE_SYSTEM_ALL_FILES and ALL_DIRECTORIES

    for DIR in "${PRUNED[@]}"; do
        # Check directory exists before trying to list
        if [[ -d "$DIR" ]]; then
            # Use command substitution to capture find output into array
            while IFS= read -r FILE; do
                FILE_SYSTEM_ALL_FILES+=("$FILE")
            done < <(find "$DIR" -type f -mmin +$OUTPUT_MINIMUM_AGE_MINUTES 2>/dev/null)
            while IFS= read -r DIRECTORY; do
                ALL_DIRECTORIES+=("$DIRECTORY")
            done < <(find "$DIR" -type d -mmin +$OUTPUT_MINIMUM_AGE_MINUTES 2>/dev/null)
        else
            echo "Warning: '$DIR' is not a valid directory" >&2
        fi
    done
}

sort_directories_by_depth_descending(){
    # Sort directories from deepest to shallowest
    # Output stored in ALL_DIRECTORIES_SORTED
    TMP=()

    for DIR in "${ALL_DIRECTORIES[@]}"; do
        DEPTH=$(grep -o "/" <<< "$DIR" | wc -l)
        TMP+=("$DEPTH:$DIR")
    done

    # Sort numerically by depth (descending)
    SORTED_TMP=$(printf "%s\n" "${TMP[@]}" | sort -t: -k1,1nr)

    # Extract the directory names back into an array
    while IFS= read -r LINE; do
        ALL_DIRECTORIES_SORTED+=("${LINE#*:}")
    done <<< "$SORTED_TMP"
}

filter_qbittorrent_managed_files(){
    local -n FILE_SYSTEM="$1"       # nameref to input array 1 - list of file system entries that exist in the qBittorrent save path recursively
    local -n QBITTORRENT_MANAGED_FILE="$2"        # nameref to input array 2 - list of files actively being managed by qBittorrent
    local -n UNMANAGED_FILE_SYSTEM_ENTRY="$3"       # nameref to output array - output list containing file system entries that are not actively managed by qbittorrent

    declare -A qb_lookup     # associative array for fast membership test
    UNMANAGED_FILE_SYSTEM_ENTRY=()                  # initialize output array

    # Load all qb_files entries into associative array
    for item in "${QBITTORRENT_MANAGED_FILE[@]}"; do
        qb_lookup["$item"]=1
    done

    # Append only entries NOT found in qb_lookup
    for item in "${FILE_SYSTEM[@]}"; do
        if [[ -z "${qb_lookup[$item]}" ]]; then
            UNMANAGED_FILE_SYSTEM_ENTRY+=("$item")
        fi
    done
}


echo "Processing qBittorrent instances..."
try > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"  # clear the output file

# Read qBittorrent instances from the file, retrieve data from qBittorrent instances
while IFS=" " read -r URL USER PASS; do
    if [[ -z "$URL" || -z "$USER" || -z "$PASS" ]]; then
        continue
    fi

    COOKIE_FILE="$OUTPUT_DIRECTORY"/"(echo "$URL" | md5sum | cut -d ' ' -f1)_cookie.txt"

    echo "Authenticating with $URL..."
    try qb_login "$URL" "$USER" "$PASS" "$COOKIE_FILE"

    if $RUN_GET_QBITTORRENT_SAVE_PATHS; then
    {   
        echo "Fetching save paths from $URL..."
        try get_qbittorrent_save_paths "$URL" "$COOKIE_FILE" #>> "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"
        # Output populates QBIT_ALL_SAVE_PATHS
    } 
    fi
    if $RUN_GET_QBITTORRENT_FILES; then
    {
        echo "Fetching file list from $URL..."
        try get_qbittorrent_files "$URL" "$COOKIE_FILE" #>> "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"
        # Outut populates FILE_SYSTEM_ALL_FILES
    }  
    fi
done < <(try grep -v "^#\|^$" "$QB_INSTANCES_FILE")

#try sort -u "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS" -o "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"


try prune_save_paths
# Input takes SAVE_PATHS
# Output populates PRUNED

try get_save_path_file_and_directory_contents
# Input takes PRUNED
# Output populates FILE_SYSTEM_ALL_FILES and ALL_DIRECTORIES

try sort_directories_by_depth_descending
# Input takes ALL_DIRECTORIES
# Output populates ALL_DIRECTORIES_SORTED

try filter_qbittorrent_managed_files FILE_SYSTEM_ALL_FILES[@] QBIT_MANAGED_FILES[@] UNMANAGED_DIRECTORIES
# Required arguments are:
# Input: File system listing array, qBittorrent managed files listing array, 
# Output: Filtered file system array that does not contain files currently managed by qBittorrent

try filter_qbittorrent_managed_files ALL_DIRECTORIES_SORTED[@] QBIT_MANAGED_FILES[@] UNMANAGED_DIRECTORIES
# Required arguments are:
# Input: Sorted Directory array, qBittorrent managed files listing array, 
# Output: Filtered file system array that does not contain files currently managed by qBittorrent

printf "%s\n" "${UNMANAGED_FILES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_FILTERED_FILE_LIST"
printf "%s\n" "${UNMANAGED_DIRECTORIES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_FILTERED_DIRECTORY_LIST"

# Write pruned directory list to temporary file
#TMP_FILE="$(mktemp)"

#printf "%s\n" "${PRUNED[@]}" > "$TMP_FILE"


# Replace the original file
#mv "$TMP_FILE" "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"






#printf "%s\n" "${FILE_SYSTEM_ALL_FILES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_FILE_SYSTEM_ALL_FILES"
#printf "%s\n" "${ALL_DIRECTORIES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_DIRECTORIES"
#printf "%s\n" "${ALL_DIRECTORIES_SORTED[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_DIRECTORIES"