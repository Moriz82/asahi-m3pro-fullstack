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
mkdir -p "$fixture/config" "$fixture/patches/u-boot" "$fixture/scripts/lib"
cp -p -- "$project_root/config/milestone0.env" "$fixture/config/milestone0.env"
cp -p -- "$project_root/scripts/verify-u-boot.sh" "$fixture/scripts/verify-u-boot.sh"
cp -p -- "$project_root/scripts/lib/u-boot-config-overlay.sh" \
    "$fixture/scripts/lib/u-boot-config-overlay.sh"

if [[ -n "${UBOOT_CONFIG_OVERLAY-}" ]]; then
    source "$project_root/scripts/lib/u-boot-config-overlay.sh"
    m0_load_u_boot_config
    u_boot_derive_patch_policy
    if u_boot_require_candidate_isolation "$project_root" "$project_root/out" "$SOURCE_VOLUME" >/dev/null 2>&1; then
        printf 'candidate accepted canonical output and source volume\n' >&2
        exit 1
    fi
    SOURCE_VOLUME_OVERRIDE=candidate-test-volume \
        u_boot_require_candidate_isolation "$project_root" \
            "$project_root/out/isolated/candidate-test" candidate-test-volume

    readonly candidate_overlay_name="$(basename -- "$UBOOT_CONFIG_OVERLAY")"
    cp -p -- "$UBOOT_CONFIG_OVERLAY" "$fixture/config/$candidate_overlay_name"
    readonly fixture_overlay="$fixture/config/$candidate_overlay_name"
    export UBOOT_CONFIG_OVERLAY="$fixture_overlay"
    if "$fixture/scripts/verify-u-boot.sh" "$evidence" >/dev/null 2>&1; then
        printf 'candidate evidence accepted without explicit noncanonical flag\n' >&2
        exit 1
    fi
    "$fixture/scripts/verify-u-boot.sh" --allow-noncanonical-candidate "$evidence" >/dev/null

    tag_tamper="$tmp/candidate-tag-tamper"
    mkdir "$tag_tamper"
    cp -pR -- "$evidence/." "$tag_tamper/"
    printf 'tampered\n' >> "$tag_tamper/upstream-tag.txt"
    (
        cd "$tag_tamper"
        checksum_files=()
        while read -r digest path; do checksum_files+=("$path"); done < SHA256SUMS
        sha256sum "${checksum_files[@]}" > SHA256SUMS
    )
    if "$fixture/scripts/verify-u-boot.sh" --allow-noncanonical-candidate "$tag_tamper" >/dev/null 2>&1; then
        printf 'tampered candidate tag object bypassed verifier\n' >&2
        exit 1
    fi

    expect_candidate_reject() {
        local name=$1 expression=$2 tampered
        tampered="$fixture/config/candidate-${name}.env"
        sed "s|^${expression%%=*}=.*|${expression}|" "$fixture_overlay" > "$tampered"
        error_log="$tmp/candidate-${name}.err"
        if UBOOT_CONFIG_OVERLAY="$tampered" "$fixture/scripts/verify-u-boot.sh" \
            --allow-noncanonical-candidate "$evidence" >/dev/null 2>"$error_log"; then
            printf 'candidate overlay tamper bypassed verifier: %s\n' "$name" >&2
            exit 1
        fi
        if grep -Fq 'UBOOT_CONFIG_OVERLAY' "$error_log"; then
            printf 'candidate overlay tamper test failed before loading overlay: %s\n' "$name" >&2
            exit 1
        fi
    }
    expect_candidate_reject tag-object 'UBOOT_UPSTREAM_TAG_OBJECT=0000000000000000000000000000000000000000'
    expect_candidate_reject source-tree 'UBOOT_SOURCE_TREE_COMMIT=0000000000000000000000000000000000000000'
    expect_candidate_reject patch-pairing 'UBOOT_PATCH_SERIES=unexpected.patch'
    expect_candidate_reject signature-state 'UBOOT_UPSTREAM_TAG_SIGNATURE_STATUS=verified'
    expect_candidate_reject required-commits \
        'UBOOT_REQUIRED_ANCESTOR_COMMITS="0000000000000000000000000000000000000000 0000000000000000000000000000000000000000 0000000000000000000000000000000000000000"'
    printf 'U-Boot-candidate-binding-tests=passed\n'
    exit 0
fi

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
