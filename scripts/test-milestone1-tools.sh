#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
source "${project_root}/scripts/lib/milestone1-evidence.sh"
readonly tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/milestone1-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

for script in build-milestone1-initramfs.sh verify-milestone1-initramfs.sh milestone1-preflight.sh milestone1-dry-run.sh milestone1-execute.sh verify-milestone1-session.sh assemble-milestone1-session.sh; do
    "${project_root}/scripts/$script" --self-test
done
[[ "$M1_KERNEL_RELATIVE" == linux-full/latest/Image ]]
[[ "$M1_DTB_RELATIVE" == linux-full/latest/dtbs/apple/t6030-j514s.dtb ]]
python3 - "$project_root/scripts/build-milestone1-initramfs.sh" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
# Static order guard complements packing tests; this does not bypass real M0
# prerequisites or claim that a complete production build ran in this fixture.
verify = source.index('"${project_root}/scripts/verify-milestone1-initramfs.sh" "$stage" "$linux_root"')
publish = source.index('evidence_atomic_publish_directory "$stage" "$destination"')
latest = source.index('atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"')
assert verify < publish < latest, 'initramfs must verify before publishing or switching latest'
PY

m0_root="$tmp/m0/milestone0"
m0_run="$m0_root/linux-full/20260902T000000Z"
mkdir -p "$m0_run/dtbs/apple"
printf 'fake Image\n' >"$m0_run/Image"
printf 'fake J514s DTB\n' >"$m0_run/dtbs/apple/t6030-j514s.dtb"
printf 'source_commit=%s\nsource_date_epoch=1787212057\n' "$LINUX_COMMIT" >"$m0_run/manifest.txt"
ln -s "$m0_run" "$m0_root/linux-full/latest"
m0_run_id="$(basename "$m0_run")"
m0_manifest_sha256="$(shasum -a 256 "$m0_run/manifest.txt" | awk '{print $1}')"
image_sha256="$(shasum -a 256 "$m0_run/Image" | awk '{print $1}')"
dtb_sha256="$(shasum -a 256 "$m0_run/dtbs/apple/t6030-j514s.dtb" | awk '{print $1}')"
initramfs_sha256="$(printf 'fake initramfs\n' | shasum -a 256 | awk '{print $1}')"
test_tool=/tmp/linux.py
test_device=/dev/cu.test
test_command="M1N1DEVICE=${test_device} python3 ${test_tool} --compression none /tmp/Image /tmp/j514s.dtb /tmp/initramfs"
mkdir "$tmp/binding-initramfs"
printf 'fake initramfs\n' >"$tmp/binding-initramfs/$M1_INITRAMFS_NAME"
binding=$(m1_artifact_binding "$m0_run" "$tmp/binding-initramfs")
printf -v test_identity '%s\ntool=%s\ndevice=%s\ncompression=none\nstorage_policy=ram-only\ncommand=%s' \
    "$binding" "$test_tool" "$test_device" "$test_command"

# Synthetic two-host evidence; never invokes readiness, inventory, or a device.
test_target="$(printf '%064d' 1)"
test_controller="$(printf '%064d' 2)"
test_tool_sha="$(printf '%064d' 3)"
test_epoch=1788000000
anchors_file="$tmp/independent-target-anchors.txt"
: >"$anchors_file"
mkdir "$tmp/target-stage" "$tmp/preflight"
printf 'fixture readiness; not a native attestation\n' >"$tmp/target-stage/readiness.log"
m1_write_target_readiness "$tmp/target-stage" "$test_target" "$test_epoch"
test_digest="$(m1_target_readiness_digest "$tmp/target-stage")"
m1_verify_target_readiness "$tmp/target-stage" "$test_target" "$test_digest" "$test_epoch"
m1_write_controller_preflight "$tmp/preflight" "$tmp/target-stage" "$test_target" "$test_digest" \
    "$test_controller" "$test_device" "$test_tool_sha" "$binding" "$test_epoch"
rm -rf "$tmp/target-stage"
m1_verify_controller_preflight "$tmp/preflight" "$test_target" "$test_digest" "$test_controller" \
    "$test_device" "$test_tool_sha" "$binding" "$test_epoch"
printf '%s\n' "$test_digest" >>"$anchors_file"
python3 "$project_root/tests/m1-provenance-self-test.py" "$project_root" "$tmp/preflight" \
    "$test_target" "$test_digest" "$test_controller" "$test_device" "$test_tool_sha" "$binding" "$test_epoch"

