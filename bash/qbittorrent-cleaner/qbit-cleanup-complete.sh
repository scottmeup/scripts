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
die() { yell "$1"; exit "${2:-1}"; }
try() { "$@" || die "Failed: $*"; }

# === Global associative and indexed arrays (MUST be global) ===
declare -A SAVE_PATHS=()
declare -A QBIT_MANAGED_FILES=()      # This is the main one you're missing!
declare -A FILE_SYSTEM_ALL_FILES=()
declare -A ALL_DIRECTORIES_SET=()     # Use assoc array to avoid duplicates
declare -a ALL_DIRECTORIES_SORTED=()
declare -a PRUNED=()
declare -a UNMANAGED_FILES=()
declare -a UNMANAGED_DIRECTORIES=()

# Config
QB_INSTANCES_FILE="qb_instances.lst"
OUTPUT_DIRECTORY="./output"
OUTPUT_MINIMUM_AGE_DAYS=14
OUTPUT_MINIMUM_AGE_MINUTES=$(( OUTPUT_MINIMUM_AGE_DAYS * 1440 ))

mkdir -p "$OUTPUT_DIRECTORY"

[[ ! -f "$QB_INSTANCES_FILE" ]] && die "Missing $QB_INSTANCES_FILE"

# ====================== FUNCTIONS ======================

qb_login() {
    local URL="$1" USER="$2" PASS="$3" COOKIE_FILE="$4"
    curl -s -X POST --data "username=$USER&password=$PASS" \
         "$URL/api/v2/auth/login" -c "$COOKIE_FILE" > /dev/null || return 1
}

get_qbittorrent_save_paths() {
    local URL="$1" COOKIE_FILE="$2"

    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/info" || echo "[]")

    while IFS= read -r torrent; do
        local save_path
        save_path=$(jq -r '.save_path' <<<"$torrent")
        save_path="${save_path%/}"
        [[ -n "$save_path" && "$save_path" != "null" ]] && SAVE_PATHS["$save_path"]=1
    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")
}

get_qbittorrent_files() {
    local URL="$1" COOKIE_FILE="$2"

    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/info" || echo "[]")

    while IFS= read -r torrent; do
        local hash save_path content_path
        hash=$(jq -r '.hash' <<<"$torrent")
        save_path=$(jq -r '.save_path // empty' <<<"$torrent" | sed 's|/$||')
        content_path=$(jq -r '.content_path // empty' <<<"$torrent" | sed 's|/$||')

        [[ -n "$save_path" ]] && SAVE_PATHS["$save_path"]=1

        local files_json
        files_json=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/files?hash=$hash" || echo "[]")

        local file_count
        file_count=$(jq 'length' <<<"$files_json")

        if (( file_count == 0 )); then
            continue
        elif (( file_count == 1 )); then
            # Single-file torrent
            local name
            name=$(jq -r '.[0].name' <<<"$files_json")
            if [[ -n "$content_path" && "$content_path" != "null" ]]; then
                QBIT_MANAGED_FILES["$content_path"]=1
            elif [[ -n "$name" && -n "$save_path" ]]; then
                local full_path="${save_path}/${name#/}"
                QBIT_MANAGED_FILES["${full_path//\/\//\/}"]=1
            fi
        else
            # Multi-file torrent
            while IFS= read -r rel_path; do
                [[ -z "$rel_path" ]] && continue
                local full_path="${save_path}/${rel_path#/}"
                QBIT_MANAGED_FILES["${full_path//\/\//\/}"]=1
            done < <(jq -r '.[].name' <<<"$files_json")
        fi
    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")
}

