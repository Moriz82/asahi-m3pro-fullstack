#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_root/config/milestone0.env"
[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly checker="$project_root/scripts/check-m5-source-readiness.sh"
readonly source_dir=$2 evidence=$4
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m5-source-readiness.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

set +e
output=$("$checker" --source-dir "$source_dir" --m0-evidence "$evidence")
result=$?
set -e
[[ $result -eq 2 ]]
for line in \
    'M5-source-readiness=checked-static-only' \
    'generic_apple_dwc3_driver_built=true' \
    'generic_apple_atc_phy_driver_built=true' \
    'generic_usb4_stack_built=true' \
    'generic_thunderbolt_altmode_built=true' \
    'generic_uas_driver_built=true' \
    'target_usb_c_ports=3' \
    'target_usb_pd_controllers=4' \
    'target_usb_data_topology=true' \
    'target_usb_pd_topology=true' \
    'target_thunderbolt_source_path=true' \
    'target_sdxc_topology=true' \
    'target_dp_output_topology=false' \
    'target_hdmi_output_topology=false' \
    'native_runtime_evidence=false' \
    'hardware_acceptance=false' \
    'm5_source_ready=false' \
    'gate=blocked-target-display-link-topology'; do
    printf '%s\n' "$output" | grep -Fx "$line" >/dev/null
done

fixture="$tmp/source"
mkdir "$fixture"
for contract in milestone2-source-files.sha256 milestone5-source-files.sha256; do
    while read -r digest path extra; do
        [[ -n ${digest:-} && $digest != \#* ]] || continue
        [[ -z ${extra:-} ]]
        mkdir -p "$fixture/$(dirname -- "$path")"
        [[ -f $fixture/$path ]] || cp -p -- "$source_dir/$path" "$fixture/$path"
    done < "$project_root/config/$contract"
done
if "$checker" --source-dir "$fixture" --m0-evidence "$evidence" >/dev/null 2>&1; then
    printf 'non-Git partial source bypassed the pinned M5 gate\n' >&2
    exit 1
fi
printf '\nremote-endpoint = <&dptx0>;\nhdmi: hdmi@0 {};\n' >> \
    "$fixture/arch/arm64/boot/dts/apple/t6030.dtsi"
if "$checker" --source-dir "$fixture" --m0-evidence "$evidence" >/dev/null 2>&1; then
    printf 'tampered source bypassed the pinned M5 gate\n' >&2
    exit 1
fi

git_fixture="$tmp/git-source"
git clone --no-checkout --shared "$source_dir" "$git_fixture" >/dev/null 2>&1
git -C "$git_fixture" sparse-checkout init --no-cone
{
    printf '/Makefile\n'
    for contract in milestone2-source-files.sha256 milestone5-source-files.sha256; do
        awk '$1 !~ /^#/ && NF == 2 { print "/" $2 }' "$project_root/config/$contract"
    done
} | LC_ALL=C sort -u > "$git_fixture/.git/info/sparse-checkout"
git -C "$git_fixture" checkout --detach "$LINUX_SOURCE_TREE_COMMIT" >/dev/null 2>&1
set +e
clean_output=$("$checker" --source-dir "$git_fixture" --m0-evidence "$evidence")
clean_result=$?
set -e
[[ $clean_result -eq 2 ]]
printf '%s\n' "$clean_output" | grep -Fx 'gate=blocked-target-display-link-topology' >/dev/null
printf '\n# uncontracted dirty source\n' >> "$git_fixture/Makefile"
if "$checker" --source-dir "$git_fixture" --m0-evidence "$evidence" >/dev/null 2>&1; then
    printf 'dirty uncontracted source bypassed the pinned M5 gate\n' >&2
    exit 1
fi
printf 'M5-source-readiness-tests=passed\n'
