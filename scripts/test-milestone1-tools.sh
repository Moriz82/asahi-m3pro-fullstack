#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
readonly tmp="$(mktemp -d "${TMPDIR:-/tmp}/milestone1-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

for script in build-milestone1-initramfs.sh verify-milestone1-initramfs.sh milestone1-preflight.sh milestone1-dry-run.sh milestone1-execute.sh verify-milestone1-session.sh assemble-milestone1-session.sh; do
    "${project_root}/scripts/$script" --self-test
done
[[ "$M1_KERNEL_RELATIVE" == linux-full/latest/Image ]]
[[ "$M1_DTB_RELATIVE" == linux-full/latest/dtbs/apple/t6030-j514s.dtb ]]

m0_root="$tmp/m0/milestone0"
m0_run="$m0_root/linux-full/20260902T000000Z"
mkdir -p "$m0_run/dtbs/apple"
printf 'fake Image\n' >"$m0_run/Image"
printf 'fake J514s DTB\n' >"$m0_run/dtbs/apple/t6030-j514s.dtb"
printf 'source_commit=%s\n' "$LINUX_COMMIT" >"$m0_run/manifest.txt"
ln -s "$m0_run" "$m0_root/linux-full/latest"
m0_run_id="$(basename "$m0_run")"
m0_manifest_sha256="$(shasum -a 256 "$m0_run/manifest.txt" | awk '{print $1}')"
image_sha256="$(shasum -a 256 "$m0_run/Image" | awk '{print $1}')"
dtb_sha256="$(shasum -a 256 "$m0_run/dtbs/apple/t6030-j514s.dtb" | awk '{print $1}')"
initramfs_sha256="$(printf 'fake initramfs\n' | shasum -a 256 | awk '{print $1}')"
test_tool=/tmp/linux.py
test_device=/dev/cu.test
test_command="M1N1DEVICE=${test_device} python3 ${test_tool} --compression none /tmp/Image /tmp/j514s.dtb /tmp/initramfs"

archive_fixture="$tmp/initramfs"
mkdir -p "$archive_fixture/bin" "$tmp/fake-tools"
printf '#!/bin/sh\nstorage_policy=ram-only\n' >"$archive_fixture/init"
printf 'static busybox\n' >"$archive_fixture/bin/busybox"
make_archive() {
    local source_dir="$1" variant="${2:-normal}" archive_tree="$tmp/archive-tree"
    rm -rf "$archive_tree"
    mkdir -p "$archive_tree/bin" "$archive_tree/dev" "$archive_tree/proc" "$archive_tree/run" "$archive_tree/sys"
    cp "$source_dir/init" "$archive_tree/init"
    cp "$source_dir/bin/busybox" "$archive_tree/bin/busybox"
    for tool in cat date dmesg grep mkdir mount sh sleep tee touch uname; do
        ln -s busybox "$archive_tree/bin/$tool"
    done
    case "$variant" in
        normal) ;;
        sh-regular) rm "$archive_tree/bin/sh"; printf 'malicious shell\n' >"$archive_tree/bin/sh" ;;
        sh-wrong-target) rm "$archive_tree/bin/sh"; ln -s ../init "$archive_tree/bin/sh" ;;
        *) return 64 ;;
    esac
    (cd "$archive_tree" && find . -mindepth 1 -print | sed 's#^./##' | LC_ALL=C sort | cpio --quiet -o -H newc | gzip -n >"$archive_fixture/milestone1-initramfs.cpio.gz")
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
(cd "$archive_fixture" && shasum -a 256 milestone1-initramfs.cpio.gz init bin/busybox initramfs.inventory file.txt busybox.readelf manifest.txt >SHA256SUMS)
printf '#!/bin/sh\nprintf "%%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\\n" "$1"\n' >"$tmp/fake-tools/file"
printf '#!/bin/sh\ncase "$1" in -h) printf "Machine: AArch64\\n" ;; -l) : ;; esac\n' >"$tmp/fake-tools/readelf"
real_shasum="$(command -v shasum)"
printf '#!/bin/sh\nhash=%s\nfor arg in "$@"; do case "$arg" in */busybox) printf "%%s  %%s\\n" "$hash" "$arg"; exit 0;; esac; done\nexec %s "$@"\n' \
    "$M1_BUSYBOX_SHA256" "$real_shasum" >"$tmp/fake-tools/shasum"