run_session_verifier() {
    "$project_root/scripts/verify-milestone1-session.sh" "$@" "$test_target" "$anchors_file"
}
run_session_assembler() {
    "$project_root/scripts/assemble-milestone1-session.sh" "$@" "$test_target" "$anchors_file"
}
write_fixture_execution() {
    local fixture_stage=$1 producer=$2 copier=$3 started provenance fixture_identity
    started=$(awk -F= '$1 == "completed_epoch" {print $2 + 1}' "$fixture_stage/execution/preflight/manifest.txt")
    provenance="$(m1_execution_identity "$fixture_stage/execution/preflight" "$started")"
    printf -v fixture_identity '%s\n%s\nexecution_id=%s' "$test_identity" "$provenance" "$(basename "$fixture_stage")"
    m1_write_execution_evidence "$fixture_stage" "$fixture_identity" "$producer" "$copier"
}

archive_fixture="$tmp/initramfs"
mkdir -p "$archive_fixture/bin" "$tmp/fake-tools"
cp "$project_root/initramfs/milestone1/init" "$archive_fixture/init"
printf 'static busybox\n' >"$archive_fixture/bin/busybox"
make_archive() {
    local source_dir="$1" variant="${2:-normal}" archive_tree="$tmp/archive-tree"
    rm -rf "$archive_tree"
    mkdir -p "$archive_tree/bin" "$archive_tree/dev" "$archive_tree/proc" "$archive_tree/run" "$archive_tree/sys"
    cp "$source_dir/init" "$archive_tree/init"
    cp "$source_dir/bin/busybox" "$archive_tree/bin/busybox"
    for tool in cat date dmesg grep head mkdir mount sh sleep tee timeout touch uname; do
        ln -s busybox "$archive_tree/bin/$tool"
    done
    case "$variant" in
        normal) ;;
        sh-regular) rm "$archive_tree/bin/sh"; printf 'malicious shell\n' >"$archive_tree/bin/sh" ;;
        sh-wrong-target) rm "$archive_tree/bin/sh"; ln -s ../init "$archive_tree/bin/sh" ;;
        *) return 64 ;;
    esac
    find "$archive_tree" -type d -exec chmod 0755 {} +
    chmod 0755 "$archive_tree/init" "$archive_tree/bin/busybox"
    if [[ $(uname -s) == Darwin ]]; then find "$archive_tree" -type l -exec chmod -h 0777 {} +; fi
    TZ=UTC find "$archive_tree" -mindepth 1 -exec touch -h -t 202608200747.37 {} +
    (cd "$archive_tree" && find . -mindepth 1 -print | sed 's#^./##' | LC_ALL=C sort | cpio --quiet -R 0:0 -o -H newc | gzip -n >"$archive_fixture/milestone1-initramfs.cpio.gz")
    # Fixture metadata models the producer's Linux staging filesystem, including
    # when the test itself runs with Darwin bsdcpio. Producer packing is tested
    # separately above using its actual helper and both execution paths.
    python3 - "$archive_fixture/milestone1-initramfs.cpio.gz" <<'PY'
import gzip, pathlib, sys
path = pathlib.Path(sys.argv[1])
raw = bytearray(gzip.decompress(path.read_bytes()))
offset = 0
while True:
    header = raw[offset:offset + 110]
    size, namesize = int(header[54:62], 16), int(header[94:102], 16)
    name = raw[offset + 110:offset + 110 + namesize - 1]
    if name == b'TRAILER!!!':
        break
    if int(header[14:22], 16) & 0o170000 == 0o040000:
        raw[offset + 38:offset + 46] = b'00000002'
    offset += (110 + namesize + 3) & ~3
    offset += (size + 3) & ~3
path.write_bytes(gzip.compress(raw, mtime=0))
PY
}
make_archive "$archive_fixture"
printf 'init\nbin/busybox\n' >"$archive_fixture/initramfs.inventory"
printf 'bin/busybox: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' >"$archive_fixture/file.txt"
printf 'Machine: AArch64\n' >"$archive_fixture/busybox.readelf"
printf 'format=1\ncomponent=milestone1-initramfs\ncompression=none\nstorage_policy=ram-only\ngate_failed=false\nkernel_artifact=%s\ndtb_artifact=%s\nsource_commit=%s\nlinux_config_fragment_sha256=%s\nm0_run_id=%s\nm0_manifest_sha256=%s\nimage_sha256=%s\ndtb_sha256=%s\ninit_sha256=%s\nbusybox_sha256=%s\narchive_init_sha256=%s\narchive_busybox_sha256=%s\nbusybox_package=%s\nbusybox_version=%s\nbusybox_deb_url=%s\nbusybox_deb_sha256=%s\nelf_inspector=readelf\n' \
    "$M1_KERNEL_RELATIVE" "$M1_DTB_RELATIVE" "$LINUX_COMMIT" "$LINUX_CONFIG_FRAGMENT_SHA256" "$m0_run_id" "$m0_manifest_sha256" "$image_sha256" "$dtb_sha256" \
    "$(shasum -a 256 "$archive_fixture/init" | awk '{print $1}')" "$M1_BUSYBOX_SHA256" \
    "$(shasum -a 256 "$archive_fixture/init" | awk '{print $1}')" "$M1_BUSYBOX_SHA256" \
    "$M1_BUSYBOX_PACKAGE" "$M1_BUSYBOX_VERSION" "$M1_BUSYBOX_DEB_URL" "$M1_BUSYBOX_DEB_SHA256" >"$archive_fixture/manifest.txt"
