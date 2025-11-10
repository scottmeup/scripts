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

# Output file location
OUTPUT_DIRECTORY="/tmp/qb-script"
OUTPUT_FILENAME_QB_PARTS="qb-in-use-parts.txt"
try mkdir -p "$OUTPUT_DIRECTORY"

# Function to authenticate with qBittorrent and get session cookie
qb_login() {
    local url="$1"
    local user="$2"
    local pass="$3"
    local cookie_file="$4"

    try curl -s -X POST --data "username=$user&password=$pass" "$url/api/v2/auth/login" -c "$cookie_file" > /dev/null
}

# Function to get list of in-use .parts files
get_qbittorrent_parts_files() {
    local url="$1"
    local cookie_file="$2"

    # Get torrents: hash + save_path
    try curl -s --cookie "$cookie_file" "$url/api/v2/torrents/info" \
        | jq -r '.[] | [.hash, .save_path] | @tsv' \
        | while IFS=$'\t' read -r hash save_path; do
            parts_file="${save_path}/.${hash}.parts"
            if [[ -f "$parts_file" ]]; then
                echo "$parts_file"
            fi
        done
}

echo "Processing qBittorrent instances..."
try > "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB_PARTS"  # clear the output file

# Read qBittorrent instances from the file
while IFS=" " read -r url user pass; do
    if [[ -z "$url" || -z "$user" || -z "$pass" ]]; then
        continue
    fi

    cookie_file="$TEMPDIR"/"$(echo "$url" | md5sum | cut -d ' ' -f1)_cookie.txt"

    echo "Authenticating with $url..."
    try qb_login "$url" "$user" "$pass" "$cookie_file"

    echo "Fetching in-use .parts files from $url..."
    try get_qbittorrent_parts_files "$url" "$cookie_file" \
        >> "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB_PARTS"
done < <(try grep -v "^#\|^$" "$QB_INSTANCES_FILE")

if $DEBUG; then
    NUMBEROFFILES=$(wc -l < "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB_PARTS")
    echo "Found $NUMBEROFFILES in-use .parts files:"
    if [ "$NUMBEROFFILES" -gt 0 ]; then
        echo "3"; sleep 1
        echo "2"; sleep 1
        echo "1"; sleep 1
        try sort -u "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB_PARTS" -o "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB_PARTS"
        cat "$OUTPUT_DIRECTORY"/"$OUTPUT_FILENAME_QB_PARTS" | more
    fi
fi
