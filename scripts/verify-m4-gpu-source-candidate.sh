#!/usr/bin/env bash
# Static M4 GPU source-candidate gate for T6030 (M3 Pro, G15 RTBuddy).
#
# Checks only that the candidate is well formed: the device-derived silicon
# profile is internally consistent, the development DT and driver patch series
# are shaped like the repository's other series and stay inside the GPU scope,
# an overlay built from every DT node the series adds passes a bounded dtc
# check with no warnings, every added node stays disabled, and no candidate
# file claims success or carries a concrete value for a reverse-engineering- or
# ADT-gated field. When a pinned Linux tree is present it also replays the
# series with git am onto the pinned commit (in a disposable copy; the pinned
# tree itself is never modified) and builds both T6030 boards, asserting zero
# new dtc warnings and a still-disabled GPU. It never builds a kernel, probes or
# runs anything on hardware, so a well-formed candidate still exits 2 (blocked
# for native execution); a malformed or fabricated candidate exits 1.
#
# RE/ADT-gated placeholder contract enforced on added DT and
# drivers/gpu/drm/asahi Rust lines: a gated property or HwConfig field may only
# hold zero literals (0, 0x0, 0b0, 0o0, 0.0, <0 0 0>), poison words
# (0xdead_beef, NaN 0x7fc0_dead) or a named sentinel (RE_GATED_*, *_RE_GATED,
# ADT_GATED_*, *_ADT_*) that the series itself defines; radix-prefixed and
# underscored literals count as values. Structural function-like DT macros such
# as GPU_REPEAT(x) <x x> are allowed. A gated value must reference no other
# identifier and must be labelled on the statement or in the comment block
# directly above it with TODO(re), "NOT a working value" or "RE-gated" (TODO(adt)
# is also accepted for ADT-gated ones). A field that assigns a sentinel is
# labelled by it; every sentinel definition must obey the same value rule and
# carry its own label. A T6030 HwConfig must not inherit from another SoC's
# HWCONFIG_* with struct-update syntax. A 00-cover-letter.patch outside the
# series is allowed only without a diff.
#
# Environment: M4_GPU_LINUX_PIN (pinned Linux git tree; empty or absent path
# skips the replay with patch_replay=not-run), M4_GPU_LINUX_PIN_COMMIT.
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly project_root
[[ $# -eq 1 && $1 == --static ]] || { printf 'usage: %s --static\n' "$0" >&2; exit 64; }

die() { printf 'M4 GPU candidate: %s\n' "$*" >&2; exit 1; }
command -v dtc >/dev/null 2>&1 || die 'dtc is required'
readonly max_file_bytes=2097152 max_node_lines=512 max_block_lines=4096 dtc_seconds=30 replay_seconds=120
readonly default_linux_pin=/private/tmp/claude-501/-private-tmp-work/9d625c24-f09f-4f1f-aa5d-7f33f13cb9df/scratchpad/linux-pin
readonly linux_pin=${M4_GPU_LINUX_PIN-$default_linux_pin}
readonly linux_pin_commit=${M4_GPU_LINUX_PIN_COMMIT:-77cb8f24c2381a8abb7272d7bbdec548d6426a8a}
readonly boards=(t6030-j514s t6030-j516s)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m4-gpu-candidate.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

run_bounded() {
    local seconds=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
        return
    fi
    "$@" &
    local pid=$! status=0 watchdog
    (sleep "$seconds"; kill -TERM "$pid" 2>/dev/null) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid" || status=$?
    kill -TERM "$watchdog" 2>/dev/null || :
    wait "$watchdog" 2>/dev/null || :
    return "$status"
}
relative() { printf '%s\n' "${1#"$project_root"/}"; }
file_bytes() { wc -c < "$1" | tr -d '[:space:]'; }

# --- (a) device-derived silicon profile -------------------------------------
readonly profile="$project_root/config/milestone4-gpu-silicon-profile.tsv"
[[ -f $profile && ! -L $profile ]] || die 'missing silicon profile: config/milestone4-gpu-silicon-profile.tsv'
(($(file_bytes "$profile") <= max_file_bytes)) || die 'oversized silicon profile'
if LC_ALL=C grep -q $'\r' "$profile"; then die 'silicon profile contains carriage returns'; fi
[[ $(grep -c '^# format=1$' "$profile") -eq 1 ]] || die 'invalid silicon profile format'
[[ $(grep -cFx $'# key\tvalue\tprovenance\tstatus' "$profile") -eq 1 ]] || die 'invalid silicon profile header'
grep -Fq 'hardware_acceptance=false' "$profile" || die 'silicon profile does not state hardware_acceptance=false'
readonly rows="$tmp/profile.rows"
awk -F '\t' '
    /^#/ || /^$/ { next }
    NF != 4 || $1 !~ /^[a-z][a-z0-9_]*$/ || $2 == "" || $3 == "" ||
        ($4 != "device-derived" && $4 != "re-gated") { invalid = 1; exit }
    seen[$1]++ { invalid = 1; exit }
    { print $1 "\t" $2 "\t" $4 }
    END { if (invalid) exit 1 }
' "$profile" > "$rows" || die 'invalid silicon profile row'
value_of() { awk -F '\t' -v key="$1" '$1 == key { print $2 }' "$rows"; }
status_of() { awk -F '\t' -v key="$1" '$1 == key { print $3 }' "$rows"; }

device_keys=(
    ioclass gpu_gen gpu_variant usc_gen num_cores_physical num_frags_physical
    num_gps num_mgpus core_mask_list gpu_core_count_active firmware_bundle chip_id
)
re_gated_keys=(
    apple_firmware_version apple_firmware_abi gpu_opp_dvfs_table
    hwconfig_unk_coef_a hwconfig_unk_coef_b hwconfig_da_db
    hwdata_shared_tables preempt_buffer_sizes temp_sensor_mask
)
cmp <(printf '%s\n' "${device_keys[@]}" "${re_gated_keys[@]}" | LC_ALL=C sort) \
    <(cut -f1 "$rows" | LC_ALL=C sort) >/dev/null || die 'silicon profile inventory mismatch'
for key in "${device_keys[@]}"; do
    [[ $(status_of "$key") == device-derived ]] || die "silicon profile row is not device-derived: $key"
done
re_gated_unknown=0
for key in "${re_gated_keys[@]}"; do
    [[ $(status_of "$key") == re-gated ]] || die "silicon profile RE-gated row changed status: $key"
    value=$(value_of "$key")
    [[ $value == UNKNOWN || $value == 'TODO(re)'* ]] || die "silicon profile RE-gated row carries a value: $key"
    re_gated_unknown=$((re_gated_unknown + 1))
done

chip_id=$(value_of chip_id)
gpu_gen=$(value_of gpu_gen)
gpu_variant=$(value_of gpu_variant)
usc_gen=$(value_of usc_gen)
physical=$(value_of num_cores_physical)
fragments=$(value_of num_frags_physical)
num_gps=$(value_of num_gps)
num_mgpus=$(value_of num_mgpus)
core_mask_list=$(value_of core_mask_list)
active=$(value_of gpu_core_count_active)
readonly chip_id gpu_gen gpu_variant usc_gen physical fragments num_gps num_mgpus core_mask_list active

# Internal consistency is recomputed rather than trusted.
for number in "$physical" "$fragments" "$num_gps" "$num_mgpus" "$active"; do
    [[ $number =~ ^[1-9][0-9]{0,3}$ ]] || die 'silicon profile count is not a positive integer'
done
[[ $fragments == "$physical" ]] || die 'num_frags_physical differs from num_cores_physical'
[[ $(value_of ioclass) == AGXAcceleratorG"$gpu_gen"* ]] || die 'ioclass does not match gpu_gen'
[[ $(value_of firmware_bundle) == "G$gpu_gen "* ]] || die 'firmware_bundle does not match gpu_gen'
[[ $core_mask_list =~ ^0x[0-9a-f]{1,8}(,0x[0-9a-f]{1,8})*$ ]] || die 'malformed core_mask_list'
IFS=, read -r -a core_masks <<< "$core_mask_list"
((${#core_masks[@]} == num_mgpus)) || die 'core_mask_list entry count differs from num_mgpus'
((physical % num_mgpus == 0)) || die 'num_cores_physical is not divisible by num_mgpus'
readonly cores_per_mgpu=$((physical / num_mgpus))
popcount=0
for mask in "${core_masks[@]}"; do
    bits=$((mask))
    ((bits < (1 << cores_per_mgpu))) || die 'core mask exceeds the physical cores of one mGPU'
    while ((bits)); do
        popcount=$((popcount + (bits & 1)))
        bits=$((bits >> 1))
    done
done
((popcount == active)) || die "gpu_core_count_active=$active differs from popcount(core_mask_list)=$popcount"
((active <= physical)) || die 'active cores exceed physical cores'

# Pinned identity read from the live M3 Pro IORegistry capture.
expect_identity() { [[ $(value_of "$1") == "$2" ]] || die "silicon profile identity mismatch: $1"; }
expect_identity chip_id 0x6030
expect_identity gpu_gen 15
expect_identity gpu_variant S
expect_identity usc_gen 3
expect_identity num_cores_physical 20
expect_identity num_mgpus 2
expect_identity core_mask_list 0x1ff,0x1ff
expect_identity gpu_core_count_active 18
expect_identity firmware_bundle 'G15 RTBuddy'

# --- (b) development DT and driver patch series ------------------------------
shopt -s nullglob
series_dirs=("$project_root"/patches/linux-gpu-development*)
shopt -u nullglob
((${#series_dirs[@]} > 0)) || die 'missing patch series under patches/linux-gpu-development*/'
readonly stream="$tmp/patch-lines.tsv"
: > "$stream"
candidate_files=("$profile")
series_files=()
series_patches=()
dt_patches=0
driver_patches=0
# Every path-bearing line is scope-checked: diff --git headers, rename/copy
# from/to, ---/+++ file headers and binary sections. Only regular-file
# creation (mode 100644) is allowed; binary patches and mode changes are not.
# shellcheck disable=SC2016 # awk program, not shell expansion
readonly patch_awk='
    function reject(reason) { printf "%s: %s\n", patch, reason > "/dev/stderr"; bad = 1; exit 1 }
    function check_path(p, what) {
        if (p !~ /^[A-Za-z0-9._\/+-]+$/ || substr(p, 1, 1) == "/" || index(p, "..")) reject("unsafe patch path in " what ": " p)
        if (p !~ /^(arch\/arm64\/boot\/dts\/apple|drivers\/gpu\/drm\/asahi|Documentation\/devicetree\/bindings)\//)
            reject("patch touches a path outside the GPU candidate scope in " what ": " p)
        return p
    }
    function patch_path(raw, prefix) {
        sub(/\t.*$/, "", raw)
        if (raw == "/dev/null") return raw
        if (substr(raw, 1, 2) != prefix "/") reject("patch path lacks " prefix "/ prefix")
        return check_path(substr(raw, 3), prefix == "a" ? "--- header" : "+++ header")
    }
    function need_git(what) { if (git_a == "") reject(what " outside a diff --git section") }
    function range_count(range) { return index(range, ",") ? substr(range, index(range, ",") + 1) + 0 : 1 }
    { if (index($0, "\r")) reject("carriage return") }
    old_left > 0 || new_left > 0 {
        c = substr($0, 1, 1)
        if ($0 == "" || c == " ") {
            if (old_left <= 0 || new_left <= 0) reject("hunk context exceeds header counts")
            old_left--; new_left--
            print " \t" patch "\t" path "\t" substr($0, 2); next
        }
        if (c == "-") { if (old_left <= 0) reject("hunk removal exceeds header counts"); old_left--; next }
        if (c == "+") {
            if (new_left <= 0) reject("hunk addition exceeds header counts")
            new_left--
            print "+\t" patch "\t" path "\t" substr($0, 2); next
        }
        if (c == "\\") next
        reject("malformed hunk line")
    }
    /^\\/ { next }
    /^diff --git / {
        if (old_seen) reject("old path without new path")
        rest = substr($0, 12)
        if (index(rest, "\"") || index(rest, "\t")) reject("quoted or tab-separated diff --git header")
        if (split(rest, names, " ") != 2 || substr(names[1], 1, 2) != "a/" || substr(names[2], 1, 2) != "b/")
            reject("malformed diff --git header")
        git_a = check_path(substr(names[1], 3), "diff --git header")
        git_b = check_path(substr(names[2], 3), "diff --git header")
        print "D\t" patch "\t" git_a; print "D\t" patch "\t" git_b
        git_pending = 1; path = ""; next
    }
    /^(rename|copy) (from|to) / {
        need_git("rename/copy header")
        split($0, words, " "); p = check_path(substr($0, length(words[1]) + length(words[2]) + 3), words[1] " " words[2])
        if (words[2] == "from" && p != git_a) reject(words[1] " from differs from the diff --git header")
        if (words[2] == "to" && p != git_b) reject(words[1] " to differs from the diff --git header")
        print "D\t" patch "\t" p; next
    }
    /^(new file mode|deleted file mode) / {
        need_git("file mode header")
        if ($NF != "100644") reject("non-regular file mode " $NF)
        next
    }
    /^(old mode|new mode) / { reject("file mode change") }
    /^Binary files / {
        if (match($0, /^Binary files [^ ]+ and [^ ]+ differ$/)) {
            split($0, words, " ")
            for (i = 3; i <= 5; i += 2) if (words[i] != "/dev/null") check_path(substr(words[i], 3), "binary section")
        }
        reject("binary patch section")
    }
    /^GIT binary patch/ { reject("binary patch section") }
    /^--- / {
        if (!git_pending) reject("file header without diff --git")
        old = patch_path(substr($0, 5), "a")
        if (old != "/dev/null" && old != git_a) reject("--- path differs from the diff --git header")
        print "O\t" patch "\t" old; old_seen = 1; next
    }
    /^\+\+\+ / {
        if (!old_seen) reject("new path without old path")
        path = patch_path(substr($0, 5), "b"); old_seen = 0; git_pending = 0; files++
        if (path != "/dev/null" && path != git_b) reject("+++ path differs from the diff --git header")
        print "F\t" patch "\t" path; next
    }
    /^@@/ {
        if (path == "" || old_seen) reject("hunk before file header")
        if (!match($0, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/)) reject("malformed hunk header")
        split(substr($0, 4, RLENGTH - 6), ranges, " ")
        old_left = range_count(substr(ranges[1], 2)); new_left = range_count(substr(ranges[2], 2))
        if (old_left == 0 && new_left == 0) reject("empty hunk")
        hunks++
        print "H\t" patch "\t" path; next
    }
    END {
        if (bad) exit 1
        if (old_left > 0 || new_left > 0) reject("truncated hunk")
        if (old_seen) reject("old path without new path")
        if (files == 0 || hunks == 0) reject("no file hunks")
    }
'
for dir in "${series_dirs[@]}"; do
    name=${dir##*/}
    [[ $name =~ ^linux-gpu-development(-[a-z0-9]+)*$ ]] || die "unexpected patch series directory name: $name"
    [[ -d $dir && ! -L $dir ]] || die "patch series is not a directory: $name"
    [[ -z $(find "$dir" ! -type f ! -type d -print -quit) ]] || die "patch series contains a non-regular file: $name"
    [[ -f $dir/series && -s $dir/series ]] || die "missing series file: $name"
    [[ -f $dir/README.md && -s $dir/README.md ]] || die "missing README.md: $name"
    grep -Fq 'hardware_acceptance=false' "$dir/README.md" || die "README.md does not state hardware_acceptance=false: $name"
    index=0
    listed=()
    while IFS= read -r entry || [[ -n $entry ]]; do
        index=$((index + 1))
        [[ $entry =~ ^[0-9]{2}-[a-z0-9][a-z0-9.-]*\.patch$ ]] || die "invalid series entry in $name: $entry"
        [[ ${entry%%-*} == "$(printf '%02d' "$index")" ]] || die "series is not numbered contiguously from 01 in $name: $entry"
        patch="$dir/$entry"
        [[ -f $patch && -s $patch ]] || die "series lists a missing patch in $name: $entry"
        (($(file_bytes "$patch") <= max_file_bytes)) || die "oversized patch in $name: $entry"
        listed+=("$entry")
        series_patches+=("$patch")
        parsed="$tmp/parsed.tsv"
        awk -v patch="$name/$entry" "$patch_awk" "$patch" > "$parsed" || die "malformed patch: $name/$entry"
        touches_dt=0
        touches_driver=0
        while IFS= read -r path; do
            [[ $path != /dev/null ]] || continue
            [[ $path =~ ^[A-Za-z0-9._/+-]+$ && $path != /* && $path != *..* ]] || die "unsafe patch path in $name/$entry: $path"
            case $path in
                arch/arm64/boot/dts/apple/*) touches_dt=1 ;;
                drivers/gpu/drm/asahi/*) touches_driver=1 ;;
                Documentation/devicetree/bindings/*) ;;
                *) die "patch touches a path outside the GPU candidate scope in $name/$entry: $path" ;;
            esac
        done < <(awk -F '\t' '$1 == "F" || $1 == "O" || $1 == "D" { print $3 }' "$parsed")
        dt_patches=$((dt_patches + touches_dt))
        driver_patches=$((driver_patches + touches_driver))
        cat "$parsed" >> "$stream"
    done < "$dir/series"
    ((index > 0)) || die "empty series: $name"
    listed_text=$'\n'$(printf '%s\n' "${listed[@]}")$'\n'
    while IFS= read -r found; do
        [[ $listed_text != *$'\n'"${found##*/}"$'\n'* ]] || continue
        if [[ ${found##*/} == 00-cover-letter.patch ]]; then
            # A mail cover letter is never applied, so it must not hide a diff.
            if grep -Eq '^(diff --git |@@ |\+\+\+ |--- a/|rename (from|to) |copy (from|to) |GIT binary patch|Binary files )' "$found"; then
                die "cover letter carries a diff in $name: ${found##*/}"
            fi
            continue
        fi
        die "patch not listed in series in $name: ${found##*/}"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
    while IFS= read -r file; do
        (($(file_bytes "$file") <= max_file_bytes)) || die "oversized candidate file: $(relative "$file")"
        series_files+=("$file")
        candidate_files+=("$file")
    done < <(find "$dir" -type f | LC_ALL=C sort)
done
((dt_patches > 0)) || die 'no DT patch (arch/arm64/boot/dts/apple/) in the GPU candidate series'
((driver_patches > 0)) || die 'no driver patch (drivers/gpu/drm/asahi/) in the GPU candidate series'
readonly compatible="apple,agx-t${chip_id#0x}"
awk -F '\t' -v wanted="\"$compatible\"" '
    $1 == "+" && $3 ~ /^drivers\/gpu\/drm\/asahi\// && index($0, wanted) { found = 1 }
    END { exit !found }
' "$stream" || die "driver series does not add the $compatible device match"

# Shared comment/string/number helpers for the DT extraction and the audits.
# shellcheck disable=SC2016 # awk program, not shell expansion
readonly awk_lexer='
    function strip_comments(s,    out, i, n, c, nx, quoted) {
        out = ""; n = length(s); i = 1; quoted = 0
        while (i <= n) {
            c = substr(s, i, 1); nx = substr(s, i + 1, 1)
            if (in_comment) { if (c == "*" && nx == "/") { in_comment = 0; i += 2 } else i++; continue }
            if (quoted) {
                out = out c
                if (c == "\\" && i < n) { out = out nx; i += 2; continue }
                if (c == "\"") quoted = 0
                i++; continue
            }
            if (c == "/" && nx == "*") { in_comment = 1; i += 2; continue }
            if (c == "/" && nx == "/") break
            if (c == "\"") quoted = 1
            out = out c; i++
        }
        return out
    }
    function strip_strings(s,    out, i, n, c, quoted) {
        out = ""; n = length(s); quoted = 0
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (quoted) { if (c == "\\") i++; else if (c == "\"") quoted = 0; continue }
            if (c == "\"") { quoted = 1; out = out " "; continue }
            out = out c
        }
        return out
    }
    function brace_delta(s,    t) { t = strip_strings(s); return gsub(/[{]/, "{", t) - gsub(/[}]/, "}", t) }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    # Recognisable poison words (0xdead_beef, NaN 0x7fc0_dead, ...) are sentinels,
    # not values; any other non-zero literal is treated as fabricated.
    function poison(digits) {
        sub(/^(7fc0|7ff8)/, "", digits)
        return digits ~ /^(dead|beef|baad|f00d|c0de|cafe|babe|feed|face)+$/
    }
    # Splits s into identifier and numeric tokens (tok_kind/tok_text); a numeric
    # token keeps its radix prefix, digits, underscores, fraction, exponent and
    # type suffix, so 0b1111_0000 or 0o7740 can never hide behind an identifier.
    function scan(s,    n, i, j, c, k) {
        n = length(s); i = 1; k = 0
        while (i <= n) {
            c = substr(s, i, 1)
            if (c ~ /[A-Za-z_]/) {
                for (j = i + 1; j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_]/; j++) {}
                tok_kind[++k] = "id"; tok_text[k] = substr(s, i, j - i); i = j; continue
            }
            if (c ~ /[0-9]/) {
                for (j = i + 1; j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_.]/; j++) {}
                if (substr(s, j - 1, 1) ~ /[eE]/ && substr(s, j, 1) ~ /[+-]/ && tolower(substr(s, i, 2)) !~ /^0[xbo]/)
                    for (j = j + 1; j <= n && substr(s, j, 1) ~ /[0-9_]/; j++) {}
                tok_kind[++k] = "num"; tok_text[k] = substr(s, i, j - i); i = j; continue
            }
            i++
        }
        return k
    }
    # zero, poison or value; a malformed literal is a value (fails closed).
    function number_class(tok,    t, digits) {
        t = tolower(tok); gsub(/_/, "", t)
        if (t ~ /^0x[0-9a-f]+([ui](8|16|32|64|128|size)|u|ul|ull|l|ll)?$/) {
            digits = substr(t, 3); sub(/[uil].*$/, "", digits)
            if (digits !~ /[1-9a-f]/) return "zero"
            return poison(digits) ? "poison" : "value"
        }
        if (t ~ /^0b[01]+([ui](8|16|32|64|128|size))?$/) {
            digits = substr(t, 3); sub(/[ui].*$/, "", digits); return digits ~ /1/ ? "value" : "zero"
        }
        if (t ~ /^0o[0-7]+([ui](8|16|32|64|128|size))?$/) {
            digits = substr(t, 3); sub(/[ui].*$/, "", digits); return digits ~ /[1-7]/ ? "value" : "zero"
        }
        if (t ~ /^[0-9]+(\.[0-9]*)?(e[+-]?[0-9]+)?([ui](8|16|32|64|128|size)|f32|f64|u|ul|ull|l|ll)?$/) {
            digits = t; sub(/e.*$/, "", digits); sub(/[uifl].*$/, "", digits)
            return digits ~ /[1-9]/ ? "value" : "zero"
        }
        return "value"
    }
'

# --- (c) every added DT node: status, scope, bounded dtc overlay harness ------
readonly dt_added="$tmp/dt-added.tsv" dt_blocks="$tmp/dt-blocks.dtsi"
readonly gpu_node="$tmp/gpu-node.dtsi" gpu_overrides="$tmp/gpu-overrides.dtsi"
readonly dt_macros="$tmp/dt-macros.tsv" dt_function_macros="$tmp/dt-function-macros.tsv"
# Added DT lines plus a boundary record for every file, hunk and context line,
# so an added block can never silently span existing tree content.
awk -F '\t' '
    $1 == "H" || $1 == "F" || $1 == "O" || $1 == "D" { print "B\t" $3; next }
    $3 !~ /^arch\/arm64\/boot\/dts\/apple\// { next }
    $1 == " " { print "B\t" $3; next }
    $1 == "+" { print "+\t" $3 "\t" substr($0, length($1) + length($2) + length($3) + 4) }
' "$stream" > "$dt_added"
: > "$dt_blocks"
: > "$gpu_node"
: > "$gpu_overrides"
: > "$dt_macros"
: > "$dt_function_macros"
# Each top-level block the series adds (/ {...}, &label {...}, &{/path} {...}
# or a bare node) becomes one overlay fragment, so dtc sees every added node.
# shellcheck disable=SC2016 # awk program, not shell expansion
dt_summary=$(awk -F '\t' -v blocks_out="$dt_blocks" -v node_out="$gpu_node" -v override_out="$gpu_overrides" \
    -v macro_out="$dt_macros" -v function_out="$dt_function_macros" -v max_block_lines="$max_block_lines" "$awk_lexer"'
    function fail(message) { printf "M4 GPU candidate: %s in %s\n", message, path > "/dev/stderr"; failed = 1 }
    function boundary() {
        if (gcap) { fail("GPU node or &gpu override is not brace-balanced"); gcap = 0; gunterminated = 1 }
        if (bcap) { fail("added DT block is not brace-balanced"); bcap = 0 }
        in_comment = 0
    }
    function open_fragment(target) {
        fragments++
        printf "\tm4-candidate-fragment-%d {\n\t\t%s;\n\t\t__overlay__ {\n\t\t\t#address-cells = <2>;\n\t\t\t#size-cells = <2>;\n", \
            fragments, target > blocks_out
    }
    function close_fragment() { printf "\t\t};\n\t};\n" > blocks_out }
    $1 == "B" { path = $2; boundary(); next }
    {
        path = $2
        text = substr($0, length($1) + length($2) + 3)
        code = strip_comments(text)
        bare = strip_strings(code)
        # A deleted or non-"disabled" status anywhere in the DT series could
        # enable the GPU or any other node the series adds.
        if (bare ~ /\/delete-property\/[[:space:]]*status([^A-Za-z0-9,._+?#-]|$)/)
            fail("DT series deletes a status property (/delete-property/ status)")
        else if (bare ~ /\/delete-(node|property)\//) fail("DT series deletes a node or property")
        if (bare ~ /(^|[^A-Za-z0-9,._+?#-])status([^A-Za-z0-9,._+?#-]|$)/ &&
            code !~ /^[[:space:]]*status[[:space:]]*=[[:space:]]*"disabled"[[:space:]]*;[[:space:]]*$/)
            fail("DT series sets a status other than \"disabled\": " trim(code))
        rest = bare
        while (match(rest, /@[0-9A-Fa-f,]+[[:space:]]*[{]/)) {
            address = substr(rest, RSTART + 1, RLENGTH - 1); sub(/[[:space:]]*[{]$/, "", address)
            digits = tolower(address); gsub(/,/, "", digits)
            if (digits ~ /[1-9a-f]/ && !poison(digits)) fail("added DT node carries an invented unit address @" address)
            rest = substr(rest, RSTART + RLENGTH)
        }
        # GPU node and every override of it (&gpu, &{/...gpu@...}, another gpu@ node).
        if (gcap) {
            print code > (gcap == 1 ? node_out : override_out)
            if (gcap == 1) node_lines++
            gdepth += brace_delta(code); if (gdepth <= 0) gcap = 0
        } else if (code ~ /(^|[[:space:]])gpu[[:space:]]*:[[:space:]]*gpu@[0-9A-Fa-f,]+[[:space:]]*[{]/) {
            nodes++; node_path = path; gcap = 1; node_lines = 1
            print code > node_out
            gdepth = brace_delta(code); if (gdepth <= 0) gcap = 0
        } else if (code ~ /&gpu[[:space:]]*[{]/ || code ~ /&[{][^}]*\/gpu@[^}]*[}][[:space:]]*[{]/ ||
            code ~ /(^|[^A-Za-z0-9_,.+-])gpu@[0-9A-Fa-f,]+[[:space:]]*[{]/) {
            overrides++; gcap = 2
            print code > override_out
            gdepth = brace_delta(code); if (gdepth <= 0) gcap = 0
        }
        if (bcap) {
            if (code ~ /^[[:space:]]*#[[:space:]]*(if|ifdef|ifndef|elif|else|endif|undef|define|include|error|line|pragma)([^A-Za-z0-9_-]|$)/)
                fail("preprocessor directive inside an added DT node")
            bdepth += brace_delta(code)
            if (bdepth <= 0) {
                if (bdepth < 0 || code !~ /^[[:space:]]*[}][[:space:]]*;[[:space:]]*$/) fail("added DT block does not close with a bare \"};\" line")
                if (btype == "node") print code > blocks_out
                close_fragment(); bcap = 0
            } else {
                print code > blocks_out
                if (++block_lines > max_block_lines) { fail("added DT blocks exceed " max_block_lines " lines"); exit 1 }
            }
            next
        }
        if (code ~ /^[[:space:]]*#[[:space:]]*define[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[(]/) {
            rest = code; sub(/^[[:space:]]*#[[:space:]]*define[[:space:]]+/, "", rest)
            name = rest; sub(/[(].*$/, "", name)
            params = substr(rest, length(name) + 2); body = params
            sub(/[)].*$/, "", params); gsub(/[[:space:]]/, "", params); sub(/^[^)]*[)]/, "", body); gsub(/\t/, " ", body)
            print name "\t" params "\t" trim(body) > function_out
            next
        }
        if (code ~ /^[[:space:]]*#[[:space:]]*define[[:space:]]+[A-Za-z_][A-Za-z0-9_]*([[:space:]]|$)/) {
            rest = code; sub(/^[[:space:]]*#[[:space:]]*define[[:space:]]+/, "", rest)
            name = rest; sub(/[[:space:]].*$/, "", name)
            print name "\t" trim(substr(rest, length(name) + 1)) > macro_out
            next
        }
        if (code ~ /^[[:space:]]*#[[:space:]]*[a-z]+([[:space:]]|$)/) next
        if (index(bare, "{")) {
            if (code ~ /^[[:space:]]*\/[[:space:]]*[{][[:space:]]*$/) { btype = "fragment"; open_fragment("target-path = \"/\"") }
            else if (code ~ /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*)?&[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[{][[:space:]]*$/) {
                label = code; sub(/[[:space:]]*[{].*$/, "", label); sub(/^.*&/, "", label)
                btype = "fragment"; open_fragment("target = <&" label ">")
            } else if (code ~ /^[[:space:]]*&[{]\/[^}]*[}][[:space:]]*[{][[:space:]]*$/) {
                target = code; sub(/^[[:space:]]*&[{]/, "", target); sub(/[}].*$/, "", target)
                btype = "fragment"; open_fragment("target-path = \"" target "\"")
            } else if (code ~ /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*)?[A-Za-z0-9][A-Za-z0-9,._+-]*(@[0-9A-Fa-f,]+)?[[:space:]]*[{][[:space:]]*$/) {
                btype = "node"; open_fragment("target-path = \"/\""); print code > blocks_out
            } else { fail("added DT block header is not alone on its line: " trim(code)); next }
            bcap = 1; blocks++; bdepth = brace_delta(code)
            next
        }
        if (brace_delta(code) != 0) fail("added DT lines are not brace-balanced")
    }
    END {
        boundary()
        printf "%d\t%d\t%d\t%d\t%s\t%d\n", nodes, overrides, gunterminated, node_lines, node_path, blocks
        exit failed
    }
' "$dt_added") || die 'DT structure audit failed'
IFS=$'\t' read -r gpu_nodes gpu_override_count gpu_unterminated gpu_node_lines gpu_node_path dt_block_count <<< "$dt_summary"
((gpu_nodes == 1)) || die "DT series must add exactly one 'gpu: gpu@' node (found $gpu_nodes)"
((gpu_unterminated == 0)) || die 'GPU node or &gpu override is not brace-balanced'
((gpu_node_lines <= max_node_lines)) || die "GPU node exceeds $max_node_lines lines"
[[ $gpu_node_path == arch/arm64/boot/dts/apple/*.dtsi ]] || die "GPU node must live in an SoC .dtsi shared by J514s and J516s: $gpu_node_path"
grep -Fq "\"$compatible\"" "$gpu_node" "$gpu_overrides" || die "GPU node compatible does not include $compatible"
grep -Eq '^[[:space:]]*status[[:space:]]*=[[:space:]]*"disabled"[[:space:]]*;[[:space:]]*$' "$gpu_node" ||
    die 'GPU node must stay status = "disabled"'

readonly dt_blocks_expanded="$tmp/dt-blocks.expanded"
# Public include/dt-bindings constants (irq.h, apple-aic.h, gpio.h); they only
# let the syntax harness compile without cpp and carry no T6030 meaning.
# Function-like macros added by the series are expanded by substitution.
# shellcheck disable=SC2016 # awk program, not shell expansion
readonly expand_awk='
    BEGIN {
        split("AIC_IRQ=0 AIC_FIQ=1 IRQ_TYPE_NONE=0 IRQ_TYPE_EDGE_RISING=1 IRQ_TYPE_EDGE_FALLING=2 " \
            "IRQ_TYPE_EDGE_BOTH=3 IRQ_TYPE_LEVEL_HIGH=4 IRQ_TYPE_LEVEL_LOW=8 GPIO_ACTIVE_HIGH=0 GPIO_ACTIVE_LOW=1", pairs, " ")
        for (i in pairs) { split(pairs[i], kv, "="); macro[kv[1]] = kv[2] }
    }
    function substitute(name, args, count,    body, out, n, i, j, c, tok, params, pcount, k, value) {
        pcount = split(fparams[name], params, ",")
        if (pcount != count && !(pcount == 0 && count == 1 && trim(args[1]) == "")) return ""
        body = fbody[name]; out = ""; n = length(body); i = 1
        while (i <= n) {
            c = substr(body, i, 1)
            if (c ~ /[A-Za-z_]/) {
                for (j = i; j <= n && substr(body, j, 1) ~ /[A-Za-z0-9_]/; j++) {}
                tok = substr(body, i, j - i); value = tok
                for (k = 1; k <= pcount; k++) if (params[k] == tok) value = trim(args[k])
                out = out value; i = j; continue
            }
            out = out c; i++
        }
        return out
    }
    function expand(s, report,    out, i, j, n, c, tok, quoted, depth, count, args, start, value) {
        out = ""; n = length(s); i = 1; quoted = 0
        while (i <= n) {
            c = substr(s, i, 1)
            if (quoted) {
                out = out c
                if (c == "\\") { out = out substr(s, i + 1, 1); i += 2; continue }
                if (c == "\"") quoted = 0
                i++; continue
            }
            if (c == "\"") { quoted = 1; out = out c; i++; continue }
            if (c ~ /[0-9]/) {
                for (j = i; j <= n && substr(s, j, 1) ~ /[0-9A-Za-z_]/; j++) {}
                out = out substr(s, i, j - i); i = j; continue
            }
            if (c ~ /[A-Za-z_]/) {
                for (j = i; j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_]/; j++) {}
                tok = substr(s, i, j - i)
                if (tok in macro) { out = out macro[tok]; i = j; continue }
                if (tok in fbody) {
                    for (start = j; start <= n && substr(s, start, 1) ~ /[[:space:]]/; start++) {}
                    if (substr(s, start, 1) == "(") {
                        depth = 1; count = 1; delete args; args[1] = ""
                        for (start++; start <= n && depth > 0; start++) {
                            c = substr(s, start, 1)
                            if (c == "(") depth++
                            else if (c == ")") { depth--; if (depth == 0) break }
                            else if (c == "," && depth == 1) { args[++count] = ""; continue }
                            args[count] = args[count] c
                        }
                        if (depth == 0 && (value = substitute(tok, args, count)) != "") {
                            out = out value; i = start + 1; continue
                        }
                    }
                }
                if (report && (tok ~ /^[A-Z][A-Z0-9_]+$/ || tok in fbody)) {
                    printf "M4 GPU candidate: unresolved preprocessor macro in added DT node: %s\n", tok > "/dev/stderr"
                    unresolved = 1
                }
                out = out tok
                i = j; continue
            }
            out = out c; i++
        }
        return out
    }
    FILENAME == macro_file { macro[$1] = substr($0, length($1) + 2); next }
    FILENAME == function_file { if ($1 != "") { fparams[$1] = $2; fbody[$1] = $3 }; next }
    {
        line = $0
        for (pass = 0; pass < 4; pass++) { next_line = expand(line, 0); if (next_line == line) break; line = next_line }
        print expand(line, 1)
    }
    END { exit unresolved }
'
awk -F '\t' -v macro_file="$dt_macros" -v function_file="$dt_function_macros" "$awk_lexer$expand_awk" \
    "$dt_macros" "$dt_function_macros" "$dt_blocks" > "$dt_blocks_expanded" || die 'added DT node macro expansion failed'
# Float cells need the Asahi dtc extension and only carry ADT/RE tuning values,
# none of which is device-derived; reject them in every added node.
# shellcheck disable=SC2016 # awk program, not shell expansion
if ! awk "$awk_lexer"'
    { t = strip_strings($0); if (t ~ /[0-9]\.|\.[0-9]/) { printf "M4 GPU candidate: %s\n", trim($0) > "/dev/stderr"; found = 1 } }
    END { exit found }
' "$dt_blocks_expanded"; then
    die 'added DT node carries a float cell literal (tuning values are not device-derived)'
fi
readonly harness="$tmp/m4-gpu-harness.dts"
{
    printf '/dts-v1/;\n/plugin/;\n\n'
    printf '/* Generated syntax harness: every node the candidate DT series adds, never a boot DT. */\n'
    printf '/ {\n'
    cat "$dt_blocks_expanded"
    printf '};\n'
} > "$harness"
# The harness adds #address-cells/#size-cells to every fragment, so the check
# for unnecessary cells only reflects the harness and is not reported.
if ! run_bounded "$dtc_seconds" dtc -Wno-avoid_unnecessary_addr_size -I dts -O dtb \
    -o "$tmp/m4-gpu-harness.dtbo" "$harness" 2> "$tmp/dtc.log"; then
    sed -n '1,20p' "$tmp/dtc.log" >&2
    die 'candidate DT overlay failed the bounded dtc syntax check'
fi
[[ -s $tmp/m4-gpu-harness.dtbo ]] || die 'dtc produced no candidate DT overlay'
dtc_warnings=$(grep -c 'Warning' "$tmp/dtc.log" || :)
if ((dtc_warnings > 0)); then
    sed -n '1,20p' "$tmp/dtc.log" >&2
    die "candidate DT overlay harness has $dtc_warnings dtc warning(s)"
fi

# --- (d) fabrication and success-claim audit ---------------------------------
readonly forbidden="$tmp/forbidden.ere"
printf '%s\n' \
    "hardware_acceptance[[:space:]]*[=:][[:space:]]*[\"']?(true|yes)" \
    "evidence_valid[[:space:]]*[=:][[:space:]]*[\"']?(true|yes)" \
    'conformance[[:space:]_-]*pass' \
    'pass(es|ed)?[[:space:]]+(the[[:space:]]+)?conformance' \
    'gpu[[:space:]_-]+rendering[[:space:]_-]+((is|was)[[:space:]]+)?verified' \
    '(^|[^[:alnum:]_])proven([^[:alnum:]_]|$)' \
    'production[[:space:]_-]*ready' > "$forbidden"
for file in "${candidate_files[@]}"; do
    if hit=$(LC_ALL=C grep -iEn -f "$forbidden" -- "$file"); then
        die "forbidden success token in $(relative "$file"): ${hit%%$'\n'*}"
    fi
done
# Each RE-gated profile item must still be tracked by the series as UNKNOWN,
# TODO(re) or an RE_GATED sentinel, and no line naming it may give it a number
# in any radix.
# shellcheck disable=SC2016 # awk program, not shell expansion
readonly mention_awk='
    index($0, key) {
        line = $0
        if (index(line, "UNKNOWN") || index(line, "TODO(re)") || index(line, "RE_GATED")) { tracked++; next }
        gsub(key, " ", line)
        count = scan(line)
        for (t = 1; t <= count; t++) if (tok_kind[t] == "num" && number_class(tok_text[t]) != "zero") valued = 1
        if (valued) {
            printf "M4 GPU candidate: %s:%d gives %s a value\n", substr(FILENAME, length(root) + 2), FNR, key > "/dev/stderr"
            exit 1
        }
    }
    END { if (!valued) print tracked + 0 }
'
for key in "${re_gated_keys[@]}"; do
    tracked=$(awk -v key="$key" -v root="$project_root" "$awk_lexer$mention_awk" "${series_files[@]}") ||
        die "RE-gated item carries a value without UNKNOWN, TODO(re) or RE_GATED: $key"
    ((tracked > 0)) || die "RE-gated item is not tracked as UNKNOWN, TODO(re) or RE_GATED by the candidate series: $key"
done

# shellcheck disable=SC2016 # awk program, not shell expansion
readonly audit_awk='
    BEGIN {
        dt_key = "^[[:space:]]*(apple,[A-Za-z0-9,._+-]+|opp-hz|opp-microvolt(-[A-Za-z0-9]+)?|" \
            "opp-microamp(-[A-Za-z0-9]+)?|opp-microwatt|opp-level|opp-peak-kBps|opp-avg-kBps|" \
            "reg|interrupts|interrupts-extended)[[:space:]]*="
        sentinel_name = "([A-Z0-9_]*_)?(RE_GATED|ADT_GATED|ADT)(_[A-Z0-9_]*)?"
        dt_def = "^[[:space:]]*#[[:space:]]*define[[:space:]]+" sentinel_name "([[:space:]]|$)"
        dt_function = "^[[:space:]]*#[[:space:]]*define[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[(]"
        rs_key = "^[[:space:]]*(pub(\\([a-z]+\\))?[[:space:]]+)?(unk_coef_a|unk_coef_b|da|db|" \
            "unk_87c|unk_8cc|unk_e24|unk_454|unk_4e0|unk_534|unk_ab8|unk_abc|unk_b30|" \
            "shared1_tab|shared1_a4|shared2_tab|shared2_unk_508|shared2_curves|shared3_unk|shared3_tab|" \
            "t1_coef|t2|t3_coefs|t3_scales|preempt1_size|preempt2_size|preempt3_size|compute_preempt1_size|" \
            "fast_sensor_mask|fast_sensor_mask_alt|fast_die0_sensor_present|" \
            "sram_k|base_clock_hz|uat_oas|tiling_control|idle_off_standby_timer_default|unk_hws2_[0-9a-z_]+|" \
            "global_tab|global_unk_[0-9a-f]+|io_mappings|sram_base|sram_size|has_csafr|" \
            "meta1_blocksize|meta2_size|meta3_size|meta4_size|max_splits)[[:space:]]*:"
        rs_def = "^[[:space:]]*(pub(\\([a-z]+\\))?[[:space:]]+)?(const|static)[[:space:]]+" sentinel_name "[[:space:]]*:"
        allowed = "^(UNKNOWN|Some|None|Option|static|as|true|false|from_bits|" \
            "f32|F32|u8|u16|u32|u64|i8|i16|i32|i64|usize|isize|bool|" \
            "HwConfigA|HwConfigB|HwConfigShared2Curves|unk_[0-9a-f]+|t1_coef|t2|t3_coefs|t3_scales|" \
            "AIC_IRQ|AIC_FIQ|IRQ_TYPE_[A-Z_]+)$"
    }
    function item_of(key) {
        if (key ~ /(^|_)ADT(_|$)|ADT_GATED/) return "ADT_GATED sentinel"
        if (key ~ /^(reg|interrupts|interrupts-extended)$/) return "ADT_GATED resource"
        if (key ~ /firmware-(version|compat)/) return "apple_firmware_version"
        if (key ~ /firmware-abi/) return "apple_firmware_abi"
        if (key ~ /^opp-|min-sram-microvolt/) return "gpu_opp_dvfs_table"
        if (key ~ /^apple,/) return "gpu_power_tuning"
        if (key == "unk_coef_a") return "hwconfig_unk_coef_a"
        if (key == "unk_coef_b") return "hwconfig_unk_coef_b"
        if (key ~ /^(da|db|unk_[0-9a-f]+)$/) return "hwconfig_da_db"
        if (key ~ /^(shared|t1_coef|t2|t3_)/) return "hwdata_shared_tables"
        if (key ~ /preempt/) return "preempt_buffer_sizes"
        if (key ~ /sensor/) return "temp_sensor_mask"
        if (key ~ /^(sram_k|base_clock_hz|uat_oas|tiling_control|idle_off_standby_timer_default|unk_hws2_|global_|io_mappings|sram_base|sram_size|has_csafr|meta[1-4]_|max_splits)/)
            return "hwconfig_firmware_fields"
        return "RE_GATED sentinel"
    }
    function report(message) {
        printf "M4 GPU candidate: %s in %s: %s: %s\n", message, swhere, spath, skey > "/dev/stderr"
        failed = 1
    }
    function line_report(message) {
        printf "M4 GPU candidate: %s in %s: %s\n", message, where, path > "/dev/stderr"
        failed = 1
    }
    function open_statement(statement_kind, code, raw, marker, separator, terminator,    position, rest, name) {
        if (separator == "name") {
            rest = code; sub(/^[[:space:]]*#[[:space:]]*define[[:space:]]+/, "", rest)
            name = rest; sub(/[[:space:]].*$/, "", name); rest = substr(rest, length(name) + 1)
        } else {
            position = index(code, separator)
            name = substr(code, 1, position - 1); rest = substr(code, position + 1)
            sub(/^[[:space:]]*(pub(\([a-z]+\))?[[:space:]]+)?((const|static)[[:space:]]+)?/, "", name)
            sub(/[[:space:]]+$/, "", name)
        }
        active = 1; skind = statement_kind; skey = name; smark = marker; sraw = raw; sval = ""; sstring = 0
        sdepth = 0; slines = 0; sterm = terminator; sadded = (kind == "+"); swhere = where; spath = path; sdone = 0
        if (skind == "def" && sadded) defined[name] = 1
        feed(rest)
        end_line()
    }
    function feed(s,    t, i, n, c) {
        t = strip_strings(s); n = length(t)
        if (t != s) sstring = 1
        for (i = 1; i <= n && !sdone; i++) {
            c = substr(t, i, 1)
            if (c == "(" || c == "[" || c == "{") sdepth++
            else if (c == ")" || c == "]" || c == "}") { sdepth--; if (sterm == "comma" && sdepth < 0) { sdone = 1; break } }
            else if (c == ";" && sterm == "semicolon" && sdepth <= 0) { sdone = 1; break }
            else if (c == "," && sterm == "comma" && sdepth == 0) { sdone = 1; break }
            sval = sval c
        }
    }
    function end_line() {
        slines++; sval = sval " "
        if (sterm == "eol" || (sterm == "comma" && sdepth <= 0)) sdone = 1
        if (sdone) evaluate()
        else if (slines > 400) { report("unterminated RE-gated statement"); active = 0 }
    }
    # A function-like DT macro is structural (e.g. GPU_REPEAT(x) <x x>) only when
    # its body holds nothing but its parameters and zero literals.
    function define_function(code,    rest, name, params, body, count, i, names, parameter, k, structural_body) {
        rest = code; sub(/^[[:space:]]*#[[:space:]]*define[[:space:]]+/, "", rest)
        name = rest; sub(/[(].*$/, "", name)
        params = substr(rest, length(name) + 2); body = params
        sub(/[)].*$/, "", params); sub(/^[^)]*[)]/, "", body)
        count = split(params, names, ",")
        for (i = 1; i <= count; i++) { gsub(/[[:space:]]/, "", names[i]); parameter[names[i]] = 1 }
        structural_body = 1
        count = scan(body)
        for (k = 1; k <= count; k++) {
            if (tok_kind[k] == "id" && !(tok_text[k] in parameter)) structural_body = 0
            if (tok_kind[k] == "num" && number_class(tok_text[k]) != "zero") structural_body = 0
        }
        if (structural_body) structural[name] = 1
        else if (name in structural) delete structural[name]
    }
    function labelled(notes, class) {
        notes = tolower(notes)
        if (index(notes, "not a working value") || index(notes, "todo(re)") || index(notes, "re-gated")) return 1
        return class == "adt" && (index(notes, "todo(adt)") || index(notes, "adt-gated"))
    }
    function evaluate(    v, nonzero, sentinel, bad, id, position, marked, item, word, count, k, class) {
        active = 0
        if (!sadded) return
        v = sval
        if (skind == "def" && sterm == "semicolon") { position = index(v, "="); v = position ? substr(v, position + 1) : "" }
        gsub(/\/bits\/[[:space:]]*[0-9]+/, " ", v)
        gsub(/;[[:space:]]*[0-9_]+[[:space:]]*\]/, "]", v)
        nonzero = 0; sentinel = 0; bad = ""
        count = scan(v)
        for (k = 1; k <= count; k++) {
            id = tok_text[k]
            if (tok_kind[k] == "num") {
                class = number_class(id)
                if (class == "value") nonzero = 1
                continue
            }
            if (id ~ ("^" sentinel_name "$")) {
                sentinel = 1
                if (!(id in used)) { used[id] = 1; used_where[id] = swhere ": " spath ": " skey }
            }
            else if (id in structural) { }
            else if (id !~ allowed && bad == "") bad = id
        }
        item = item_of(skey)
        word = item ~ /ADT/ ? "ADT-gated" : "RE-gated"
        marked = labelled(smark "\n" sraw, word == "ADT-gated" ? "adt" : "re")
        if (nonzero) report("fabricated " word " value (" item ")")
        else if (sstring) report(word " value (" item ") is a string literal")
        else if (skind != "decl" && bad != "") report(word " value (" item ") references non-sentinel identifier " bad)
        else if (skind == "def" && !marked) report("unlabeled " word " sentinel (" item ")")
        else if ((skind == "field" || skind == "prop") && !sentinel && !marked) report("unlabeled " word " placeholder (" item ")")
        checked++
    }
    function identity(code,    v) {
        if (match(code, /chip_id[[:space:]]*:[[:space:]]*0[xX][0-9A-Fa-f]+/)) {
            v = tolower(substr(code, RSTART, RLENGTH)); sub(/^chip_id[[:space:]]*:[[:space:]]*/, "", v)
            if (v != chip) line_report("HwConfig chip_id " v " differs from profile chip_id " chip)
            else chip_seen++
        }
        if (code ~ /gpu_gen[[:space:]]*:/ && match(code, /GpuGen::G[0-9]+/)) {
            v = substr(code, RSTART + 9, RLENGTH - 9)
            if (v != gen) line_report("HwConfig gpu_gen G" v " differs from profile gpu_gen " gen)
        }
        if (code ~ /gpu_variant[[:space:]]*:/ && match(code, /GpuVariant::[A-Za-z]+/)) {
            v = substr(code, RSTART + 12, RLENGTH - 12)
            if (v != variant) line_report("HwConfig gpu_variant " v " differs from profile gpu_variant " variant)
        }
        if (code ~ /gpu_core[[:space:]]*:/ && match(code, /GpuCore::G[0-9]+[A-Za-z]*/)) {
            v = substr(code, RSTART + 9, RLENGTH - 9)
            if (v != "G" gen variant) line_report("HwConfig gpu_core " v " differs from profile G" gen variant)
        }
        if (match(code, /\.\.[[:space:]]*([A-Za-z0-9_]+::)*HWCONFIG_[A-Za-z0-9_]+/)) {
            v = substr(code, RSTART, RLENGTH); sub(/^.*HWCONFIG_/, "", v)
            if (v !~ /^T603/) line_report("HwConfig inherits RE-gated fields from another SoC (HWCONFIG_" v ")")
        }
    }
    function finish() { if (active) { if (!sdone && sadded) report("unterminated RE-gated statement"); else evaluate(); active = 0 } }
    $1 == "H" || $1 == "F" || $1 == "O" || $1 == "D" { finish(); in_comment = 0; pending = ""; next }
    $1 != "+" && $1 != " " { next }
    {
        kind = $1; where = $2; path = $3
        text = substr($0, length($1) + length($2) + length($3) + 4)
        if (path ~ /^arch\/arm64\/boot\/dts\/apple\//) lang = "dt"
        else if (path ~ /^drivers\/gpu\/drm\/asahi\/.*\.rs$/) lang = "rs"
        else next
        code = strip_comments(text)
        if (active) { sraw = sraw "\n" text; feed(code); end_line(); next }
        if (code ~ /^[[:space:]]*$/) {
            if (text ~ /^[[:space:]]*$/) pending = ""
            else pending = pending "\n" text
            next
        }
        marker = pending; pending = ""
        if (lang == "dt" && code ~ dt_function) { define_function(code); next }
        if (kind == "+" && lang == "rs") identity(code)
        if (lang == "dt" && code ~ dt_key) open_statement("prop", code, text, marker, "=", "semicolon")
        else if (lang == "dt" && code ~ dt_def) open_statement("def", code, text, marker, "name", "eol")
        else if (lang == "rs" && code ~ rs_def) open_statement("def", code, text, marker, ":", "semicolon")
        else if (lang == "rs" && code ~ rs_key && substr(code, index(code, ":") + 1, 1) != ":")
            open_statement(code ~ /^[[:space:]]*pub/ ? "decl" : "field", code, text, marker, ":", "comma")
    }
    END {
        finish()
        for (id in used) if (!(id in defined)) {
            printf "M4 GPU candidate: gated sentinel %s is not defined by the candidate series (used in %s)\n", id, used_where[id] > "/dev/stderr"
            failed = 1
        }
        if (!chip_seen) {
            printf "M4 GPU candidate: driver series adds no HwConfig with chip_id %s\n", chip > "/dev/stderr"
            failed = 1
        }
        print checked + 0
        exit failed
    }
'
re_gated_checked=$(awk -F '\t' -v chip="$chip_id" -v gen="$gpu_gen" -v variant="$gpu_variant" \
    "$awk_lexer$audit_awk" "$stream") || die 'RE-gated placeholder audit failed'

# --- (e) optional replay onto the pinned tree and full-board dtc builds ------
# The pinned tree is only read (git archive); the series is applied with git am
# in a disposable repository holding the pinned commit's DT, dt-bindings and
# touched files, so a dirty or case-folded checkout cannot affect the result.
replay_lines=()
if [[ -z $linux_pin || ! -e $linux_pin ]]; then
    replay_lines+=('patch_replay=not-run' 'patch_replay_reason=pinned-linux-tree-absent' 'board_dtc_new_warnings=not-run')
else
    command -v git >/dev/null 2>&1 || die 'git is required for the pinned-tree replay'
    preprocessor=
    for tool in clang gcc cpp; do
        if command -v "$tool" >/dev/null 2>&1; then preprocessor=$tool; break; fi
    done
    [[ -n $preprocessor ]] || die 'a C preprocessor (clang, gcc or cpp) is required for the pinned-tree replay'
    [[ $linux_pin_commit =~ ^[0-9a-f]{40}$ ]] || die "M4_GPU_LINUX_PIN_COMMIT is not a full commit id: $linux_pin_commit"
    git -C "$linux_pin" rev-parse --verify --quiet "$linux_pin_commit^{commit}" >/dev/null ||
        die "pinned Linux tree lacks commit $linux_pin_commit: $linux_pin"
    replay="$tmp/linux-replay"
    mkdir "$replay"
    archive_paths=(arch/arm64/boot/dts/apple include/dt-bindings scripts/dtc/include-prefixes/dt-bindings)
    while IFS= read -r path; do
        [[ $path != /dev/null && $path != arch/arm64/boot/dts/apple/* ]] || continue
        archive_paths+=("$path")
    done < <(awk -F '\t' '$1 == "F" || $1 == "O" || $1 == "D" { print $3 }' "$stream" | LC_ALL=C sort -u)
    present_paths=()
    for path in "${archive_paths[@]}"; do
        if git -C "$linux_pin" cat-file -e "$linux_pin_commit:$path" 2>/dev/null; then present_paths+=("$path"); fi
    done
    git -C "$linux_pin" archive --format=tar "$linux_pin_commit" -- "${present_paths[@]}" > "$tmp/pin.tar" ||
        die 'git archive of the pinned Linux tree failed'
    tar -xf "$tmp/pin.tar" -C "$replay" || die 'unpacking the pinned Linux tree failed'
    rm -f -- "$tmp/pin.tar"
    replay_git() {
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
            GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@localhost GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@localhost \
            run_bounded "$replay_seconds" git -C "$replay" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
            -c core.autocrlf=false -c gc.auto=0 -c gc.autoDetach=false -c maintenance.auto=false \
            -c core.fsmonitor=false "$@"
    }
    replay_git init -q >/dev/null 2>&1 || die 'cannot initialise the replay repository'
    replay_git add -A >/dev/null 2>&1 || die 'cannot stage the pinned tree in the replay repository'
    replay_git commit -q --no-verify -m "pinned $linux_pin_commit" >/dev/null 2>&1 || die 'cannot commit the pinned tree in the replay repository'

    # Prints the normalized warning list; the build log and DTB stay in $tmp.
    build_board() {
        local board=$1 tag=$2 log="$tmp/board-$1-$2.log"
        (cd -- "$replay" && run_bounded "$dtc_seconds" "$preprocessor" -E -nostdinc -undef -D__DTS__ \
            -x assembler-with-cpp -I arch/arm64/boot/dts/apple -I include -I scripts/dtc/include-prefixes \
            -o "$tmp/board-$board-$tag.dts" "arch/arm64/boot/dts/apple/$board.dts") > "$log" 2>&1 || return 1
        run_bounded "$dtc_seconds" dtc -I dts -O dtb -o "$tmp/board-$board-$tag.dtb" "$tmp/board-$board-$tag.dts" \
            >> "$log" 2>&1 || return 1
        sed -n 's/^.*\(Warning (.*\)$/\1/p' "$log" | LC_ALL=C sort > "$tmp/board-$board-$tag.warnings"
    }
    # path<TAB>status<TAB>compatible for every node of a decompiled DTB.
    # shellcheck disable=SC2016 # awk program, not shell expansion
    readonly nodes_awk='
        function value(line) { sub(/^[^=]*=[[:space:]]*/, "", line); sub(/;[[:space:]]*$/, "", line); return line }
        /^[[:space:]]*[^[:space:]=]+[[:space:]]*[{][[:space:]]*$/ {
            name = $1; sub(/[[:space:]]*[{].*$/, "", name)
            node = depth == 0 ? "/" : (stack[depth] == "/" ? "/" name : stack[depth] "/" name)
            stack[++depth] = node; order[++count] = node; status[node] = "-"; compat[node] = ""; next
        }
        /^[[:space:]]*[}];[[:space:]]*$/ { depth--; next }
        /^[[:space:]]*status[[:space:]]*=/ { status[stack[depth]] = value($0); next }
        /^[[:space:]]*compatible[[:space:]]*=/ { compat[stack[depth]] = value($0); next }
        END { for (i = 1; i <= count; i++) print order[i] "\t" status[order[i]] "\t" compat[order[i]] }
    '
    for board in "${boards[@]}"; do
        [[ -f $replay/arch/arm64/boot/dts/apple/$board.dts ]] || die "pinned Linux tree lacks board $board"
        build_board "$board" baseline || { sed -n '1,20p' "$tmp/board-$board-baseline.log" >&2; die "pinned baseline board does not build: $board"; }
    done
    am_log="$tmp/git-am.log"
    replay_git am -q --no-3way "${series_patches[@]}" > "$am_log" 2>&1 || {
        sed -n '1,20p' "$am_log" >&2
        die "patch series does not git-am cleanly onto pinned commit $linux_pin_commit"
    }
    applied=$(($(replay_git rev-list --count HEAD) - 1))
    ((applied == ${#series_patches[@]})) || die "git am applied $applied of ${#series_patches[@]} patches"
    replay_lines+=('patch_replay=git-am-clean' "patch_replay_pinned_commit=$linux_pin_commit" "patch_replay_patches=$applied")
    total_new=0
    for board in "${boards[@]}"; do
        build_board "$board" patched || { sed -n '1,20p' "$tmp/board-$board-patched.log" >&2; die "patched board does not build: $board"; }
        baseline_count=$(wc -l < "$tmp/board-$board-baseline.warnings" | tr -d '[:space:]')
        patched_count=$(wc -l < "$tmp/board-$board-patched.warnings" | tr -d '[:space:]')
        new_count=$(LC_ALL=C comm -13 "$tmp/board-$board-baseline.warnings" "$tmp/board-$board-patched.warnings" | wc -l | tr -d '[:space:]')
        if ((new_count > 0 || patched_count > baseline_count)); then
            LC_ALL=C comm -13 "$tmp/board-$board-baseline.warnings" "$tmp/board-$board-patched.warnings" | sed -n '1,20p' >&2
            die "patched board $board has new dtc warnings ($patched_count vs baseline $baseline_count)"
        fi
        for tag in baseline patched; do
            dtc -I dtb -O dts "$tmp/board-$board-$tag.dtb" 2>/dev/null | awk "$nodes_awk" > "$tmp/board-$board-$tag.nodes" ||
                die "cannot decompile $tag board DTB: $board"
        done
        # Existing nodes keep their status; every new node is disabled except
        # operating-points-v2 tables and their entries, which have no status.
        gpu_status=$(awk -F '\t' -v board="$board" -v compatible="$compatible" '
            FNR == NR { base[$1] = $2; next }
            $3 ~ /operating-points-v2/ { opp[$1] = 1 }
            {
                parent = $1; sub(/\/[^\/]*$/, "", parent)
                if ($1 in base) {
                    if (base[$1] != $2) { printf "M4 GPU candidate: board %s changes the status of existing node %s (%s -> %s)\n", board, $1, base[$1], $2 > "/dev/stderr"; bad = 1 }
                } else if (!($1 in opp) && !(parent in opp) && $2 != "\"disabled\"") {
                    printf "M4 GPU candidate: board %s adds node %s that is not disabled (status %s)\n", board, $1, $2 > "/dev/stderr"; bad = 1
                }
                if (index($3, "\"" compatible "\"")) { gpu++; if ($2 != "\"disabled\"") { printf "M4 GPU candidate: board %s GPU node %s is not disabled\n", board, $1 > "/dev/stderr"; bad = 1 } }
            }
            END { if (gpu != 1) { printf "M4 GPU candidate: board %s has %d nodes with the GPU compatible\n", board, gpu > "/dev/stderr"; bad = 1 }; print "disabled"; exit bad }
        ' "$tmp/board-$board-baseline.nodes" "$tmp/board-$board-patched.nodes") ||
            die "board DTB status audit failed: $board"
        total_new=$((total_new + new_count))
        replay_lines+=("board_dtb_$board=built,baseline_warnings=$baseline_count,patched_warnings=$patched_count,new_warnings=$new_count,gpu_status=$gpu_status")
    done
    replay_lines+=("board_dtc_new_warnings=$total_new")
fi

# --- (f) static result; hardware stays blocked -------------------------------
printf 'M4-gpu-source-candidate=checked-static-only\n'
printf 'gpu_silicon_profile=consistent\n'
printf 'gpu_chip_id=%s\n' "$chip_id"
printf 'gpu_gen=%s\n' "$gpu_gen"
printf 'gpu_variant=%s\n' "$gpu_variant"
printf 'gpu_usc_gen=%s\n' "$usc_gen"
printf 'gpu_num_mgpus=%s\n' "$num_mgpus"
printf 'gpu_cores_physical=%s\n' "$physical"
printf 'gpu_cores_active=%s\n' "$active"
printf 'gpu_core_mask_list=%s\n' "$core_mask_list"
printf 're_gated_profile_items=%s\n' "${#re_gated_keys[@]}"
printf 're_gated_profile_items_unknown=%s\n' "$re_gated_unknown"
printf 'gpu_patch_series=%s\n' "${#series_dirs[@]}"
printf 'gpu_dt_patches=%s\n' "$dt_patches"
printf 'gpu_driver_patches=%s\n' "$driver_patches"
printf 'gpu_patch_scope=checked\n'
printf 'gpu_node_source=%s\n' "$gpu_node_path"
printf 'gpu_node_overrides=%s\n' "$gpu_override_count"
printf 'gpu_node_status=disabled\n'
printf 'dt_added_blocks=%s\n' "$dt_block_count"
printf 'dt_overlay_dtc_syntax=checked\n'
printf 'dt_overlay_dtc_warnings=%s\n' "${dtc_warnings:-0}"
printf 're_gated_placeholders_checked=%s\n' "$re_gated_checked"
printf 'forbidden_success_tokens=absent\n'
printf '%s\n' "${replay_lines[@]}"
printf 'native_runtime_evidence=false\n'
printf 'tooling_valid=true\nevidence_valid=not-provided\nhardware_acceptance=false\n'
printf 'gate=blocked-for-native-execution\n'
exit 2
