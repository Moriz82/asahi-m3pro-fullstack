#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $# -eq 2 && $1 == --evidence ]] || {
    printf 'usage: %s --evidence ABS\n' "$0" >&2
    exit 64
}
readonly evidence=$2
[[ $evidence == /* && -d $evidence ]] || { printf 'invalid U-Boot evidence\n' >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/u-boot-patch-binding.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
readonly fixture="$tmp/project"
mkdir -p "$fixture/config" "$fixture/patches/u-boot" "$fixture/scripts"
cp -p -- "$project_root/config/milestone0.env" "$fixture/config/milestone0.env"
cp -p -- "$project_root/scripts/verify-u-boot.sh" "$fixture/scripts/verify-u-boot.sh"
source "$project_root/config/milestone0.env"
cp -p -- "$project_root/patches/u-boot/$UBOOT_PATCH_SERIES" \
    "$fixture/patches/u-boot/$UBOOT_PATCH_SERIES"

"$fixture/scripts/verify-u-boot.sh" "$evidence" >/dev/null
printf 'tampered\n' >> "$fixture/patches/u-boot/$UBOOT_PATCH_SERIES"
if "$fixture/scripts/verify-u-boot.sh" "$evidence" >/dev/null 2>&1; then
    printf 'tampered U-Boot patch bypassed verifier\n' >&2
    exit 1
fi
rm -- "$fixture/patches/u-boot/$UBOOT_PATCH_SERIES"
ln -s "$project_root/patches/u-boot/$UBOOT_PATCH_SERIES" \
    "$fixture/patches/u-boot/$UBOOT_PATCH_SERIES"
if "$fixture/scripts/verify-u-boot.sh" "$evidence" >/dev/null 2>&1; then
    printf 'symlinked U-Boot patch bypassed verifier\n' >&2
    exit 1
fi
rm -- "$fixture/patches/u-boot/$UBOOT_PATCH_SERIES"
if "$fixture/scripts/verify-u-boot.sh" "$evidence" >/dev/null 2>&1; then
    printf 'missing U-Boot patch bypassed verifier\n' >&2
    exit 1
fi
printf 'U-Boot-patch-binding-tests=passed\n'
