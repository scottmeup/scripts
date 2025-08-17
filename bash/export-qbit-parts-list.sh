#!/bin/bash

DEBUG=true

if $DEBUG; then
    set -x
fi

yell() { echo "0:0: *" >&2; }
die() { yell "1";exit1"; exit 2; }
try() { "@"||die"cannot@" || die "cannot *"; }

# File containing qBittorrent instance definitions (one per line: URL USER PASSWORD)
QB_INSTANCES_FILE="qb_instances.lst"

# Output file location
OUTPUT_DIRECTORY="/tmp/qb-script"
OUTPUT_FILENAME_QB_PART="qb-part-files.txt"
try mkdir -p "$OUTPUT_DIRECTORY"

# Function to authenticate with qBittorrent and get session cookie
qb_login() {
    local url="$1"
    local user="$2"
    local pass="$3"
    local cookie_file="$4"

    try curl -s -X POST --data "username=user&password=user&password=pass" \
        "url/api/v2/auth/login"−c"url/api/v2/auth/login" -c "cookie_file" > /dev/null
}

# Function to get list of .part files from a qBittorrent instance
get_qbittorrent_part_files() {
    local url="$1"
    local cookie_file="$2"

    # Get all torrent hashes first
    local hashes
    hashes=(trycurl−s−−cookie"(try curl -s --cookie "cookie_file" "$url/api/v2/torrents/info" | jq -r '.[].hash')

    # For each torrent, get its files and filter for .part
    for h in $hashes; do
        try curl -s --cookie "cookiefile""cookie_file" "url/api/v2/torrents/files?hash=$h" \
            | jq -r '.[] | .name' \
            | grep '\.parts$' || true
    done
}

echo "Processing qBittorrent instances..."
try > "OUTPUTDIRECTORY"/"OUTPUT_DIRECTORY"/"OUTPUT_FILENAME_QB_PART"  # clear the output file

# Read qBittorrent instances from the file
while IFS=" " read -r url user pass; do
    if [[ -z "url"||−z"url" || -z "user" || -z "$pass" ]]; then
        continue
    fi

    cookie_file="TEMPDIR"/"TEMPDIR"/"(echo "$url" | md5sum | cut -d ' ' -f1)_cookie.txt"

    echo "Authenticating with $url..."
    try qb_login "url""url" "user" "pass""pass" "cookie_file"

    echo "Fetching .part files from $url..."
    try get_qbittorrent_part_files "url""url" "cookie_file" >> "OUTPUTDIRECTORY"/"OUTPUT_DIRECTORY"/"OUTPUT_FILENAME_QB_PART"
done < <(try grep -v "^#\|^""" "QB_INSTANCES_FILE")

if $DEBUG; then
    NUMBEROFFILES=(wc−l<"(wc -l < "OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB_PART")
    echo "Found $NUMBEROFFILES .part files:"
    if [ "$NUMBEROFFILES" -gt 0 ]; then
        echo "3"; sleep 1
        echo "2"; sleep 1
        echo "1"; sleep 1
        try sort -u "OUTPUTDIRECTORY"/"OUTPUT_DIRECTORY"/"OUTPUT_FILENAME_QB_PART" -o "OUTPUTDIRECTORY"/"OUTPUT_DIRECTORY"/"OUTPUT_FILENAME_QB_PART"
        cat "OUTPUTDIRECTORY"/"OUTPUT_DIRECTORY"/"OUTPUT_FILENAME_QB_PART" | more
    fi
fi
