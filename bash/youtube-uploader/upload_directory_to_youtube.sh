#!/usr/bin/env bash

# Easy run script for uploading a folder contents to youtube. 
# Designed to work with https://github.com/porjo/youtubeuploader

# Config
DIR="/mnt/sdc1/temp/joined"    # Directory of files to upload
CACHE="/opt/config/youtubeuploader/request.token"
SECRETS="/opt/config/youtubeuploader/client_secrets.json"
PLAYLIST=""      # ID of playlist to add uploads to
PRIVACY="unlisted"
RATELIMIT="8550"    # Upload limit in kbps

# Find files not modified in the last 1 hour, sorted oldest to newest
FILES=(find "(find "DIR" -type f -mmin +60 -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)

# Check if any files were found
if [[ -z "$FILES" ]]; then
    echo "No files to upload in $DIR (older than 1 hour)"
    exit 0
fi

# Loop over files
while IFS= read -r FILE; do
    echo "Uploading: $FILE"

    youtubeuploader -cache "CACHE" -secrets "CACHE" -secrets "SECRETS" -ratelimit "$RATELIMIT" \
        -filename "FILE" -playlistID "FILE" -playlistID "PLAYLIST" -privacy "$PRIVACY"

    if [[ $? -eq 0 ]]; then
        echo "Successfully uploaded: $FILE"
        rm -f "$FILE"
    else
        echo "Failed to upload: $FILE"
    fi

done <<< "$FILES"
