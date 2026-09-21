#!/usr/bin/env bash
set -Eeuo pipefail

# Source-specific tier, not part of the source-free static suite. Run only in
# the documented network-disabled AArch64 Linux container. Never boots either
# artifact. Both C programs address process-owned memory exclusively.
[[ $# == 2 ]] || {
    printf 'usage: %s M1N1_SOURCE UBOOT_SOURCE\n' "$0" >&2
    exit 64
}
[[ $(uname -s) == Linux && $(uname -m) == aarch64 && -f /.dockerenv ]]
readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly m1n1_source=$1 uboot_source=$2
for path in "$m1n1_source" "$uboot_source"; do
    [[ $path == /* && -d $path ]]
done
readonly source_root="$(dirname -- "$m1n1_source")"
[[ $(dirname -- "$uboot_source") == "$source_root" ]]
# Open read-only: the suite must also work with a read-only source mount.
# Builders take the exclusive side of this same source-volume lock.
exec 9<"$source_root/.milestone0-build.lock"
flock --shared --nonblock 9 || {
    printf 'A builder owns the source-volume lock; source tests not run\n' >&2
    exit 1
}
[[ $(git -C "$m1n1_source" rev-parse HEAD) == 940439b9a407fbfc499bea933269219f3f62d4c7 ]]
[[ $(git -C "$uboot_source" rev-parse HEAD) == ec49c9d70e6ab003813d6f475fec62dc1c0f4bfe ]]
for source in "$m1n1_source" "$uboot_source"; do
    [[ -z $(git -C "$source" status --porcelain --untracked-files=all) ]]
done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/bootloader-source.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
cd "$tmp"
ulimit -c 0

expect_status() {
    local expected=$1 result=0
    shift
    "$@" > result.log 2>&1 || result=$?
    if [[ $result != "$expected" ]]; then
        cat result.log >&2
        printf 'expected exit %s, got %s\n' "$expected" "$result" >&2
        exit 1
    fi
}

# Never accept external generated headers, even from an apparently compatible
# Apple build. Generate configuration and offsets from the pinned source in a
# fresh disposable directory; this prepares headers, not a bootable artifact.
readonly uboot_build="$tmp/u-boot-build"
SOURCE_DATE_EPOCH=$(git -C "$uboot_source" show -s --format=%ct HEAD)
export SOURCE_DATE_EPOCH
if make -s -C "$uboot_source" O="$uboot_build" CROSS_COMPILE=aarch64-linux-gnu- \
        apple_m1_defconfig > prepare.log 2>&1 &&
    make -s -C "$uboot_source" O="$uboot_build" CROSS_COMPILE=aarch64-linux-gnu- \
        -j2 prepare >> prepare.log 2>&1; then
    for symbol in ARCH_APPLE ARM64 NVME_APPLE; do
        grep -Fx "CONFIG_${symbol}=y" "$uboot_build/.config" >/dev/null
    done
else
    cat prepare.log >&2
    exit 1
fi
mkdir mismatched-build
printf 'CONFIG_ARCH_APPLE=y\nCONFIG_ARM64=y\nCONFIG_NVME_APPLE=y\n' > mismatched-build/.config
expect_status 64 bash "$project_root/tests/bootloader-source-self-test.sh" \
    "$m1n1_source" "$uboot_source" "$tmp/mismatched-build"
grep -F 'M1N1_SOURCE UBOOT_SOURCE' result.log >/dev/null
printf 'external_generated_config_rejected=true\n'

m1n1_flags=(-g -ffunction-sections -fdata-sections -Wl,--gc-sections -I "$m1n1_source/src")
nvme_flags=(-g -no-pie -fno-pie -ffunction-sections -fdata-sections -Wl,--gc-sections
    -nostdinc -isystem "$(gcc -print-file-name=include)"
    -I "$uboot_source/drivers/nvme" -I "$uboot_build/include"
    -I "$uboot_source/include" -I "$uboot_source/arch/arm/include"
    -I "$uboot_source/arch/arm/mach-apple/include"
    -include "$uboot_source/include/linux/kconfig.h"
    -D__KERNEL__ -D__UBOOT__ -D__ARM__ -D__LINUX_ARM_ARCH__=8
    -ffreestanding -fno-builtin -fno-strict-aliasing -fshort-wchar
    -ffixed-x18 -mgeneral-regs-only -mstrict-align)
readonly m1n1_test="$project_root/tests/m1n1-usb-phy-self-test.c"
readonly nvme_test="$project_root/tests/u-boot-apple-nvme-self-test.c"

gcc -O2 -fsanitize=undefined -fno-sanitize-recover=all "${m1n1_flags[@]}" \
    "-DM1N1_USB_SOURCE=\"$m1n1_source/src/usb.c\"" "$m1n1_test" -o usb-test
./usb-test
mkdir baseline
git -C "$m1n1_source" archive 60e53e7078c5cb7efce32d64bf50829e9401e44f src/usb.c \
    | tar -x -C baseline
gcc -O2 "${m1n1_flags[@]}" "-DM1N1_USB_SOURCE=\"$tmp/baseline/src/usb.c\"" \
    "$m1n1_test" -o usb-baseline
expect_status 134 ./usb-baseline
grep -F 'event_count == 9 && clear_calls == 2' result.log >/dev/null
printf 'usb_reset_regression_control=passed\n'

gcc -O2 -fsanitize=undefined -fno-sanitize-recover=all "${nvme_flags[@]}" \
    "-DUBOOT_NVME_SOURCE=\"$uboot_source/drivers/nvme/nvme_apple.c\"" "$nvme_test" -o nvme-test
./nvme-test
for page in 4096 16384; do
    for prp in 1 2 3; do
        expect_status 91 ./nvme-test "$page" "$prp"
        grep -Fx 'admin_alignment_rejected_before_writes=true' result.log >/dev/null
    done
done
printf 'admin_alignment_negative_cases=6 passed\n'

for rev in dbd2154cb0d3a5552505cfcc00a8b5f8da737030 \
    01e7f95a99224d1e526cc6c8b1782ed7b01db441 6bfd8a4fa848c74ff1ae0cf060c5dc17bc305977; do
    git -C "$uboot_source" archive "$rev" drivers/nvme/nvme_apple.c | tar -x -C baseline
    gcc -O2 "${nvme_flags[@]}" \
        "-DUBOOT_NVME_SOURCE=\"$tmp/baseline/drivers/nvme/nvme_apple.c\"" "$nvme_test" -o nvme-baseline
    if [[ $rev == 6bfd8a4fa848c74ff1ae0cf060c5dc17bc305977 ]]; then
        ./nvme-baseline
        expect_status 1 ./nvme-baseline 4096 1
        grep -F 'check failed: false' result.log >/dev/null
    else
        expect_status 1 ./nvme-baseline
        grep -F 'check failed: tcb_memory[i] == value' result.log >/dev/null
    fi
    printf 'nvme_regression_control=%s passed\n' "$rev"
done

# Coverage builds are separate from the optimized UBSan runs above. U-Boot's
# hidden allocator declarations require a static libc when linking libgcov.
gcc -O0 --coverage "${m1n1_flags[@]}" \
    "-DM1N1_USB_SOURCE=\"$m1n1_source/src/usb.c\"" "$m1n1_test" -o usb-coverage
./usb-coverage
gcov -f -b -c usb-coverage-m1n1-usb-phy-self-test.gcno > usb-gcov.log
for function in usb_drd_get_regs usb_phy_bringup; do
    grep -E "^function $function called [0-9]+ returned 100% blocks executed 100%$" usb.c.gcov
done

gcc -O0 --coverage -static "${nvme_flags[@]}" \
    "-DUBOOT_NVME_SOURCE=\"$uboot_source/drivers/nvme/nvme_apple.c\"" "$nvme_test" -o nvme-coverage
./nvme-coverage
for page in 4096 16384; do
    for prp in 1 2 3; do
        expect_status 91 ./nvme-coverage "$page" "$prp"
        grep -Fx 'admin_alignment_rejected_before_writes=true' result.log >/dev/null
    done
done
gcov -f -b -c nvme-coverage-u-boot-apple-nvme-self-test.gcno > nvme-gcov.log
for function in apple_nvme_submit_cmd apple_nvme_complete_cmd; do
    grep -E "^function $function called [0-9]+ returned [0-9]+% blocks executed 100%$" nvme_apple.c.gcov
done
printf 'bootloader_source_tests=passed\ncanonical_evidence=false\nhardware_acceptance=false\n'
