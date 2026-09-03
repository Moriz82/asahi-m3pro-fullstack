#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
readonly m0_root="${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone0"

verify_checksum_manifest() {
    python3 - "$1" "$2" "${3:-recursive}" <<'PY'
import hashlib, os, re, stat, sys

root, sums = map(os.path.abspath, sys.argv[1:3])
scope = sys.argv[3]
if os.path.islink(sums):
    raise SystemExit('checksum root or manifest is not a real directory/file')
root = os.path.realpath(root)
sums = os.path.realpath(sums)
if not os.path.isdir(root):
    raise SystemExit('checksum root or manifest is not a real directory/file')
if os.path.relpath(sums, root) != 'SHA256SUMS':
    raise SystemExit('checksum manifest must be the rooted SHA256SUMS file')
line_re = re.compile(rb'^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+@%=-]*(?:/[A-Za-z0-9][A-Za-z0-9._+@%=-]*)*)\n$')
try:
    data = open(sums, 'rb').read()
except OSError as exc:
    raise SystemExit(str(exc))
if not data or not data.endswith(b'\n'):
    raise SystemExit('checksum manifest must have newline-terminated records')
listed = {}
for line in data.splitlines(keepends=True):
    match = line_re.fullmatch(line)
    if not match:
        raise SystemExit('invalid checksum record')
    rel = match.group(2).decode('ascii')
    if rel == 'SHA256SUMS' or any(part in ('.', '..') for part in rel.split('/')):
        raise SystemExit('unsafe checksum path')
    target = os.path.abspath(os.path.join(root, rel))
    if os.path.commonpath((root, target)) != root or rel in listed:
        raise SystemExit('duplicate or escaping checksum path')
    listed[rel] = match.group(1).decode('ascii')
actual = {}
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    for name in list(dirs) + list(files):
        path = os.path.join(current, name)
        if os.path.islink(path):
            raise SystemExit('symlink anywhere in evidence tree')
        if not os.path.isdir(path) and not stat.S_ISREG(os.lstat(path).st_mode):
            raise SystemExit('non-regular evidence tree member')
    for name in files:
        path = os.path.join(current, name)
        rel = os.path.relpath(path, root).replace(os.sep, '/')
        if rel != 'SHA256SUMS' and (scope == 'recursive' or current == root):
            digest = hashlib.sha256(open(path, 'rb').read()).hexdigest()
            actual[rel] = digest
if set(listed) != set(actual):
    raise SystemExit('checksum manifest has missing or extra files')
for rel, expected in listed.items():
    if actual[rel] != expected:
        raise SystemExit('checksum mismatch: ' + rel)
PY
}

if [[ "${1:-}" == --self-test ]]; then
    [[ "$M1_REQUIRED_BOOT_COUNT" == 20 ]]
    for name in watchdog panic reboot macos-return dfu; do
        grep -Fq "$name" "${project_root}/scripts/verify-milestone1-session.sh"
    done
    grep -Fq 'seen[$1]++' "${project_root}/scripts/verify-milestone1-session.sh"
    grep -Fq 'serial_path' "${project_root}/scripts/verify-milestone1-session.sh"
    printf 'verify-milestone1-session self-test passed\n'
    exit 0
fi
readonly evidence="${1:-}"
test -n "$evidence" && test -d "$evidence" || { printf 'Session directory is required.\n' >&2; exit 2; }
for required in manifest.txt records.tsv SHA256SUMS; do
    test -s "$evidence/$required" || { printf 'Missing session evidence: %s\n' "$evidence/$required" >&2; exit 1; }
