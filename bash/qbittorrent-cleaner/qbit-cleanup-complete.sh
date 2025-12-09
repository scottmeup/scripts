#!/usr/bin/env bash

DEBUG=true

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
declare -A QBIT_MANAGED_FILES=()             # All files currently in use by qBittorrent
declare -A QBIT_SAVE_PATHS=()                     # Base save path for each category with a torrent that was retrieved
declare -A FILE_SYSTEM_ALL_FILES=()          # Recursive listing for all files inside all QBIT_SAVE_PATHS
declare -A FILE_SYSTEM_ALL_DIRECTORIES=()    
declare -a FILE_SYSTEM_ALL_DIRECTORIES_SORTED_LARGEST_DESCENDING=()
declare -a QBIT_SAVE_PATHS_PRUNED=()
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
        [[ -n "$save_path" && "$save_path" != "null" ]] && QBIT_SAVE_PATHS["$save_path"]=1
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

        [[ -n "$save_path" ]] && QBIT_SAVE_PATHS["$save_path"]=1

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
    done < <(printf '%s\n' "${!QBIT_SAVE_PATHS[@]}" | sort -r)

    QBIT_SAVE_PATHS_PRUNED=()
    for dir in "${sorted[@]}"; do
        local skip=false
        for kept in "${QBIT_SAVE_PATHS_PRUNED[@]}"; do
            if [[ "$dir" == "$kept"/* || "$dir" == "$kept" ]]; then
                skip=true
                break
            fi
        done
        "$skip" || QBIT_SAVE_PATHS_PRUNED+=("$dir")
    done
}

scan_filesystem() {
    local dir
    for dir in "${QBIT_SAVE_PATHS_PRUNED[@]}"; do
        [[ -d "$dir" ]] || { yell "Warning: Save path does not exist: $dir"; continue; }

        while IFS= read -r file; do
            FILE_SYSTEM_ALL_FILES["$file"]=1
        done < <(find "$dir" -type f -mmin +"$OUTPUT_MINIMUM_AGE_MINUTES" 2>/dev/null)

        while IFS= read -r subdir; do
            FILE_SYSTEM_ALL_DIRECTORIES["$subdir"]=1
        done < <(find "$dir" -type d 2>/dev/null)
    done
}

sort_directories_deepest_first() {
    local dir depth
    local -a temp=()

    for dir in "${!FILE_SYSTEM_ALL_DIRECTORIES[@]}"; do
        depth=$(grep -o '/' <<<"$dir" | wc -l)
        temp+=("$depth:$dir")
    done

    FILE_SYSTEM_ALL_DIRECTORIES_SORTED_LARGEST_DESCENDING=()
    while IFS= read -r line; do
        FILE_SYSTEM_ALL_DIRECTORIES_SORTED_LARGEST_DESCENDING+=("${line#*:}")
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

dump_all_arrays_to_files() {
    local out="$OUTPUT_DIRECTORY"
    mkdir -p "$out"

    echo "=== Dumping all arrays to individual files in $out ==="

    # 1. Regular indexed arrays
    printf '%s\n' "${QBIT_SAVE_PATHS_PRUNED[@]}"              | sort > "$out/pruned-save-paths.txt"
    printf '%s\n' "${UNMANAGED_FILES[@]}"     | sort > "$out/unmanaged-files.txt"
    printf '%s\n' "${UNMANAGED_DIRECTORIES[@]}"  > "$out/unmanaged-directories.txt"
    printf '%s\n' "${FILE_SYSTEM_ALL_DIRECTORIES_SORTED_LARGEST_DESCENDING[@]}"  > "$out/all-directories-sorted-deepest-first.txt"

    # 2. Associative arrays
    {
        for k in "${!QBIT_SAVE_PATHS[@]}";            do echo "$k"; done
    } | sort > "$out/save-paths-from-qbittorrent.txt"

    {
        for k in "${!QBIT_MANAGED_FILES[@]}";   do echo "$k"; done
    } | sort > "$out/qbittorrent-managed-files.txt"

    {
        for k in "${!FILE_SYSTEM_ALL_FILES[@]}"; do echo "$k"; done
    } | sort > "$out/filesystem-all-files.txt"

    {
        for k in "${!FILE_SYSTEM_ALL_DIRECTORIES[@]}";   do echo "$k"; done
    } | sort > "$out/filesystem-all-directories.txt"

    # Optional: also dump counts in one summary file
    {
        echo "=== ARRAY SIZES $(date) ==="
        echo "Pruned save paths               : ${#QBIT_SAVE_PATHS_PRUNED[@]}"
        echo "qBittorrent save paths          : ${#QBIT_SAVE_PATHS[@]}"
        echo "qBittorrent managed files       : ${#QBIT_MANAGED_FILES[@]}"
        echo "Filesystem all files (>$OUTPUT_MINIMUM_AGE_DAYS d)    : ${#FILE_SYSTEM_ALL_FILES[@]}"
        echo "Filesystem all directories      : ${#FILE_SYSTEM_ALL_DIRECTORIES[@]}"
        echo "Unmanaged files                 : ${#UNMANAGED_FILES[@]}"
        echo "Unmanaged directories           : ${#UNMANAGED_DIRECTORIES[@]}"
    } > "$out/00-ARRAY-SUMMARY.txt"

    echo "All arrays dumped to individual files in $out"
}

# ====================== MAIN ======================

echo "Processing qBittorrent instances..."

while IFS=' ' read -r URL USER PASS || [[ -n "$URL" ]]; do
    [[ -z "$URL" || "$URL" =~ ^# ]] && continue

    COOKIE_FILE="$OUTPUT_DIRECTORY/$(echo "$URL" | md5sum | awk '{print $1}')_cookie.txt"

    echo "Logging into $URL ..."
    qb_login "$URL" "$USER" "$PASS" "$COOKIE_FILE" || { yell "Login failed for $URL"; continue; }

    get_qbittorrent_save_paths "$URL" "$COOKIE_FILE"
    get_qbittorrent_files "$URL" "$COOKIE_FILE"

    rm -f "$COOKIE_FILE"
done < "$QB_INSTANCES_FILE"

echo "Found ${#QBIT_SAVE_PATHS[@]} unique save paths"
echo "Found ${#QBIT_MANAGED_FILES[@]} managed files"

# Now process filesystem
prune_save_paths
echo "Pruned to ${#QBIT_SAVE_PATHS_PRUNED[@]} top-level save paths"

scan_filesystem
echo "Scanned filesystem: ${#FILE_SYSTEM_ALL_FILES[@]} files, ${#FILE_SYSTEM_ALL_DIRECTORIES[@]} directories"

sort_directories_deepest_first

# Filter unmanaged files and directories
filter_unmanaged FILE_SYSTEM_ALL_FILES QBIT_MANAGED_FILES UNMANAGED_FILES
filter_unmanaged FILE_SYSTEM_ALL_DIRECTORIES QBIT_MANAGED_FILES UNMANAGED_DIRECTORIES

# === Output Results ===
{
    printf '%s\n' "${UNMANAGED_FILES[@]}" | sort > "$OUTPUT_DIRECTORY/filtered-file-list.txt"
    printf '%s\n' "${UNMANAGED_DIRECTORIES[@]}" > "$OUTPUT_DIRECTORY/filtered-directory-list.txt"
    printf '%s\n' "${UNMANAGED_FILES[@]}" "${UNMANAGED_DIRECTORIES[@]}" | sort > "$OUTPUT_DIRECTORY/filtered-files-and-directories-list.txt"
    $DEBUG && dump_all_arrays_to_files
} 

echo "Done!"
echo "Unmanaged files: ${#UNMANAGED_FILES[@]} → $OUTPUT_DIRECTORY/filtered-file-list.txt"
echo "Unmanaged directories: ${#UNMANAGED_DIRECTORIES[@]} → $OUTPUT_DIRECTORY/filtered-directory-list.txt"