#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
source "${project_root}/scripts/lib/atomic-symlink.sh"
source "${project_root}/scripts/lib/evidence.sh"
readonly output_root="${MILESTONE1_OUTPUT_ROOT:-${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone1}"
readonly m0_root="${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone0"
readonly busybox="${M1_BUSYBOX:-$(command -v busybox || true)}"
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

validate_busybox() {
    local candidate="$1" file_info
    test -f "$candidate" && test ! -L "$candidate" || return 1
    file_info="$(file "$candidate")"
    grep -Eiq 'ELF 64-bit.*(aarch64|AArch64|ARM)' <<<"$file_info" || return 1
    grep -Eiq 'statically linked' <<<"$file_info" || return 1
    grep -Eq '(Machine:[[:space:]]+AArch64|architecture:[[:space:]]+aarch64)' < <(elf_header "$candidate") || return 1
    ! elf_program_headers "$candidate" 2>/dev/null | grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)'
}

cleanup_staging() {
    # These are this run's collision-checked private paths, never destination
    # or latest. After publication the staging path no longer exists.
    [[ -z ${archive_tmp:-} ]] || rm -f -- "$archive_tmp"
    rm -f -- "$latest_tmp"
    rm -rf -- "$stage"
}

pack_initramfs() {
    local root="$1" epoch="$2" archive="$3" timestamp archive_parent image_id
    [[ $epoch =~ ^(0|[1-9][0-9]{0,9})$ ]] && ((epoch <= 4294967295)) || return 1
    [[ -d $root && ! -L $root && -f $archive && ! -L $archive ]] || return 1
    root=$(cd -- "$root" && pwd -P) || return 1
    archive_parent=$(cd -- "$(dirname -- "$archive")" && pwd -P) || return 1
    archive="$archive_parent/$(basename -- "$archive")"
    [[ $archive != "$root/"* ]] || return 1
    timestamp=$(python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y%m%d%H%M.%S"))' "$epoch") || return 1
    # Only the private staging tree is normalized, never source/evidence inputs.
    find "$root" -type d -exec chmod 0755 {} + || return 1
    # Darwin creates umask-dependent symlink modes; Linux links are always 0777.
    if [[ $(uname -s) == Darwin ]]; then
        find "$root" -type l -exec chmod -h 0777 {} + || return 1
    fi
    TZ=UTC find "$root" -mindepth 1 -exec touch -h -t "$timestamp" {} + || return 1
    if [[ $(uname -s) == Linux ]] && cpio --help 2>&1 | grep -Fq -- '--reproducible'; then
        (cd "$root" && LC_ALL=C find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort |
            cpio --quiet --reproducible --owner=0:0 -o -H newc | gzip -n >"$archive")
    else
        command -v docker >/dev/null || return 1
        image_id=$(docker image inspect --format '{{.Id}}' "$BUILD_IMAGE") || return 1
        [[ $image_id =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
        docker run --rm --pull=never --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
            --tmpfs /tmp:rw,nosuid,noexec,size=64m \
            --user "$(id -u):$(id -g)" \
            --mount "type=bind,src=${root},dst=/stage,readonly" \
            --mount "type=bind,src=${archive},dst=/archive" \
            "$image_id" bash -Eeuo pipefail -c '
                # Darwin directory link counts survive bind mounts. Copy onto
                # ephemeral Linux storage before cpio records those counts.
                mkdir /tmp/stage
                cp -R --preserve=mode,timestamps /stage/. /tmp/stage/
                cd /tmp/stage
                LC_ALL=C find . -mindepth 1 -print | sed "s#^\./##" | LC_ALL=C sort |
                    cpio --quiet --reproducible --owner=0:0 -o -H newc | gzip -n > /archive
            '
    fi
}

if [[ "${1:-}" == --self-test ]]; then
    grep -Fqx 'M1_COMPRESSION=none' "${project_root}/config/milestone1.env"
    grep -Fq 'storage_policy=ram-only' "${project_root}/initramfs/milestone1/init"
    grep -Fq 'readelf -h' "$0"
    readonly fake_busybox="$(mktemp)"
    printf 'not an ELF\n' >"$fake_busybox"
    ! validate_busybox "$fake_busybox"
    rm -f "$fake_busybox"
    archive_test=$(mktemp -d "${TMPDIR:-/tmp}/m1-archive-test.XXXXXX")
    trap 'rm -rf -- "$archive_test"' EXIT
    for name in first second; do
        mkdir -p "$archive_test/$name/bin"
        printf 'fixture only; never booted\n' >"$archive_test/$name/init"
        chmod 0755 "$archive_test/$name/init"
        cp -p "$archive_test/$name/init" "$archive_test/$name/bin/busybox"
        ln -s busybox "$archive_test/$name/bin/sh"
        : >"$archive_test/$name.gz"
    done
    chmod 0700 "$archive_test/first/bin"
    chmod 0775 "$archive_test/second/bin"
    TZ=UTC find "$archive_test/first" -mindepth 1 -exec touch -h -t 202001010000.00 {} +
    TZ=UTC find "$archive_test/second" -mindepth 1 -exec touch -h -t 202101010000.00 {} +
    pack_initramfs "$archive_test/first" 1787212057 "$archive_test/first.gz"
    pack_initramfs "$archive_test/second" 1787212057 "$archive_test/second.gz"
    cmp "$archive_test/first.gz" "$archive_test/second.gz"
    printf 'fixture_archive_sha256=%s\n' "$(shasum -a 256 "$archive_test/first.gz" | awk '{print $1}')"
    python3 - "$archive_test/first.gz" <<'PY'
import gzip, sys
raw = gzip.open(sys.argv[1], 'rb').read()
offset = 0
seen = set()
while True:
    header = raw[offset:offset + 110]
    mode, uid, gid, nlink, mtime, size, namesize = (
        int(header[start:start + 8], 16) for start in (14, 22, 30, 38, 46, 54, 94)
    )
    name = raw[offset + 110:offset + 110 + namesize - 1].decode()
    if name == 'TRAILER!!!':
        break
    assert uid == gid == 0 and mtime == 1787212057, 'non-canonical archive metadata'
    assert nlink == (2 if name == 'bin' else 1), 'host-dependent archive link count'
    assert mode == {'bin': 0o040755, 'bin/sh': 0o120777}.get(name, 0o100755), (name, oct(mode))
    seen.add(name)
    offset += (110 + namesize + 3) & ~3
    offset += (size + 3) & ~3
assert seen == {'bin', 'bin/busybox', 'bin/sh', 'init'}
PY
    for bad_epoch in -1 01 4294967296 not-a-time; do
        if pack_initramfs "$archive_test/first" "$bad_epoch" "$archive_test/first.gz"; then exit 1; fi
    done
    : >"$archive_test/first/recursive.gz"
    if pack_initramfs "$archive_test/first" 1787212057 "$archive_test/first/recursive.gz"; then exit 1; fi
    mkdir "$archive_test/kept"
    printf 'keep existing evidence\n' >"$archive_test/kept/marker"
    ln -s kept "$archive_test/latest"
    cleanup_status=0
    (
        stage="$archive_test/.failed.tmp"
        latest_tmp="$archive_test/.latest.failed.tmp"
        archive_tmp="$archive_test/.archive.failed"
        mkdir "$stage"
        : >"$archive_tmp"
        ln -s not-published "$latest_tmp"
        trap cleanup_staging EXIT
        exit 23
    ) || cleanup_status=$?
    [[ $cleanup_status == 23 ]]
    [[ ! -e $archive_test/.failed.tmp && ! -e $archive_test/.archive.failed && ! -L $archive_test/.latest.failed.tmp ]]
    [[ ! -e $archive_test/not-published && $(readlink "$archive_test/latest") == kept ]]
    grep -Fx 'keep existing evidence' "$archive_test/kept/marker" >/dev/null
    printf 'initramfs failure cleanup self-test passed\n'
    printf 'initramfs archive reproducibility self-test passed\n'
    printf 'build-milestone1-initramfs self-test passed\n'
    exit 0
fi

linux_runs_root="$(cd "${m0_root}/linux-full" && pwd -P)" || { printf 'Missing M0 Linux evidence root.\n' >&2; exit 1; }
readonly linux_runs_root
readonly linux_latest="${linux_runs_root}/latest"
test -L "$linux_latest" || { printf 'Missing M0 Linux latest pointer: %s\n' "$linux_latest" >&2; exit 1; }
linux_root="$(cd "$linux_latest" && pwd -P)" || { printf 'Broken M0 Linux latest pointer.\n' >&2; exit 1; }
readonly linux_root
[[ "$(dirname "$linux_root")" == "$linux_runs_root" ]] || { printf 'Unsafe M0 Linux run binding.\n' >&2; exit 1; }
[[ "$(basename "$linux_root")" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && "$(basename "$linux_root")" != latest ]] || { printf 'Invalid M0 Linux run binding.\n' >&2; exit 1; }
readonly dtb="${linux_root}/dtbs/apple/t6030-j514s.dtb"
command -v cpio >/dev/null || { printf 'Missing cpio\n' >&2; exit 1; }
command -v gzip >/dev/null || { printf 'Missing gzip\n' >&2; exit 1; }
command -v bsdtar >/dev/null || { printf 'Missing bsdtar\n' >&2; exit 1; }
command -v file >/dev/null || { printf 'Missing file\n' >&2; exit 1; }
test -n "$busybox" && test -x "$busybox" || {
    printf 'Set M1_BUSYBOX to a target-architecture static busybox binary\n' >&2
    exit 1
}
validate_busybox "$busybox" || { printf 'BusyBox must be a static AArch64 ELF binary\n' >&2; exit 1; }
test "$(shasum -a 256 "$busybox" | awk '{print $1}')" = "$M1_BUSYBOX_SHA256" || {
    printf 'BusyBox does not match the pinned M1 binary\n' >&2
    exit 1
}
test -s "${linux_root}/Image" || { printf 'Missing M0 Image: %s\n' "${linux_root}/Image" >&2; exit 1; }
test -s "$dtb" || { printf 'Missing M0 J514s DTB: %s\n' "$dtb" >&2; exit 1; }
"${project_root}/scripts/verify-linux-full.sh" "$linux_root"
source_epoch=$(awk -F= '$1 == "source_date_epoch" {print $2}' "$linux_root/manifest.txt")
[[ $source_epoch =~ ^(0|[1-9][0-9]{0,9})$ ]] && ((source_epoch <= 4294967295)) || {
    printf 'Invalid M0 source epoch for newc metadata\n' >&2; exit 1;
}
readonly source_epoch
readonly m0_run_dir="$(cd "$linux_root" && pwd -P)"
readonly m0_run_id="$(basename "$m0_run_dir")"
readonly m0_manifest_sha256="$(shasum -a 256 "$linux_root/manifest.txt" | awk '{print $1}')"
readonly image_sha256="$(shasum -a 256 "$linux_root/Image" | awk '{print $1}')"
readonly dtb_sha256="$(shasum -a 256 "$dtb" | awk '{print $1}')"

readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly stage="${output_root}/initramfs/.${run_id}.tmp"
readonly destination="${output_root}/initramfs/${run_id}"
readonly latest="${output_root}/initramfs/latest"
readonly latest_tmp="${output_root}/initramfs/.latest.${run_id}.tmp"
mkdir -p "${output_root}/initramfs"
if [[ -e "$stage" || -L "$stage" || -e "$destination" || -L "$destination" || -e "$latest_tmp" || -L "$latest_tmp" ]] ||
    [[ -e "$latest" && ! -L "$latest" ]]; then
    printf 'Refusing colliding Milestone 1 initramfs publication path\n' >&2
    exit 1
fi
mkdir "$stage"
archive_tmp=''
trap cleanup_staging EXIT
mkdir "$stage/bin" "$stage/dev" "$stage/proc" "$stage/sys" "$stage/run"
install -m 0755 "${project_root}/initramfs/milestone1/init" "$stage/init"
install -m 0755 "$busybox" "$stage/bin/busybox"
for tool in cat date dmesg grep head mkdir mount sh sleep tee timeout touch uname; do
    ln -s busybox "$stage/bin/$tool"
done

archive_tmp=$(mktemp "${output_root}/initramfs/.archive.${run_id}.XXXXXX")
pack_initramfs "$stage" "$source_epoch" "$archive_tmp"
chmod 0644 "$archive_tmp"
mv "$archive_tmp" "$stage/${M1_INITRAMFS_NAME}"
archive_extract() {
    gzip -dc "$stage/${M1_INITRAMFS_NAME}" | bsdtar -xOf - "$1"
}
archive_check=$(mktemp -d "$stage/.archive-check.XXXXXX")
archive_init="$archive_check/init"
archive_busybox="$archive_check/busybox"
archive_extract init >"$archive_init"
archive_extract bin/busybox >"$archive_busybox"
cmp "$stage/init" "$archive_init"
cmp "$stage/bin/busybox" "$archive_busybox"
readonly init_sha256="$(shasum -a 256 "$stage/init" | awk '{print $1}')"
readonly busybox_sha256="$(shasum -a 256 "$stage/bin/busybox" | awk '{print $1}')"
readonly archive_init_sha256="$(shasum -a 256 "$archive_init" | awk '{print $1}')"
readonly archive_busybox_sha256="$(shasum -a 256 "$archive_busybox" | awk '{print $1}')"
rm -rf -- "$archive_check"
# Keep evidence a regular-file tree. The applet links remain in the compressed
# CPIO payload, but are not exposed as attacker-followed evidence paths.
find "$stage/bin" -type l -delete
(
    cd "$stage"
    LC_ALL=C find . \( -type f -o -type l \) -print | sed 's#^\./##' | LC_ALL=C sort >initramfs.inventory
    file "$stage/${M1_INITRAMFS_NAME}" "$stage/bin/busybox" >file.txt
    elf_header "$stage/bin/busybox" >busybox.readelf
    grep -Eiq 'statically linked' < <(file "$stage/bin/busybox")
    {
        printf 'format=1\ncomponent=milestone1-initramfs\n'
        printf 'kernel_artifact=%s\n' "$M1_KERNEL_RELATIVE"
        printf 'dtb_artifact=%s\n' "$M1_DTB_RELATIVE"
        printf 'compression=%s\n' "$M1_COMPRESSION"
        printf 'storage_policy=ram-only\n'
        printf 'gate_failed=false\n'
        printf 'source_commit=%s\n' "$LINUX_COMMIT"
        printf 'linux_config_fragment_sha256=%s\n' "$LINUX_CONFIG_FRAGMENT_SHA256"
        printf 'm0_run_id=%s\nm0_manifest_sha256=%s\n' "$m0_run_id" "$m0_manifest_sha256"
        printf 'image_sha256=%s\ndtb_sha256=%s\n' "$image_sha256" "$dtb_sha256"
        printf 'init_sha256=%s\nbusybox_sha256=%s\narchive_init_sha256=%s\narchive_busybox_sha256=%s\n' "$init_sha256" "$busybox_sha256" "$archive_init_sha256" "$archive_busybox_sha256"
        printf 'busybox_package=%s\nbusybox_version=%s\nbusybox_deb_url=%s\nbusybox_deb_sha256=%s\nelf_inspector=%s\n' \
            "$M1_BUSYBOX_PACKAGE" "$M1_BUSYBOX_VERSION" "$M1_BUSYBOX_DEB_URL" "$M1_BUSYBOX_DEB_SHA256" "$elf_inspector"
        printf 'source_date_epoch=%s\n' "$source_epoch"
        printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >manifest.txt
    sha256sum "${M1_INITRAMFS_NAME}" init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS
)
"${project_root}/scripts/verify-milestone1-initramfs.sh" "$stage" "$linux_root"
evidence_atomic_publish_directory "$stage" "$destination"
atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"
printf 'milestone1.initramfs=%s\n' "$destination"