done
verify_checksum_manifest "$evidence" "$evidence/SHA256SUMS" top-level
grep -Fx 'format=1' "$evidence/manifest.txt" >/dev/null
grep -Fx 'status=complete' "$evidence/manifest.txt" >/dev/null
grep -Fx 'storage_policy=ram-only' "$evidence/manifest.txt" >/dev/null
grep -Fx 'evidence_policy=checksummed-execution-and-serial' "$evidence/manifest.txt" >/dev/null
grep -Eq '^initramfs_sha256=[0-9a-f]{64}$' "$evidence/manifest.txt"
session_tool="$(awk -F= '$1 == "tool" {sub(/^[^=]*=/, ""); print; exit}' "$evidence/manifest.txt")"
session_device="$(awk -F= '$1 == "device" {sub(/^[^=]*=/, ""); print; exit}' "$evidence/manifest.txt")"
session_command="$(awk -F= '$1 == "command" {sub(/^[^=]*=/, ""); print; exit}' "$evidence/manifest.txt")"
test -n "$session_tool" && test -n "$session_device" && test -n "$session_command"

readonly m0_run_dir="$(cd "${m0_root}/linux-full/latest" && pwd -P)"
readonly m0_run_id="$(basename "$m0_run_dir")"
readonly m0_manifest_sha256="$(shasum -a 256 "$m0_run_dir/manifest.txt" | awk '{print $1}')"
readonly image_sha256="$(shasum -a 256 "$m0_run_dir/Image" | awk '{print $1}')"
readonly dtb_sha256="$(shasum -a 256 "$m0_run_dir/dtbs/apple/t6030-j514s.dtb" | awk '{print $1}')"
grep -Fx "source_commit=${M1N1_COMMIT}" "$evidence/manifest.txt" >/dev/null
grep -Fx "m0_run_id=${m0_run_id}" "$evidence/manifest.txt" >/dev/null
grep -Fx "m0_manifest_sha256=${m0_manifest_sha256}" "$evidence/manifest.txt" >/dev/null
grep -Fx "image_sha256=${image_sha256}" "$evidence/manifest.txt" >/dev/null
grep -Fx "dtb_sha256=${dtb_sha256}" "$evidence/manifest.txt" >/dev/null

scan_clean() {
    local file="$1"
    if grep -Eiq 'corrupt(ion)?|kernel panic|panic:|I/O error|data loss|filesystem (error|corrupt)|watchdog reset|unexpected reset|fault signature|gate_failed' "$file"; then
        printf 'Fault, corruption, or gate signature found: %s\n' "$file" >&2
        return 1
    fi
}

