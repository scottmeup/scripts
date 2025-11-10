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
OUTPUT_DIRECTORY="/tmp/qb-script"
OUTPUT_FILENAME_QB="qb-save-paths.txt"
try mkdir -p "$OUTPUT_DIRECTORY"

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
try > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"  # clear the output file

# Read qBittorrent instances from the file
while IFS=" " read -r url user pass; do
    if [[ -z "$url" || -z "$user" || -z "$pass" ]]; then
        continue
    fi

    cookie_file="$TEMPDIR"/"(echo "$url" | md5sum | cut -d ' ' -f1)_cookie.txt"

    echo "Authenticating with $url..."
    try qb_login "$url" "$user" "$pass" "$cookie_file"

    echo "Fetching save paths from $url..."
    try get_qbittorrent_save_paths "$url" "$cookie_file" >> "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"
done < <(try grep -v "^#\|^$" "$QB_INSTANCES_FILE")

try sort -u "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB" -o "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"

# Prune the directory list

# Use a temporary file for safe overwrite
TMP_FILE="$(mktemp)"

# Read and sort directories
mapfile -t dirs < "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"
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
mv "$TMP_FILE" "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"

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
            cat "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB" | more
        fi
fi