printf 'source_date_epoch=1787212057\n' >>"$archive_fixture/manifest.txt"
(cd "$archive_fixture" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)
printf '#!/bin/sh\nprintf "%%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\\n" "$1"\n' >"$tmp/fake-tools/file"
printf '#!/bin/sh\ncase "$1" in -h) printf "Machine: AArch64\\n" ;; -l) : ;; esac\n' >"$tmp/fake-tools/readelf"
real_shasum="$(command -v shasum)"
printf '#!/bin/sh\nhash=%s\nfor arg in "$@"; do case "$arg" in */busybox) printf "%%s  %%s\\n" "$hash" "$arg"; exit 0;; esac; done\nexec %s "$@"\n' \
    "$M1_BUSYBOX_SHA256" "$real_shasum" >"$tmp/fake-tools/shasum"
chmod +x "$tmp/fake-tools/file" "$tmp/fake-tools/readelf" "$tmp/fake-tools/shasum"
PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$archive_fixture"
mkdir -p "$tmp/m1/initramfs" "$tmp/m1-source/proxyclient/tools"
ln -s "$archive_fixture" "$tmp/m1/initramfs/latest"
printf '# dry-run fixture\n' >"$tmp/m1-source/proxyclient/tools/linux.py"
dry_run_output="$(PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" MILESTONE1_OUTPUT_ROOT="$tmp/m1" \
    M1N1DEVICE="$test_device" M1_M1N1_SOURCE_DIR="$tmp/m1-source" "${project_root}/scripts/milestone1-dry-run.sh")"
[[ "$(tail -n 1 <<<"$dry_run_output")" == "M1N1DEVICE=${test_device} python3 ${tmp}/m1-source/proxyclient/tools/linux.py --compression none ${m0_run}/Image ${m0_run}/dtbs/apple/t6030-j514s.dtb ${archive_fixture}/milestone1-initramfs.cpio.gz" ]]
m0_rotated="$m0_root/linux-full/20260902T000001Z"
mkdir -p "$m0_rotated/dtbs/apple"
cp "$m0_run/Image" "$m0_rotated/Image"
cp "$m0_run/dtbs/apple/t6030-j514s.dtb" "$m0_rotated/dtbs/apple/t6030-j514s.dtb"
printf 'source_commit=%s\nsource_date_epoch=1787212057\nrotation=true\n' "$LINUX_COMMIT" >"$m0_rotated/manifest.txt"
rm "$m0_root/linux-full/latest"
ln -s "$m0_rotated" "$m0_root/linux-full/latest"
PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$archive_fixture" "$m0_run"
if PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$archive_fixture" >/dev/null 2>&1; then
    printf 'Expected default moving-latest binding rejection.\n' >&2
    exit 1
fi
rm "$m0_root/linux-full/latest"
ln -s "$m0_run" "$m0_root/linux-full/latest"
check_init_reject() {
    local candidate="$1" expected="${2:-}"
    if PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$candidate" >"$tmp/init-reject.log" 2>&1; then
        printf 'Expected initramfs rejection: %s\n' "$candidate" >&2
        exit 1
    fi
    if [[ -n $expected ]]; then grep -Fq "$expected" "$tmp/init-reject.log"; fi
}
# Checksums alone must not bless an ignored second CPIO/gzip archive.
for variant in concat-gzip concat-newc trailing-data trailing-zeros truncated-padding \
    oversized-name oversized-member embedded-name-nul prefixed-trailer \
    non-executable-init setuid-busybox wrong-uid wrong-gid wrong-mtime hardlinked-init \
    wrong-directory-nlink empty-gzip-member too-many-members oversized-stream \
    oversized-compressed truncated-gzip bad-gzip-crc inventory-injection \
    newline-name tab-name newline-link tab-link; do
    candidate="$tmp/initramfs-$variant"
    cp -R "$archive_fixture" "$candidate"
    python3 - "$candidate/$M1_INITRAMFS_NAME" "$variant" <<'PY'
import gzip, pathlib, sys
path = pathlib.Path(sys.argv[1])
compressed = path.read_bytes()
raw = gzip.decompress(compressed)
variant = sys.argv[2]
if variant == 'concat-gzip':
    path.write_bytes(compressed + compressed)
    raise SystemExit
if variant == 'empty-gzip-member':
    path.write_bytes(compressed + gzip.compress(b'', mtime=0))
    raise SystemExit
if variant == 'truncated-gzip':
    path.write_bytes(compressed[:-1])
    raise SystemExit
if variant == 'bad-gzip-crc':
    compressed = bytearray(compressed)
    compressed[-8] ^= 1
    path.write_bytes(compressed)
    raise SystemExit
