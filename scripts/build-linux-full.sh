#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
readonly source_volume="${SOURCE_VOLUME_OVERRIDE:-${SOURCE_VOLUME}}"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
source "${project_root}/scripts/lib/atomic-symlink.sh"
m0_validate_output_root "$project_root"
readonly output_root="$MILESTONE0_OUTPUT_ROOT"
readonly stage_policy_lib="${project_root}/scripts/lib/milestone0-linux-full-stage.sh"
readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly full_output="${output_root}/milestone0/linux-full"
readonly stage="${full_output}/.${run_id}.tmp"
readonly destination="${full_output}/${run_id}"
readonly latest="${full_output}/latest"
readonly latest_tmp="${full_output}/.latest.${run_id}.tmp"

for value in RUST_VERSION RUSTUP_VERSION RUSTUP_INIT_SHA256 ARCH_BUILD_IMAGE SOURCE_VOLUME LINUX_URL LINUX_REF LINUX_COMMIT LINUX_SOURCE_TREE_COMMIT LINUX_TARGET_DT_DIAGNOSTICS_SHA256 LINUX_TARGET_DT_DIAGNOSTICS_LINES LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS LINUX_DEFCONFIG LINUX_DTB LINUX_UPSTREAM_URL LINUX_UPSTREAM_REF LINUX_UPSTREAM_COMMIT LINUX_CONFIG_FRAGMENT LINUX_CONFIG_FRAGMENT_SHA256 LINUX_PATCH_SERIES LINUX_PATCH_SERIES_SHA256 LINUX_LOCALVERSION LINUX_PKGBASE LINUX_PKGREL; do
    test -n "${!value:-}" || { printf 'Missing configuration value: %s\n' "$value" >&2; exit 1; }
