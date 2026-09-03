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
[[ $evidence_arg == /* && -d $evidence_arg && ! -L $evidence_arg ]] || die 'invalid M0 evidence directory'
readonly source_dir="$(cd -- "$source_arg" && pwd -P)"
readonly evidence="$(cd -- "$evidence_arg" && pwd -P)"
[[ $source_dir == "$source_arg" ]] || die 'source directory must be canonical'
command -v git >/dev/null || die 'git is required'
[[ $(git -C "$source_dir" rev-parse --is-inside-work-tree 2>/dev/null) == true ]] ||
    die 'M7 source directory must be a Git worktree'
readonly source_root="$(git -C "$source_dir" rev-parse --show-toplevel)"
[[ $source_root == "$source_dir" ]] || die 'M7 source directory must be the worktree root'
readonly source_head="$(git -C "$source_dir" rev-parse HEAD)"
[[ $source_head == "$LINUX_SOURCE_TREE_COMMIT" ]] || die 'M7 source HEAD is not the pinned tree'
source_status=$(git -C "$source_dir" status --porcelain=v1 --untracked-files=all --ignored=matching) ||
    die 'cannot inspect M7 source status'
readonly source_status
[[ -z $source_status ]] || die 'M7 source tree is not clean'
sparse_entries=$(git -C "$source_dir" ls-files -t | awk '$1 == "S" { count++ } END { print count + 0 }') ||
    die 'cannot inspect M7 sparse-checkout state'
readonly sparse_entries
[[ $sparse_entries -eq 0 ]] || die 'M7 source worktree is sparse'

"$project_root/scripts/verify-m2-source-contract.sh" \
    --source-dir "$source_dir" --m0-evidence "$evidence" >/dev/null

readonly contract="$project_root/config/milestone7-source-files.sha256"
[[ -f $contract && ! -L $contract ]] || die 'invalid M7 source contract'
[[ $(grep -c '^# format=1$' "$contract") -eq 1 ]] || die 'invalid M7 source contract format'
[[ $(grep -c '^# target=Mac15,6/J514s/T6030$' "$contract") -eq 1 ]] || die 'invalid M7 source contract target'
[[ $(sed -n 's/^# source_tree_commit=//p' "$contract") == "$LINUX_SOURCE_TREE_COMMIT" ]] ||
    die 'M7 source contract is not bound to the pinned tree'

expected_files=(
    arch/arm64/boot/dts/apple/t6030-j514s.dts
    arch/arm64/boot/dts/apple/t6030-pmgr.dtsi
    arch/arm64/boot/dts/apple/t6030.dtsi
    arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi
    drivers/iommu/apple-dart.c
    drivers/perf/Kconfig
    drivers/perf/apple_m1_cpu_pmu.c
    drivers/soc/apple/Kconfig
    drivers/soc/apple/Makefile
    drivers/soc/apple/sep.rs
)
contract_files=()
while read -r digest source_path extra; do
    [[ -n ${digest:-} && $digest != \#* ]] || continue
    [[ $digest =~ ^[0-9a-f]{64}$ && -n ${source_path:-} && -z ${extra:-} ]] || die 'invalid M7 source hash row'
    [[ $source_path != /* && $source_path != *..* && $source_path =~ ^[A-Za-z0-9._/+:-]+$ ]] || die 'unsafe M7 source path'
    contract_files+=("$source_path")
    [[ -f $source_dir/$source_path && ! -L $source_dir/$source_path ]] || die "missing M7 source file: $source_path"
    [[ $(sha256sum "$source_dir/$source_path" | awk '{print $1}') == "$digest" ]] || die "M7 source hash mismatch: $source_path"
done < "$contract"
cmp <(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort) \
    <(printf '%s\n' "${contract_files[@]}" | LC_ALL=C sort) >/dev/null ||
    die 'M7 source contract inventory mismatch'

for setting in \
    CONFIG_HW_PERF_EVENTS=y CONFIG_VIRTUALIZATION=y CONFIG_KVM=y \
    CONFIG_APPLE_DART=m CONFIG_APPLE_SEP=m CONFIG_ARM_PMU=y \
    CONFIG_APPLE_M1_CPU_PMU=y CONFIG_KEYS=y CONFIG_SECURITY=y CONFIG_INTEGRITY=y \
    '# CONFIG_TRUSTED_KEYS is not set' '# CONFIG_ENCRYPTED_KEYS is not set' \
    '# CONFIG_SECURITY_LOCKDOWN_LSM is not set' '# CONFIG_INTEGRITY_SIGNATURE is not set'; do
    grep -Fx "$setting" "$evidence/config" >/dev/null || die "M7 config setting missing: $setting"
done

evidence_abs_regular "$evidence/modules.inventory"
modules_hash=$(awk '$2 == "./modules.inventory" { print $1; found++ } END { if (found != 1) exit 1 }' \
    "$evidence/SHA256SUMS") || die 'M0 checksum missing or duplicated: modules.inventory'
readonly modules_hash
[[ $(evidence_sha256 "$evidence/modules.inventory") == "$modules_hash" ]] || die 'M0 modules inventory hash mismatch'
require_module() {
    local relative=$1 suffix="/kernel/$1" inventory_path module_path checksum_path module_hash
    inventory_path=$(awk -v suffix="$suffix" '
        substr($0, length($0) - length(suffix) + 1) == suffix { entry=$0; count++ }
        END { if (count != 1) exit 1; print entry }
    ' "$evidence/modules.inventory") || die "M7 module missing or duplicated: $relative"
    module_path="$evidence/modules/$inventory_path"
    evidence_path_under "$module_path" "$evidence/modules"
    evidence_abs_regular "$module_path"
    checksum_path="./modules/$inventory_path"
    module_hash=$(awk -v wanted="$checksum_path" '$2 == wanted { print $1; found++ } END { if (found != 1) exit 1 }' \
        "$evidence/SHA256SUMS") || die "M0 checksum missing or duplicated: $checksum_path"
    [[ $(evidence_sha256 "$module_path") == "$module_hash" ]] || die "M0 module checksum mismatch: $relative"
}
require_module drivers/iommu/apple-dart.ko
require_module drivers/soc/apple/sep.ko

readonly soc_dtsi="$source_dir/arch/arm64/boot/dts/apple/t6030.dtsi"
readonly pmgr_dtsi="$source_dir/arch/arm64/boot/dts/apple/t6030-pmgr.dtsi"
readonly target_dts="$source_dir/arch/arm64/boot/dts/apple/t6030-j514s.dts"
readonly board_dtsi="$source_dir/arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi"
readonly sep_driver="$source_dir/drivers/soc/apple/sep.rs"
readonly pmu_driver="$source_dir/drivers/perf/apple_m1_cpu_pmu.c"
readonly dart_driver="$source_dir/drivers/iommu/apple-dart.c"
target_fragments=("$target_dts" "$soc_dtsi" "$pmgr_dtsi" "$board_dtsi")

generic_sep_stub_driver_built=false
if grep -Fq 'description: "Secure enclave processor stub driver"' "$sep_driver" &&
    grep -Fq 'of::DeviceId::new(c"apple,sep")' "$sep_driver"; then
    generic_sep_stub_driver_built=true
fi
target_sep_topology=false
grep -Eq 'compatible[[:space:]]*=[^;]*"apple,sep"' "${target_fragments[@]}" && target_sep_topology=true
sep_service_api=false
target_touchid_biometric_service=false
grep -Eiq 'compatible[[:space:]]*=[^;]*"apple,[^"]*(touchid|biometric|fingerprint)' "${target_fragments[@]}" &&
    target_touchid_biometric_service=true
sep_backed_key_storage=false

target_ane_topology=false
grep -Eiq 'compatible[[:space:]]*=[^;]*"apple,[^"]*(ane|npu)' "${target_fragments[@]}" &&
    target_ane_topology=true
target_ane_driver=false
if grep -REiq 'apple,(ane|npu)|Apple Neural Engine' "$source_dir/drivers/accel" "$source_dir/drivers/soc/apple"; then
    target_ane_driver=true
fi

target_pmu_compatible=false
if grep -Eq 'apple,(sawtooth|everest)-pmu' "$pmu_driver" &&
    grep -Eq 'compatible[[:space:]]*=[^;]*"apple,(sawtooth|everest)-pmu"' "$soc_dtsi"; then
    target_pmu_compatible=true
fi
generic_kvm_configured=true
target_virtual_timer_topology=false
grep -Fq 'interrupt-names = "phys", "virt", "hyp-phys", "hyp-virt";' "$soc_dtsi" &&
    target_virtual_timer_topology=true
target_dart_fallback_topology=false
if grep -Fq 'compatible = "apple,t6030-dart", "apple,t8110-dart";' "$soc_dtsi" &&
    grep -Fq '.compatible = "apple,t8110-dart"' "$dart_driver"; then
    target_dart_fallback_topology=true
fi
kernel_lockdown_lsm=false
integrity_signatures=false

printf 'M7-source-readiness=checked-static-only\n'
printf 'generic_sep_stub_driver_built=%s\n' "$generic_sep_stub_driver_built"
printf 'target_sep_topology=%s\n' "$target_sep_topology"
printf 'sep_service_api=%s\n' "$sep_service_api"
printf 'target_touchid_biometric_service=%s\n' "$target_touchid_biometric_service"
printf 'sep_backed_key_storage=%s\n' "$sep_backed_key_storage"
printf 'target_ane_topology=%s\n' "$target_ane_topology"
printf 'target_ane_driver=%s\n' "$target_ane_driver"
printf 'target_pmu_compatible=%s\n' "$target_pmu_compatible"
printf 'generic_kvm_configured=%s\n' "$generic_kvm_configured"
printf 'target_virtual_timer_topology=%s\n' "$target_virtual_timer_topology"
printf 'target_dart_fallback_topology=%s\n' "$target_dart_fallback_topology"
printf 'kernel_lockdown_lsm=%s\n' "$kernel_lockdown_lsm"
printf 'integrity_signatures=%s\n' "$integrity_signatures"
printf 'native_kvm_evidence=false\n'
printf 'native_runtime_evidence=false\n'
printf 'hardware_acceptance=false\n'
if [[ $target_sep_topology == true && $sep_service_api == true && \
    $target_touchid_biometric_service == true && $sep_backed_key_storage == true && \
    $target_ane_topology == true && $target_ane_driver == true && \
    $target_pmu_compatible == true && $kernel_lockdown_lsm == true && \
    $integrity_signatures == true ]]; then
    printf 'm7_source_ready=true\n'
    exit 0
fi
printf 'm7_source_ready=false\n'
printf 'gate=blocked-target-sep-touchid-ane-pmu-and-lockdown\n'
exit 2
