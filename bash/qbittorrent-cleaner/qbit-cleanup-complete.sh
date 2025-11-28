#!/usr/bin/env bash

DEBUG=false

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
OUTPUT_DIRECTORY="./output"
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


OUTPUT_MINIMUM_AGE_MINUTES=$(( OUTPUT_MINIMUM_AGE_DAYS*60*24 ))

if $DEBUG; then
    echo "Minimum Age is $OUTPUT_MINIMUM_AGE_MINUTES minutes" >> "$OUTPUT_DIRECTORY"/minimum-age.txt
fi

try mkdir -p "$OUTPUT_DIRECTORY"

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

    # associative arrays for uniqueness
    declare -A SAVE_PATHS=()
    declare -A ALL_FILES=()
    declare -A ALL_DIRS=()

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
    local URL="$1"
    local COOKIE_FILE="$2"

    # Get torrents info (hash, save_path, content_path)
    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL}/api/v2/torrents/info")
     if [[ -z "$COOKIE_FILE" ]]; then
        echo "Failed to log in to qBittorrent at $URL" >&2
        return 1
    fi

    # associative arrays for uniqueness
    declare -A SAVE_PATHS=()
    declare -A ALL_FILES=()
    declare -A ALL_DIRS=()

    # Get torrents info JSON
    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/info" || echo "[]")

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
            mapfile -t RELS < <(jq -r '.[] | .name' <<<"$FILES_JSON")
            for REL_NAME in "${RELS[@]}"; do
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
    for FILE_PATH in "${!ALL_FILES[@]}"; do
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
            ALL_DIRS["${DIR_PATH%/}/"]=1
            DIR_PATH=$(dirname "$DIR_PATH")
        done
    done

    # Output: save_paths, directories, files (unique)
    {
        for S_P in "${!SAVE_PATHS[@]}"; do printf '%s\n' "$S_P"; done
        for D in "${!ALL_DIRS[@]}"; do printf '%s\n' "$D"; done
        for F in "${!ALL_FILES[@]}"; do printf '%s\n' "$F"; done
    }
}
# END get_qbittorrent_files()

echo "Processing qBittorrent instances..."
try > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"  # clear the output file

# Read qBittorrent instances from the file
while IFS=" " read -r URL USER PASS; do
    if [[ -z "$URL" || -z "$USER" || -z "$PASS" ]]; then
        continue
    fi

    COOKIE_FILE="$TEMPDIR"/"(echo "$URL" | md5sum | cut -d ' ' -f1)_cookie.txt"

    echo "Authenticating with $URL..."
    try qb_login "$URL" "$USER" "$PASS" "$COOKIE_FILE"

    echo "Fetching save paths from $URL..."
    try get_qbittorrent_save_paths "$URL" "$COOKIE_FILE" >> "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"
done < <(try grep -v "^#\|^$" "$QB_INSTANCES_FILE")

try sort -u "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS" -o "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"

# Prune the directory list

# Use a temporary file for safe overwrite
TMP_FILE="$(mktemp)"

# Read and sort directories
mapfile -t DIRS < "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"
IFS=$'\n' DIRS=($(printf "%s\n" "${DIRS[@]}" | sort))

PRUNED=()

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

# Write pruned directory list to temporary file
printf "%s\n" "${PRUNED[@]}" > "$TMP_FILE"

# Replace the original file
mv "$TMP_FILE" "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_SAVE_PATHS"

# Get listing of files and directories within search paths
ALL_FILES=()
ALL_DIRECTORIES=()

for dir in "${PRUNED[@]}"; do
    # Check directory exists before trying to list
    if [[ -d "$DIR" ]]; then
        # Use command substitution to capture find output into array
        while IFS= read -r file; do
            ALL_FILES+=("$file")
        done < <(find "$DIR" -type f -mmin +$OUTPUT_MINIMUM_AGE_MINUTES 2>/dev/null)
        while IFS= read -r directory; do
            ALL_DIRECTORIES+=("$DIRectory")
        done < <(find "$DIR" -type d -mmin +$OUTPUT_MINIMUM_AGE_MINUTES 2>/dev/null)
    else
        echo "Warning: '$DIR' is not a valid directory" >&2
    fi
done


# Sort directories from deepest to shallowest
TMP=()

for DIR in "${ALL_DIRECTORIES[@]}"; do
    DEPTH=$(grep -o "/" <<< "$DIR" | wc -l)
    TMP+=("$DEPTH:$DIR")
done

# Sort numerically by depth (descending)
SORTED_TMP=$(printf "%s\n" "${TMP[@]}" | sort -t: -k1,1nr)

# Extract the directory names back into an array
SORTED_DIRECTORIES=()
while IFS= read -r LINE; do
    SORTED_DIRECTORIES+=("${LINE#*:}")
done <<< "$SORTED_TMP"

printf "%s\n" "${ALL_FILES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_FILES"
#printf "%s\n" "${ALL_DIRECTORIES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_DIRECTORIES"
printf "%s\n" "${SORTED_DIRECTORIES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_DIRECTORIES"