done
[[ "$LINUX_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$LINUX_SOURCE_TREE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$LINUX_UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]]
command -v docker >/dev/null
docker info >/dev/null
test "$(sha256sum "${project_root}/patches/linux/${LINUX_PATCH_SERIES}" | awk '{print $1}')" = "$LINUX_PATCH_SERIES_SHA256"

readonly cache_dir="${output_root}/cache"
readonly mirror="${cache_dir}/linux.git"
mkdir -p "$cache_dir" "$output_root"
if [[ ! -d "$mirror" ]]; then
    git clone --bare --depth=1 --branch "$LINUX_REF" "$LINUX_URL" "$mirror"
else
    test "$(git -C "$mirror" remote get-url origin)" = "$LINUX_URL"
    if [[ "$(git -C "$mirror" rev-parse "refs/heads/${LINUX_REF}" 2>/dev/null || true)" != "$LINUX_COMMIT" ]]; then
        git -C "$mirror" fetch --depth=1 origin "+refs/heads/${LINUX_REF}:refs/heads/${LINUX_REF}"
    fi
fi
if git -C "$mirror" remote get-url upstream >/dev/null 2>&1; then
    test "$(git -C "$mirror" remote get-url upstream)" = "$LINUX_UPSTREAM_URL"
else
    git -C "$mirror" remote add upstream "$LINUX_UPSTREAM_URL"
fi
if [[ "$(git -C "$mirror" rev-parse "refs/remotes/upstream/${LINUX_UPSTREAM_REF}" 2>/dev/null || true)" != "$LINUX_UPSTREAM_COMMIT" ]]; then
    git -C "$mirror" fetch --depth=1 upstream "+refs/heads/${LINUX_UPSTREAM_REF}:refs/remotes/upstream/${LINUX_UPSTREAM_REF}"
fi
test "$(git -C "$mirror" rev-parse "refs/heads/${LINUX_REF}")" = "$LINUX_COMMIT"
test "$(git -C "$mirror" rev-parse "refs/remotes/upstream/${LINUX_UPSTREAM_REF}")" = "$LINUX_UPSTREAM_COMMIT"
ancestry_depth=1
while ! git -C "$mirror" merge-base --is-ancestor "$LINUX_UPSTREAM_COMMIT" "$LINUX_COMMIT"; do
    test "$(git -C "$mirror" rev-parse --is-shallow-repository)" = true
    test "$ancestry_depth" -lt 8192
    ancestry_depth=$((ancestry_depth * 2))
    git -C "$mirror" fetch --depth="$ancestry_depth" origin \
        "+refs/heads/${LINUX_REF}:refs/heads/${LINUX_REF}"
done

mkdir -p "$full_output"
if [[ -e "$stage" || -L "$stage" || -e "$destination" || -L "$destination" || -e "$latest_tmp" || -L "$latest_tmp" ]] ||
    [[ -e "$latest" && ! -L "$latest" ]]; then
    printf 'Refusing colliding linux-full publication path for run %s\n' "$run_id" >&2
    exit 1
fi
mkdir "$stage"

docker build --provenance=false \
    --build-arg "BC_VERSION=1.08.2-1" \
    --build-arg "RSYNC_VERSION=3.5.0-1" \
    --build-arg "PAHOLE_VERSION=1:1.31-2" \
    --build-arg "RUST_VERSION=${RUST_VERSION}" \
    --build-arg "RUSTUP_VERSION=${RUSTUP_VERSION}" \
    --build-arg "RUSTUP_INIT_SHA256=${RUSTUP_INIT_SHA256}" \
    --file "${project_root}/build/Containerfile.arch" --tag "$ARCH_BUILD_IMAGE" "${project_root}/build"
test "$(docker volume inspect --format '{{ index .Labels "com.moriz.project" }}' "$source_volume")" = asahi-m3pro-fullstack
readonly image_id="$(docker image inspect --format '{{.Id}}' "$ARCH_BUILD_IMAGE")"

docker run --rm \
    --env "BUILD_IMAGE=${ARCH_BUILD_IMAGE}" --env "BUILD_IMAGE_ID=${image_id}" \
    --env "LINUX_COMMIT=${LINUX_COMMIT}" --env "LINUX_PKGREL=${LINUX_PKGREL}" \
    --env "LINUX_SOURCE_TREE_COMMIT=${LINUX_SOURCE_TREE_COMMIT}" \
    --env "LINUX_TARGET_DT_DIAGNOSTICS_SHA256=${LINUX_TARGET_DT_DIAGNOSTICS_SHA256}" \
    --env "LINUX_TARGET_DT_DIAGNOSTICS_LINES=${LINUX_TARGET_DT_DIAGNOSTICS_LINES}" \
    --env "LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS=${LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS}" \
    --env "LINUX_CONFIG_FRAGMENT=${LINUX_CONFIG_FRAGMENT}" --env "LINUX_CONFIG_FRAGMENT_SHA256=${LINUX_CONFIG_FRAGMENT_SHA256}" \
    --env "LINUX_PATCH_SERIES=${LINUX_PATCH_SERIES}" --env "LINUX_PATCH_SERIES_SHA256=${LINUX_PATCH_SERIES_SHA256}" \
    --env "LINUX_LOCALVERSION=${LINUX_LOCALVERSION}" \
    --env "LINUX_DEFCONFIG=${LINUX_DEFCONFIG}" --env "LINUX_DTB=${LINUX_DTB}" \
    --env "RUN_ID=${run_id}" \
    --env "CLEAN_BUILD=${CLEAN_BUILD:-0}" \
    --env "LINUX_REF=${LINUX_REF}" --env "LINUX_URL=${LINUX_URL}" \
    --env "LINUX_UPSTREAM_COMMIT=${LINUX_UPSTREAM_COMMIT}" --env "LINUX_UPSTREAM_REF=${LINUX_UPSTREAM_REF}" --env "LINUX_UPSTREAM_URL=${LINUX_UPSTREAM_URL}" \
    --env "RUST_VERSION=${RUST_VERSION}" --env "RUSTUP_INIT_SHA256=${RUSTUP_INIT_SHA256}" --env "RUSTUP_VERSION=${RUSTUP_VERSION}" \
    --mount "type=bind,src=${mirror},dst=/inputs/linux.git,readonly" \
    --mount "type=bind,src=${project_root}/patches/linux,dst=/inputs/linux-patches,readonly" \
    --mount "type=bind,src=${stage_policy_lib},dst=/verify/milestone0-linux-full-stage.sh,readonly" \
    --mount "type=volume,src=${source_volume},dst=/workspace" \
    --mount "type=bind,src=${output_root},dst=/out" "$ARCH_BUILD_IMAGE" bash -Eeuo pipefail -c '
        source /verify/milestone0-linux-full-stage.sh
        exec 9>/workspace/.milestone0-build.lock
        flock -n 9 || { printf "Another Milestone 0 build owns the source volume\n" >&2; exit 1; }
        readonly repository=/workspace/src/linux
        readonly component_build=/workspace/build/linux-full
        readonly output=/out/milestone0/linux-full
        readonly run_id="$RUN_ID"
        readonly stage="$output/.${run_id}.tmp"
        readonly destination="$output/${run_id}"
        readonly filesystem_type="$(stat -f -c %T /workspace)"
        case "$filesystem_type" in apfs|hfs|hfsplus) printf "Workspace is not on a Linux filesystem: %s\n" "$filesystem_type" >&2; exit 1;; esac
        install -d /workspace/src /workspace/build "$output"
        if [[ -e "$repository" && ! -d "$repository/.git" ]]; then rmdir "$repository"; fi
        if [[ ! -d "$repository/.git" ]]; then git clone --no-local /inputs/linux.git "$repository"; git -C "$repository" remote set-url origin "$LINUX_URL"; fi
        test "$(git -C "$repository" remote get-url origin)" = "$LINUX_URL"
        test -z "$(git -C "$repository" status --porcelain --untracked-files=all)"
        git -C "$repository" fetch --depth=1 /inputs/linux.git "$LINUX_COMMIT"
        git -C "$repository" checkout --detach "$LINUX_COMMIT"
        test "$(git -C "$repository" rev-parse HEAD)" = "$LINUX_COMMIT"
        readonly source_epoch="$(git -C "$repository" show -s --format=%ct "$LINUX_COMMIT")"
        test "$(sha256sum "/inputs/linux-patches/$LINUX_PATCH_SERIES" | cut -d " " -f1)" = "$LINUX_PATCH_SERIES_SHA256"
        git -C "$repository" -c user.name="M3 Pro Linux downstream" -c user.email=m3pro-linux@localhost \
            am --committer-date-is-author-date "/inputs/linux-patches/$LINUX_PATCH_SERIES"
        readonly source_tree_commit="$(git -C "$repository" rev-parse HEAD)"
        test "$source_tree_commit" = "$LINUX_SOURCE_TREE_COMMIT"
        test -z "$(git -C "$repository" status --porcelain --untracked-files=all)"
        export KBUILD_BUILD_HOST=milestone0 KBUILD_BUILD_USER=builder KBUILD_BUILD_VERSION="$LINUX_PKGREL" SOURCE_DATE_EPOCH="$source_epoch"
        export KBUILD_BUILD_TIMESTAMP="$(date -u --date="@${source_epoch}" "+%Y-%m-%d %H:%M:%S UTC")"
        test -d "$stage" && test ! -L "$stage" && test ! -e "$destination"
        install -d "$stage/dtbs" "$stage/dtbs-install" "$stage/modules"
        if [[ "${CLEAN_BUILD:-0}" = 1 ]]; then
            make -C "$repository" O="$component_build" ARCH=arm64 mrproper
        else
            install -d "$component_build"
        fi
        make -C "$repository" O="$component_build" ARCH=arm64 "$LINUX_DEFCONFIG"
        cp "$component_build/.config" "$stage/defconfig.config"
        test "$(sha256sum "$repository/$LINUX_CONFIG_FRAGMENT" | cut -d " " -f1)" = "$LINUX_CONFIG_FRAGMENT_SHA256"
        KCONFIG_CONFIG="$component_build/.config" "$repository/scripts/kconfig/merge_config.sh" -m "$component_build/.config" "$repository/$LINUX_CONFIG_FRAGMENT"
        make -C "$repository" O="$component_build" ARCH=arm64 olddefconfig
        "$repository/scripts/config" --file "$component_build/.config" --disable LOCALVERSION_AUTO --set-str LOCALVERSION "$LINUX_LOCALVERSION"
        make -C "$repository" O="$component_build" ARCH=arm64 olddefconfig
        make -C "$repository" O="$component_build" ARCH=arm64 rustavailable 2>&1 | tee "$stage/rustavailable.log"
        make -C "$repository" O="$component_build" ARCH=arm64 listnewconfig 2>&1 | tee "$stage/listnewconfig.log"
        ! grep -q "^CONFIG_" "$stage/listnewconfig.log"
        {
            for setting in \
                CONFIG_ARM64=y CONFIG_ARCH_APPLE=y CONFIG_ARM64_16K_PAGES=y \
                "# CONFIG_ARM64_4K_PAGES is not set" CONFIG_MODULES=y \
                CONFIG_SUSPEND=y CONFIG_PM=y CONFIG_OF=y CONFIG_RUST=y CONFIG_DRM=y \
                CONFIG_BLK_DEV_NVME=m CONFIG_NVME_APPLE=m CONFIG_DRM_ASAHI=m \
                CONFIG_DRM_APPLE=m CONFIG_PCIE_APPLE=m CONFIG_IOMMU_SUPPORT=y \
                CONFIG_IOMMU_IO_PGTABLE_LPAE=y CONFIG_APPLE_DART=m CONFIG_APPLE_AIC=y \
                CONFIG_APPLE_MAILBOX=y CONFIG_APPLE_PMGR_PWRSTATE=y CONFIG_APPLE_PMGR_MISC=y \
                CONFIG_MFD_MACSMC=m CONFIG_GPIO_MACSMC=m CONFIG_RTC_DRV_MACSMC=m \
                CONFIG_SENSORS_MACSMC_HWMON=m CONFIG_I2C_APPLE=m CONFIG_SPI_APPLE=m \
                CONFIG_SPMI=y CONFIG_SPMI_APPLE=m CONFIG_PINCTRL_APPLE_GPIO=m CONFIG_APPLE_WATCHDOG=m \
                CONFIG_APPLE_RTKIT=y CONFIG_APPLE_RTKIT_HELPER=m CONFIG_USB_DWC3_APPLE=m \
                CONFIG_SND_SOC_APPLE_MACAUDIO=m CONFIG_CPU_IDLE=y CONFIG_ARM_APPLE_CPUIDLE=y \
                CONFIG_CPU_FREQ=y CONFIG_ARM_APPLE_SOC_CPUFREQ=m CONFIG_PM_SLEEP=y \
                CONFIG_HWMON=y CONFIG_THERMAL=y CONFIG_THERMAL_HWMON=y \
                "CONFIG_LOCALVERSION=\"$LINUX_LOCALVERSION\"" "# CONFIG_LOCALVERSION_AUTO is not set"; do
                grep -Fx "$setting" "$component_build/.config"
            done
        } > "$stage/config-assertions.txt"
        diff -u "$stage/defconfig.config" "$component_build/.config" > "$stage/defconfig.diff" || :
        printf "%s  %s\n" "$(sha256sum "$component_build/.config" | cut -d " " -f1)" config > "$stage/config-merged.sha256"
        readonly diagnostic_pattern="warning:|Warning:|Warning \\(|error:|Error:|Error \\(|\\[(warning|error)\\]|Missing .* constraint|failed to match any schema|\\.dtb: "
        set +e
        LC_ALL=C make -C "$repository" O="$component_build" ARCH=arm64 W=1 -j"$(nproc)" Image modules dtbs 2>&1 | tee "$stage/build.log"
        pipeline_status=("${PIPESTATUS[@]}")
        build_status=${pipeline_status[0]}
        build_tee_status=${pipeline_status[1]}
        set -e
        grep -E "$diagnostic_pattern" "$stage/build.log" | LC_ALL=C sort -u > "$stage/build-warning-inventory.txt" || :
        test "$build_status" -eq 0
        test "$build_tee_status" -eq 0
        unset DT_SCHEMA_FILES
        set +e
        MAKEFLAGS= LC_ALL=C make -C "$repository" O="$component_build" ARCH=arm64 W=1 -j1 dt_binding_check 2>&1 | tee "$stage/dt-binding-check.log"
        pipeline_status=("${PIPESTATUS[@]}")
        binding_status=${pipeline_status[0]}
        binding_tee_status=${pipeline_status[1]}
        set -e
        grep -E "$diagnostic_pattern" "$stage/dt-binding-check.log" | LC_ALL=C sort -u > "$stage/dt-binding-warning-inventory.txt" || :
        test "$binding_status" -eq 0
        test "$binding_tee_status" -eq 0
        set +e
        MAKEFLAGS= LC_ALL=C make -C "$repository" O="$component_build" ARCH=arm64 W=1 -j"$(nproc)" dtbs_check 2>&1 | tee "$stage/dtbs-check.log"
        pipeline_status=("${PIPESTATUS[@]}")
        dtbs_status=${pipeline_status[0]}
        dtbs_tee_status=${pipeline_status[1]}
        set -e
        grep -E "$diagnostic_pattern" "$stage/dtbs-check.log" | LC_ALL=C sort -u > "$stage/dtbs-warning-inventory.txt" || :
        test "$dtbs_status" -eq 0
        test "$dtbs_tee_status" -eq 0
        readonly target_dtb="$component_build/arch/arm64/boot/dts/$LINUX_DTB"
        readonly target_dtb_cmd="$(dirname "$target_dtb")/.$(basename "$target_dtb").cmd"
        rm -f "$target_dtb" "$target_dtb_cmd"
        set +e
        MAKEFLAGS= LC_ALL=C make -C "$repository" O="$component_build" ARCH=arm64 W=1 CHECK_DTBS=1 -j1 "$LINUX_DTB" 2>&1 | tee "$stage/target-dtbs-check.raw.log"
        pipeline_status=("${PIPESTATUS[@]}")
        target_dtbs_status=${pipeline_status[0]}
        target_dtbs_tee_status=${pipeline_status[1]}
        set -e
        test "$target_dtbs_status" -eq 0
        test "$target_dtbs_tee_status" -eq 0
        awk -v target="arch/arm64/boot/dts/$LINUX_DTB" '\''
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
        '\'' "$stage/target-dtbs-check.raw.log" \
            | sed -E "s#/workspace/src/linux/##g; s#/workspace/build/linux-full/##g" \
            > "$stage/target-dtbs-check.log"
        test "$(wc -l < "$stage/target-dtbs-check.log")" -eq "$LINUX_TARGET_DT_DIAGNOSTICS_LINES"
        test "$(sha256sum "$stage/target-dtbs-check.log" | cut -d " " -f1)" = "$LINUX_TARGET_DT_DIAGNOSTICS_SHA256"
        awk -v target="arch/arm64/boot/dts/$LINUX_DTB:" '\''
            /Warning \(/ || index($0, target) == 1 { print }
        '\'' "$stage/target-dtbs-check.log" | LC_ALL=C sort -u > "$stage/target-warning-inventory.txt"
        test "$(wc -l < "$stage/target-warning-inventory.txt")" -eq "$LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS"
        printf "policy=all unfiltered diagnostics are recorded; the normalized J514s/T6030 block must exactly match the pinned known baseline\nknown_target_diagnostics_sha256=%s\nknown_target_diagnostics_lines=%s\nknown_target_diagnostic_fingerprints=%s\nclassification=known target diagnostics are unresolved upstream/downstream debt and are not hardware-support evidence\n" \
            "$LINUX_TARGET_DT_DIAGNOSTICS_SHA256" "$LINUX_TARGET_DT_DIAGNOSTICS_LINES" "$LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS" \
            > "$stage/schema-exceptions.txt"
        dtschema_version="$(dt-validate --version)"
        printf "dt_binding_check=passed\ndtbs_check=passed\ntarget_dtbs_check=passed\nwarning_policy=W=1-diagnostic\ndt_schema_files=unfiltered\ndt_binding_check_serialized=true\ndtbs_check_parallel=true\ntarget_dtbs_check_serialized=true\ndtbs_list_policy=normalized-kernel-dtbs-list\ndtbs_inventory_policy=raw-build-superset\ndtbs_install_policy=native-make-dtbs_install\ndtbs_install_inventory_policy=installed-equals-dtbs-list\ndtbs_install_byte_equality=true\ntarget_diagnostics_policy=pinned-known-baseline\ntarget_diagnostics_sha256=%s\ntarget_diagnostics_lines=%s\ntarget_diagnostic_fingerprints=%s\ndtschema_version=%s\n" \
            "$LINUX_TARGET_DT_DIAGNOSTICS_SHA256" "$LINUX_TARGET_DT_DIAGNOSTICS_LINES" "$LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS" "$dtschema_version" > "$stage/checks.txt"
        printf "dtbs_install_subset_policy=kernel-install-subset\n" >> "$stage/checks.txt"
        printf "headers_evidence_policy=deterministic-headers-tar\nheaders_archive_policy=gnu-tar-sort-name-source-epoch-numeric-root\nheaders_archive_root=usr/include\nheaders_inventory_policy=sorted-regular-members\nheaders_source_filesystem=ext4-docker-volume\nheaders_install_fresh_root=true\nheaders_archive_byte_stable=true\n" >> "$stage/checks.txt"
        printf "artifact_symlink_policy=none-portable-handoff\n" >> "$stage/checks.txt"
        install -m 0644 "$component_build/arch/arm64/boot/Image" "$stage/Image"
        install -m 0644 "$component_build/System.map" "$stage/System.map"
        install -m 0644 "$component_build/vmlinux" "$stage/vmlinux"
        install -m 0644 "$component_build/.config" "$stage/config"
        install -m 0644 "$repository/arch/arm64/configs/asahi.config" "$stage/asahi.config"
        readonly dtbs_source="$component_build/arch/arm64/boot/dts"
        test -s "$dtbs_source/dtbs-list"
        ! grep -Evq "^arch/arm64/boot/dts/[^/[:space:]]+(/[^/[:space:]]+)*\\.(dtb|dtbo)$" "$dtbs_source/dtbs-list"
        sed -E "s#^arch/arm64/boot/dts/##" "$dtbs_source/dtbs-list" | LC_ALL=C sort > "$stage/dtbs-list.inventory"
        ! grep -Eq "(^|/)\\.\\.?(/|$)" "$stage/dtbs-list.inventory"
        ! grep -Evq "^[^/[:space:]]+(/[^/[:space:]]+)*\\.(dtb|dtbo)$" "$stage/dtbs-list.inventory"
        LC_ALL=C sort -u "$stage/dtbs-list.inventory" | cmp - "$stage/dtbs-list.inventory"
        make -C "$repository" O="$component_build" ARCH=arm64 INSTALL_DTBS_PATH="$stage/dtbs-install" dtbs_install
        make -C "$repository" O="$component_build" ARCH=arm64 INSTALL_MOD_PATH="$stage/modules" modules_install
        readonly kernel_release="$(make -s -C "$repository" O="$component_build" ARCH=arm64 kernelrelease)"
        m0_make_linux_full_stage_portable "$stage" "$kernel_release"
        # headers_install must run on the case-sensitive ext4 Docker volume;
        # only the resulting deterministic archive is copied to the APFS stage.
        readonly headers_root="/workspace/build/linux-headers-install-${run_id}"
        readonly headers_archive="/workspace/build/headers-${run_id}.tar"
        headers_cleanup() { rm -rf -- "$headers_root" "$headers_archive"; }
        trap headers_cleanup EXIT
        test ! -e "$headers_root" && test ! -e "$headers_archive"
        install -d "$headers_root"
        make -C "$repository" O="$component_build" ARCH=arm64 INSTALL_HDR_PATH="$headers_root/usr" headers_install
        test -s "$headers_root/usr/include/linux/kernel.h"
        test -z "$(find -P "$headers_root" ! -type f ! -type d -print -quit)"
        find "$headers_root" -type f -printf "%P\n" | LC_ALL=C sort > "$stage/headers.inventory"
        test -s "$stage/headers.inventory"
        ! grep -Eq "(^|/)\.\.?(/|$)" "$stage/headers.inventory"
        LC_ALL=C sort -u "$stage/headers.inventory" | cmp - "$stage/headers.inventory"
        tar --sort=name --format=gnu --mtime="@${source_epoch}" --owner=0 --group=0 --numeric-owner \
            -cf "$headers_archive" -C "$headers_root" usr
        cp "$headers_archive" "$stage/headers.tar"
        test -f "$headers_archive" && test ! -L "$headers_archive"
        test -f "$stage/headers.tar" && test ! -L "$stage/headers.tar" && test -s "$stage/headers.tar"
        rsync -a --include="*/" --include="*.dtb" --include="*.dtbo" --exclude="*" "$dtbs_source/" "$stage/dtbs/"
        find "$stage/dtbs" "$stage/dtbs-install" "$stage/modules" -depth -type d -empty -delete
        find "$stage/dtbs" -type f \( -name "*.dtb" -o -name "*.dtbo" \) -printf "%P\n" | LC_ALL=C sort > "$stage/dtbs.inventory"
        find "$stage/dtbs-install" -type f \( -name "*.dtb" -o -name "*.dtbo" \) -printf "%P\n" | LC_ALL=C sort > "$stage/dtbs-install.inventory"
        cmp "$stage/dtbs-list.inventory" "$stage/dtbs-install.inventory"
        (( $(wc -l < "$stage/dtbs.inventory") >= $(wc -l < "$stage/dtbs-list.inventory") ))
        while IFS= read -r dt_path; do
            test -f "$stage/dtbs/$dt_path"
            grep -Fx "$dt_path" "$stage/dtbs.inventory" >/dev/null
        done < "$stage/dtbs-list.inventory"
        while IFS= read -r dt_path; do
            cmp "$stage/dtbs/$dt_path" "$stage/dtbs-install/$dt_path"
        done < "$stage/dtbs-list.inventory"
        grep -Fx "apple/t6030-j514s.dtb" "$stage/dtbs.inventory"
        find "$stage/modules" -type f -printf "%P\n" | LC_ALL=C sort > "$stage/modules.inventory"
        grep -Fx "lib/modules/$kernel_release/modules.dep" "$stage/modules.inventory"
        find "$stage" -type l -printf "%P\n" | LC_ALL=C sort > "$stage/symlinks.inventory"
        while IFS= read -r link; do printf "%s -> %s\n" "$link" "$(readlink "$stage/$link")"; done < "$stage/symlinks.inventory" > "$stage/symlink-targets.txt"
        cp "$repository/$LINUX_CONFIG_FRAGMENT" "$stage/config-input"
        cp "$repository/arch/arm64/configs/asahi.config" "$stage/config-fragment"
        git -C "$repository" status --porcelain --untracked-files=all > "$stage/source-status.txt"
        test ! -s "$stage/source-status.txt"
        make -s -C "$repository" O="$component_build" ARCH=arm64 kernelrelease > "$stage/kernelrelease"
        pacman -Q | LC_ALL=C sort > "$stage/packages.txt"
        {
        printf "format=1\nbuilt_utc=%s\ntarget=Mac15,6/J514s/T6030\ncomponent=linux-full\nsource_url=%s\nsource_commit=%s\nsource_tree_commit=%s\nsource_ref=%s\nupstream_url=%s\nupstream_ref=%s\nupstream_commit=%s\nsource_clean=true\nsource_date_epoch=%s\nlinux_config_fragment_sha256=%s\nconfig_fragment=%s\nlinux_patch_series=%s\nlinux_patch_series_sha256=%s\ndefconfig=%s\nlocalversion=%s\nworkspace_filesystem=%s\nbuild_environment=archlinuxarm-native\nrust_version=%s\nrustup_version=%s\nrustup_init_sha256=%s\ncontainer_image=%s\ncontainer_image_id=%s\ncompiler=%s\nlinker=%s\nwarning_policy=W=1-diagnostic\ndt_schema_files=unfiltered\ndtbs_list_policy=normalized-kernel-dtbs-list\ndtbs_inventory_policy=raw-build-superset\ndtbs_install_policy=native-make-dtbs_install\ndtbs_install_inventory_policy=installed-equals-dtbs-list\ndtbs_install_byte_equality=true\ntarget_diagnostics_policy=pinned-known-baseline\ntarget_diagnostics_sha256=%s\ntarget_diagnostics_lines=%s\ntarget_diagnostic_fingerprints=%s\ndtschema_version=%s\nconfig_merged_sha256=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINUX_URL" "$LINUX_COMMIT" "$source_tree_commit" "$LINUX_REF" "$LINUX_UPSTREAM_URL" "$LINUX_UPSTREAM_REF" "$LINUX_UPSTREAM_COMMIT" "$source_epoch" "$LINUX_CONFIG_FRAGMENT_SHA256" "$LINUX_CONFIG_FRAGMENT" "$LINUX_PATCH_SERIES" "$LINUX_PATCH_SERIES_SHA256" "$LINUX_DEFCONFIG" "$LINUX_LOCALVERSION" "$filesystem_type" "$RUST_VERSION" "$RUSTUP_VERSION" "$RUSTUP_INIT_SHA256" "$BUILD_IMAGE" "$BUILD_IMAGE_ID" "$(gcc --version | head -n 1)" "$(ld --version | head -n 1)" "$LINUX_TARGET_DT_DIAGNOSTICS_SHA256" "$LINUX_TARGET_DT_DIAGNOSTICS_LINES" "$LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS" "$dtschema_version" "$(sha256sum "$component_build/.config" | cut -d " " -f1)"
        } > "$stage/manifest.txt"
        printf "dtbs_install_subset_policy=kernel-install-subset\n" >> "$stage/manifest.txt"
        printf "headers_evidence_policy=deterministic-headers-tar\nheaders_archive_policy=gnu-tar-sort-name-source-epoch-numeric-root\nheaders_archive_root=usr/include\nheaders_inventory_policy=sorted-regular-members\nheaders_source_filesystem=ext4-docker-volume\nheaders_install_fresh_root=true\nheaders_archive_byte_stable=true\n" >> "$stage/manifest.txt"
        printf "artifact_symlink_policy=none-portable-handoff\n" >> "$stage/manifest.txt"
        file "$stage/Image" "$stage/vmlinux" "$stage/dtbs/apple/t6030-j514s.dtb" > "$stage/file.txt"
        test -z "$(find -P "$stage" -mindepth 1 -type d -empty -print -quit)"
        (cd "$stage"; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS)
    '

"${project_root}/scripts/verify-linux-full.sh" "$stage"
if [[ -e "$destination" || -L "$destination" ]]; then
    printf 'Refusing colliding linux-full destination for run %s\n' "$run_id" >&2
    exit 1
fi
mv "$stage" "$destination"
atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"
printf 'linux-full.baseline=%s\n' "$destination"