if variant == 'oversized-compressed':
    path.write_bytes(compressed + b'x' * 100000)
    raise SystemExit
if variant == 'concat-newc':
    raw += raw
elif variant == 'trailing-data':
    raw += b'not another permitted archive'
elif variant == 'trailing-zeros':
    raw += b'\0' * 512
elif variant == 'oversized-stream':
    raw += b'\0' * 100000
elif variant == 'truncated-padding':
    raw = raw[:-1]
elif variant in ('oversized-name', 'oversized-member', 'embedded-name-nul'):
    raw = bytearray(raw)
    if variant == 'oversized-name':
        raw[94:102] = b'ffffffff'
    elif variant == 'oversized-member':
        raw[54:62] = b'ffffffff'
    else:
        raw[110] = 0
elif variant in ('inventory-injection', 'newline-name', 'tab-name', 'newline-link', 'tab-link'):
    records = bytearray()
    offset = 0
    while True:
        header = bytearray(raw[offset:offset + 110])
        size, namesize = int(header[54:62], 16), int(header[94:102], 16)
        name = raw[offset + 110:offset + 110 + namesize - 1]
        offset += (110 + namesize + 3) & ~3
        data = raw[offset:offset + size]
        offset += (size + 3) & ~3
        if variant == 'inventory-injection' and name == b'bin/date':
            continue
        if name == b'bin' and variant in ('newline-name', 'tab-name'):
            name = b'b\nn' if variant == 'newline-name' else b'b\tn'
        if name == b'bin/cat' and variant in ('inventory-injection', 'newline-link', 'tab-link'):
            data = {
                'inventory-injection': b'busybox\nbin/date\tsymlink\tbusybox',
                'newline-link': b'busybox\n',
                'tab-link': b'busybox\t',
            }[variant]
        header[54:62] = f'{len(data):08x}'.encode()
        header[94:102] = f'{len(name) + 1:08x}'.encode()
        records += header + name + b'\0'
        records += b'\0' * (-len(records) % 4)
        records += data + b'\0' * (-len(data) % 4)
        if name == b'TRAILER!!!':
            break
    records += b'\0' * (-len(records) % 512)
    raw = records
elif variant in ('prefixed-trailer', 'too-many-members'):
    offset = 0
    while True:
        header = raw[offset:offset + 110]
        size, namesize = int(header[54:62], 16), int(header[94:102], 16)
        name = raw[offset + 110:offset + 110 + namesize - 1]
        if name == b'TRAILER!!!':
            if variant == 'too-many-members':
                # First fixture record is the canonical empty bin directory.
                record = raw[:116]
                extra = b''.join(record[:110] + f'x{n:02d}'.encode() + record[113:] for n in range(19))
                raw = raw[:offset] + extra + raw[offset:offset + 124]
                raw += b'\0' * (-len(raw) % 512)
                break
            header = bytearray(header)
            name = b'./TRAILER!!!\0'
            header[94:102] = f'{len(name):08x}'.encode()
            raw = raw[:offset] + header + name
            raw += b'\0' * (-len(raw) % 512)
            break
        offset += (110 + namesize + 3) & ~3
        offset += (size + 3) & ~3
else:
    raw = bytearray(raw)
    target = {'setuid-busybox': b'bin/busybox', 'wrong-directory-nlink': b'bin'}.get(variant, b'init')
    fields = {
        'non-executable-init': (14, 0o100644),
        'setuid-busybox': (14, 0o104755),
        'wrong-uid': (22, 1000),
        'wrong-gid': (30, 1000),
        'wrong-mtime': (46, 1787212058),
        'hardlinked-init': (38, 2),
        'wrong-directory-nlink': (38, 4),
    }
    offset = 0
    while True:
        header = raw[offset:offset + 110]
        size, namesize = int(header[54:62], 16), int(header[94:102], 16)
        name = raw[offset + 110:offset + 110 + namesize - 1]
        if name == target:
            field, value = fields[variant]
            raw[offset + field:offset + field + 8] = f'{value:08x}'.encode()
            break
        assert name != b'TRAILER!!!', 'fixture target missing'
        offset += (110 + namesize + 3) & ~3
        offset += (size + 3) & ~3
path.write_bytes(gzip.compress(raw, mtime=0))
PY
    (cd "$candidate" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)
    expected=''
    case "$variant" in
        empty-gzip-member|truncated-gzip) expected='exactly one complete gzip member' ;;
        too-many-members) expected='too many newc members' ;;
        oversized-stream) expected='decompressed initramfs exceeds bounded payload size' ;;
        oversized-compressed) expected='compressed initramfs exceeds bounded payload size' ;;
        wrong-directory-nlink) expected='invalid newc directory metadata' ;;
    esac
    check_init_reject "$candidate" "$expected"