prune_save_paths() {
    local dir
    local -a sorted=()

    # Get sorted list of save paths
    while IFS= read -r dir; do
        sorted+=("$dir")
    done < <(printf '%s\n' "${!SAVE_PATHS[@]}" | sort -r)

    PRUNED=()
    for dir in "${sorted[@]}"; do
        local skip=false
        for kept in "${PRUNED[@]}"; do
            if [[ "$dir" == "$kept"/* || "$dir" == "$kept" ]]; then
                skip=true
                break
            fi
        done
        "$skip" || PRUNED+=("$dir")
    done
}

scan_filesystem() {
    local dir
    for dir in "${PRUNED[@]}"; do
        [[ -d "$dir" ]] || { yell "Warning: Save path does not exist: $dir"; continue; }

        while IFS= read -r file; do
            FILE_SYSTEM_ALL_FILES["$file"]=1
        done < <(find "$dir" -type f -mmin +"$OUTPUT_MINIMUM_AGE_MINUTES" 2>/dev/null)

        while IFS= read -r subdir; do
            ALL_DIRECTORIES_SET["$subdir"]=1
        done < <(find "$dir" -type d 2>/dev/null)
    done
}

sort_directories_deepest_first() {
    local dir depth
    local -a temp=()

    for dir in "${!ALL_DIRECTORIES_SET[@]}"; do
        depth=$(grep -o '/' <<<"$dir" | wc -l)
        temp+=("$depth:$dir")
    done

    ALL_DIRECTORIES_SORTED=()
    while IFS= read -r line; do
        ALL_DIRECTORIES_SORTED+=("${line#*:}")
    done < <(printf '%s\n' "${temp[@]}" | sort -t: -k1,1nr)
}

filter_unmanaged() {
    local -n filesystem_ref=$1
    local -n managed_ref=$2
    local -n output_ref=$3

    output_ref=()

    for path in "${!filesystem_ref[@]}"; do
        [[ -z "${managed_ref[$path]}" ]] && output_ref+=("$path")
    done
}

# ====================== MAIN ======================

echo "Processing qBittorrent instances..."

while IFS=' ' read -r URL USER PASS || [[ -n "$URL" ]]; do
    [[ -z "$URL" || "$URL" =~ ^# ]] && continue

    COOKIE_FILE="$OUTPUT_DIRECTORY/$(echo "$URL" | md5sum | awk '{print $1}')_cookie.txt"

    echo "Logging into $URL ..."
    qb_login "$URL" "$USER" "$PASS" "$COOKIE_FILE" || { yell "Login failed for $URL"; continue; }

    $RUN_GET_QBITTORRENT_SAVE_PATHS && get_qbittorrent_save_paths "$URL" "$COOKIE_FILE"
    $RUN_GET_QBITTORRENT_FILES && get_qbittorrent_files "$URL" "$COOKIE_FILE"

    rm -f "$COOKIE_FILE"
done < "$QB_INSTANCES_FILE"

echo "Found ${#SAVE_PATHS[@]} unique save paths"
echo "Found ${#QBIT_MANAGED_FILES[@]} managed files"

# Now process filesystem
prune_save_paths
echo "Pruned to ${#PRUNED[@]} top-level save paths"

scan_filesystem
echo "Scanned filesystem: ${#FILE_SYSTEM_ALL_FILES[@]} old files, ${#ALL_DIRECTORIES_SET[@]} directories"

sort_directories_deepest_first

# Filter unmanaged files and directories
filter_unmanaged FILE_SYSTEM_ALL_FILES QBIT_MANAGED_FILES UNMANAGED_FILES
filter_unmanaged ALL_DIRECTORIES_SET    QBIT_MANAGED_FILES UNMANAGED_DIRECTORIES

# === Output Results ===
{
    printf '%s\n' "${UNMANAGED_FILES[@]}" | sort > "$OUTPUT_DIRECTORY/filtered-file-list.txt"
    printf '%s\n' "${UNMANAGED_DIRECTORIES[@]}" | sort -r > "$OUTPUT_DIRECTORY/filtered-directory-list.txt"
    printf '%s\n' "${UNMANAGED_FILES[@]}" "${UNMANAGED_DIRECTORIES[@]}" | sort > "$OUTPUT_DIRECTORY/filtered-files-and-directories-list.txt"
} 

echo "Done!"
echo "Unmanaged old files: ${#UNMANAGED_FILES[@]} → $OUTPUT_DIRECTORY/filtered-file-list.txt"
echo "Unmanaged directories: ${#UNMANAGED_DIRECTORIES[@]} → $OUTPUT_DIRECTORY/filtered-directory-list.txt"1~#!/usr/bin/env bash

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
die() { yell "$1"; exit "${2:-1}"; }
try() { "$@" || die "Failed: $*"; }

# === Global associative and indexed arrays (MUST be global) ===
declare -A SAVE_PATHS=()
declare -A QBIT_MANAGED_FILES=()      # This is the main one you're missing!
declare -A FILE_SYSTEM_ALL_FILES=()
declare -A ALL_DIRECTORIES_SET=()     # Use assoc array to avoid duplicates
declare -a ALL_DIRECTORIES_SORTED=()
declare -a PRUNED=()
declare -a UNMANAGED_FILES=()
declare -a UNMANAGED_DIRECTORIES=()

# Config
QB_INSTANCES_FILE="qb_instances.lst"
OUTPUT_DIRECTORY="./output"
OUTPUT_MINIMUM_AGE_DAYS=14
OUTPUT_MINIMUM_AGE_MINUTES=$(( OUTPUT_MINIMUM_AGE_DAYS * 1440 ))

mkdir -p "$OUTPUT_DIRECTORY"

[[ ! -f "$QB_INSTANCES_FILE" ]] && die "Missing $QB_INSTANCES_FILE"

# ====================== FUNCTIONS ======================

qb_login() {
    local URL="$1" USER="$2" PASS="$3" COOKIE_FILE="$4"
    curl -s -X POST --data "username=$USER&password=$PASS" \
         "$URL/api/v2/auth/login" -c "$COOKIE_FILE" > /dev/null || return 1
}

get_qbittorrent_save_paths() {
    local URL="$1" COOKIE_FILE="$2"

    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/info" || echo "[]")

    while IFS= read -r torrent; do
        local save_path
        save_path=$(jq -r '.save_path' <<<"$torrent")
        save_path="${save_path%/}"
        [[ -n "$save_path" && "$save_path" != "null" ]] && SAVE_PATHS["$save_path"]=1
    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")
}

get_qbittorrent_files() {
    local URL="$1" COOKIE_FILE="$2"

    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/info" || echo "[]")

    while IFS= read -r torrent; do
        local hash save_path content_path
        hash=$(jq -r '.hash' <<<"$torrent")
        save_path=$(jq -r '.save_path // empty' <<<"$torrent" | sed 's|/$||')
        content_path=$(jq -r '.content_path // empty' <<<"$torrent" | sed 's|/$||')

        [[ -n "$save_path" ]] && SAVE_PATHS["$save_path"]=1

        local files_json
        files_json=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/files?hash=$hash" || echo "[]")

        local file_count
        file_count=$(jq 'length' <<<"$files_json")

        if (( file_count == 0 )); then
            continue
        elif (( file_count == 1 )); then
            # Single-file torrent
            local name
            name=$(jq -r '.[0].name' <<<"$files_json")
            if [[ -n "$content_path" && "$content_path" != "null" ]]; then
                QBIT_MANAGED_FILES["$content_path"]=1
            elif [[ -n "$name" && -n "$save_path" ]]; then
                local full_path="${save_path}/${name#/}"
                QBIT_MANAGED_FILES["${full_path//\/\//\/}"]=1
            fi
        else
            # Multi-file torrent
            while IFS= read -r rel_path; do
                [[ -z "$rel_path" ]] && continue
                local full_path="${save_path}/${rel_path#/}"
                QBIT_MANAGED_FILES["${full_path//\/\//\/}"]=1
            done < <(jq -r '.[].name' <<<"$files_json")
        fi
    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")
}

prune_save_paths() {
    local dir
    local -a sorted=()

    # Get sorted list of save paths
    while IFS= read -r dir; do
        sorted+=("$dir")
    done < <(printf '%s\n' "${!SAVE_PATHS[@]}" | sort -r)

    PRUNED=()
    for dir in "${sorted[@]}"; do
        local skip=false
        for kept in "${PRUNED[@]}"; do
            if [[ "$dir" == "$kept"/* || "$dir" == "$kept" ]]; then
                skip=true
                break
            fi
        done
        "$skip" || PRUNED+=("$dir")
    done
}

scan_filesystem() {
    local dir
    for dir in "${PRUNED[@]}"; do
        [[ -d "$dir" ]] || { yell "Warning: Save path does not exist: $dir"; continue; }

        while IFS= read -r file; do
            FILE_SYSTEM_ALL_FILES["$file"]=1
        done < <(find "$dir" -type f -mmin +"$OUTPUT_MINIMUM_AGE_MINUTES" 2>/dev/null)

        while IFS= read -r subdir; do
            ALL_DIRECTORIES_SET["$subdir"]=1
        done < <(find "$dir" -type d 2>/dev/null)
    done
}

sort_directories_deepest_first() {
    local dir depth
    local -a temp=()

    for dir in "${!ALL_DIRECTORIES_SET[@]}"; do
        depth=$(grep -o '/' <<<"$dir" | wc -l)
        temp+=("$depth:$dir")
    done

    ALL_DIRECTORIES_SORTED=()
    while IFS= read -r line; do
        ALL_DIRECTORIES_SORTED+=("${line#*:}")
    done < <(printf '%s\n' "${temp[@]}" | sort -t: -k1,1nr)
}

filter_unmanaged() {
    local -n filesystem_ref=$1
    local -n managed_ref=$2
    local -n output_ref=$3

    output_ref=()

    for path in "${!filesystem_ref[@]}"; do
        [[ -z "${managed_ref[$path]}" ]] && output_ref+=("$path")
    done
}

# ====================== MAIN ======================

echo "Processing qBittorrent instances..."

while IFS=' ' read -r URL USER PASS || [[ -n "$URL" ]]; do
    [[ -z "$URL" || "$URL" =~ ^# ]] && continue

    COOKIE_FILE="$OUTPUT_DIRECTORY/$(echo "$URL" | md5sum | awk '{print $1}')_cookie.txt"

    echo "Logging into $URL ..."
    qb_login "$URL" "$USER" "$PASS" "$COOKIE_FILE" || { yell "Login failed for $URL"; continue; }

    $RUN_GET_QBITTORRENT_SAVE_PATHS && get_qbittorrent_save_paths "$URL" "$COOKIE_FILE"
    $RUN_GET_QBITTORRENT_FILES && get_qbittorrent_files "$URL" "$COOKIE_FILE"

    rm -f "$COOKIE_FILE"
done < "$QB_INSTANCES_FILE"

echo "Found ${#SAVE_PATHS[@]} unique save paths"
echo "Found ${#QBIT_MANAGED_FILES[@]} managed files"

# Now process filesystem
prune_save_paths
echo "Pruned to ${#PRUNED[@]} top-level save paths"

scan_filesystem
echo "Scanned filesystem: ${#FILE_SYSTEM_ALL_FILES[@]} old files, ${#ALL_DIRECTORIES_SET[@]} directories"

sort_directories_deepest_first

# Filter unmanaged files and directories
filter_unmanaged FILE_SYSTEM_ALL_FILES QBIT_MANAGED_FILES UNMANAGED_FILES
filter_unmanaged ALL_DIRECTORIES_SET    QBIT_MANAGED_FILES UNMANAGED_DIRECTORIES

# === Output Results ===
{
    printf '%s\n' "${UNMANAGED_FILES[@]}" | sort > "$OUTPUT_DIRECTORY/filtered-file-list.txt"
    printf '%s\n' "${UNMANAGED_DIRECTORIES[@]}" | sort -r > "$OUTPUT_DIRECTORY/filtered-directory-list.txt"
    printf '%s\n' "${UNMANAGED_FILES[@]}" "${UNMANAGED_DIRECTORIES[@]}" | sort > "$OUTPUT_DIRECTORY/filtered-files-and-directories-list.txt"
} 

echo "Done!"
echo "Unmanaged old files: ${#UNMANAGED_FILES[@]} → $OUTPUT_DIRECTORY/filtered-file-list.txt"
echo "Unmanaged directories: ${#UNMANAGED_DIRECTORIES[@]} → $OUTPUT_DIRECTORY/filtered-directory-list.txt"1~#!/usr/bin/env bash

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
die() { yell "$1"; exit "${2:-1}"; }
try() { "$@" || die "Failed: $*"; }

# === Global associative and indexed arrays (MUST be global) ===
declare -A SAVE_PATHS=()
declare -A QBIT_MANAGED_FILES=()      # This is the main one you're missing!
declare -A FILE_SYSTEM_ALL_FILES=()
declare -A ALL_DIRECTORIES_SET=()     # Use assoc array to avoid duplicates
declare -a ALL_DIRECTORIES_SORTED=()
declare -a PRUNED=()
declare -a UNMANAGED_FILES=()
declare -a UNMANAGED_DIRECTORIES=()

# Config
QB_INSTANCES_FILE="qb_instances.lst"
OUTPUT_DIRECTORY="./output"
OUTPUT_MINIMUM_AGE_DAYS=14
OUTPUT_MINIMUM_AGE_MINUTES=$(( OUTPUT_MINIMUM_AGE_DAYS * 1440 ))

mkdir -p "$OUTPUT_DIRECTORY"

[[ ! -f "$QB_INSTANCES_FILE" ]] && die "Missing $QB_INSTANCES_FILE"

# ====================== FUNCTIONS ======================

qb_login() {
    local URL="$1" USER="$2" PASS="$3" COOKIE_FILE="$4"
    curl -s -X POST --data "username=$USER&password=$PASS" \
         "$URL/api/v2/auth/login" -c "$COOKIE_FILE" > /dev/null || return 1
}

get_qbittorrent_save_paths() {
    local URL="$1" COOKIE_FILE="$2"

    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/info" || echo "[]")

    while IFS= read -r torrent; do
        local save_path
        save_path=$(jq -r '.save_path' <<<"$torrent")
        save_path="${save_path%/}"
        [[ -n "$save_path" && "$save_path" != "null" ]] && SAVE_PATHS["$save_path"]=1
    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")
}

get_qbittorrent_files() {
    local URL="$1" COOKIE_FILE="$2"

    local TORRENTS_JSON
    TORRENTS_JSON=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/info" || echo "[]")

    while IFS= read -r torrent; do
        local hash save_path content_path
        hash=$(jq -r '.hash' <<<"$torrent")
        save_path=$(jq -r '.save_path // empty' <<<"$torrent" | sed 's|/$||')
        content_path=$(jq -r '.content_path // empty' <<<"$torrent" | sed 's|/$||')

        [[ -n "$save_path" ]] && SAVE_PATHS["$save_path"]=1

        local files_json
        files_json=$(curl -s --cookie "$COOKIE_FILE" "${URL%/}/api/v2/torrents/files?hash=$hash" || echo "[]")

        local file_count
        file_count=$(jq 'length' <<<"$files_json")

        if (( file_count == 0 )); then
            continue
        elif (( file_count == 1 )); then
            # Single-file torrent
            local name
            name=$(jq -r '.[0].name' <<<"$files_json")
            if [[ -n "$content_path" && "$content_path" != "null" ]]; then
                QBIT_MANAGED_FILES["$content_path"]=1
            elif [[ -n "$name" && -n "$save_path" ]]; then
                local full_path="${save_path}/${name#/}"
                QBIT_MANAGED_FILES["${full_path//\/\//\/}"]=1
            fi
        else
            # Multi-file torrent
            while IFS= read -r rel_path; do
                [[ -z "$rel_path" ]] && continue
                local full_path="${save_path}/${rel_path#/}"
                QBIT_MANAGED_FILES["${full_path//\/\//\/}"]=1
            done < <(jq -r '.[].name' <<<"$files_json")
        fi
    done < <(jq -c '.[]' <<<"$TORRENTS_JSON")
}

prune_save_paths() {
    local dir
    local -a sorted=()

    # Get sorted list of save paths
    while IFS= read -r dir; do
        sorted+=("$dir")
    done < <(printf '%s\n' "${!SAVE_PATHS[@]}" | sort -r)

    PRUNED=()
    for dir in "${sorted[@]}"; do
        local skip=false
        for kept in "${PRUNED[@]}"; do
            if [[ "$dir" == "$kept"/* || "$dir" == "$kept" ]]; then
                skip=true
                break
            fi
        done
        "$skip" || PRUNED+=("$dir")
    done
}

scan_filesystem() {
    local dir
    for dir in "${PRUNED[@]}"; do
        [[ -d "$dir" ]] || { yell "Warning: Save path does not exist: $dir"; continue; }

        while IFS= read -r file; do
            FILE_SYSTEM_ALL_FILES["$file"]=1
        done < <(find "$dir" -type f -mmin +"$OUTPUT_MINIMUM_AGE_MINUTES" 2>/dev/null)

        while IFS= read -r subdir; do
            ALL_DIRECTORIES_SET["$subdir"]=1
        done < <(find "$dir" -type d 2>/dev/null)
    done
}

sort_directories_deepest_first() {
    local dir depth
    local -a temp=()

    for dir in "${!ALL_DIRECTORIES_SET[@]}"; do
        depth=$(grep -o '/' <<<"$dir" | wc -l)
        temp+=("$depth:$dir")
    done

    ALL_DIRECTORIES_SORTED=()
    while IFS= read -r line; do
        ALL_DIRECTORIES_SORTED+=("${line#*:}")
    done < <(printf '%s\n' "${temp[@]}" | sort -t: -k1,1nr)
}

filter_unmanaged() {
    local -n filesystem_ref=$1
    local -n managed_ref=$2
    local -n output_ref=$3

    output_ref=()

    for path in "${!filesystem_ref[@]}"; do
        [[ -z "${managed_ref[$path]}" ]] && output_ref+=("$path")
    done
}

# ====================== MAIN ======================

echo "Processing qBittorrent instances..."

while IFS=' ' read -r URL USER PASS || [[ -n "$URL" ]]; do
    [[ -z "$URL" || "$URL" =~ ^# ]] && continue

    COOKIE_FILE="$OUTPUT_DIRECTORY/$(echo "$URL" | md5sum | awk '{print $1}')_cookie.txt"

    echo "Logging into $URL ..."
    qb_login "$URL" "$USER" "$PASS" "$COOKIE_FILE" || { yell "Login failed for $URL"; continue; }

    $RUN_GET_QBITTORRENT_SAVE_PATHS && get_qbittorrent_save_paths "$URL" "$COOKIE_FILE"
    $RUN_GET_QBITTORRENT_FILES && get_qbittorrent_files "$URL" "$COOKIE_FILE"

    rm -f "$COOKIE_FILE"
done < "$QB_INSTANCES_FILE"

echo "Found ${#SAVE_PATHS[@]} unique save paths"
echo "Found ${#QBIT_MANAGED_FILES[@]} managed files"

# Now process filesystem
prune_save_paths
echo "Pruned to ${#PRUNED[@]} top-level save paths"

scan_filesystem
echo "Scanned filesystem: ${#FILE_SYSTEM_ALL_FILES[@]} old files, ${#ALL_DIRECTORIES_SET[@]} directories"

sort_directories_deepest_first

# Filter unmanaged files and directories
filter_unmanaged FILE_SYSTEM_ALL_FILES QBIT_MANAGED_FILES UNMANAGED_FILES
filter_unmanaged ALL_DIRECTORIES_SET    QBIT_MANAGED_FILES UNMANAGED_DIRECTORIES

# === Output Results ===
{
    printf '%s\n' "${UNMANAGED_FILES[@]}" | sort > "$OUTPUT_DIRECTORY/filtered-file-list.txt"
    printf '%s\n' "${UNMANAGED_DIRECTORIES[@]}" | sort -r > "$OUTPUT_DIRECTORY/filtered-directory-list.txt"
    printf '%s\n' "${UNMANAGED_FILES[@]}" "${UNMANAGED_DIRECTORIES[@]}" | sort > "$OUTPUT_DIRECTORY/filtered-files-and-directories-list.txt"
} 

echo "Done!"
echo "Unmanaged old files: ${#UNMANAGED_FILES[@]} → $OUTPUT_DIRECTORY/filtered-file-list.txt"
echo "Unmanaged directories: ${#UNMANAGED_DIRECTORIES[@]} → $OUTPUT_DIRECTORY/filtered-directory-list.txt"
