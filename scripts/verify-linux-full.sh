#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
m0_validate_output_root "$project_root"
readonly evidence="${1:-${MILESTONE0_OUTPUT_ROOT}/milestone0/linux-full/latest}"
test -d "$evidence"
for required in SHA256SUMS Image System.map vmlinux config config-input config-fragment config-assertions.txt defconfig.config defconfig.diff config-merged.sha256 asahi.config checks.txt dt-binding-check.log dtbs-check.log target-dtbs-check.raw.log target-dtbs-check.log build-warning-inventory.txt dt-binding-warning-inventory.txt dtbs-warning-inventory.txt target-warning-inventory.txt schema-exceptions.txt dtbs-list.inventory dtbs.inventory dtbs-install.inventory modules.inventory headers.inventory headers.tar symlinks.inventory symlink-targets.txt dtbs dtbs-install modules file.txt kernelrelease listnewconfig.log manifest.txt packages.txt rustavailable.log source-status.txt; do
    test -e "$evidence/$required" || { printf 'Missing evidence file: %s\n' "$evidence/$required" >&2; exit 1; }
done
test ! -e "$evidence/headers"
test -f "$evidence/headers.tar" && test ! -L "$evidence/headers.tar"
(
    cd "$evidence"
    sha256sum -c SHA256SUMS
)
grep -Fx "target=Mac15,6/J514s/T6030" "$evidence/manifest.txt" >/dev/null
grep -Fx "component=linux-full" "$evidence/manifest.txt" >/dev/null
grep -Fx "source_url=${LINUX_URL}" "$evidence/manifest.txt" >/dev/null
grep -Fx "source_commit=${LINUX_COMMIT}" "$evidence/manifest.txt" >/dev/null
grep -Fx "source_tree_commit=${LINUX_SOURCE_TREE_COMMIT}" "$evidence/manifest.txt" >/dev/null
grep -Fx "linux_patch_series=${LINUX_PATCH_SERIES}" "$evidence/manifest.txt" >/dev/null
grep -Fx "linux_patch_series_sha256=${LINUX_PATCH_SERIES_SHA256}" "$evidence/manifest.txt" >/dev/null
test "$(sha256sum "${project_root}/patches/linux/${LINUX_PATCH_SERIES}" | awk '{print $1}')" = "$LINUX_PATCH_SERIES_SHA256"
grep -Fx "source_ref=${LINUX_REF}" "$evidence/manifest.txt" >/dev/null
grep -Fx "upstream_url=${LINUX_UPSTREAM_URL}" "$evidence/manifest.txt" >/dev/null
grep -Fx "upstream_ref=${LINUX_UPSTREAM_REF}" "$evidence/manifest.txt" >/dev/null
grep -Fx "upstream_commit=${LINUX_UPSTREAM_COMMIT}" "$evidence/manifest.txt" >/dev/null
grep -Fx 'source_clean=true' "$evidence/manifest.txt" >/dev/null
grep -Fx 'build_environment=archlinuxarm-native' "$evidence/manifest.txt" >/dev/null
grep -Fx "container_image=${ARCH_BUILD_IMAGE}" "$evidence/manifest.txt" >/dev/null
test "$(grep -c '^container_image_id=' "$evidence/manifest.txt")" -eq 1
readonly container_image_id="$(sed -n 's/^container_image_id=//p' "$evidence/manifest.txt")"
[[ $container_image_id =~ ^sha256:[0-9a-f]{64}$ ]]
grep -Eq '^compiler=gcc \(GCC\) ' "$evidence/manifest.txt"
grep -Eq '^linker=GNU ld ' "$evidence/manifest.txt"
grep -Fx "linux_config_fragment_sha256=${LINUX_CONFIG_FRAGMENT_SHA256}" "$evidence/manifest.txt" >/dev/null
grep -Fx "config_fragment=${LINUX_CONFIG_FRAGMENT}" "$evidence/manifest.txt" >/dev/null
grep -Fx "localversion=${LINUX_LOCALVERSION}" "$evidence/manifest.txt" >/dev/null
grep -Fx 'warning_policy=W=1-diagnostic' "$evidence/manifest.txt" >/dev/null
grep -Fx 'dt_schema_files=unfiltered' "$evidence/manifest.txt" >/dev/null
grep -Fx 'dt_schema_files=unfiltered' "$evidence/checks.txt" >/dev/null
grep -Fx 'dt_binding_check=passed' "$evidence/checks.txt" >/dev/null
grep -Fx 'dtbs_check=passed' "$evidence/checks.txt" >/dev/null
grep -Fx 'target_dtbs_check=passed' "$evidence/checks.txt" >/dev/null
grep -Fx 'dt_binding_check_serialized=true' "$evidence/checks.txt" >/dev/null
grep -Fx 'dtbs_check_parallel=true' "$evidence/checks.txt" >/dev/null
grep -Fx 'target_dtbs_check_serialized=true' "$evidence/checks.txt" >/dev/null
grep -Fx 'dtbs_list_policy=normalized-kernel-dtbs-list' "$evidence/checks.txt" >/dev/null
grep -Fx 'dtbs_inventory_policy=raw-build-superset' "$evidence/checks.txt" >/dev/null
grep -Fx 'dtbs_install_policy=native-make-dtbs_install' "$evidence/checks.txt" >/dev/null
grep -Fx 'dtbs_install_inventory_policy=installed-equals-dtbs-list' "$evidence/checks.txt" >/dev/null
grep -Fx 'dtbs_install_byte_equality=true' "$evidence/checks.txt" >/dev/null
grep -Fx 'dtbs_install_subset_policy=kernel-install-subset' "$evidence/checks.txt" >/dev/null
grep -Fx 'headers_evidence_policy=deterministic-headers-tar' "$evidence/checks.txt" >/dev/null
grep -Fx 'headers_archive_policy=gnu-tar-sort-name-source-epoch-numeric-root' "$evidence/checks.txt" >/dev/null
grep -Fx 'headers_archive_root=usr/include' "$evidence/checks.txt" >/dev/null
grep -Fx 'headers_inventory_policy=sorted-regular-members' "$evidence/checks.txt" >/dev/null
grep -Fx 'headers_source_filesystem=ext4-docker-volume' "$evidence/checks.txt" >/dev/null
grep -Fx 'headers_install_fresh_root=true' "$evidence/checks.txt" >/dev/null
grep -Fx 'headers_archive_byte_stable=true' "$evidence/checks.txt" >/dev/null
grep -Fx 'artifact_symlink_policy=none-portable-handoff' "$evidence/checks.txt" >/dev/null
grep -Fx 'target_diagnostics_policy=pinned-known-baseline' "$evidence/checks.txt" >/dev/null
grep -Fx "target_diagnostics_sha256=${LINUX_TARGET_DT_DIAGNOSTICS_SHA256}" "$evidence/checks.txt" >/dev/null
grep -Fx "target_diagnostics_lines=${LINUX_TARGET_DT_DIAGNOSTICS_LINES}" "$evidence/checks.txt" >/dev/null
grep -Fx "target_diagnostic_fingerprints=${LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS}" "$evidence/checks.txt" >/dev/null
grep -Fx 'target_diagnostics_policy=pinned-known-baseline' "$evidence/manifest.txt" >/dev/null
grep -Fx 'dtbs_list_policy=normalized-kernel-dtbs-list' "$evidence/manifest.txt" >/dev/null
grep -Fx 'dtbs_inventory_policy=raw-build-superset' "$evidence/manifest.txt" >/dev/null
grep -Fx 'dtbs_install_policy=native-make-dtbs_install' "$evidence/manifest.txt" >/dev/null
grep -Fx 'dtbs_install_inventory_policy=installed-equals-dtbs-list' "$evidence/manifest.txt" >/dev/null
grep -Fx 'dtbs_install_byte_equality=true' "$evidence/manifest.txt" >/dev/null
grep -Fx 'dtbs_install_subset_policy=kernel-install-subset' "$evidence/manifest.txt" >/dev/null
grep -Fx 'headers_evidence_policy=deterministic-headers-tar' "$evidence/manifest.txt" >/dev/null
grep -Fx 'headers_archive_policy=gnu-tar-sort-name-source-epoch-numeric-root' "$evidence/manifest.txt" >/dev/null
grep -Fx 'headers_archive_root=usr/include' "$evidence/manifest.txt" >/dev/null
grep -Fx 'headers_inventory_policy=sorted-regular-members' "$evidence/manifest.txt" >/dev/null
grep -Fx 'headers_source_filesystem=ext4-docker-volume' "$evidence/manifest.txt" >/dev/null
grep -Fx 'headers_install_fresh_root=true' "$evidence/manifest.txt" >/dev/null
grep -Fx 'headers_archive_byte_stable=true' "$evidence/manifest.txt" >/dev/null
grep -Fx 'artifact_symlink_policy=none-portable-handoff' "$evidence/manifest.txt" >/dev/null
grep -Fx "target_diagnostics_sha256=${LINUX_TARGET_DT_DIAGNOSTICS_SHA256}" "$evidence/manifest.txt" >/dev/null
grep -Fx "target_diagnostics_lines=${LINUX_TARGET_DT_DIAGNOSTICS_LINES}" "$evidence/manifest.txt" >/dev/null
grep -Fx "target_diagnostic_fingerprints=${LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS}" "$evidence/manifest.txt" >/dev/null
grep -Fx 'dtschema_version=2025.12' "$evidence/checks.txt" >/dev/null
grep -Fx 'dtschema_version=2025.12' "$evidence/manifest.txt" >/dev/null
grep -Fx 'policy=all unfiltered diagnostics are recorded; the normalized J514s/T6030 block must exactly match the pinned known baseline' "$evidence/schema-exceptions.txt" >/dev/null
grep -Fx "known_target_diagnostics_sha256=${LINUX_TARGET_DT_DIAGNOSTICS_SHA256}" "$evidence/schema-exceptions.txt" >/dev/null
grep -Fx "known_target_diagnostics_lines=${LINUX_TARGET_DT_DIAGNOSTICS_LINES}" "$evidence/schema-exceptions.txt" >/dev/null
grep -Fx "known_target_diagnostic_fingerprints=${LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS}" "$evidence/schema-exceptions.txt" >/dev/null
grep -Fx 'classification=known target diagnostics are unresolved upstream/downstream debt and are not hardware-support evidence' "$evidence/schema-exceptions.txt" >/dev/null
grep -Fx 'source_clean=true' "$evidence/manifest.txt" >/dev/null
test ! -s "$evidence/source-status.txt"
test "$(sha256sum "$evidence/config-input" | awk '{print $1}')" = "$LINUX_CONFIG_FRAGMENT_SHA256"
test "$(sha256sum "$evidence/config" | awk '{print $1}')" = "$(awk '{print $1}' "$evidence/config-merged.sha256")"
for setting in \
    CONFIG_ARM64=y CONFIG_ARCH_APPLE=y CONFIG_ARM64_16K_PAGES=y \
    '# CONFIG_ARM64_4K_PAGES is not set' CONFIG_MODULES=y CONFIG_SUSPEND=y CONFIG_PM=y \
    CONFIG_OF=y CONFIG_RUST=y CONFIG_DRM=y CONFIG_BLK_DEV_NVME=m CONFIG_NVME_APPLE=m \
    CONFIG_DRM_ASAHI=m CONFIG_DRM_APPLE=m CONFIG_PCIE_APPLE=m CONFIG_IOMMU_SUPPORT=y \
    CONFIG_IOMMU_IO_PGTABLE_LPAE=y CONFIG_APPLE_DART=m CONFIG_APPLE_AIC=y CONFIG_APPLE_MAILBOX=y \
    CONFIG_APPLE_PMGR_PWRSTATE=y CONFIG_APPLE_PMGR_MISC=y CONFIG_APPLE_RTKIT=y \
    CONFIG_MFD_MACSMC=m CONFIG_GPIO_MACSMC=m CONFIG_RTC_DRV_MACSMC=m \
    CONFIG_SENSORS_MACSMC_HWMON=m CONFIG_I2C_APPLE=m CONFIG_SPI_APPLE=m \
    CONFIG_SPMI=y CONFIG_SPMI_APPLE=m CONFIG_PINCTRL_APPLE_GPIO=m CONFIG_APPLE_WATCHDOG=m \
    CONFIG_APPLE_RTKIT_HELPER=m CONFIG_USB_DWC3_APPLE=m CONFIG_SND_SOC_APPLE_MACAUDIO=m \
    CONFIG_CPU_IDLE=y CONFIG_ARM_APPLE_CPUIDLE=y CONFIG_CPU_FREQ=y CONFIG_ARM_APPLE_SOC_CPUFREQ=m \
    CONFIG_PM_SLEEP=y CONFIG_HWMON=y CONFIG_THERMAL=y CONFIG_THERMAL_HWMON=y \
    'CONFIG_LOCALVERSION=".asahi1"' '# CONFIG_LOCALVERSION_AUTO is not set'; do
    grep -Fx "$setting" "$evidence/config" >/dev/null