done
init_link="$tmp/initramfs-required-link"
cp -a "$archive_fixture" "$init_link"
unlink "$init_link/init"
ln -s bin/busybox "$init_link/init"
check_init_reject "$init_link"
init_nested="$tmp/initramfs-nested-link"
cp -a "$archive_fixture" "$init_nested"
mkdir "$init_nested/nested"
ln -s ../bin "$init_nested/nested/bin-link"
check_init_reject "$init_nested"
set_manifest_value() {
    local key="$1" value="$2"
    awk -F= -v key="$key" -v value="$value" '$1 == key {$0=key "=" value} {print}' "$archive_fixture/manifest.txt" >"$tmp/manifest.new"
    mv "$tmp/manifest.new" "$archive_fixture/manifest.txt"
}
# A self-consistent, fully rehashed old init must not pass current-source review.
(
    original_fixture="$archive_fixture"
    archive_fixture="$tmp/stale-initramfs"
    cp -R "$original_fixture" "$archive_fixture"
    printf '\n# superseded init\n' >>"$archive_fixture/init"
    make_archive "$archive_fixture"
    stale_hash=$(shasum -a 256 "$archive_fixture/init" | awk '{print $1}')
    set_manifest_value init_sha256 "$stale_hash"
    set_manifest_value archive_init_sha256 "$stale_hash"
    (cd "$archive_fixture" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)
    if PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" \
        "$project_root/scripts/verify-milestone1-initramfs.sh" "$archive_fixture" >"$tmp/stale-init.log" 2>&1; then exit 1; fi
    grep -Fx 'Embedded M1 init differs from the reviewed source; rebuild the initramfs.' "$tmp/stale-init.log"
)
archive_tamper="$tmp/archive-tamper-init"
mkdir -p "$archive_tamper/bin"
printf 'tampered embedded init\n' >"$archive_tamper/init"
cp "$archive_fixture/bin/busybox" "$archive_tamper/bin/busybox"
make_archive "$archive_tamper"
set_manifest_value archive_init_sha256 "$(printf 'tampered embedded init\n' | shasum -a 256 | awk '{print $1}')"
(cd "$archive_fixture" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)
if PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$archive_fixture" >/dev/null 2>&1; then
    printf 'Expected tampered archive rejection.\n' >&2
    exit 1
fi
archive_tamper="$tmp/archive-tamper-busybox"
mkdir -p "$archive_tamper/bin"
cp "$archive_fixture/init" "$archive_tamper/init"
printf 'tampered embedded busybox\n' >"$archive_tamper/bin/busybox"
make_archive "$archive_tamper"
set_manifest_value archive_init_sha256 "$(shasum -a 256 "$archive_fixture/init" | awk '{print $1}')"
set_manifest_value archive_busybox_sha256 "$(printf 'tampered embedded busybox\n' | shasum -a 256 | awk '{print $1}')"
(cd "$archive_fixture" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)
if PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$archive_fixture" >/dev/null 2>&1; then
    printf 'Expected tampered embedded BusyBox rejection.\n' >&2
    exit 1
fi
make_archive "$archive_fixture"
(cd "$archive_fixture" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)
make_archive "$archive_fixture" sh-regular
(cd "$archive_fixture" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)
if PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$archive_fixture" >/dev/null 2>&1; then
    printf 'Expected regular bin/sh rejection.\n' >&2
    exit 1
fi
make_archive "$archive_fixture" sh-wrong-target
(cd "$archive_fixture" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)
if PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$archive_fixture" >/dev/null 2>&1; then
    printf 'Expected wrong-target bin/sh rejection.\n' >&2
    exit 1
fi
make_archive "$archive_fixture"
(cd "$archive_fixture" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)

source_runs="$tmp/sessions"
mkdir -p "$source_runs"
for n in $(seq 1 20); do
    run_dir="$tmp/session-stage-$n"
    execution_dir="$run_dir/execution"
    mkdir -p "$execution_dir"
    printf 'fixture boot=%s result=success; not hardware evidence\n' "$n" >"$execution_dir/host.log"
    # Vary the per-run readiness/preflight while retaining common host/artifacts.
    mkdir "$tmp/target-$n"
    printf 'fixture readiness %s; not hardware evidence\n' "$n" >"$tmp/target-$n/readiness.log"
    m1_write_target_readiness "$tmp/target-$n" "$test_target" "$((test_epoch + n * 10))"
    run_digest="$(m1_target_readiness_digest "$tmp/target-$n")"
    printf '%s\n' "$run_digest" >>"$anchors_file"
    m1_write_controller_preflight "$execution_dir/preflight" "$tmp/target-$n" "$test_target" "$run_digest" \
        "$test_controller" "$test_device" "$test_tool_sha" "$binding" "$((test_epoch + n * 10 + 1))"
    rm -rf "$tmp/target-$n"
    write_fixture_execution "$run_dir" 0 0
    # Real producer output must survive rename and pass the real assembler.
    mv "$run_dir" "$source_runs/run-$n"
    awk -F= '++seen[$1] > 1 {exit 1}' "$source_runs/run-$n/manifest.txt"
    awk -F= '++seen[$1] > 1 {exit 1}' "$source_runs/run-$n/execution/manifest.txt"
