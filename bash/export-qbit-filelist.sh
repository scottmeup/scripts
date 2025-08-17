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

# Temporary files
TEMP_DIR="/tmp/qb-script"
try mkdir -p "$TEMP_DIR"

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

    try curl -s --cookie "$cookie_file" "$url/api/v2/torrents/info" | jq -r '.[].content_path'
}

echo "Processing qBittorrent instances..."
try > "$TEMP_DIR/qb-files.txt"  # clear the output file

# Read qBittorrent instances from the file
while IFS=" " read -r url user pass; do
    if [[ -z "$url" || -z "$user" || -z "$pass" ]]; then
        continue
    fi

    cookie_file="TEMPDIR/TEMP_DIR/(echo "$url" | md5sum | cut -d ' ' -f1)_cookie.txt"

    echo "Authenticating with $url..."
    try qb_login "$url" "$user" "$pass" "$cookie_file"

    echo "Fetching files from $url..."
    try get_qbittorrent_files "$url" "$cookie_file" >> "$TEMP_DIR/qb-files.txt"
#done < "$QB_INSTANCES_FILE"
done < <(try grep -v "^#\|^$" "$QB_INSTANCES_FILE")

try sort -u "$TEMP_DIR/qb-files.txt" -o "$TEMP_DIR/qb-files.txt"

if $DEBUG; then
        NUMBEROFFILES=`wc -l "$TEMP_DIR"/qb-files.txt | cut -f 1 -d ' '`
        echo "Found $NUMBEROFFILES files:"
        if [ $NUMBEROFFILES -gt 0 ]; then
            cat "$TEMP_DIR/qb-files.txt" | more
        fi
fi
