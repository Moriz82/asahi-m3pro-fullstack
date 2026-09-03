#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly checker="$project_root/scripts/check-m3-source-readiness.sh"
readonly source_dir=$2
readonly evidence=$4
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m3-source-readiness.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

set +e
output=$("$checker" --source-dir "$source_dir" --m0-evidence "$evidence")
result=$?
set -e
[[ $result -eq 2 ]]
for line in \
    'M3-source-readiness=checked-static-only' \
    'generic_dcp_driver_configured=true' \
    'target_dcp_node=false' \
    'target_dcp_mailbox=false' \
    'target_dcp_dart=false' \
    'target_display_subsystem=false' \
    'loader_simple_framebuffer_node=true' \
    'native_runtime_evidence=false' \
    'hardware_acceptance=false' \
    'm3_source_ready=false' \
    'gate=blocked-target-dcp-topology'; do
    printf '%s\n' "$output" | grep -Fx "$line" >/dev/null
done

fixture="$tmp/source"
mkdir "$fixture"
while read -r digest path extra; do
    [[ -n ${digest:-} && $digest != \#* ]] || continue
    [[ -z ${extra:-} ]]
    mkdir -p "$fixture/$(dirname -- "$path")"
    cp -p -- "$source_dir/$path" "$fixture/$path"
done < "$project_root/config/milestone2-source-files.sha256"
mkdir -p "$fixture/drivers/gpu/drm/apple"
for file in Makefile apple_drv.c dcp.c; do cp -p -- "$source_dir/drivers/gpu/drm/apple/$file" "$fixture/drivers/gpu/drm/apple/$file"; done
printf '\ncompatible = "apple,t6030-dcp", "apple,dcp";\ndcp_mbox: mbox@0 {}\ndcp_dart: iommu@0 {}\ncompatible = "apple,display-subsystem";\n' >> \
    "$fixture/arch/arm64/boot/dts/apple/t6030.dtsi"
if "$checker" --source-dir "$fixture" --m0-evidence "$evidence" >/dev/null 2>&1; then
    printf 'tampered source bypassed the pinned M3 gate\n' >&2
    exit 1
fi
printf 'M3-source-readiness-tests=passed\n'
