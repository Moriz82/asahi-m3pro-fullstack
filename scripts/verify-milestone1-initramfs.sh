#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
readonly output_root="${MILESTONE1_OUTPUT_ROOT:-${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone1}"
readonly evidence="${1:-${output_root}/initramfs/latest}"
readonly m0_root="${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone0"
if command -v readelf >/dev/null 2>&1; then
    readonly elf_inspector=readelf
elif command -v xcrun >/dev/null 2>&1 && xcrun -f llvm-objdump >/dev/null 2>&1; then
    readonly elf_inspector=llvm-objdump
else
    printf 'Missing readelf or llvm-objdump\n' >&2
    exit 1
fi

elf_header() {
    if [[ "$elf_inspector" == readelf ]]; then readelf -h "$1"; else xcrun llvm-objdump -f "$1"; fi
}

elf_program_headers() {
    if [[ "$elf_inspector" == readelf ]]; then readelf -l "$1"; else xcrun llvm-objdump -p "$1"; fi
}

verify_checksum_manifest() {
    python3 - "$1" "$2" <<'PY'
import hashlib, os, re, stat, sys

root, sums = map(os.path.abspath, sys.argv[1:])
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
        if rel != 'SHA256SUMS':
            actual[rel] = hashlib.sha256(open(path, 'rb').read()).hexdigest()
if set(listed) != set(actual):
    raise SystemExit('checksum manifest has missing or extra files')
for rel, expected in listed.items():
    if actual[rel] != expected:
        raise SystemExit('checksum mismatch: ' + rel)
PY
}

validate_busybox() {
    local candidate="$1" info
    test -f "$candidate" && test ! -L "$candidate" || return 1
    info="$(file "$candidate")"
    grep -Eiq 'ELF 64-bit.*(aarch64|AArch64|ARM)' <<<"$info" || return 1
    grep -Eiq 'statically linked' <<<"$info" || return 1
    grep -Eq '(Machine:[[:space:]]+AArch64|architecture:[[:space:]]+aarch64)' < <(elf_header "$candidate") || return 1
    ! elf_program_headers "$candidate" 2>/dev/null | grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)'
}

if [[ "${1:-}" == --self-test ]]; then
    grep -Fq 'mount_ram /proc proc' "${project_root}/initramfs/milestone1/init"
    grep -Fq 'storage_policy=ram-only' "${project_root}/initramfs/milestone1/init"
    grep -Fq 'elf_header' "${project_root}/scripts/verify-milestone1-initramfs.sh"
    grep -Fq 'phase=safe-halt' "${project_root}/initramfs/milestone1/init"
    grep -Fq "gate_failed=false" "${project_root}/scripts/verify-milestone1-initramfs.sh"
    printf 'verify-milestone1-initramfs self-test passed\n'
    exit 0
fi

linux_runs_root="$(cd "${m0_root}/linux-full" && pwd -P)" || { printf 'Missing M0 Linux evidence root.\n' >&2; exit 1; }
readonly linux_runs_root
readonly linux_candidate="${2:-${linux_runs_root}/latest}"
linux_root="$(cd "$linux_candidate" && pwd -P)" || { printf 'Missing M0 Linux run binding.\n' >&2; exit 1; }
readonly linux_root
[[ "$(dirname "$linux_root")" == "$linux_runs_root" ]] || { printf 'Unsafe M0 Linux run binding.\n' >&2; exit 1; }
[[ "$(basename "$linux_root")" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && "$(basename "$linux_root")" != latest ]] || { printf 'Invalid M0 Linux run binding.\n' >&2; exit 1; }
test -d "$evidence"
command -v file >/dev/null || { printf 'Missing file\n' >&2; exit 1; }
command -v python3 >/dev/null || { printf 'Missing python3\n' >&2; exit 1; }
for required in "$M1_INITRAMFS_NAME" init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt SHA256SUMS; do
    test -s "$evidence/$required" || { printf 'Missing initramfs evidence: %s\n' "$evidence/$required" >&2; exit 1; }