done
! grep -q '^CONFIG_' "$evidence/listnewconfig.log"
grep -Fx 'CONFIG_ARM64=y' "$evidence/config-assertions.txt" >/dev/null
grep -Fx 'CONFIG_ARCH_APPLE=y' "$evidence/config-assertions.txt" >/dev/null
grep -Fx 'CONFIG_DRM_ASAHI=m' "$evidence/config-assertions.txt" >/dev/null
extract_target_log() {
    awk -v target="arch/arm64/boot/dts/$LINUX_DTB" '
        /^  (DTC|OVL) \[C\] arch\/arm64\/boot\/dts\// {
            if (capture) {
                terminated = 1
                exit
            }
            capture = index($0, target) > 0
            if (capture) seen = 1
        }
        capture && /^make(\[[0-9]+\])?: Leaving directory/ {
            terminated = 1
            exit
        }
        capture { print }
        END { if (!seen || !terminated) exit 1 }
    ' "$evidence/target-dtbs-check.raw.log" \
        | sed -E 's#/workspace/src/linux/##g; s#/workspace/build/linux-full/##g'
}
cmp <(extract_target_log) "$evidence/target-dtbs-check.log"
test "$(wc -l < "$evidence/target-dtbs-check.log" | tr -d ' ')" -eq "$LINUX_TARGET_DT_DIAGNOSTICS_LINES"
test "$(sha256sum "$evidence/target-dtbs-check.log" | awk '{print $1}')" = "$LINUX_TARGET_DT_DIAGNOSTICS_SHA256"
test "$(wc -l < "$evidence/target-warning-inventory.txt" | tr -d ' ')" -eq "$LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS"
awk -v target="arch/arm64/boot/dts/$LINUX_DTB:" '
    /Warning \(/ || index($0, target) == 1 { print }
' "$evidence/target-dtbs-check.log" | LC_ALL=C sort -u | cmp - "$evidence/target-warning-inventory.txt"
validate_dtb_inventory() {
    local inventory="$1" path
    test -s "$inventory"
    if grep -Evq '^[^/[:space:]]+(/[^/[:space:]]+)*\.(dtb|dtbo)$' "$inventory"; then return 1; fi
    if grep -Eq '(^|/)\.\.?(/|$)' "$inventory"; then return 1; fi
    LC_ALL=C sort -u "$inventory" | cmp - "$inventory"
    while IFS= read -r path; do test -n "$path"; done < "$inventory"
}
validate_dtb_inventory "$evidence/dtbs-list.inventory"
validate_dtb_inventory "$evidence/dtbs.inventory"
validate_dtb_inventory "$evidence/dtbs-install.inventory"
cmp "$evidence/dtbs-list.inventory" "$evidence/dtbs-install.inventory"
test "$(wc -l < "$evidence/dtbs.inventory" | tr -d ' ')" -ge "$(wc -l < "$evidence/dtbs-list.inventory" | tr -d ' ')"
while IFS= read -r dt_path; do
    grep -Fx "$dt_path" "$evidence/dtbs.inventory" >/dev/null
done < "$evidence/dtbs-list.inventory"
grep -Fx 'apple/t6030-j514s.dtb' "$evidence/dtbs-list.inventory" >/dev/null
grep -Fx 'apple/t6030-j514s.dtb' "$evidence/dtbs-install.inventory" >/dev/null
test "$(find "$evidence/dtbs" -type f \( -name '*.dtb' -o -name '*.dtbo' \) | wc -l | tr -d ' ')" -gt 1
test -s "$evidence/dtbs/apple/t6030-j514s.dtb"
test -z "$(find -P "$evidence/dtbs" -type f ! \( -name '*.dtb' -o -name '*.dtbo' \) -print -quit)"
test -z "$(find -P "$evidence/dtbs-install" -type f ! \( -name '*.dtb' -o -name '*.dtbo' \) -print -quit)"
test -z "$(find -P "$evidence/dtbs" ! -type f ! -type d -print -quit)"
test -z "$(find -P "$evidence/dtbs-install" ! -type f ! -type d -print -quit)"
kernelrelease="$(<"$evidence/kernelrelease")"
[[ "$kernelrelease" =~ ^[A-Za-z0-9._+-]+$ ]]
grep -Fx "lib/modules/${kernelrelease}/modules.dep" "$evidence/modules.inventory" >/dev/null
(cd "$evidence"; find dtbs -type f \( -name '*.dtb' -o -name '*.dtbo' \) -print | sed 's#^dtbs/##' | LC_ALL=C sort) | cmp - "$evidence/dtbs.inventory"
(cd "$evidence"; find dtbs-install -type f \( -name '*.dtb' -o -name '*.dtbo' \) -print | sed 's#^dtbs-install/##' | LC_ALL=C sort) | cmp - "$evidence/dtbs-install.inventory"
while IFS= read -r dt_path; do
    test -f "$evidence/dtbs/$dt_path"
    cmp "$evidence/dtbs/$dt_path" "$evidence/dtbs-install/$dt_path"
done < "$evidence/dtbs-list.inventory"
(cd "$evidence"; find modules -type f -print | sed 's#^modules/##' | LC_ALL=C sort) | cmp - "$evidence/modules.inventory"
(cd "$evidence"; test ! -e headers)
(cd "$evidence"; test -z "$(find -P . -type l -print -quit)")
(cd "$evidence"; test -z "$(find -P . -mindepth 1 -type d -empty -print -quit)")
test ! -s "$evidence/symlinks.inventory"
test ! -s "$evidence/symlink-targets.txt"
(cd "$evidence"; find . -type l -print | sed 's#^./##' | LC_ALL=C sort) | cmp - "$evidence/symlinks.inventory"
(cd "$evidence"; while IFS= read -r link; do printf '%s -> %s\n' "$link" "$(readlink "$link")"; done < symlinks.inventory) | cmp - "$evidence/symlink-targets.txt"
test "$(wc -c < "$evidence/Image" | tr -d ' ')" -gt 1000000
test "$(wc -c < "$evidence/vmlinux" | tr -d ' ')" -gt 1000000
grep -Eq 'Image:.*(ARM|aarch64|64-bit)' "$evidence/file.txt"
grep -Eq 't6030-j514s\.dtb: Device Tree Blob version 17' "$evidence/file.txt"
command -v docker >/dev/null
docker info >/dev/null
docker image inspect "$container_image_id" >/dev/null
readonly evidence_abs="$(cd "$evidence" && pwd -P)"
docker run --rm --mount "type=bind,src=${evidence_abs},dst=/evidence,readonly" \
    "$container_image_id" bash -Eeuo pipefail -c '
        readonly archive=/evidence/headers.tar
        readonly inventory=/evidence/headers.inventory
        readonly extract_root="$(mktemp -d /tmp/m0-headers.XXXXXX)"
        trap "rm -rf \"$extract_root\"" EXIT
        test -s "$archive" && test -s "$inventory"
        mapfile -t members < <(tar -tf "$archive" | sed "s#^\\./##")
        ((${#members[@]} > 0))
        printf "%s\\n" "${members[@]}" | LC_ALL=C sort -u | cmp - <(printf "%s\\n" "${members[@]}" | LC_ALL=C sort)
        while IFS= read -r member; do
            [[ "$member" != /* ]]
            ! grep -Eq "(^|/)\.\.?(/|$)" <<< "$member"
            case "$member" in
                usr|usr/|usr/include|usr/include/|usr/include/*) ;;
                *) printf "Unsafe headers archive member: %s\\n" "$member" >&2; exit 1 ;;
            esac
            [[ "$member" != *[[:space:]]* ]]
        done < <(printf "%s\\n" "${members[@]}")
        while IFS= read -r verbose; do
            case "${verbose:0:1}" in
                -|d) ;;
                *) printf "Non-file/non-directory headers member: %s\\n" "$verbose" >&2; exit 1 ;;
            esac
        done < <(tar -tvf "$archive")
        grep -Fx "usr/include/linux/kernel.h" "$inventory" >/dev/null
        ! grep -Evq "^usr/include/[^/[:space:]]+(/[^/[:space:]]+)*$" "$inventory"
        ! grep -Eq "(^|/)\\.\\.?(/|$)" "$inventory"
        LC_ALL=C sort -u "$inventory" | cmp - "$inventory"
        tar -xf "$archive" -C "$extract_root"
        test -d "$extract_root/usr/include"
        test -s "$extract_root/usr/include/linux/kernel.h"
        test -z "$(find -P "$extract_root" ! -type f ! -type d -print -quit)"
        (cd "$extract_root"; find usr/include -type f -printf "%P\\n" | sed "s#^#usr/include/#" | LC_ALL=C sort) | cmp - "$inventory"
    '
printf 'linux-full.baseline=verified\n'
