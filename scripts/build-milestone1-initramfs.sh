#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
source "${project_root}/scripts/lib/atomic-symlink.sh"
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

if [[ "${1:-}" == --self-test ]]; then
    grep -Fqx 'M1_COMPRESSION=none' "${project_root}/config/milestone1.env"
    grep -Fq 'storage_policy=ram-only' "${project_root}/initramfs/milestone1/init"
    grep -Fq 'readelf -h' "$0"
    readonly fake_busybox="$(mktemp)"
    printf 'not an ELF\n' >"$fake_busybox"
    ! validate_busybox "$fake_busybox"
    rm -f "$fake_busybox"
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
mkdir "$stage/bin" "$stage/dev" "$stage/proc" "$stage/sys" "$stage/run"
install -m 0755 "${project_root}/initramfs/milestone1/init" "$stage/init"
install -m 0755 "$busybox" "$stage/bin/busybox"
for tool in cat date dmesg grep mkdir mount sh sleep tee touch uname; do
    ln -s busybox "$stage/bin/$tool"
done

(
    cd "$stage"
    if cpio --help 2>&1 | grep -Fq -- '--reproducible'; then
        LC_ALL=C find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort |
            cpio --quiet --reproducible -o -H newc | gzip -n >"../${M1_INITRAMFS_NAME}"
    else
        command -v docker >/dev/null
        docker image inspect "$BUILD_IMAGE" >/dev/null
        archive_tmp="$(cd .. && pwd -P)/${M1_INITRAMFS_NAME}"
        : >"$archive_tmp"
        docker run --rm --user "$(id -u):$(id -g)" \
            --mount "type=bind,src=$(pwd -P),dst=/stage,readonly" \
            --mount "type=bind,src=${archive_tmp},dst=/archive" \
            "$BUILD_IMAGE" bash -Eeuo pipefail -c '
                cd /stage
                LC_ALL=C find . -mindepth 1 -print | sed "s#^\./##" | LC_ALL=C sort |
                    cpio --quiet --reproducible -o -H newc | gzip -n > /archive
            '
    fi
)
mv "${output_root}/initramfs/${M1_INITRAMFS_NAME}" "$stage/${M1_INITRAMFS_NAME}"
archive_extract() {
    gzip -dc "$stage/${M1_INITRAMFS_NAME}" | bsdtar -xOf - "$1"
}
archive_init="$(mktemp)"
archive_busybox="$(mktemp)"
archive_extract init >"$archive_init"
archive_extract bin/busybox >"$archive_busybox"
cmp "$stage/init" "$archive_init"
cmp "$stage/bin/busybox" "$archive_busybox"
readonly init_sha256="$(shasum -a 256 "$stage/init" | awk '{print $1}')"
readonly busybox_sha256="$(shasum -a 256 "$stage/bin/busybox" | awk '{print $1}')"
readonly archive_init_sha256="$(shasum -a 256 "$archive_init" | awk '{print $1}')"
readonly archive_busybox_sha256="$(shasum -a 256 "$archive_busybox" | awk '{print $1}')"
rm -f "$archive_init" "$archive_busybox"
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
        printf 'source_date_epoch=%s\n' "$(awk -F= '$1=="source_date_epoch" {print $2}' "$linux_root/manifest.txt")"
        printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >manifest.txt
    sha256sum "${M1_INITRAMFS_NAME}" init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS
)
mv "$stage" "$destination"
"${project_root}/scripts/verify-milestone1-initramfs.sh" "$destination" "$linux_root"
atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"
printf 'milestone1.initramfs=%s\n' "$destination"
