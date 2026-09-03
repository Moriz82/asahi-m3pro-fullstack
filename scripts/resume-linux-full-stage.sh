#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
source "${project_root}/scripts/lib/atomic-symlink.sh"
m0_validate_output_root "$project_root"

readonly run_id="${1:-}"
[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]+$ ]] || {
    printf 'usage: %s YYYYMMDDTHHMMSSZ-PID-RANDOM\n' "$0" >&2
    exit 2
}

readonly output_root="$MILESTONE0_OUTPUT_ROOT"
readonly source_volume="${SOURCE_VOLUME_OVERRIDE:-${SOURCE_VOLUME}}"
readonly stage="${output_root}/milestone0/linux-full/.${run_id}.tmp"
readonly destination="${output_root}/milestone0/linux-full/${run_id}"
readonly latest="${output_root}/milestone0/linux-full/latest"
readonly latest_tmp="${output_root}/milestone0/linux-full/.latest.${run_id}.tmp"
readonly stage_policy_lib="${project_root}/scripts/lib/milestone0-linux-full-stage.sh"

test -d "$stage"
test ! -L "$stage"
test ! -e "$destination"
if [[ -e "$latest_tmp" || -L "$latest_tmp" ]] || [[ -e "$latest" && ! -L "$latest" ]]; then
    printf 'Refusing colliding linux-full publication path for run %s\n' "$run_id" >&2
    exit 1
fi
command -v docker >/dev/null
docker info >/dev/null
test "$(docker volume inspect --format '{{ index .Labels "com.moriz.project" }}' "$source_volume")" = asahi-m3pro-fullstack
readonly image_id="$(docker image inspect --format '{{.Id}}' "$ARCH_BUILD_IMAGE")"

