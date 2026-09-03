#!/usr/bin/env bash
# Shared, deliberately small helpers for software-only evidence tooling.

evidence_die() { printf 'error: %s\n' "$*" >&2; return 1; }

evidence_sha256() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$file" | awk '{print $1}'
    else
        evidence_die 'no portable SHA-256 utility found'
    fi
}

evidence_sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        evidence_die 'no portable SHA-256 utility found'
    fi
}

evidence_abs_regular() {
    local path=${1:-}
    [[ $path == /* ]] || evidence_die "path is not absolute: $path"
    [[ ! -L $path ]] || evidence_die "symlink is not allowed: $path"
    [[ -f $path ]] || evidence_die "regular file required: $path"
}

evidence_abs_dir() {
    local path=${1:-}
    [[ $path == /* ]] || evidence_die "path is not absolute: $path"
    [[ ! -L $path ]] || evidence_die "symlink is not allowed: $path"
    [[ -d $path ]] || evidence_die "directory required: $path"
}

evidence_readonly() {
    local path=$1 mode
    evidence_abs_regular "$path"
    mode=$(stat -c '%a' -- "$path" 2>/dev/null || stat -f '%Lp' -- "$path") || evidence_die "cannot inspect permissions: $path"
    [[ $mode =~ ^[0-7]+$ && $mode != *[2367]* ]] || evidence_die "file is writable: $path"
}

evidence_path_under() {
    local evidence_path=$1 allowed_root=${2%/} canonical_root canonical_candidate canonical_parent parent cursor component physical_cursor
    local entered_root=0 component_is_link=0
    local -a components
    [[ -n "$allowed_root" ]] || allowed_root=/
    [[ $evidence_path == /* && $allowed_root == /* ]] || { evidence_die 'path and root must be absolute'; return 1; }
    [[ $evidence_path != *$'\n'* && $allowed_root != *$'\n'* ]] || { evidence_die 'path and root must not contain newlines'; return 1; }
    [[ ! $evidence_path =~ (^|/)\.\.?(/|$) && ! $allowed_root =~ (^|/)\.\.?(/|$) ]] || { evidence_die "unsafe path: $evidence_path"; return 1; }
    [[ -d $allowed_root && ! -L $allowed_root ]] || { evidence_die "allowed root is not a directory: $allowed_root"; return 1; }
    canonical_root=$(cd -P -- "$allowed_root" && pwd -P) || { evidence_die "cannot resolve allowed root: $allowed_root"; return 1; }
    [[ $canonical_root != / ]] || entered_root=1
    [[ ! -L $evidence_path ]] || { evidence_die "path is a symlink: $evidence_path"; return 1; }

    if [[ -d $evidence_path ]]; then
        canonical_candidate=$(cd -P -- "$evidence_path" && pwd -P) || { evidence_die "cannot resolve path: $evidence_path"; return 1; }
        [[ $canonical_candidate != "$canonical_root" ]] || return 0
    fi
    parent=$(dirname -- "$evidence_path")
    [[ -d $parent ]] || { evidence_die "path parent is not a directory: $parent"; return 1; }
    canonical_parent=$(cd -P -- "$parent" && pwd -P) || { evidence_die "cannot resolve path parent: $parent"; return 1; }
    [[ $canonical_parent == "$canonical_root" || $canonical_parent == "$canonical_root"/* ]] || { evidence_die "path is outside allowed root: $evidence_path"; return 1; }

    cursor=/
    IFS=/ read -r -a components <<< "${parent#/}"
    for component in "${components[@]}"; do
        [[ -n $component ]] || continue
        [[ $cursor == / ]] && cursor="/$component" || cursor="$cursor/$component"
        [[ -L $cursor ]] && component_is_link=1 || component_is_link=0
        [[ -d $cursor ]] || { evidence_die "path ancestor is not a directory: $cursor"; return 1; }
        physical_cursor=$(cd -P -- "$cursor" && pwd -P) || { evidence_die "cannot resolve path ancestor: $cursor"; return 1; }
        if (( entered_root == 1 && component_is_link == 1 )); then
            evidence_die "symlinked path ancestor below allowed root: $cursor"
            return 1
        fi
        if [[ $physical_cursor == "$canonical_root" ]]; then
            entered_root=1
        elif [[ $physical_cursor == "$canonical_root"/* ]]; then
            if (( entered_root == 0 && component_is_link == 1 )); then
                evidence_die "symlinked path ancestor enters below allowed root: $cursor"
                return 1
            fi
            entered_root=1
        fi
    done
    (( entered_root == 1 )) || { evidence_die "path does not enter allowed root: $evidence_path"; return 1; }
}

evidence_new_dir() {
    local dir=$1 parent
    [[ $dir == /* ]] || evidence_die "output path is not absolute: $dir"
    [[ ! -e $dir && ! -L $dir ]] || evidence_die "output already exists: $dir"
    parent=$(dirname -- "$dir")
    [[ -d $parent && ! -L $parent ]] || evidence_die "output parent must already exist: $parent"
    mkdir -m 700 -- "$dir" || evidence_die "cannot create output: $dir"
}

evidence_new_file() {
    local file=$1
    [[ ! -e $file && ! -L $file ]] || evidence_die "file already exists: $file"
    (umask 077; : >"$file") || evidence_die "cannot create file: $file"
}

evidence_atomic_publish_directory() {
    local source=$1 destination=$2
    command -v python3 >/dev/null 2>&1 || evidence_die 'python3 is required for atomic output publication'
    python3 - "$source" "$destination" <<'PY'
import ctypes
import os
import platform
import sys

source, destination = (os.fsencode(value) for value in sys.argv[1:3])
libc = ctypes.CDLL(None, use_errno=True)
at_fdcwd = -100

if sys.platform == "darwin":
    function = getattr(libc, "renameatx_np", None)
    if function is None:
        print("atomic no-replace publish is unavailable: renameatx_np", file=sys.stderr)
        raise SystemExit(1)
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    result = function(at_fdcwd, source, at_fdcwd, destination, 0x00000004)  # RENAME_EXCL
else:
    function = getattr(libc, "renameat2", None)
    if function is not None:
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        result = function(at_fdcwd, source, at_fdcwd, destination, 0x1)  # RENAME_NOREPLACE
    else:
        syscall_number = {"x86_64": 316, "amd64": 316, "aarch64": 276, "arm64": 276}.get(platform.machine().lower())
        if syscall_number is None:
            print("atomic no-replace publish is unavailable on this Linux architecture", file=sys.stderr)
            raise SystemExit(1)
        function = libc.syscall
        function.restype = ctypes.c_long
        result = function(syscall_number, at_fdcwd, source, at_fdcwd, destination, 0x1)  # RENAME_NOREPLACE

if result != 0:
    error = ctypes.get_errno()
    print(f"atomic no-replace publish failed: [{error}] {os.strerror(error)}", file=sys.stderr)
    raise SystemExit(1)
PY
}

evidence_kv() {
    local file=$1 key=$2
    awk -v wanted="$key" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        !/^[A-Za-z_][A-Za-z0-9_]*=[^[:cntrl:]]*$/ { exit 2 }
        { split($0, a, "="); if (a[1] == wanted) { print substr($0, index($0, "=") + 1); found++ } }
        END { if (found != 1) exit 3 }
    ' "$file" || evidence_die "invalid or missing key $key in $file"
}

evidence_require_keys() {
    local file=$1 key
    evidence_abs_regular "$file"
    for key in "${@:2}"; do evidence_kv "$file" "$key" >/dev/null || return; done
}

evidence_hash_file() {
    local file=$1 hash=$2 actual
    evidence_abs_regular "$file"
    actual=$(evidence_sha256 "$file")
    [[ $actual == "$hash" ]] || evidence_die "hash mismatch: $file"
}

evidence_copy_regular_tree() {
    local source=$1 destination=$2 rel target parent
    evidence_abs_dir "$source"
    while IFS= read -r -d '' file; do
        [[ ! -L $file ]] || evidence_die "symlink is not allowed: $file"
        rel=${file#"$source"/}
        [[ $rel != /* && $rel != *'/'../* && $rel != ../* && $rel != *'/'.. ]] || evidence_die "unsafe relative path: $rel"
        target="$destination/$rel"
        parent=$(dirname -- "$target")
        mkdir -p -m 700 -- "$parent"
        [[ ! -e $target && ! -L $target ]] || evidence_die "duplicate destination: $target"
        cp -p -- "$file" "$target"
    done < <(find -P "$source" -type f -print0 | sort -z)
}

evidence_verify_sums() {
    local root=$1 sums=$2 hash rel file
    evidence_abs_dir "$root"
    evidence_abs_regular "$sums"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^([[:xdigit:]]{64})[[:space:]]{2}([^[:space:]]+)$ ]] || evidence_die "invalid SHA256SUMS line"
        hash=${BASH_REMATCH[1]}; rel=${BASH_REMATCH[2]}
        [[ $rel != /* && $rel != *'/'../* && $rel != ../* && $rel != *'/'.. && $rel != SHA256SUMS ]] || evidence_die "unsafe checksum path: $rel"
        file="$root/$rel"
        evidence_abs_regular "$file"
        [[ $(evidence_sha256 "$file") == "$hash" ]] || evidence_die "checksum mismatch: $rel"
    done < "$sums"
    while IFS= read -r -d '' file; do
        rel=${file#"$root"/}
        [[ $rel == SHA256SUMS ]] && continue
        grep -F -x -- "$rel" < <(sed -E 's/^[[:xdigit:]]{64}[[:space:]]{2}//' "$sums") >/dev/null || evidence_die "missing checksum: $rel"
    done < <(find -P "$root" -type f -print0)
}

evidence_validate_identity() {
    local file=$1
    evidence_require_keys "$file" model board soc
    [[ $(evidence_kv "$file" model) == Mac15,6 ]] || evidence_die 'identity model is not Mac15,6'
    [[ $(evidence_kv "$file" board) == J514s ]] || evidence_die 'identity board is not J514s'
    [[ $(evidence_kv "$file" soc) == T6030 ]] || evidence_die 'identity SoC is not T6030'
}

evidence_validate_tsv() {
    local file=$1 required=$2 min=$3 header line fields i key value status_col cycle_col
    evidence_abs_regular "$file"
    IFS=$'\t' read -r -a header < "$file" || evidence_die "missing TSV header: $file"
    ((${#header[@]} >= 2)) || evidence_die "invalid TSV header: $file"
    for key in $required; do
        printf '%s\n' "${header[@]}" | grep -Fx "$key" >/dev/null || evidence_die "missing TSV column $key: $file"
    done
    while IFS=$'\t' read -r line; do
        [[ -z $line ]] && continue
        IFS=$'\t' read -r -a fields <<< "$line"
        ((${#fields[@]} == ${#header[@]})) || evidence_die "invalid TSV row: $file"
        for i in "${!fields[@]}"; do [[ ${fields[i]} != *$'\n'* ]] || evidence_die "invalid TSV value"; done
    done < <(tail -n +2 "$file")
}

evidence_count_success() {
    local file=$1 min=$2 cycle_index status_index value line cycle count=0 seen='|'
    IFS=$'\t' read -r -a _e_header < "$file"
    cycle_index=-1; status_index=-1
    for i in "${!_e_header[@]}"; do
        [[ ${_e_header[i]} == cycle || ${_e_header[i]} == id ]] && cycle_index=$i
        [[ ${_e_header[i]} == status || ${_e_header[i]} == result ]] && status_index=$i
    done
    ((cycle_index >= 0 && status_index >= 0)) || evidence_die "cycle/status columns required: $file"
    while IFS=$'\t' read -r line; do
        [[ -z $line ]] && continue
        IFS=$'\t' read -r -a _e_fields <<< "$line"
        cycle=${_e_fields[cycle_index]}
        [[ $cycle =~ ^[0-9]+$ ]] || evidence_die "non-numeric cycle in $file"
        [[ $seen != *"|$cycle|"* ]] || evidence_die "duplicate cycle/id $cycle in $file"
        seen="${seen}${cycle}|"
        [[ ${_e_fields[status_index],,} =~ ^(success|passed|pass|ok|complete|observed)$ ]] && count=$((count + 1))
    done < <(tail -n +2 "$file")
    ((count >= min)) || evidence_die "$file has $count successful records; need $min"
}

evidence_validate_cycle_tsv() {
    local file=$1 minimum=$2
    evidence_validate_tsv "$file" cycle 0
    IFS=$'\t' read -r -a _e_header < "$file"
    printf '%s\n' "${_e_header[@]}" | grep -Eix 'status|result' >/dev/null || evidence_die "status/result column required: $file"
    evidence_count_success "$file" "$minimum"
}

evidence_validate_modes_tsv() {
    local file=$1 line row_count=0
    evidence_validate_tsv "$file" mode 0
    IFS=$'\t' read -r -a _e_header < "$file"
    for key in width height; do printf '%s\n' "${_e_header[@]}" | grep -Fx "$key" >/dev/null || evidence_die "missing display mode column $key"; done
    while IFS=$'\t' read -r line; do
        [[ -z $line ]] && continue
        IFS=$'\t' read -r -a _e_fields <<< "$line"
        [[ ${_e_fields[*]} =~ [0-9]+ ]] || evidence_die "unstructured display mode row: $file"
        row_count=$((row_count + 1))
    done < <(tail -n +2 "$file")
    ((row_count > 0)) || evidence_die "no display modes declared: $file"
}

evidence_validate_no_bare_pass() {
    local file=$1
    ! grep -Eiq '^[[:space:]]*(pass|passed|success|conformant[[:space:]]*=[[:space:]]*(true|yes|pass|passed))[[:space:]]*$|conformance[[:space:]_=-]*(pass|passed|true|yes)' "$file" || evidence_die "unstructured acceptance claim in $file"
}

evidence_verify_analysis_report() {
    local input=$1 report=$2 expected_hash report_hash report_status report_matches
    evidence_abs_regular "$report"
    expected_hash=$(evidence_sha256 "$input")
    report_hash=$(awk -F= '$1 == "input_sha256" { print substr($0, index($0, "=") + 1); found++ } END { exit !(found == 1) }' "$report") || evidence_die "invalid analysis report: $report"
    report_status=$(awk -F= '$1 == "status" { print substr($0, index($0, "=") + 1); found++ } END { exit !(found == 1) }' "$report") || evidence_die "invalid analysis report: $report"
    report_matches=$(awk -F= '$1 == "matched_lines" { print substr($0, index($0, "=") + 1); found++ } END { exit !(found == 1) }' "$report") || evidence_die "invalid analysis report: $report"
    [[ $report_hash == "$expected_hash" ]] || evidence_die "analysis report hash mismatch: $report"
    [[ $report_status == clean && $report_matches == 0 ]] || evidence_die "analysis report is not clean: $report"
}

evidence_validate_stress_tsv() {
    local file=$1 minimum=$2 duration_index=-1 status_index=-1 line total=0 value
    evidence_abs_regular "$file"
    IFS=$'\t' read -r -a _e_header < "$file"
    printf '%s\n' "${_e_header[@]}" | grep -Eix 'duration_seconds|seconds' >/dev/null || evidence_die "duration/seconds column required: $file"
    printf '%s\n' "${_e_header[@]}" | grep -Eix 'status|result' >/dev/null || evidence_die "status/result column required: $file"
    IFS=$'\t' read -r -a _e_header < "$file"
    for i in "${!_e_header[@]}"; do
        [[ ${_e_header[i]} == duration_seconds || ${_e_header[i]} == seconds ]] && duration_index=$i
        [[ ${_e_header[i]} == status || ${_e_header[i]} == result ]] && status_index=$i
    done
    ((duration_index >= 0 && status_index >= 0)) || evidence_die "duration/status columns required: $file"
    while IFS=$'\t' read -r line; do
        [[ -z $line ]] && continue
        IFS=$'\t' read -r -a _e_fields <<< "$line"
        value=${_e_fields[duration_index]}
        [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]] || evidence_die "invalid stress duration: $file"
        case ${_e_fields[status_index],,} in success|passed|pass|ok|complete|observed) total=$(awk -v a="$total" -v b="$value" 'BEGIN { print a+b }');; esac
    done < <(tail -n +2 "$file")
    awk -v total="$total" -v minimum="$minimum" 'BEGIN { exit !(total >= minimum) }' || evidence_die "$file has $total supplied stress seconds; need $minimum"
}

evidence_validate_m2() {
    local root=$1
    evidence_validate_identity "$root/identity.txt"
    evidence_require_clean_log "$root/kernel.log"
    evidence_validate_cycle_tsv "$root/power-thermal.tsv" 20
    evidence_validate_cycle_tsv "$root/suspend-resume.tsv" 20
}

evidence_validate_m3() {
    local root=$1
    evidence_validate_identity "$root/identity.txt"
    evidence_require_clean_log "$root/kernel.log"
    evidence_require_clean_log "$root/dcp.log"
    evidence_validate_modes_tsv "$root/display-modes.tsv"
    evidence_validate_cycle_tsv "$root/brightness.tsv" 100
    evidence_validate_cycle_tsv "$root/suspend-resume.tsv" 50
    evidence_validate_no_bare_pass "$root/brightness.tsv"
    evidence_validate_no_bare_pass "$root/suspend-resume.tsv"
}

evidence_validate_m4() {
    local root=$1
    evidence_validate_identity "$root/identity.txt"
    evidence_require_clean_log "$root/kernel.log"
    grep -Eiq 'Apple|AGX' "$root/renderer.txt" || evidence_die 'renderer does not declare Apple/AGX'
    grep -Eiq 'llvmpipe|softpipe|software[[:space:]_-]*raster|swrast|software renderer' "$root/renderer.txt" && evidence_die 'software renderer is not accepted'
    evidence_validate_tsv "$root/conformance.tsv" api 0
    evidence_validate_no_bare_pass "$root/conformance.tsv"
    evidence_validate_stress_tsv "$root/stress.tsv" 86400
    evidence_abs_regular "$root/reset-recovery.txt"
    grep -Eiq 'reset' "$root/reset-recovery.txt" || evidence_die 'reset evidence missing'
    grep -Eiq 'recover' "$root/reset-recovery.txt" || evidence_die 'recovery evidence missing'
    evidence_validate_no_bare_pass "$root/reset-recovery.txt"
}

evidence_scan_fault_log() {
    local file=$1
    evidence_abs_regular "$file"
    if grep -Eiq \
        -e 'panic' \
        -e '(^|[^[:alnum:]_])(BUG|Oops|WARNING)([^[:alnum:]_]|$)' \
        -e 'KASAN|KCSAN|UBSAN' \
        -e 'lockdep' \
        -e 'DART[^[:cntrl:]]*fault' \
        -e 'IOMMU[^[:cntrl:]]*fault' \
        -e '(^|[^[:alnum:]_])SError([^[:alnum:]_]|$)' \
        -e 'unhandled[[:space:]]+fault' "$file"; then
        return 1
    fi
}

evidence_require_clean_log() { evidence_scan_fault_log "$1" || evidence_die "fault or warning found in log: $1"; }

evidence_write_sums() {
    local root=$1 output=$2 file rel
    : > "$output"
    while IFS= read -r -d '' file; do
        rel=${file#"$root"/}
        [[ $rel != SHA256SUMS ]] || continue
        printf '%s  %s\n' "$(evidence_sha256 "$file")" "$rel" >> "$output"
    done < <(find -P "$root" -type f -print0 | sort -z)
}