done
verify_checksum_manifest "$evidence" "$evidence/SHA256SUMS"
grep -Fx 'component=milestone1-initramfs' "$evidence/manifest.txt" >/dev/null
grep -Fx 'compression=none' "$evidence/manifest.txt" >/dev/null
grep -Fx 'storage_policy=ram-only' "$evidence/manifest.txt" >/dev/null
grep -Fx 'gate_failed=false' "$evidence/manifest.txt" >/dev/null
grep -Fx "kernel_artifact=${M1_KERNEL_RELATIVE}" "$evidence/manifest.txt" >/dev/null
grep -Fx "dtb_artifact=${M1_DTB_RELATIVE}" "$evidence/manifest.txt" >/dev/null
grep -Fx "source_commit=${LINUX_COMMIT}" "$evidence/manifest.txt" >/dev/null
grep -Fx "linux_config_fragment_sha256=${LINUX_CONFIG_FRAGMENT_SHA256}" "$evidence/manifest.txt" >/dev/null
grep -Fx "busybox_package=${M1_BUSYBOX_PACKAGE}" "$evidence/manifest.txt" >/dev/null
grep -Fx "busybox_version=${M1_BUSYBOX_VERSION}" "$evidence/manifest.txt" >/dev/null
grep -Fx "busybox_deb_url=${M1_BUSYBOX_DEB_URL}" "$evidence/manifest.txt" >/dev/null
grep -Fx "busybox_deb_sha256=${M1_BUSYBOX_DEB_SHA256}" "$evidence/manifest.txt" >/dev/null
grep -Fx "elf_inspector=${elf_inspector}" "$evidence/manifest.txt" >/dev/null
readonly m0_run_dir="$(cd "$linux_root" && pwd -P)"
readonly m0_run_id="$(basename "$m0_run_dir")"
grep -Fx "m0_run_id=${m0_run_id}" "$evidence/manifest.txt" >/dev/null
grep -Fx "m0_manifest_sha256=$(shasum -a 256 "$linux_root/manifest.txt" | awk '{print $1}')" "$evidence/manifest.txt" >/dev/null
grep -Fx "image_sha256=$(shasum -a 256 "$linux_root/Image" | awk '{print $1}')" "$evidence/manifest.txt" >/dev/null
grep -Fx "dtb_sha256=$(shasum -a 256 "$linux_root/dtbs/apple/t6030-j514s.dtb" | awk '{print $1}')" "$evidence/manifest.txt" >/dev/null
grep -Fx init "$evidence/initramfs.inventory" >/dev/null
grep -Fx bin/busybox "$evidence/initramfs.inventory" >/dev/null
if grep -Fq 'root=/dev' "$evidence/init"; then exit 1; fi
if grep -Eq 'mount[[:space:]]+-t[[:space:]]+(ext[234]|apfs|hfs|xfs|btrfs)' "$evidence/init"; then exit 1; fi
validate_busybox "$evidence/bin/busybox"
test "$(shasum -a 256 "$evidence/bin/busybox" | awk '{print $1}')" = "$M1_BUSYBOX_SHA256"
if elf_program_headers "$evidence/bin/busybox" 2>/dev/null | grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)'; then exit 1; fi
gzip -t "$evidence/$M1_INITRAMFS_NAME"
archive_inventory() {
    python3 - "$evidence/$M1_INITRAMFS_NAME" <<'PY'
import gzip, sys

path = sys.argv[1]
seen = set()
with gzip.open(path, 'rb') as stream:
    def take(length):
        data = stream.read(length)
        if len(data) != length:
            raise SystemExit('truncated newc member')
        return data
    while True:
        header = take(110)
        if len(header) != 110 or header[:6] != b'070701':
            raise SystemExit('invalid newc header')
        size = int(header[54:62], 16)
        namesize = int(header[94:102], 16)
        name_bytes = take(namesize)
        if not name_bytes.endswith(b'\0'):
            raise SystemExit('invalid newc name')
        name = name_bytes[:-1].decode('utf-8')
        take((-((110 + namesize) % 4)) % 4)
        mode = int(header[14:22], 16)
        data = take(size)
        take((-(size % 4)) % 4)
        normalized = name[2:] if name.startswith('./') else name
        if not normalized or normalized.startswith('/') or '..' in normalized.split('/'):
            raise SystemExit('unsafe newc path')
        if normalized != 'TRAILER!!!':
            if normalized in seen:
                raise SystemExit('duplicate newc member')
            seen.add(normalized)
            kind = mode & 0o170000
            if kind == 0o100000:
                member_type = 'file'
                payload = '-'
            elif kind == 0o040000:
                member_type = 'dir'
                payload = '-'
            elif kind == 0o120000:
                member_type = 'symlink'
                try:
                    payload = data.decode('utf-8')
                except UnicodeDecodeError:
                    raise SystemExit('non-UTF-8 newc symlink')
            else:
                raise SystemExit('unsupported newc member type')
            print(normalized + '\t' + member_type + '\t' + payload)
        else:
            break
PY
}
archive_extract() {
    local member="$1"
    python3 - "$evidence/$M1_INITRAMFS_NAME" "$member" <<'PY'
import gzip, sys

path, target = sys.argv[1:]
found = False
with gzip.open(path, 'rb') as stream:
    def take(length):
        data = stream.read(length)
        if len(data) != length:
            raise SystemExit('truncated newc member')
        return data
    while True:
        header = take(110)
        if len(header) != 110 or header[:6] != b'070701':
            raise SystemExit('invalid newc header')
        size = int(header[54:62], 16)
        namesize = int(header[94:102], 16)
        name_bytes = take(namesize)
        if not name_bytes.endswith(b'\0'):
            raise SystemExit('invalid newc name')
        name = name_bytes[:-1].decode('utf-8')
        take((-((110 + namesize) % 4)) % 4)
        mode = int(header[14:22], 16)
        data = take(size)
        take((-(size % 4)) % 4)
        normalized = name[2:] if name.startswith('./') else name
        if not normalized or normalized.startswith('/') or '..' in normalized.split('/'):
            raise SystemExit('unsafe newc path')
        if normalized == 'TRAILER!!!':
            break
        if normalized == target:
            if found or (mode & 0o170000) != 0o100000:
                raise SystemExit('invalid required newc member')
            sys.stdout.buffer.write(data)
            found = True
if not found:
    raise SystemExit('missing required newc member')
PY
}
archive_inventory_output="$(archive_inventory)"
readonly expected_applets='cat date dmesg grep mkdir mount sh sleep tee touch uname'
expected_archive_inventory="$(
    printf '%s\n' \
        $'bin\tdir\t-' \
        $'dev\tdir\t-' \
        $'init\tfile\t-' \
        $'proc\tdir\t-' \
        $'run\tdir\t-' \
        $'sys\tdir\t-' \
        $'bin/busybox\tfile\t-'
    for applet in $expected_applets; do printf 'bin/%s\tsymlink\tbusybox\n' "$applet"; done
)"
diff -u \
    <(printf '%s\n' "$expected_archive_inventory" | LC_ALL=C sort -u) \
    <(printf '%s\n' "$archive_inventory_output" | LC_ALL=C sort -u)
