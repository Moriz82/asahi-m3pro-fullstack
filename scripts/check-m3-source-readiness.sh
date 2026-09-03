#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly source_arg=$2
readonly evidence_arg=$4
[[ $source_arg == /* && -d $source_arg ]] || { printf 'invalid source directory\n' >&2; exit 1; }
[[ $evidence_arg == /* && -d $evidence_arg ]] || { printf 'invalid M0 evidence directory\n' >&2; exit 1; }
readonly source_dir="$(cd -- "$source_arg" && pwd -P)"
readonly evidence="$(cd -- "$evidence_arg" && pwd -P)"

"$project_root/scripts/verify-m2-source-contract.sh" \
    --source-dir "$source_dir" --m0-evidence "$evidence" >/dev/null
grep -Fx 'CONFIG_DRM_APPLE=m' "$evidence/config" >/dev/null
grep -Fx 'CONFIG_BACKLIGHT_CLASS_DEVICE=m' "$evidence/config" >/dev/null
grep -Fq 'obj-$(CONFIG_DRM_APPLE) += appledrm.o' "$source_dir/drivers/gpu/drm/apple/Makefile"
grep -Fq 'apple,display-subsystem' "$source_dir/drivers/gpu/drm/apple/apple_drv.c"
grep -Fq 'apple,dcp' "$source_dir/drivers/gpu/drm/apple/dcp.c"

target_fragments=(
    "$source_dir/arch/arm64/boot/dts/apple/t6030-j514s.dts"
    "$source_dir/arch/arm64/boot/dts/apple/t6030.dtsi"
    "$source_dir/arch/arm64/boot/dts/apple/t6030-pmgr.dtsi"
    "$source_dir/arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi"
)
has_pattern() {
    local pattern=$1
    if grep -Eq "$pattern" "${target_fragments[@]}"; then printf true; else printf false; fi
}
readonly dcp_node="$(has_pattern 'compatible[[:space:]]*=[^;]*"apple,[^"]*dcp')"
readonly dcp_mailbox="$(has_pattern 'dcp_mbox:|mboxes[[:space:]]*=[^;]*dcp_mbox')"
readonly dcp_dart="$(has_pattern 'dcp_dart:|iommus[[:space:]]*=[^;]*dcp_dart')"
readonly display_subsystem="$(has_pattern '"apple,display-subsystem"')"
readonly simple_framebuffer="$(has_pattern '"apple,simple-framebuffer"')"

printf 'M3-source-readiness=checked-static-only\n'
printf 'generic_dcp_driver_configured=true\n'
printf 'target_dcp_node=%s\n' "$dcp_node"
printf 'target_dcp_mailbox=%s\n' "$dcp_mailbox"
printf 'target_dcp_dart=%s\n' "$dcp_dart"
printf 'target_display_subsystem=%s\n' "$display_subsystem"
printf 'loader_simple_framebuffer_node=%s\n' "$simple_framebuffer"
printf 'native_runtime_evidence=false\n'
printf 'hardware_acceptance=false\n'
if [[ $dcp_node == true && $dcp_mailbox == true && $dcp_dart == true && $display_subsystem == true ]]; then
    printf 'm3_source_ready=true\n'
    exit 0
fi
printf 'm3_source_ready=false\n'
printf 'gate=blocked-target-dcp-topology\n'
exit 2
