#!/bin/bash

DEBUG=true

if $DEBUG; then
    set -x
fi

yell() { echo "$0: $*" >&2; }
die() { yell "$1"; exit $2; }
try() { "$@" || die "cannot $*"; }

# File containing qBittorrent instance definitions (one per line: URL USER PASSWORD)
QB_INSTANCES_FILE="qb_instances.lst"

# Output file location
OUTPUT_DIRECTORY="/tmp/qb-script"
OUTPUT_FILENAME_QB="qb-part-files.txt"
try mkdir -p "$OUTPUT_DIRECTORY"

# Function to authenticate with qBittorrent and get session cookie
qb_login() {
    local url="$1"
    local user="$2"
    local pass="$3"
    local cookie_file="$4"

    try curl -s -X POST --data "username=$user&password=$pass" \
        "$url/api/v2/auth/login" -c "$cookie_file" > /dev/null
}

# Function to get list of absolute .part files from a qBittorrent instance
get_qbittorrent_part_files() {
    local url="$1"
    local cookie_file="$2"

    # Get all torrent hashes and their base content_path
    local torrents
    torrents=$(try curl -s --cookie "$cookie_file" "$url/api/v2/torrents/info")

    echo "$torrents" | jq -r '.[] | @base64' | while read -r torrent; do
        _jq() { echo "$torrent" | base64 --decode | jq -r "$1"; }

        local hash content_path
        hash=$(_jq '.hash')
        content_path=$(_jq '.content_path')

        # Fetch files for this torrent
        try curl -s --cookie "$cookie_file" "$url/api/v2/torrents/files?hash=$hash" \
            | jq -r --arg base "$content_path" '.[] | $base + "/" + .name' \
            | grep '\.parts$' || true
    done
}

echo "Processing qBittorrent instances..."
try > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"  # clear the output file

# Read qBittorrent instances from the file
while IFS=" " read -r url user pass; do
    if [[ -z "$url" || -z "$user" || -z "$pass" ]]; then
        continue
    fi

    cookie_file="$TEMPDIR"/"$(echo "$url" | md5sum | cut -d ' ' -f1)_cookie.txt"

    echo "Authenticating with $url..."
    try qb_login "$url" "$user" "$pass" "$cookie_file"

    echo "Fetching .part files from $url..."
    try get_qbittorrent_part_files "$url" "$cookie_file" >> "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"
done < <(try grep -v "^#\|^$" "$QB_INSTANCES_FILE")

if $DEBUG; then
    NUMBEROFFILES=$(wc -l < "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB")
    echo "Found $NUMBEROFFILES .parts files:"
    if [ "$NUMBEROFFILES" -gt 0 ]; then
        echo "3"; sleep 1
        echo "2"; sleep 1
        echo "1"; sleep 1
        try sort -u "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB" -o "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB"
        cat "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB" | more
    fi
fi