archive_list="$(printf '%s\n' "$archive_inventory_output" | cut -f1)"
grep -Eq 'busybox.*(ELF|aarch64|ARM)' "$evidence/file.txt"
if grep -Eiq '(^|/)(etc/fstab|dev/[^/]+)$' <<<"$archive_list"; then exit 1; fi
archive_tmp="$(mktemp -d)"
trap 'rm -rf "$archive_tmp"' EXIT
archive_extract init >"$archive_tmp/init"
archive_extract bin/busybox >"$archive_tmp/busybox"
cmp "$evidence/init" "$archive_tmp/init"
cmp "$evidence/bin/busybox" "$archive_tmp/busybox"
grep -Fx "init_sha256=$(shasum -a 256 "$evidence/init" | awk '{print $1}')" "$evidence/manifest.txt" >/dev/null
grep -Fx "busybox_sha256=$(shasum -a 256 "$evidence/bin/busybox" | awk '{print $1}')" "$evidence/manifest.txt" >/dev/null
grep -Fx "archive_init_sha256=$(shasum -a 256 "$archive_tmp/init" | awk '{print $1}')" "$evidence/manifest.txt" >/dev/null
grep -Fx "archive_busybox_sha256=$(shasum -a 256 "$archive_tmp/busybox" | awk '{print $1}')" "$evidence/manifest.txt" >/dev/null
validate_busybox "$archive_tmp/busybox"
printf 'milestone1.initramfs=verified\n'