done
for failure in producer tee; do
    candidate="$tmp/failed-$failure"
    mkdir -p "$candidate/execution"
    printf 'fixture log\n' >"$candidate/execution/host.log"
    cp -R "$tmp/preflight" "$candidate/execution/preflight"
    if [[ $failure == producer ]]; then
        write_fixture_execution "$candidate" 7 0
    else
        write_fixture_execution "$candidate" 0 8
    fi
    grep -Fx status=failed "$candidate/manifest.txt"
    grep -Fx status=failed "$candidate/execution/manifest.txt"
    grep -Fx $'1\tfailed\texecution\tserial.log' "$candidate/records.tsv"
    (cd "$candidate" && shasum -a 256 -c SHA256SUMS >/dev/null)
done
for name in watchdog panic reboot macos-return dfu; do
    printf 'observed=true\nrecorded_by=operator\nsource=serial-log\n' >"$source_runs/evidence-${name}.txt"
done
MILESTONE0_OUTPUT_ROOT="$tmp/m0" run_session_assembler "$source_runs" "$tmp/assembled"
session="$tmp/assembled"
# No implicit anchor defaults on any entrypoint, including historical handoffs.
if MILESTONE0_OUTPUT_ROOT="$tmp/m0" "$project_root/scripts/verify-milestone1-session.sh" "$session" >/dev/null 2>&1; then exit 1; fi
mkdir "$tmp/handoffs" "$tmp/handoff-evidence"
MILESTONE0_OUTPUT_ROOT="$tmp/m0" MILESTONE_HANDOFF_ROOT="$tmp/handoffs" MILESTONE_EVIDENCE_ROOT="$tmp/handoff-evidence" \
    "$project_root/scripts/create-milestone-handoff.sh" --milestone M1 --source "$session" --out "$tmp/handoffs/M1" \
    --expected-target-identity-sha256 "$test_target" --target-readiness-anchors "$anchors_file" >"$tmp/handoff.log"
MILESTONE0_OUTPUT_ROOT="$tmp/m0" MILESTONE_HANDOFF_ROOT="$tmp/handoffs" \
    "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$tmp/handoffs/M1" \
    --expected-target-identity-sha256 "$test_target" --target-readiness-anchors "$anchors_file" >>"$tmp/handoff.log"
if MILESTONE0_OUTPUT_ROOT="$tmp/m0" MILESTONE_HANDOFF_ROOT="$tmp/handoffs" \
    "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$tmp/handoffs/M1" >/dev/null 2>&1; then exit 1; fi
for arguments in '--target-readiness --controller-preflight' '--dfu-rehearsed --sample-restore-verified' \
    '--controller-preflight' '--target-readiness --dfu-rehearsed' '--expected-target-bundle-sha256'; do
    # Deliberate word splitting: every fixture argument here is a fixed flag.
    # shellcheck disable=SC2086
    if "$project_root/scripts/milestone1-preflight.sh" $arguments >/dev/null 2>&1; then exit 1; fi
done

# Validation failure must never publish an apparently finished session.
cp -R "$source_runs" "$tmp/panic-source"
printf 'kernel panic\n' >"$tmp/panic-source/run-1/execution/host.log"
write_fixture_execution "$tmp/panic-source/run-1" 0 0
if MILESTONE0_OUTPUT_ROOT="$tmp/m0" run_session_assembler \
    "$tmp/panic-source" "$tmp/must-not-publish" >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$tmp/must-not-publish" && ! -L "$tmp/must-not-publish" ]]
ln -s "$tmp/missing-destination" "$tmp/output-link"
if MILESTONE0_OUTPUT_ROOT="$tmp/m0" run_session_assembler \
    "$source_runs" "$tmp/output-link" >/dev/null 2>&1; then exit 1; fi
[[ -L "$tmp/output-link" && ! -e "$tmp/missing-destination" ]]