chmod +x "$tmp/fake-tools/file" "$tmp/fake-tools/readelf" "$tmp/fake-tools/shasum"
PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$archive_fixture"
m0_rotated="$m0_root/linux-full/20260902T000001Z"
mkdir -p "$m0_rotated/dtbs/apple"
cp "$m0_run/Image" "$m0_rotated/Image"
cp "$m0_run/dtbs/apple/t6030-j514s.dtb" "$m0_rotated/dtbs/apple/t6030-j514s.dtb"
printf 'source_commit=%s\nrotation=true\n' "$LINUX_COMMIT" >"$m0_rotated/manifest.txt"
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
    local candidate="$1"
    if PATH="$tmp/fake-tools:$PATH" MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-initramfs.sh" "$candidate" >/dev/null 2>&1; then
        printf 'Expected initramfs rejection: %s\n' "$candidate" >&2
        exit 1
    fi
}
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
    run_dir="$source_runs/run-$n"
    execution_dir="$run_dir/execution"
    mkdir -p "$execution_dir"
    printf 'boot=%s result=success\n' "$n" >"$execution_dir/serial.log"
    printf 'host output %s\n' "$n" >"$execution_dir/host.log"
    printf 'format=1\nstatus=completed\nsource_commit=%s\nm0_run_id=%s\nm0_manifest_sha256=%s\nimage_sha256=%s\ndtb_sha256=%s\ninitramfs_sha256=%s\ntool=%s\ndevice=%s\nstorage_policy=ram-only\nproducer_exit=0\ntee_exit=0\npipe_status=0,0\ncommand=%s\n' "$M1N1_COMMIT" "$m0_run_id" "$m0_manifest_sha256" "$image_sha256" "$dtb_sha256" "$initramfs_sha256" "$test_tool" "$test_device" "$test_command" >"$execution_dir/manifest.txt"
    (cd "$execution_dir" && shasum -a 256 manifest.txt host.log serial.log >SHA256SUMS)
    execution_sha256="$(shasum -a 256 "$execution_dir/manifest.txt" | awk '{print $1}')"
    printf '1\tsuccess\texecution\tserial.log\n' >"$run_dir/records.tsv"
    printf 'format=1\nstatus=completed\nsource_commit=%s\nm0_run_id=%s\nm0_manifest_sha256=%s\nimage_sha256=%s\ndtb_sha256=%s\ninitramfs_sha256=%s\ntool=%s\ndevice=%s\ncommand=%s\nstorage_policy=ram-only\nevidence_policy=checksummed-execution-and-serial\nexecution_sha256=%s\n' "$M1N1_COMMIT" "$m0_run_id" "$m0_manifest_sha256" "$image_sha256" "$dtb_sha256" "$initramfs_sha256" "$test_tool" "$test_device" "$test_command" "$execution_sha256" >"$run_dir/manifest.txt"
    (cd "$run_dir" && shasum -a 256 records.tsv manifest.txt execution/SHA256SUMS execution/manifest.txt execution/host.log execution/serial.log >SHA256SUMS)
done
for name in watchdog panic reboot macos-return dfu; do
    printf 'observed=true\nrecorded_by=operator\nsource=serial-log\n' >"$source_runs/evidence-${name}.txt"
done
MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/assemble-milestone1-session.sh" "$source_runs" "$tmp/assembled"
session="$tmp/assembled"

check_reject() {
    local candidate="$1"
    if MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/verify-milestone1-session.sh" "$candidate" >/dev/null 2>&1; then
        printf 'Expected rejection: %s\n' "$candidate" >&2
        exit 1
    fi
}
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
done
cp -a "$session" "$tmp/duplicate"
head -n 1 "$tmp/duplicate/records.tsv" >>"$tmp/duplicate/records.tsv"
(cd "$tmp/duplicate" && shasum -a 256 records.tsv manifest.txt evidence-*.txt >SHA256SUMS)
check_reject "$tmp/duplicate"
cp -a "$session" "$tmp/malformed"
awk -F '\t' 'NR == 2 {$4=""} {print}' OFS='\t' "$tmp/malformed/records.tsv" >"$tmp/malformed/records.new"
mv "$tmp/malformed/records.new" "$tmp/malformed/records.tsv"
(cd "$tmp/malformed" && shasum -a 256 records.tsv manifest.txt evidence-*.txt >SHA256SUMS)
check_reject "$tmp/malformed"
cp -a "$session" "$tmp/traversal"
awk -F '\t' 'NR == 2 {$4="../../escape.txt"} {print}' OFS='\t' "$tmp/traversal/records.tsv" >"$tmp/traversal/records.new"
mv "$tmp/traversal/records.new" "$tmp/traversal/records.tsv"
(cd "$tmp/traversal" && shasum -a 256 records.tsv manifest.txt evidence-*.txt >SHA256SUMS)
check_reject "$tmp/traversal"
cp -a "$session" "$tmp/panic"
printf 'kernel panic\n' >"$tmp/panic/run-1/serial.log"
(cd "$tmp/panic/run-1" && shasum -a 256 manifest.txt host.log serial.log >SHA256SUMS)
check_reject "$tmp/panic"
if M1_EXECUTE_ATTESTATION=bad MILESTONE0_OUTPUT_ROOT="$tmp/m0" "${project_root}/scripts/milestone1-execute.sh" --execute >/dev/null 2>&1; then
    printf 'Expected bad attestation rejection.\n' >&2
    exit 1
fi
printf 'milestone1 tools self-tests passed\n'
