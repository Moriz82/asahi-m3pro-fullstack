#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
source "${project_root}/scripts/lib/evidence.sh"
m0_validate_output_root "$project_root"
evidence="${MILESTONE0_OUTPUT_ROOT}/milestone0/boot-payload/latest"
m1n1_source='' linux_dtb_source='' uboot_source=''
if (($#)); then
    if [[ $1 != --* ]]; then evidence=$1; shift; fi
fi
while (($#)); do
    case $1 in
        --m1n1-source|--linux-dtb-source|--u-boot-source)
            (($# >= 2)) || { printf 'missing value for %s\n' "$1" >&2; exit 64; }
            case $1 in
                --m1n1-source) m1n1_source=$2;;
                --linux-dtb-source) linux_dtb_source=$2;;
                --u-boot-source) uboot_source=$2;;
            esac
            shift 2
            ;;
        *) printf 'usage: %s [EVIDENCE] [--m1n1-source DIR --linux-dtb-source DIR --u-boot-source DIR]\n' "$0" >&2; exit 64;;
    esac
done
readonly evidence m1n1_source linux_dtb_source uboot_source

test -d "$evidence"
for required in SHA256SUMS "$BOOT_PAYLOAD" file.txt linux-dtb-manifest.txt m1n1-manifest.txt m1n1.macho manifest.txt t6030-j514s.dtb u-boot-manifest.txt u-boot-nodtb.bin; do
    test -s "${evidence}/${required}" || {
        printf 'Missing evidence file: %s\n' "${evidence}/${required}" >&2
        exit 1
    }
done

(
    cd "$evidence"
    shasum -a 256 -c SHA256SUMS
)

manifest_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "${evidence}/manifest.txt"
}

manifest_sha256() {
    evidence_sha256 "$1/manifest.txt"
}

verify_bound_source() {
    local label=$1 source_dir=$2 run_key=$3 hash_key=$4 copied_manifest=$5 copied_input=$6 source_input=$7
    [[ -n $source_dir ]] || return 0
    evidence_abs_dir "$source_dir"
    evidence_abs_regular "$source_dir/manifest.txt"
    [[ "$(basename -- "$source_dir")" == "$(manifest_value "$run_key")" ||
        "$(basename -- "$source_dir")" == latest ]] || {
        printf '%s source run ID mismatch\n' "$label" >&2
        exit 1
    }
    [[ "$(manifest_sha256 "$source_dir")" == "$(manifest_value "$hash_key")" ]] || {
        printf '%s source manifest hash mismatch\n' "$label" >&2
        exit 1
    }
    cmp "$source_dir/manifest.txt" "$evidence/$copied_manifest" || {
        printf '%s copied manifest differs from source\n' "$label" >&2
        exit 1
    }
    cmp "$source_dir/$source_input" "$evidence/$copied_input" || {
        printf '%s copied input differs from source\n' "$label" >&2
        exit 1
    }
}

grep -Fx 'target=Mac15,6/J514s/T6030' "${evidence}/manifest.txt" >/dev/null
grep -Fx 'status=build-verified-not-hardware-booted' "${evidence}/manifest.txt" >/dev/null
grep -Fx 'layout=m1n1.macho+t6030-j514s.dtb+u-boot-nodtb.bin' \
    "${evidence}/manifest.txt" >/dev/null
grep -Fx "payload=${BOOT_PAYLOAD}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "m1n1_commit=${M1N1_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "linux_commit=${LINUX_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Fx "u_boot_commit=${UBOOT_COMMIT}" "${evidence}/manifest.txt" >/dev/null
grep -Eq "${BOOT_PAYLOAD}:.*Mach-O 64-bit arm64" "${evidence}/file.txt"

for key in m1n1_source_run_id linux_dtb_source_run_id u_boot_source_run_id; do
    [[ $(manifest_value "$key") =~ ^[A-Za-z0-9._-]+$ ]] || {
        printf 'invalid payload binding %s\n' "$key" >&2
        exit 1
    }
done
for key in m1n1_source_manifest_sha256 linux_dtb_source_manifest_sha256 u_boot_source_manifest_sha256; do
    [[ $(manifest_value "$key") =~ ^[[:xdigit:]]{64}$ ]] || {
        printf 'invalid payload binding %s\n' "$key" >&2
        exit 1
    }
done
verify_bound_source m1n1 "$m1n1_source" m1n1_source_run_id m1n1_source_manifest_sha256 \
    m1n1-manifest.txt m1n1.macho m1n1.macho
verify_bound_source linux-dtb "$linux_dtb_source" linux_dtb_source_run_id linux_dtb_source_manifest_sha256 \
    linux-dtb-manifest.txt t6030-j514s.dtb t6030-j514s.dtb
verify_bound_source u-boot "$uboot_source" u_boot_source_run_id u_boot_source_manifest_sha256 \
    u-boot-manifest.txt u-boot-nodtb.bin u-boot-nodtb.bin

readonly m1n1_size="$(wc -c < "${evidence}/m1n1.macho" | tr -d ' ')"
readonly dtb_size="$(wc -c < "${evidence}/t6030-j514s.dtb" | tr -d ' ')"
readonly uboot_size="$(wc -c < "${evidence}/u-boot-nodtb.bin" | tr -d ' ')"
readonly total_size="$(wc -c < "${evidence}/${BOOT_PAYLOAD}" | tr -d ' ')"

test "$(manifest_value m1n1_offset)" -eq 0
test "$(manifest_value m1n1_size)" -eq "$m1n1_size"
test "$(manifest_value dtb_offset)" -eq "$m1n1_size"
test "$(manifest_value dtb_size)" -eq "$dtb_size"
test "$(manifest_value u_boot_offset)" -eq "$((m1n1_size + dtb_size))"
test "$(manifest_value u_boot_size)" -eq "$uboot_size"
test "$(manifest_value total_size)" -eq "$total_size"
test "$total_size" -eq "$((m1n1_size + dtb_size + uboot_size))"

dd if="${evidence}/${BOOT_PAYLOAD}" bs=1 count="$m1n1_size" 2>/dev/null \
    | cmp "${evidence}/m1n1.macho" -
dd if="${evidence}/${BOOT_PAYLOAD}" bs=1 skip="$m1n1_size" count="$dtb_size" 2>/dev/null \
    | cmp "${evidence}/t6030-j514s.dtb" -
dd if="${evidence}/${BOOT_PAYLOAD}" bs=1 skip="$((m1n1_size + dtb_size))" 2>/dev/null \
    | cmp "${evidence}/u-boot-nodtb.bin" -

printf 'boot-payload.baseline=verified\n'