check_reject() {
    local candidate="$1"
    if MILESTONE0_OUTPUT_ROOT="$tmp/m0" run_session_verifier "$candidate" >/dev/null 2>&1; then
        printf 'Expected rejection: %s\n' "$candidate" >&2
        exit 1
    fi
}
cp -R "$session" "$tmp/reused-execution"
awk -F '\t' 'BEGIN {OFS="\t"} {$3="run-1"; print}' "$tmp/reused-execution/records.tsv" >"$tmp/records-reused"
mv "$tmp/records-reused" "$tmp/reused-execution/records.tsv"
m1_checksum_tree "$tmp/reused-execution"
check_reject "$tmp/reused-execution"
cp -R "$session" "$tmp/legacy-session"
sed 's/^format=2$/format=1/' "$tmp/legacy-session/manifest.txt" >"$tmp/legacy-manifest"
mv "$tmp/legacy-manifest" "$tmp/legacy-session/manifest.txt"
m1_checksum_tree "$tmp/legacy-session"
check_reject "$tmp/legacy-session"
cp -R "$session" "$tmp/copied-execution"
rm -rf "$tmp/copied-execution/run-2"
cp -R "$tmp/copied-execution/run-1" "$tmp/copied-execution/run-2"
m1_checksum_tree "$tmp/copied-execution"
if MILESTONE0_OUTPUT_ROOT="$tmp/m0" run_session_verifier "$tmp/copied-execution" >"$tmp/replayed-session.log" 2>&1; then exit 1; fi
grep -Fx 'Duplicate execution ID.' "$tmp/replayed-session.log"
cp -R "$source_runs" "$tmp/copied-source"
rm -rf "$tmp/copied-source/run-2"
cp -R "$tmp/copied-source/run-1" "$tmp/copied-source/run-2"
if MILESTONE0_OUTPUT_ROOT="$tmp/m0" run_session_assembler "$tmp/copied-source" "$tmp/replay-must-not-publish" >"$tmp/replayed-source.log" 2>&1; then exit 1; fi
grep -Fx 'Duplicate execution ID.' "$tmp/replayed-source.log"
[[ ! -e "$tmp/replay-must-not-publish" ]]
cp -R "$session" "$tmp/hidden-directory"
mkdir "$tmp/hidden-directory/.hidden"
m1_checksum_tree "$tmp/hidden-directory"
check_reject "$tmp/hidden-directory"
printf 'unlisted hidden data\n' >"$tmp/hidden-directory/.hidden/data"
check_reject "$tmp/hidden-directory"
# A scanner error must not look like grep's no-match status. Keep all other
# grep calls real so this covers the complete session verifier and publisher.
mkdir "$tmp/scan-tools"
real_grep=$(command -v grep)
printf '#!/bin/sh\nif [ "$1" = -Eiq ]; then\n  for argument do target=$argument; done\n  case "$target" in */"$M1_SCAN_FIXTURE_SUFFIX") exit "$M1_SCAN_FIXTURE_EXIT" ;; esac\nfi\nexec %s "$@"\n' \
    "$real_grep" >"$tmp/scan-tools/grep"
chmod 0755 "$tmp/scan-tools/grep"
for scan_suffix in serial.log host.log evidence-dfu.txt; do
    for scan_exit in 2 127; do
        if PATH="$tmp/scan-tools:$PATH" M1_SCAN_FIXTURE_SUFFIX="$scan_suffix" M1_SCAN_FIXTURE_EXIT="$scan_exit" \
            MILESTONE0_OUTPUT_ROOT="$tmp/m0" run_session_verifier \
            "$session" >"$tmp/scan-error.log" 2>&1; then
            printf 'Scanner failure accepted as clean: %s exit %s\n' "$scan_suffix" "$scan_exit" >&2
            exit 1
        fi
        grep -F 'Could not scan evidence log:' "$tmp/scan-error.log" >/dev/null
    done
done
PATH="$tmp/scan-tools:$PATH" M1_SCAN_FIXTURE_SUFFIX=serial.log M1_SCAN_FIXTURE_EXIT=1 \
    MILESTONE0_OUTPUT_ROOT="$tmp/m0" run_session_verifier "$session" >/dev/null
if PATH="$tmp/scan-tools:$PATH" M1_SCAN_FIXTURE_SUFFIX=serial.log M1_SCAN_FIXTURE_EXIT=2 \
    MILESTONE0_OUTPUT_ROOT="$tmp/m0" run_session_assembler \
    "$source_runs" "$tmp/scanner-must-not-publish" >"$tmp/scan-publication.log" 2>&1; then exit 1; fi
