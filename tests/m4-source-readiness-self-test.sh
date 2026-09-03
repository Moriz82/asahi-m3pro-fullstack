#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly checker="$project_root/scripts/check-m4-source-readiness.sh"
readonly source_dir=$2 evidence=$4
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m4-source-readiness.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

set +e
output=$("$checker" --source-dir "$source_dir" --m0-evidence "$evidence")
result=$?
set -e
[[ $result -eq 2 ]]
for line in \
    'M4-source-readiness=checked-static-only' \
    'generic_asahi_driver_configured=true' \
    'generic_gpu_recovery_hook=true' \
    'target_t6030_device_match=false' \
    'target_t6030_hw_config=false' \
    'target_gpu_node=false' \
    'target_gpu_mailbox=false' \
    'target_gpu_power_domain=false' \
    'target_gpu_firmware_abi=false' \
    'native_runtime_evidence=false' \
    'hardware_acceptance=false' \
    'm4_source_ready=false' \
    'gate=blocked-target-gpu-driver-and-topology'; do
    printf '%s\n' "$output" | grep -Fx "$line" >/dev/null
done

fixture="$tmp/source"
mkdir "$fixture"
for contract in milestone2-source-files.sha256 milestone4-source-files.sha256; do
    while read -r digest path extra; do
        [[ -n ${digest:-} && $digest != \#* ]] || continue
        [[ -z ${extra:-} ]]
        mkdir -p "$fixture/$(dirname -- "$path")"
        [[ -f $fixture/$path ]] || cp -p -- "$source_dir/$path" "$fixture/$path"
    done < "$project_root/config/$contract"
done
printf '\napple,agx-t6030\n' >> "$fixture/drivers/gpu/drm/asahi/driver.rs"
printf '\npub(crate) mod t6030;\n' >> "$fixture/drivers/gpu/drm/asahi/hw/mod.rs"
printf '\ngpu: gpu@0 { compatible = "apple,agx-t6030"; mboxes = <&agx_mbox>; power-domains = <&ps_gfx>; apple,firmware-abi = <0 0 0>; };\nagx_mbox: mbox@0 {};\n' >> \
    "$fixture/arch/arm64/boot/dts/apple/t6030.dtsi"
if "$checker" --source-dir "$fixture" --m0-evidence "$evidence" >/dev/null 2>&1; then
    printf 'tampered source bypassed the pinned M4 gate\n' >&2
    exit 1
fi
printf 'M4-source-readiness-tests=passed\n'
