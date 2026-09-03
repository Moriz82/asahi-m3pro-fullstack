#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
readonly output_root="${MILESTONE1_OUTPUT_ROOT:-${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone1}"
readonly m0_root="${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/milestone0"

build_command() {
    local command_device="$1" command_tool="$2" command_image="$3" command_dtb="$4" command_initramfs="$5"
    printf 'M1N1DEVICE=%q python3 %q --compression %q %q %q %q\n' \
        "$command_device" "$command_tool" "$M1_COMPRESSION" "$command_image" "$command_dtb" "$command_initramfs"
}

if [[ "${1:-}" == --self-test ]]; then
    rendered="$(build_command /dev/test /tmp/linux.py /tmp/Image /tmp/j514s.dtb /tmp/initramfs)"
    [[ "$rendered" == 'M1N1DEVICE=/dev/test python3 /tmp/linux.py --compression none /tmp/Image /tmp/j514s.dtb /tmp/initramfs' ]]
    if grep -Fq 'root=' <<<"$rendered"; then exit 1; fi
    printf 'milestone1-dry-run self-test passed\n'
    exit 0
fi

test -n "$M1N1DEVICE" || { printf 'M1N1DEVICE must be explicit.\n' >&2; exit 2; }
test -n "$M1_M1N1_SOURCE_DIR" || { printf 'M1_M1N1_SOURCE_DIR must be explicit.\n' >&2; exit 2; }
readonly linux_run="$(cd "${m0_root}/linux-full/latest" && pwd -P)"
readonly initramfs_run="$(cd "${output_root}/initramfs/latest" && pwd -P)"
readonly image="${linux_run}/${M1_KERNEL_RELATIVE#linux-full/latest/}"
readonly dtb="${linux_run}/${M1_DTB_RELATIVE#linux-full/latest/}"
readonly initramfs="${initramfs_run}/${M1_INITRAMFS_NAME}"
readonly tool="${M1_M1N1_SOURCE_DIR}/${M1_M1N1_TOOL_RELATIVE}"
test -s "$image" && test -s "$dtb" && test -s "$initramfs" && test -f "$tool" || {
    printf 'Missing one or more dry-run inputs; build and verify M0/M1 first.\n' >&2
    exit 1
}
"${project_root}/scripts/verify-milestone1-initramfs.sh" "$initramfs_run" "$linux_run"
build_command "$M1N1DEVICE" "$tool" "$image" "$dtb" "$initramfs"
