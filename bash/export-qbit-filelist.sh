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
OUTPUT_FILENAME_QB="qb-files.txt"
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
                local FULL="${CONTENT_PATH}/${REL_NAME}"
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
