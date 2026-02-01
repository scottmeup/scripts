#!/usr/bin/env bash
OUTPUT_DIRECTORY="~/array-dump"
mkdir -p "$OUTPUT_DIRECTORY"

declare -a indexed_array_01=()
declare -a indexed_array_02=()
declare -a indexed_array_03=()
declare -a indexed_array_04=()
declare -A ASSOCIATIVE_ARRAY_11=()
declare -A ASSOCIATIVE_ARRAY_12=()
declare -A ASSOCIATIVE_ARRAY_13=()
declare -A ASSOCIATIVE_ARRAY_14=()

populate_arrays(){
    # Your code for data goes here
}

dump_all_arrays_to_files() {
    local out="$OUTPUT_DIRECTORY"

    echo "=== Dumping all arrays to individual files in $out ==="

    # Dump indexed arrays
    printf '%s\n' "${indexed_array_01[@]}"  | sort > "$out/indexed_array_01.txt"    #sorted
    printf '%s\n' "${indexed_array_02[@]}"  | sort > "$out/indexed_array_02.txt"    #sorted
    printf '%s\n' "${indexed_array_03[@]}"  > "$out/indexed_array_03.txt"           #unsorted
    printf '%s\n' "${indexed_array_03[@]}"  > "$out/indexed_array_04.txt"           #unsorted


    # Dump associative arrays. Good idea to keep these sorted for consistent results.
    {
        for k in "${!ASSOCIATIVE_ARRAY_11[@]}"; do echo "$k"; done
    } | sort > "$out/ASSOCIATIVE_ARRAY_11.txt"

    {
        for k in "${!ASSOCIATIVE_ARRAY_12[@]}"; do echo "$k"; done
    } | sort > "$out/ASSOCIATIVE_ARRAY_12.txt"

    {
        for k in "${!ASSOCIATIVE_ARRAY_13[@]}"; do echo "$k"; done
    } | sort > "$out/ASSOCIATIVE_ARRAY_13.txt"

    {
        for k in "${!ASSOCIATIVE_ARRAY_14[@]}"; do echo "$k"; done
    } | sort > "$out/ASSOCIATIVE_ARRAY_14.txt"

    # Dump counts to a summary file
    {
        echo "=== ARRAY SIZES $(date) ==="
        echo "indexed_array_01                          : ${#indexed_array_01[@]}"
        echo "indexed_array_02                          : ${#indexed_array_02[@]}"
        echo "indexed_array_03                          : ${#indexed_array_03[@]}"
        echo "indexed_array_04                          : ${#indexed_array_04[@]}"
        echo "ASSOCIATIVE_ARRAY_11                      : ${#ASSOCIATIVE_ARRAY_11[@]}"
        echo "ASSOCIATIVE_ARRAY_12                      : ${#ASSOCIATIVE_ARRAY_12[@]}"
        echo "ASSOCIATIVE_ARRAY_13                      : ${#ASSOCIATIVE_ARRAY_13[@]}"
        echo "ASSOCIATIVE_ARRAY_14                      : ${#ASSOCIATIVE_ARRAY_14[@]}"
    } > "$out/ARRAY-SUMMARY.txt"

    echo "All arrays dumped to individual files in $out"
}

populate_arrays()
dump_all_arrays_to_files()