docker run --rm \
    --env "RUN_ID=${run_id}" \
    --env "BUILD_IMAGE=${ARCH_BUILD_IMAGE}" --env "BUILD_IMAGE_ID=${image_id}" \
    --env "LINUX_COMMIT=${LINUX_COMMIT}" --env "LINUX_PKGREL=${LINUX_PKGREL}" \
    --env "LINUX_SOURCE_TREE_COMMIT=${LINUX_SOURCE_TREE_COMMIT}" \
    --env "LINUX_TARGET_DT_DIAGNOSTICS_SHA256=${LINUX_TARGET_DT_DIAGNOSTICS_SHA256}" \
    --env "LINUX_TARGET_DT_DIAGNOSTICS_LINES=${LINUX_TARGET_DT_DIAGNOSTICS_LINES}" \
    --env "LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS=${LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS}" \
    --env "LINUX_CONFIG_FRAGMENT=${LINUX_CONFIG_FRAGMENT}" --env "LINUX_CONFIG_FRAGMENT_SHA256=${LINUX_CONFIG_FRAGMENT_SHA256}" \
    --env "LINUX_PATCH_SERIES=${LINUX_PATCH_SERIES}" --env "LINUX_PATCH_SERIES_SHA256=${LINUX_PATCH_SERIES_SHA256}" \
    --env "LINUX_LOCALVERSION=${LINUX_LOCALVERSION}" --env "LINUX_DEFCONFIG=${LINUX_DEFCONFIG}" --env "LINUX_DTB=${LINUX_DTB}" \
    --env "LINUX_REF=${LINUX_REF}" --env "LINUX_URL=${LINUX_URL}" \
    --env "LINUX_UPSTREAM_COMMIT=${LINUX_UPSTREAM_COMMIT}" --env "LINUX_UPSTREAM_REF=${LINUX_UPSTREAM_REF}" --env "LINUX_UPSTREAM_URL=${LINUX_UPSTREAM_URL}" \
    --env "RUST_VERSION=${RUST_VERSION}" --env "RUSTUP_INIT_SHA256=${RUSTUP_INIT_SHA256}" --env "RUSTUP_VERSION=${RUSTUP_VERSION}" \
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
        readonly stage="$output/.$RUN_ID.tmp"
        readonly destination="$output/$RUN_ID"
        readonly filesystem_type="$(stat -f -c %T /workspace)"
        case "$filesystem_type" in apfs|hfs|hfsplus) exit 1;; esac
        test -d "$stage" && test ! -L "$stage" && test ! -e "$destination"
        test "$(git -C "$repository" rev-parse HEAD)" = "$LINUX_SOURCE_TREE_COMMIT"
        test -z "$(git -C "$repository" status --porcelain --untracked-files=all)"
        readonly source_epoch="$(git -C "$repository" show -s --format=%ct "$LINUX_COMMIT")"
        test "$(sha256sum "/inputs/linux-patches/$LINUX_PATCH_SERIES" | cut -d " " -f1)" = "$LINUX_PATCH_SERIES_SHA256"
        test "$(sha256sum "$repository/$LINUX_CONFIG_FRAGMENT" | cut -d " " -f1)" = "$LINUX_CONFIG_FRAGMENT_SHA256"
        readonly kernel_release="$(make -s -C "$repository" O="$component_build" ARCH=arm64 kernelrelease)"
        m0_make_linux_full_stage_portable "$stage" "$kernel_release"

        for required in Image System.map vmlinux config defconfig.config defconfig.diff config-merged.sha256 asahi.config config-assertions.txt rustavailable.log listnewconfig.log build.log build-warning-inventory.txt dt-binding-check.log dt-binding-warning-inventory.txt dtbs-check.log dtbs-warning-inventory.txt target-dtbs-check.raw.log target-dtbs-check.log target-warning-inventory.txt schema-exceptions.txt checks.txt dtbs dtbs-install modules headers.tar dtbs-list.inventory dtbs.inventory dtbs-install.inventory headers.inventory; do
            test -e "$stage/$required"
        done
        test -f "$stage/headers.tar" && test ! -L "$stage/headers.tar"
        test ! -e "$stage/headers"
        grep -Fx "dt_binding_check=passed" "$stage/checks.txt"
        grep -Fx "dtbs_check=passed" "$stage/checks.txt"
        grep -Fx "target_dtbs_check=passed" "$stage/checks.txt"
        grep -Fx "dtbs_list_policy=normalized-kernel-dtbs-list" "$stage/checks.txt"
        grep -Fx "dtbs_inventory_policy=raw-build-superset" "$stage/checks.txt"
        grep -Fx "dtbs_install_policy=native-make-dtbs_install" "$stage/checks.txt"
        grep -Fx "dtbs_install_inventory_policy=installed-equals-dtbs-list" "$stage/checks.txt"
        grep -Fx "dtbs_install_byte_equality=true" "$stage/checks.txt"
        grep -Fx "dtbs_install_subset_policy=kernel-install-subset" "$stage/checks.txt"
        grep -Fx "headers_evidence_policy=deterministic-headers-tar" "$stage/checks.txt"
        grep -Fx "headers_archive_policy=gnu-tar-sort-name-source-epoch-numeric-root" "$stage/checks.txt"
        grep -Fx "headers_archive_root=usr/include" "$stage/checks.txt"
        grep -Fx "headers_inventory_policy=sorted-regular-members" "$stage/checks.txt"
        grep -Fx "headers_source_filesystem=ext4-docker-volume" "$stage/checks.txt"
        grep -Fx "headers_install_fresh_root=true" "$stage/checks.txt"
        grep -Fx "headers_archive_byte_stable=true" "$stage/checks.txt"
        tail -n 8 "$stage/dt-binding-check.log" | grep -E "make(\[[0-9]+\])?: Leaving directory"
        tail -n 8 "$stage/dtbs-check.log" | grep -E "make(\[[0-9]+\])?: Leaving directory"
        awk -v target="arch/arm64/boot/dts/$LINUX_DTB" '\''
            /^  (DTC|OVL) \[C\] arch\/arm64\/boot\/dts\// {
                if (capture) { terminated = 1; exit }
                capture = index($0, target) > 0
                if (capture) seen = 1
            }
            capture && /^make(\[[0-9]+\])?: Leaving directory/ { terminated = 1; exit }
            capture { print }
            END { if (!seen || !terminated) exit 1 }
        '\'' "$stage/target-dtbs-check.raw.log" \
            | sed -E "s#/workspace/src/linux/##g; s#/workspace/build/linux-full/##g" \
            | cmp - "$stage/target-dtbs-check.log"
        test "$(wc -l < "$stage/target-dtbs-check.log")" -eq "$LINUX_TARGET_DT_DIAGNOSTICS_LINES"
        test "$(sha256sum "$stage/target-dtbs-check.log" | cut -d " " -f1)" = "$LINUX_TARGET_DT_DIAGNOSTICS_SHA256"
        test "$(wc -l < "$stage/target-warning-inventory.txt")" -eq "$LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS"

        cmp "$component_build/arch/arm64/boot/Image" "$stage/Image"
        cmp "$component_build/System.map" "$stage/System.map"
        cmp "$component_build/vmlinux" "$stage/vmlinux"
        cmp "$component_build/.config" "$stage/config"
        readonly dtbs_source="$component_build/arch/arm64/boot/dts"
        readonly dtbs_list_tmp="$(mktemp)"
        readonly raw_inventory_tmp="$(mktemp)"
        readonly headers_root="/workspace/build/linux-headers-resume-${RUN_ID}"
        readonly headers_archive="/workspace/build/headers-resume-${RUN_ID}.tar"
        readonly headers_inventory_tmp="$(mktemp)"
        trap "rm -f -- \"$dtbs_list_tmp\" \"$raw_inventory_tmp\" \"$headers_inventory_tmp\"; rm -rf -- \"$headers_root\" \"$headers_archive\"" EXIT
        # A killed retry may leave only these exact run-scoped paths behind;
        # clear them before creating the fresh headers_install root.
        rm -rf -- "$headers_root" "$headers_archive"
        find "$dtbs_source" -type f \( -name "*.dtb" -o -name "*.dtbo" \) -printf "%P\n" | LC_ALL=C sort > "$raw_inventory_tmp"
        ! grep -Evq "^[^/[:space:]]+(/[^/[:space:]]+)*\\.(dtb|dtbo)$" "$raw_inventory_tmp"
        ! grep -Eq "(^|/)\\.\\.?(/|$)" "$raw_inventory_tmp"
        LC_ALL=C sort -u "$raw_inventory_tmp" | cmp - "$raw_inventory_tmp"
        test -z "$(find -P "$dtbs_source" ! -type f ! -type d -print -quit)"
        cmp "$raw_inventory_tmp" "$stage/dtbs.inventory"
        while IFS= read -r dt_path; do
            cmp "$dtbs_source/$dt_path" "$stage/dtbs/$dt_path"
        done < "$raw_inventory_tmp"
        sed -E "s#^arch/arm64/boot/dts/##" "$dtbs_source/dtbs-list" | LC_ALL=C sort > "$dtbs_list_tmp"
        ! grep -Evq "^[^/[:space:]]+(/[^/[:space:]]+)*\\.(dtb|dtbo)$" "$dtbs_list_tmp"
        ! grep -Eq "(^|/)\\.\\.?(/|$)" "$dtbs_list_tmp"
        LC_ALL=C sort -u "$dtbs_list_tmp" | cmp - "$dtbs_list_tmp"
        cmp "$dtbs_list_tmp" "$stage/dtbs-list.inventory"
        cmp "$component_build/arch/arm64/boot/dts/$LINUX_DTB" "$stage/dtbs/$LINUX_DTB"
        ! grep -Evq "^[^/[:space:]]+(/[^/[:space:]]+)*\\.(dtb|dtbo)$" "$stage/dtbs.inventory"
        ! grep -Evq "^[^/[:space:]]+(/[^/[:space:]]+)*\\.(dtb|dtbo)$" "$stage/dtbs-install.inventory"
        ! grep -Eq "(^|/)\\.\\.?(/|$)" "$stage/dtbs.inventory"
        ! grep -Eq "(^|/)\\.\\.?(/|$)" "$stage/dtbs-install.inventory"
        LC_ALL=C sort -u "$stage/dtbs.inventory" | cmp - "$stage/dtbs.inventory"
        LC_ALL=C sort -u "$stage/dtbs-install.inventory" | cmp - "$stage/dtbs-install.inventory"
        test -z "$(find -P "$stage/dtbs" ! -type f ! -type d -print -quit)"
        test -z "$(find -P "$stage/dtbs-install" ! -type f ! -type d -print -quit)"
        cmp "$stage/dtbs-list.inventory" "$stage/dtbs-install.inventory"
        (( $(wc -l < "$stage/dtbs.inventory") >= $(wc -l < "$stage/dtbs-list.inventory") ))
        while IFS= read -r dt_path; do
            grep -Fx "$dt_path" "$stage/dtbs.inventory" >/dev/null
        done < "$stage/dtbs-list.inventory"
        (cd "$stage"; find dtbs -type f \( -name "*.dtb" -o -name "*.dtbo" \) -printf "%P\n" | LC_ALL=C sort) | cmp - "$stage/dtbs.inventory"
        (cd "$stage"; find dtbs-install -type f \( -name "*.dtb" -o -name "*.dtbo" \) -printf "%P\n" | LC_ALL=C sort) | cmp - "$stage/dtbs-install.inventory"
        while IFS= read -r dt_path; do
            test -f "$stage/dtbs/$dt_path"
            cmp "$stage/dtbs/$dt_path" "$stage/dtbs-install/$dt_path"
        done < "$stage/dtbs-list.inventory"
        find "$stage/modules" -type f -printf "%P\n" | LC_ALL=C sort > "$stage/modules.inventory"
        grep -Fx "lib/modules/$kernel_release/modules.dep" "$stage/modules.inventory"
        find "$stage/dtbs" "$stage/dtbs-install" "$stage/modules" -depth -type d -empty -delete
        sed -i "/^artifact_symlink_policy=/d" "$stage/checks.txt"
        printf "artifact_symlink_policy=none-portable-handoff\n" >> "$stage/checks.txt"

        test ! -e "$headers_root" && test ! -e "$headers_archive"
        install -d "$headers_root"
        make -C "$repository" O="$component_build" ARCH=arm64 INSTALL_HDR_PATH="$headers_root/usr" headers_install
        test -s "$headers_root/usr/include/linux/kernel.h"
        test -z "$(find -P "$headers_root" ! -type f ! -type d -print -quit)"
        find "$headers_root" -type f -printf "%P\n" | LC_ALL=C sort > "$headers_inventory_tmp"
        cmp "$headers_inventory_tmp" "$stage/headers.inventory"
        tar --sort=name --format=gnu --mtime="@${source_epoch}" --owner=0 --group=0 --numeric-owner \
            -cf "$headers_archive" -C "$headers_root" usr
        cmp "$headers_archive" "$stage/headers.tar"
        test -f "$headers_archive" && test ! -L "$headers_archive"
        find "$stage" -type l -printf "%P\n" | LC_ALL=C sort > "$stage/symlinks.inventory"
        while IFS= read -r link; do printf "%s -> %s\n" "$link" "$(readlink "$stage/$link")"; done < "$stage/symlinks.inventory" > "$stage/symlink-targets.txt"
        cp "$repository/$LINUX_CONFIG_FRAGMENT" "$stage/config-input"
        cp "$repository/arch/arm64/configs/asahi.config" "$stage/config-fragment"
        git -C "$repository" status --porcelain --untracked-files=all > "$stage/source-status.txt"
        test ! -s "$stage/source-status.txt"
        printf "%s\n" "$kernel_release" > "$stage/kernelrelease"
        pacman -Q | LC_ALL=C sort > "$stage/packages.txt"
        readonly dtschema_version="$(dt-validate --version)"
        {
            printf "format=1\nbuilt_utc=%s\ntarget=Mac15,6/J514s/T6030\ncomponent=linux-full\nsource_url=%s\nsource_commit=%s\nsource_tree_commit=%s\nsource_ref=%s\nupstream_url=%s\nupstream_ref=%s\nupstream_commit=%s\nsource_clean=true\nsource_date_epoch=%s\nlinux_config_fragment_sha256=%s\nconfig_fragment=%s\nlinux_patch_series=%s\nlinux_patch_series_sha256=%s\ndefconfig=%s\nlocalversion=%s\nworkspace_filesystem=%s\nbuild_environment=archlinuxarm-native\nrust_version=%s\nrustup_version=%s\nrustup_init_sha256=%s\ncontainer_image=%s\ncontainer_image_id=%s\ncompiler=%s\nlinker=%s\nwarning_policy=W=1-diagnostic\ndt_schema_files=unfiltered\ndtbs_list_policy=normalized-kernel-dtbs-list\ndtbs_inventory_policy=raw-build-superset\ndtbs_install_policy=native-make-dtbs_install\ndtbs_install_inventory_policy=installed-equals-dtbs-list\ndtbs_install_byte_equality=true\ntarget_diagnostics_policy=pinned-known-baseline\ntarget_diagnostics_sha256=%s\ntarget_diagnostics_lines=%s\ntarget_diagnostic_fingerprints=%s\ndtschema_version=%s\nconfig_merged_sha256=%s\nresumed_from_validated_stage=true\n" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINUX_URL" "$LINUX_COMMIT" "$LINUX_SOURCE_TREE_COMMIT" "$LINUX_REF" "$LINUX_UPSTREAM_URL" "$LINUX_UPSTREAM_REF" "$LINUX_UPSTREAM_COMMIT" "$source_epoch" "$LINUX_CONFIG_FRAGMENT_SHA256" "$LINUX_CONFIG_FRAGMENT" "$LINUX_PATCH_SERIES" "$LINUX_PATCH_SERIES_SHA256" "$LINUX_DEFCONFIG" "$LINUX_LOCALVERSION" "$filesystem_type" "$RUST_VERSION" "$RUSTUP_VERSION" "$RUSTUP_INIT_SHA256" "$BUILD_IMAGE" "$BUILD_IMAGE_ID" "$(gcc --version | head -n 1)" "$(ld --version | head -n 1)" "$LINUX_TARGET_DT_DIAGNOSTICS_SHA256" "$LINUX_TARGET_DT_DIAGNOSTICS_LINES" "$LINUX_TARGET_DT_DIAGNOSTICS_FINGERPRINTS" "$dtschema_version" "$(sha256sum "$component_build/.config" | cut -d " " -f1)"
        } > "$stage/manifest.txt"
        printf "dtbs_install_subset_policy=kernel-install-subset\n" >> "$stage/manifest.txt"
        printf "headers_evidence_policy=deterministic-headers-tar\nheaders_archive_policy=gnu-tar-sort-name-source-epoch-numeric-root\nheaders_archive_root=usr/include\nheaders_inventory_policy=sorted-regular-members\nheaders_source_filesystem=ext4-docker-volume\nheaders_install_fresh_root=true\nheaders_archive_byte_stable=true\n" >> "$stage/manifest.txt"
        printf "artifact_symlink_policy=none-portable-handoff\n" >> "$stage/manifest.txt"
        file "$stage/Image" "$stage/vmlinux" "$stage/dtbs/$LINUX_DTB" > "$stage/file.txt"
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
printf 'linux-full.resumed=%s\n' "$destination"