[[ ! -e "$tmp/scanner-must-not-publish" && ! -L "$tmp/scanner-must-not-publish" ]]
grep -F 'Could not scan evidence log:' "$tmp/scan-publication.log" >/dev/null
checksum_dotdot="$tmp/checksum-dotdot"
cp -a "$session" "$checksum_dotdot"
printf 'outside\n' >"$tmp/outside"
printf '%s  ../outside\n' "$(shasum -a 256 "$tmp/outside" | awk '{print $1}')" >>"$checksum_dotdot/SHA256SUMS"
check_reject "$checksum_dotdot"
checksum_absolute="$tmp/checksum-absolute"
cp -a "$session" "$checksum_absolute"
printf '%s  /tmp/absolute\n' "$(shasum -a 256 "$tmp/outside" | awk '{print $1}')" >>"$checksum_absolute/SHA256SUMS"
check_reject "$checksum_absolute"
checksum_duplicate="$tmp/checksum-duplicate"
cp -a "$session" "$checksum_duplicate"
head -n 1 "$checksum_duplicate/SHA256SUMS" >>"$checksum_duplicate/SHA256SUMS"
check_reject "$checksum_duplicate"
checksum_missing="$tmp/checksum-missing"
cp -a "$session" "$checksum_missing"
sed '1d' "$checksum_missing/SHA256SUMS" >"$checksum_missing/SHA256SUMS.tmp"
mv "$checksum_missing/SHA256SUMS.tmp" "$checksum_missing/SHA256SUMS"
check_reject "$checksum_missing"
checksum_extra="$tmp/checksum-extra"
cp -a "$session" "$checksum_extra"
printf 'extra\n' >"$checksum_extra/extra.txt"
check_reject "$checksum_extra"
symlink_required="$tmp/symlink-required"
cp -a "$session" "$symlink_required"
unlink "$symlink_required/run-1/host.log"
ln -s serial.log "$symlink_required/run-1/host.log"
check_reject "$symlink_required"
nested_symlink="$tmp/nested-symlink"
cp -a "$session" "$nested_symlink"
mkdir "$nested_symlink/run-1/nested"
ln -s ../serial.log "$nested_symlink/run-1/nested/serial.log"
check_reject "$nested_symlink"
bad_device="$tmp/device-regular"
printf 'not a device\n' >"$bad_device"
for candidate in "$bad_device" "$bad_device.link" /dev/disk0 /dev/null; do
    if [[ "$candidate" = "$bad_device.link" ]]; then
        ln -s "$bad_device" "$candidate"
    fi
    if M1_EXECUTE_ATTESTATION="$M1_REQUIRED_EXECUTE_ATTESTATION" M1N1DEVICE="$candidate" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/milestone1-execute.sh" --execute >/dev/null 2>&1; then
        printf 'Expected pre-invocation device rejection: %s\n' "$candidate" >&2
        exit 1
    fi
    for entrypoint in milestone1-preflight milestone1-execute; do
        if [[ $entrypoint == milestone1-preflight ]]; then
            args=(--controller-preflight --target-readiness-dir "$tmp/preflight/target-readiness"
                --expected-target-identity-sha256 "$test_target" --expected-target-bundle-sha256 "$test_digest")
        else
            args=(--execute --expected-target-identity-sha256 "$test_target" --expected-target-bundle-sha256 "$test_digest")
        fi
        if M1_EXECUTE_ATTESTATION="$M1_REQUIRED_EXECUTE_ATTESTATION" M1N1DEVICE="$candidate" \
            MILESTONE0_OUTPUT_ROOT="$tmp/absent-m0" M1_M1N1_SOURCE_DIR="$tmp/absent-m1n1" \
            "$project_root/scripts/$entrypoint.sh" "${args[@]}" >"$tmp/rejected-device.log" 2>&1; then exit 1; fi
        # The old readonly assignment swallowed rejection and reached later gates.
        [[ $(wc -l <"$tmp/rejected-device.log" | tr -d ' ') == 1 ]]
        grep -Fx 'M1N1DEVICE is outside the macOS serial-device allowlist.' "$tmp/rejected-device.log"
    done
done
cp -a "$session" "$tmp/duplicate"
head -n 1 "$tmp/duplicate/records.tsv" >>"$tmp/duplicate/records.tsv"
m1_checksum_tree "$tmp/duplicate"
check_reject "$tmp/duplicate"
cp -a "$session" "$tmp/malformed"
awk -F '\t' 'NR == 2 {$4=""} {print}' OFS='\t' "$tmp/malformed/records.tsv" >"$tmp/malformed/records.new"
mv "$tmp/malformed/records.new" "$tmp/malformed/records.tsv"
m1_checksum_tree "$tmp/malformed"
check_reject "$tmp/malformed"
cp -a "$session" "$tmp/traversal"
awk -F '\t' 'NR == 2 {$4="../../escape.txt"} {print}' OFS='\t' "$tmp/traversal/records.tsv" >"$tmp/traversal/records.new"
mv "$tmp/traversal/records.new" "$tmp/traversal/records.tsv"
m1_checksum_tree "$tmp/traversal"
check_reject "$tmp/traversal"
cp -a "$session" "$tmp/panic"
printf 'kernel panic\n' >"$tmp/panic/run-1/serial.log"
m1_checksum_tree "$tmp/panic/run-1"
m1_checksum_tree "$tmp/panic"
check_reject "$tmp/panic"
if M1_EXECUTE_ATTESTATION=bad MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/milestone1-execute.sh" --execute \
    --expected-target-identity-sha256 "$test_target" --expected-target-bundle-sha256 "$test_digest" >"$tmp/attestation.log" 2>&1; then
    printf 'Expected bad attestation rejection.\n' >&2
    exit 1
fi
grep -F 'Set M1_EXECUTE_ATTESTATION=I_UNDERSTAND_CONTROLLED_TETHER explicitly before invocation.' "$tmp/attestation.log"
python3 "$project_root/tests/m1-init-self-test.py"
printf 'milestone1 tools self-tests passed\n'
