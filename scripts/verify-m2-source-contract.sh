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
readonly source_arg=$2
readonly evidence_arg=$4
[[ $source_arg == /* && -d $source_arg && ! -L $source_arg ]] || die 'source directory must be an absolute physical directory'
[[ $evidence_arg == /* && -d $evidence_arg ]] || die 'M0 evidence must be an absolute directory'
readonly source_dir="$(cd -- "$source_arg" && pwd -P)"
readonly evidence="$(cd -- "$evidence_arg" && pwd -P)"
[[ $source_dir == "$source_arg" ]] || die 'source directory must be canonical'

readonly contract="$project_root/config/milestone2-source-files.sha256"
[[ -f $contract && ! -L $contract ]] || die 'M2 source contract must be a regular file'
[[ $(grep -c '^# format=1$' "$contract") -eq 1 ]] || die 'invalid M2 source contract format'
[[ $(grep -c '^# target=Mac15,6/J514s/T6030$' "$contract") -eq 1 ]] || die 'invalid M2 source contract target'
readonly contract_commit="$(sed -n 's/^# source_tree_commit=//p' "$contract")"
[[ $contract_commit == "$LINUX_SOURCE_TREE_COMMIT" ]] || die 'M2 contract is not bound to the pinned Linux source tree'

expected_files=(
    arch/arm64/boot/dts/apple/t6030-j514s.dts
    arch/arm64/boot/dts/apple/t6030.dtsi
    arch/arm64/boot/dts/apple/t6030-pmgr.dtsi
    arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi
    arch/arm64/boot/dts/apple/spi1-nvram.dtsi
    arch/arm64/boot/dts/apple/hwmon-common.dtsi
    arch/arm64/boot/dts/apple/hwmon-fan-dual.dtsi
    arch/arm64/boot/dts/apple/hwmon-laptop.dtsi
    drivers/irqchip/irq-apple-aic.c
    drivers/iommu/apple-dart.c
    drivers/pmdomain/apple/pmgr-pwrstate.c
    drivers/mfd/macsmc.c
    drivers/gpio/gpio-macsmc.c
    drivers/rtc/rtc-macsmc.c
    drivers/hwmon/macsmc-hwmon.c
    drivers/i2c/busses/i2c-pasemi-platform.c
    drivers/spi/spi-apple.c
    drivers/spmi/spmi-apple-controller.c
    drivers/pinctrl/pinctrl-apple-gpio.c
    drivers/watchdog/apple_wdt.c
    drivers/nvme/host/apple.c
    drivers/pci/controller/pcie-apple.c
    drivers/cpufreq/apple-soc-cpufreq.c
    drivers/cpuidle/cpuidle-apple.c
)
contract_files=()
while read -r digest path extra; do
    [[ -n ${digest:-} ]] || continue
    [[ $digest != \#* ]] || continue
    [[ $digest =~ ^[0-9a-f]{64}$ && -n ${path:-} && -z ${extra:-} ]] || die 'invalid M2 source hash row'
    [[ $path != /* && $path != *..* && $path =~ ^[A-Za-z0-9._/+:-]+$ ]] || die 'unsafe M2 source path'
    contract_files+=("$path")
    [[ -f $source_dir/$path && ! -L $source_dir/$path ]] || die "missing M2 source file: $path"
    [[ $(sha256sum "$source_dir/$path" | awk '{print $1}') == "$digest" ]] || die "M2 source hash mismatch: $path"
done < "$contract"
cmp <(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort) \
    <(printf '%s\n' "${contract_files[@]}" | LC_ALL=C sort) >/dev/null || die 'M2 source contract inventory mismatch'

readonly target_dts="$source_dir/arch/arm64/boot/dts/apple/t6030-j514s.dts"
readonly soc_dtsi="$source_dir/arch/arm64/boot/dts/apple/t6030.dtsi"
readonly board_dtsi="$source_dir/arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi"
grep -Fx '#include "t6030.dtsi"' "$target_dts" >/dev/null
grep -Fx '#include "t603x-j514-j516.dtsi"' "$target_dts" >/dev/null
grep -Fq 'compatible = "apple,j514s", "apple,t6030", "apple,arm-platform";' "$target_dts"
for compatible in \
    apple,t6030-aic3 apple,t6030-dart apple,t6030-pmgr-pwrstate apple,t6030-smc \
    apple,t6030-i2c apple,t6030-spi apple,t6030-spmi apple,t6030-pinctrl \
    apple,t6030-wdt apple,t6030-nvme-ans3 apple,t6030-pcie apple,t6030-cluster-cpufreq \
    apple,smc-hwmon apple,smc-rtc; do
    grep -Fq "$compatible" "$soc_dtsi" "$source_dir/arch/arm64/boot/dts/apple/t6030-pmgr.dtsi"
done
for include in spi1-nvram.dtsi hwmon-common.dtsi hwmon-fan-dual.dtsi hwmon-laptop.dtsi; do
    grep -Fq "#include \"$include\"" "$board_dtsi"
done
for bus in i2c1 i2c2 i2c3 nub_spmi_a0 nub_spmi_a1; do grep -Fq "&$bus {" "$board_dtsi"; done
grep -Fq '&spi1 {' "$source_dir/arch/arm64/boot/dts/apple/spi1-nvram.dtsi"
require_driver_compatible() {
    local compatible=$1 path=$2
    grep -Fq "$compatible" "$source_dir/$path" || die "M2 driver match missing: $compatible"
}
require_driver_compatible apple,t8122-aic3 drivers/irqchip/irq-apple-aic.c
require_driver_compatible apple,t8110-dart drivers/iommu/apple-dart.c
require_driver_compatible apple,t8103-pmgr-pwrstate drivers/pmdomain/apple/pmgr-pwrstate.c
require_driver_compatible apple,t8103-smc drivers/mfd/macsmc.c
require_driver_compatible apple,smc-gpio drivers/gpio/gpio-macsmc.c
require_driver_compatible apple,smc-rtc drivers/rtc/rtc-macsmc.c
require_driver_compatible apple,smc-hwmon drivers/hwmon/macsmc-hwmon.c
require_driver_compatible apple,t8103-i2c drivers/i2c/busses/i2c-pasemi-platform.c
require_driver_compatible apple,t8103-spi drivers/spi/spi-apple.c
require_driver_compatible apple,t8103-spmi drivers/spmi/spmi-apple-controller.c
require_driver_compatible apple,t8103-pinctrl drivers/pinctrl/pinctrl-apple-gpio.c
require_driver_compatible apple,t8103-wdt drivers/watchdog/apple_wdt.c
require_driver_compatible apple,t8103-nvme-ans2 drivers/nvme/host/apple.c
require_driver_compatible apple,t6020-pcie drivers/pci/controller/pcie-apple.c
require_driver_compatible apple,t8112-cluster-cpufreq drivers/cpufreq/apple-soc-cpufreq.c
require_driver_compatible apple,t6030 drivers/cpuidle/cpuidle-apple.c
grep -Fq 'enter_s2idle' "$source_dir/drivers/cpuidle/cpuidle-apple.c" || die 'Apple s2idle source hook missing'

for required in SHA256SUMS manifest.txt config config-input config-merged.sha256 source-status.txt; do
    evidence_abs_regular "$evidence/$required"
done
while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([[:xdigit:]]{64})[[:space:]]{2}\./([^[:space:]]+)$ ]] || die 'invalid M0 checksum row'
    path=${BASH_REMATCH[2]}
    [[ $path != /* && $path != *'/'../* && $path != ../* && $path != *'/'.. ]] || die 'unsafe M0 checksum path'
done < "$evidence/SHA256SUMS"
awk '{ if (++seen[$2] != 1) invalid=1 } END { exit invalid }' "$evidence/SHA256SUMS" || die 'duplicate M0 checksum path'
for required in manifest.txt config config-input config-merged.sha256 source-status.txt; do
    expected_hash=$(awk -v path="./$required" '$2 == path { print $1; found++ } END { if (found != 1) exit 1 }' "$evidence/SHA256SUMS") ||
        die "M0 checksum missing or duplicated: $required"
    [[ $(evidence_sha256 "$evidence/$required") == "$expected_hash" ]] || die "M0 checksum mismatch: $required"
done
grep -Fx 'target=Mac15,6/J514s/T6030' "$evidence/manifest.txt" >/dev/null
grep -Fx 'component=linux-full' "$evidence/manifest.txt" >/dev/null
grep -Fx "source_commit=$LINUX_COMMIT" "$evidence/manifest.txt" >/dev/null
grep -Fx "source_tree_commit=$contract_commit" "$evidence/manifest.txt" >/dev/null
grep -Fx 'source_clean=true' "$evidence/manifest.txt" >/dev/null
grep -Fx "linux_config_fragment_sha256=$LINUX_CONFIG_FRAGMENT_SHA256" "$evidence/manifest.txt" >/dev/null
[[ ! -s $evidence/source-status.txt ]] || die 'M0 source status is not clean'
[[ $(evidence_sha256 "$evidence/config-input") == "$LINUX_CONFIG_FRAGMENT_SHA256" ]] || die 'M0 config input hash mismatch'
[[ $(evidence_sha256 "$evidence/config") == "$(awk '{print $1}' "$evidence/config-merged.sha256")" ]] || die 'M0 merged config hash mismatch'
for setting in \
    CONFIG_APPLE_AIC=y CONFIG_APPLE_DART=m CONFIG_APPLE_PMGR_PWRSTATE=y CONFIG_APPLE_PMGR_MISC=y \
    CONFIG_MFD_MACSMC=m CONFIG_GPIO_MACSMC=m CONFIG_RTC_DRV_MACSMC=m CONFIG_SENSORS_MACSMC_HWMON=m \
    CONFIG_I2C_APPLE=m CONFIG_SPI_APPLE=m CONFIG_SPMI=y CONFIG_SPMI_APPLE=m \
    CONFIG_PINCTRL_APPLE_GPIO=m CONFIG_APPLE_WATCHDOG=m CONFIG_NVME_APPLE=m CONFIG_PCIE_APPLE=m \
    CONFIG_CPU_FREQ=y CONFIG_ARM_APPLE_SOC_CPUFREQ=m CONFIG_CPU_IDLE=y CONFIG_ARM_APPLE_CPUIDLE=y \
    CONFIG_SUSPEND=y CONFIG_PM_SLEEP=y CONFIG_HWMON=y CONFIG_THERMAL=y CONFIG_THERMAL_HWMON=y; do
    grep -Fx "$setting" "$evidence/config" >/dev/null || die "M2 config setting missing: $setting"
done

thermal_fragments=(
    "$target_dts"
    "$soc_dtsi"
    "$source_dir/arch/arm64/boot/dts/apple/t6030-pmgr.dtsi"
    "$board_dtsi"
    "$source_dir/arch/arm64/boot/dts/apple/spi1-nvram.dtsi"
    "$source_dir/arch/arm64/boot/dts/apple/hwmon-common.dtsi"
    "$source_dir/arch/arm64/boot/dts/apple/hwmon-fan-dual.dtsi"
    "$source_dir/arch/arm64/boot/dts/apple/hwmon-laptop.dtsi"
)
! grep -Eq 'thermal-zones|cooling-maps' "${thermal_fragments[@]}" || die 'unexpected target thermal policy map; review contract classification'

printf 'M2-source-contract=verified-static-only\n'
printf 'source_tree_commit=%s\n' "$contract_commit"
printf 'source_files=%s\n' "${#contract_files[@]}"
printf 'thermal_telemetry=smc-hwmon\n'
printf 'thermal_policy_map=absent-in-contracted-target-fragments\n'
printf 'native_runtime_evidence=false\n'
printf 'hardware_acceptance=false\n'
