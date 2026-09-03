#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_root/config/milestone0.env"
[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly source_arg=$2 evidence_arg=$4
[[ $source_arg == /* && -d $source_arg ]] || { printf 'invalid source directory\n' >&2; exit 1; }
[[ $evidence_arg == /* && -d $evidence_arg ]] || { printf 'invalid M0 evidence directory\n' >&2; exit 1; }
readonly source_dir="$(cd -- "$source_arg" && pwd -P)"
readonly evidence="$(cd -- "$evidence_arg" && pwd -P)"

"$project_root/scripts/verify-m2-source-contract.sh" \
    --source-dir "$source_dir" --m0-evidence "$evidence" >/dev/null

readonly contract="$project_root/config/milestone4-source-files.sha256"
[[ -f $contract && ! -L $contract ]] || { printf 'invalid M4 source contract\n' >&2; exit 1; }
[[ $(grep -c '^# format=1$' "$contract") -eq 1 ]] || { printf 'invalid M4 source contract format\n' >&2; exit 1; }
[[ $(grep -c '^# target=Mac15,6/J514s/T6030$' "$contract") -eq 1 ]] || { printf 'invalid M4 source contract target\n' >&2; exit 1; }
[[ $(sed -n 's/^# source_tree_commit=//p' "$contract") == "$LINUX_SOURCE_TREE_COMMIT" ]] || {
    printf 'M4 source contract is not bound to the pinned tree\n' >&2
    exit 1
}
expected_files=(
    drivers/gpu/drm/asahi/Kconfig
    drivers/gpu/drm/asahi/Makefile
    drivers/gpu/drm/asahi/driver.rs
    drivers/gpu/drm/asahi/gpu.rs
    drivers/gpu/drm/asahi/hw/mod.rs
)
contract_files=()
while read -r digest path extra; do
    [[ -n ${digest:-} && $digest != \#* ]] || continue
    [[ $digest =~ ^[0-9a-f]{64}$ && -n ${path:-} && -z ${extra:-} ]] || { printf 'invalid M4 source hash row\n' >&2; exit 1; }
    [[ $path != /* && $path != *..* && $path =~ ^[A-Za-z0-9._/+:-]+$ ]] || { printf 'unsafe M4 source path\n' >&2; exit 1; }
    contract_files+=("$path")
    [[ -f $source_dir/$path && ! -L $source_dir/$path ]] || { printf 'missing M4 source file: %s\n' "$path" >&2; exit 1; }
    [[ $(sha256sum "$source_dir/$path" | awk '{print $1}') == "$digest" ]] || { printf 'M4 source hash mismatch: %s\n' "$path" >&2; exit 1; }
done < "$contract"
cmp <(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort) \
    <(printf '%s\n' "${contract_files[@]}" | LC_ALL=C sort) >/dev/null || {
    printf 'M4 source contract inventory mismatch\n' >&2
    exit 1
}

grep -Fx 'CONFIG_DRM_ASAHI=m' "$evidence/config" >/dev/null
grep -Fq 'obj-$(CONFIG_DRM_ASAHI) += asahi.o' "$source_dir/drivers/gpu/drm/asahi/Makefile"
grep -Fq 'fn recover(&self)' "$source_dir/drivers/gpu/drm/asahi/gpu.rs"

target_fragments=(
    "$source_dir/arch/arm64/boot/dts/apple/t6030-j514s.dts"
    "$source_dir/arch/arm64/boot/dts/apple/t6030.dtsi"
    "$source_dir/arch/arm64/boot/dts/apple/t6030-pmgr.dtsi"
    "$source_dir/arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi"
)
has_pattern() { if grep -Eq "$1" "${target_fragments[@]}"; then printf true; else printf false; fi; }
readonly device_match="$(grep -Eq 'apple,agx-t6030' "$source_dir/drivers/gpu/drm/asahi/driver.rs" && printf true || printf false)"
readonly hw_config="$(grep -Eq '(^|[^[:alnum:]_])t6030([^[:alnum:]_]|$)' "$source_dir/drivers/gpu/drm/asahi/hw/mod.rs" && printf true || printf false)"
readonly gpu_node="$(has_pattern 'gpu:[[:space:]]+gpu@|compatible[[:space:]]*=[^;]*"apple,agx')"
readonly gpu_mailbox="$(has_pattern 'agx_mbox:|mboxes[[:space:]]*=[^;]*agx_mbox')"
readonly gpu_power="$(has_pattern 'power-domains[[:space:]]*=[^;]*ps_gfx')"
readonly firmware_abi="$(has_pattern 'apple,firmware-abi')"

printf 'M4-source-readiness=checked-static-only\n'
printf 'generic_asahi_driver_configured=true\n'
printf 'generic_gpu_recovery_hook=true\n'
printf 'target_t6030_device_match=%s\n' "$device_match"
printf 'target_t6030_hw_config=%s\n' "$hw_config"
printf 'target_gpu_node=%s\n' "$gpu_node"
printf 'target_gpu_mailbox=%s\n' "$gpu_mailbox"
printf 'target_gpu_power_domain=%s\n' "$gpu_power"
printf 'target_gpu_firmware_abi=%s\n' "$firmware_abi"
printf 'native_runtime_evidence=false\n'
printf 'hardware_acceptance=false\n'
if [[ $device_match == true && $hw_config == true && $gpu_node == true && $gpu_mailbox == true && $gpu_power == true && $firmware_abi == true ]]; then
    printf 'm4_source_ready=true\n'
    exit 0
fi
printf 'm4_source_ready=false\n'
printf 'gate=blocked-target-gpu-driver-and-topology\n'
exit 2