readonly evidence_real="$(cd "$evidence" && pwd -P)"
for entry in "$evidence"/*; do
    name="$(basename "$entry")"
    case "$name" in
        manifest.txt|records.tsv|SHA256SUMS|evidence-watchdog.txt|evidence-panic.txt|evidence-reboot.txt|evidence-macos-return.txt|evidence-dfu.txt)
            test -f "$entry" && test ! -L "$entry" ;;
        run-*)
            [[ "$name" =~ ^run-([1-9]|1[0-9]|20)$ ]] && test -d "$entry" && test ! -L "$entry" ;;
        *)
            printf 'Unexpected session evidence entry: %s\n' "$entry" >&2
            exit 1 ;;
    esac
done
count="$(awk -v required="$M1_REQUIRED_BOOT_COUNT" -F '\t' '
    BEGIN { good=0; bad=0 }
    /^[[:space:]]*$/ || /^#/ { next }
    NF != 4 || $2 != "success" || $1 !~ /^[0-9]+$/ || $3 == "" || $4 == "" || seen[$1]++ { bad++; next }
    { good++ }
    END { if (bad || good != required) exit 1; print good }
' "$evidence/records.tsv")" || { printf 'Invalid records.tsv count or duplicate IDs.\n' >&2; exit 1; }
readonly count
if [[ "$count" != "$M1_REQUIRED_BOOT_COUNT" ]]; then
    printf 'Expected exactly %s successful records; found %s.\n' "$M1_REQUIRED_BOOT_COUNT" "$count" >&2
    exit 1
fi
while IFS=$'\t' read -r boot_id result execution_dir serial_path; do
    [[ -z "$boot_id" || "$boot_id" == \#* ]] && continue
    if [[ "$result" != success ]]; then exit 1; fi
    if [[ "$execution_dir" == /* || "$execution_dir" == *..* || "$serial_path" == /* || "$serial_path" == *..* ]]; then exit 1; fi
    execution_path="$evidence/$execution_dir"
    test -d "$execution_path" && test ! -L "$execution_path"
    execution_real="$(cd "$execution_path" && pwd -P)"
    if [[ "$execution_real" != "$evidence_real/"* ]]; then exit 1; fi
    for required in manifest.txt SHA256SUMS host.log serial.log; do
        test -s "$execution_path/$required" || { printf 'Missing execution evidence: %s\n' "$execution_path/$required" >&2; exit 1; }
    done
    verify_checksum_manifest "$execution_path" "$execution_path/SHA256SUMS"
    serial_file="$execution_path/$serial_path"
    test -f "$serial_file" && test ! -L "$serial_file"
    serial_real="$(cd "$(dirname "$serial_file")" && pwd -P)/$(basename "$serial_file")"
    if [[ "$serial_real" != "$execution_real/"* ]]; then exit 1; fi
    test -s "$serial_file"
    grep -Fx 'status=completed' "$execution_path/manifest.txt" >/dev/null
    grep -Fx 'producer_exit=0' "$execution_path/manifest.txt" >/dev/null
    grep -Fx 'tee_exit=0' "$execution_path/manifest.txt" >/dev/null
    grep -Fx 'pipe_status=0,0' "$execution_path/manifest.txt" >/dev/null
    grep -Fx 'storage_policy=ram-only' "$execution_path/manifest.txt" >/dev/null
    grep -Fq 'command=' "$execution_path/manifest.txt"
    grep -Fq -- '--compression none' "$execution_path/manifest.txt"
    if grep -Fq 'root=' "$execution_path/manifest.txt"; then exit 1; fi
    grep -Fx "source_commit=${M1N1_COMMIT}" "$execution_path/manifest.txt" >/dev/null
    grep -Fx "m0_run_id=${m0_run_id}" "$execution_path/manifest.txt" >/dev/null
    grep -Fx "m0_manifest_sha256=${m0_manifest_sha256}" "$execution_path/manifest.txt" >/dev/null
    grep -Fx "image_sha256=${image_sha256}" "$execution_path/manifest.txt" >/dev/null
    grep -Fx "dtb_sha256=${dtb_sha256}" "$execution_path/manifest.txt" >/dev/null
    grep -Fx "initramfs_sha256=$(awk -F= '$1 == "initramfs_sha256" {print $2; exit}' "$evidence/manifest.txt")" "$execution_path/manifest.txt" >/dev/null
    grep -Fx "tool=${session_tool}" "$execution_path/manifest.txt" >/dev/null
    grep -Fx "device=${session_device}" "$execution_path/manifest.txt" >/dev/null
    grep -Fx "command=${session_command}" "$execution_path/manifest.txt" >/dev/null
    scan_clean "$serial_file"
    scan_clean "$execution_path/host.log"
done <"$evidence/records.tsv"

for required in watchdog panic reboot macos-return dfu; do
    evidence_file="$evidence/evidence-${required}.txt"
    test -s "$evidence_file" || { printf 'Missing required observation evidence: %s\n' "$evidence_file" >&2; exit 1; }
    grep -Fx 'observed=true' "$evidence_file" >/dev/null
    grep -Fx 'recorded_by=operator' "$evidence_file" >/dev/null
    grep -Fx 'source=serial-log' "$evidence_file" >/dev/null
    grep -F "  evidence-${required}.txt" "$evidence/SHA256SUMS" >/dev/null
    scan_clean "$evidence_file"
done
printf 'milestone1.session=verified evidence_complete=true hardware_exit_claim=false\n'
