#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_root/config/milestone0.env"
source "$project_root/scripts/lib/evidence.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }

[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly source_arg=$2 evidence_arg=$4
[[ $source_arg == /* && -d $source_arg && ! -L $source_arg ]] || die 'invalid source directory'
[[ $evidence_arg == /* && -d $evidence_arg ]] || die 'invalid M0 evidence directory'
readonly source_dir="$(cd -- "$source_arg" && pwd -P)"
readonly evidence="$(cd -- "$evidence_arg" && pwd -P)"
[[ $source_dir == "$source_arg" ]] || die 'source directory must be canonical'
command -v git >/dev/null || die 'git is required'
[[ $(git -C "$source_dir" rev-parse --is-inside-work-tree 2>/dev/null) == true ]] ||
    die 'M5 source directory must be a Git worktree'
readonly source_root="$(git -C "$source_dir" rev-parse --show-toplevel)"
[[ $source_root == "$source_dir" ]] || die 'M5 source directory must be the worktree root'
readonly source_head="$(git -C "$source_dir" rev-parse HEAD)"
[[ $source_head == "$LINUX_SOURCE_TREE_COMMIT" ]] || die 'M5 source HEAD is not the pinned tree'
source_status=$(git -C "$source_dir" status --porcelain=v1 --untracked-files=all --ignored=matching) ||
    die 'cannot inspect M5 source status'
readonly source_status
[[ -z $source_status ]] || die 'M5 source tree is not clean'

"$project_root/scripts/verify-m2-source-contract.sh" \
    --source-dir "$source_dir" --m0-evidence "$evidence" >/dev/null

readonly contract="$project_root/config/milestone5-source-files.sha256"
[[ -f $contract && ! -L $contract ]] || die 'invalid M5 source contract'
[[ $(grep -c '^# format=1$' "$contract") -eq 1 ]] || die 'invalid M5 source contract format'
[[ $(grep -c '^# target=Mac15,6/J514s/T6030$' "$contract") -eq 1 ]] || die 'invalid M5 source contract target'
[[ $(sed -n 's/^# source_tree_commit=//p' "$contract") == "$LINUX_SOURCE_TREE_COMMIT" ]] ||
    die 'M5 source contract is not bound to the pinned tree'

expected_files=(
    drivers/phy/apple/atc.c
    drivers/mmc/host/sdhci-pci-core.c
    drivers/mmc/host/sdhci-pci-gli.c
    drivers/thunderbolt/nhi.c
    drivers/usb/dwc3/dwc3-apple.c
    drivers/usb/typec/altmodes/thunderbolt.c
    drivers/usb/typec/tipd/spmi.c
)
contract_files=()
while read -r digest path extra; do
    [[ -n ${digest:-} && $digest != \#* ]] || continue
    [[ $digest =~ ^[0-9a-f]{64}$ && -n ${path:-} && -z ${extra:-} ]] || die 'invalid M5 source hash row'
    [[ $path != /* && $path != *..* && $path =~ ^[A-Za-z0-9._/+:-]+$ ]] || die 'unsafe M5 source path'
    contract_files+=("$path")
    [[ -f $source_dir/$path && ! -L $source_dir/$path ]] || die "missing M5 source file: $path"
    [[ $(sha256sum "$source_dir/$path" | awk '{print $1}') == "$digest" ]] || die "M5 source hash mismatch: $path"
done < "$contract"
cmp <(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort) \
    <(printf '%s\n' "${contract_files[@]}" | LC_ALL=C sort) >/dev/null ||
    die 'M5 source contract inventory mismatch'

for setting in \
    CONFIG_PCIE_APPLE=m CONFIG_USB_DWC3_APPLE=m CONFIG_PHY_APPLE_ATC=m \
    CONFIG_TYPEC_SN201202X=m CONFIG_TYPEC_DP_ALTMODE=m CONFIG_TYPEC_TBT_ALTMODE=m \
    CONFIG_USB4=m CONFIG_USB_UAS=m CONFIG_HOTPLUG_PCI_PCIE=y CONFIG_MMC_SDHCI_PCI=m; do
    grep -Fx "$setting" "$evidence/config" >/dev/null || die "M5 config setting missing: $setting"
done

evidence_abs_regular "$evidence/modules.inventory"
modules_hash=$(awk '$2 == "./modules.inventory" { print $1; found++ } END { if (found != 1) exit 1 }' \
    "$evidence/SHA256SUMS") || die 'M0 checksum missing or duplicated: modules.inventory'
readonly modules_hash
[[ $(evidence_sha256 "$evidence/modules.inventory") == "$modules_hash" ]] || die 'M0 modules inventory hash mismatch'
require_module() {
    local relative=$1 suffix="/kernel/$1" count
    count=$(awk -v suffix="$suffix" 'substr($0, length($0) - length(suffix) + 1) == suffix { n++ } END { print n + 0 }' \
        "$evidence/modules.inventory")
    [[ $count -eq 1 ]] || die "M5 module missing or duplicated: $relative"
}
for module in \
    drivers/phy/apple/phy-apple-atc.ko \
    drivers/mmc/host/sdhci-pci.ko \
    drivers/thunderbolt/thunderbolt.ko \
    drivers/usb/dwc3/dwc3-apple.ko \
    drivers/usb/storage/uas.ko \
    drivers/usb/typec/altmodes/typec_displayport.ko \
    drivers/usb/typec/altmodes/typec_thunderbolt.ko \
    drivers/usb/typec/tipd/sn201202x.ko; do
    require_module "$module"
done

grep -Fq 'apple,t8103-dwc3' "$source_dir/drivers/usb/dwc3/dwc3-apple.c"
grep -Fq 'apple,t8122-atcphy' "$source_dir/drivers/phy/apple/atc.c"
grep -Fq 'apple,sn201202x' "$source_dir/drivers/usb/typec/tipd/spmi.c"
grep -Fq 'USB_TYPEC_TBT_SID' "$source_dir/drivers/usb/typec/altmodes/thunderbolt.c"
grep -Fq 'PCI_DEVICE_CLASS(PCI_CLASS_SERIAL_USB_USB4' "$source_dir/drivers/thunderbolt/nhi.c"
grep -Fq 'SDHCI_PCI_DEVICE(GLI, 9755, gl9755)' "$source_dir/drivers/mmc/host/sdhci-pci-core.c"
grep -Fq 'const struct sdhci_pci_fixes sdhci_gl9755' "$source_dir/drivers/mmc/host/sdhci-pci-gli.c"

readonly soc_dtsi="$source_dir/arch/arm64/boot/dts/apple/t6030.dtsi"
readonly board_dtsi="$source_dir/arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi"
count_fixed() { awk -v text="$1" 'index($0, text) { n++ } END { print n + 0 }' "$2"; }
readonly dwc3_nodes="$(count_fixed 'compatible = "apple,t6030-dwc3", "apple,t8103-dwc3";' "$soc_dtsi")"
readonly atcphy_nodes="$(count_fixed 'compatible = "apple,t6030-atcphy", "apple,t8122-atcphy";' "$soc_dtsi")"
readonly typec_connectors="$(count_fixed 'compatible = "usb-c-connector";' "$board_dtsi")"
readonly pd_nodes="$(count_fixed 'compatible = "apple,sn201202x";' "$board_dtsi")"
readonly role_switches="$(count_fixed 'usb-role-switch;' "$soc_dtsi")"
readonly power_roles="$(count_fixed 'power-role = "dual";' "$board_dtsi")"
readonly data_roles="$(count_fixed 'data-role = "dual";' "$board_dtsi")"

target_usb_data_topology=false
[[ $dwc3_nodes -eq 3 && $atcphy_nodes -eq 3 && $typec_connectors -eq 3 ]] && target_usb_data_topology=true
target_usb_pd_topology=false
[[ $pd_nodes -ge 3 && $role_switches -eq 3 && $power_roles -eq 3 && $data_roles -eq 3 ]] && target_usb_pd_topology=true
target_sdxc_topology=false
grep -Fq 'compatible = "pci17a0,9755";' "$board_dtsi" && target_sdxc_topology=true
target_dp_output_topology=false
grep -Eq 'remote-endpoint[[:space:]]*=[^;]*(dcp|dptx|display)|compatible[[:space:]]*=[^;]*"dp-connector"' \
    "$soc_dtsi" "$board_dtsi" && target_dp_output_topology=true
target_hdmi_output_topology=false
grep -Eq 'compatible[[:space:]]*=[^;]*"[^"]*hdmi|hdmi:[[:space:]]*[A-Za-z0-9_-]+@' \
    "$soc_dtsi" "$board_dtsi" && target_hdmi_output_topology=true

printf 'M5-source-readiness=checked-static-only\n'
printf 'generic_apple_dwc3_driver_built=true\n'
printf 'generic_apple_atc_phy_driver_built=true\n'
printf 'generic_usb4_stack_built=true\n'
printf 'generic_thunderbolt_altmode_built=true\n'
printf 'generic_uas_driver_built=true\n'
printf 'target_usb_c_ports=%s\n' "$typec_connectors"
printf 'target_usb_pd_controllers=%s\n' "$pd_nodes"
printf 'target_usb_data_topology=%s\n' "$target_usb_data_topology"
printf 'target_usb_pd_topology=%s\n' "$target_usb_pd_topology"
printf 'target_thunderbolt_source_path=true\n'
printf 'target_sdxc_topology=%s\n' "$target_sdxc_topology"
printf 'target_dp_output_topology=%s\n' "$target_dp_output_topology"
printf 'target_hdmi_output_topology=%s\n' "$target_hdmi_output_topology"
printf 'native_runtime_evidence=false\n'
printf 'hardware_acceptance=false\n'
if [[ $target_usb_data_topology == true && $target_usb_pd_topology == true && \
    $target_sdxc_topology == true && $target_dp_output_topology == true && \
    $target_hdmi_output_topology == true ]]; then
    printf 'm5_source_ready=true\n'
    exit 0
fi
printf 'm5_source_ready=false\n'
printf 'gate=blocked-target-display-link-topology\n'
exit 2
