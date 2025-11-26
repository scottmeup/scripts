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
OUTPUT_FILENAME_SAVE_PATHS="qb-save-paths.txt"
OUTPUT_FILENAME_ALL_FILES="save-path-all-files.txt"
OUTPUT_FILENAME_ALL_DIRECTORIES="save-path-all-directories.txt"
OUTPUT_MINIMUM_AGE_DAYS=14    #Minimum age of files to add to output


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
        for SP in "${!SAVE_PATHS[@]}"; do printf '%s\n' "$SP"; done
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

for dir in "${ALL_DIRECTORIES[@]}"; do
    depth=$(grep -o "/" <<< "$DIR" | wc -l)
    TMP+=("$depth:$DIR")
done

# Sort numerically by depth (descending)
SORTED_TMP=$(printf "%s\n" "${TMP[@]}" | sort -t: -k1,1nr)

# Extract the directory names back into an array
SORTED_DIRECTORIES=()
while IFS= read -r LINE; do
    sorted_directories+=("${LINE#*:}")
done <<< "$SORTED_TMP"

printf "%s\n" "${ALL_FILES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_FILES"
#printf "%s\n" "${ALL_DIRECTORIES[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_DIRECTORIES"
printf "%s\n" "${sorted_directories[@]}" > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_ALL_DIRECTORIES"