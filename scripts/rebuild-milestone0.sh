#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
source "${project_root}/scripts/lib/milestone0-components.sh"
m0_validate_output_root "$project_root"
readonly output_root="$MILESTONE0_OUTPUT_ROOT"
readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly rebuild_root="${project_root}/out/isolated/rebuild-${run_id}"
readonly temp_volume="asahi-m3pro-milestone0-rebuild-${run_id}"
readonly canonical_root="${output_root}/milestone0"
readonly cleanup_volume=1
command -v docker >/dev/null
docker info >/dev/null
test -d "$canonical_root"
"${project_root}/scripts/verify-milestone0.sh" "$canonical_root"
readonly canonical_symlink_list=("${m0_component_names[@]}")
declare -a canonical_symlinks canonical_paths
for index in "${!canonical_symlink_list[@]}"; do
    component=${canonical_symlink_list[index]}
    snapshot=$(m0_component_snapshot "$canonical_root" "$component")
    canonical_symlinks[index]=${snapshot%%$'\t'*}
    canonical_paths[index]=${snapshot#*$'\t'}
done
declare -a rebuild_symlinks rebuild_paths
[[ "$rebuild_root" == "$project_root/out/isolated/rebuild-"* ]]
[[ "${rebuild_root##*/}" =~ ^rebuild-[A-Za-z0-9._-]+$ ]]
docker volume create --label com.moriz.project=asahi-m3pro-fullstack --label com.moriz.purpose=milestone0-rebuild "$temp_volume" >/dev/null
cleanup() {
    if (( cleanup_volume )) && [[ "$(docker volume inspect --format '{{ index .Labels "com.moriz.project" }}:{{ index .Labels "com.moriz.purpose" }}' "$temp_volume" 2>/dev/null || true)" = 'asahi-m3pro-fullstack:milestone0-rebuild' ]]; then
        docker volume rm "$temp_volume" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
MILESTONE0_OUTPUT_ROOT="$rebuild_root" SOURCE_VOLUME_OVERRIDE="$temp_volume" CLEAN_BUILD=1 \
    "${project_root}/scripts/build-milestone0.sh"
MILESTONE0_OUTPUT_ROOT="$rebuild_root" \
    "${project_root}/scripts/verify-milestone0.sh" "$rebuild_root/milestone0"

for index in "${!canonical_symlink_list[@]}"; do
    component=${canonical_symlink_list[index]}
    m0_component_assert_unchanged "$canonical_root" "$component" \
        "${canonical_symlinks[index]}" "${canonical_paths[index]}"
    rebuild_snapshot=$(m0_component_snapshot "$rebuild_root/milestone0" "$component")
    rebuild_pointer=${rebuild_snapshot%%$'\t'*}
    rebuild_path=${rebuild_snapshot#*$'\t'}
    test -n "$rebuild_pointer" && test -n "$rebuild_path"
    rebuild_symlinks[index]=$rebuild_pointer
    rebuild_paths[index]=$rebuild_path
done
for relative in \
    m1n1/m1n1.macho m1n1/m1n1.bin \
    u-boot/u-boot u-boot/u-boot-nodtb.bin linux-dtb/t6030-j514s.dtb \
    linux-full/Image linux-full/vmlinux linux-full/System.map linux-full/config \
    linux-full/config-input linux-full/config-fragment linux-full/asahi.config linux-full/kernelrelease \
    linux-full/config-assertions.txt linux-full/dtbs-list.inventory linux-full/dtbs.inventory \
    linux-full/dtbs-install.inventory linux-full/modules.inventory \
    linux-full/headers.tar linux-full/headers.inventory \
    boot-payload/m1n1.macho boot-payload/t6030-j514s.dtb boot-payload/u-boot-nodtb.bin \
    boot-payload/u-boot-j514s-candidate.macho; do
    component=${relative%/*}
    index=$(m0_component_index "$component")
    cmp "${canonical_paths[index]}/${relative##*/}" \
        "${rebuild_paths[index]}/${relative##*/}"
done
compare_manifest_keys() {
    local left="$1" right="$2" key left_value right_value
    shift 2
    local -a keys=("$@")
    for key in "${keys[@]}"; do
        left_value="$(sed -n "s/^${key}=//p" "$left")"
        right_value="$(sed -n "s/^${key}=//p" "$right")"
        if [[ -z "$left_value" || -z "$right_value" ]]; then
            printf 'Reproducibility manifest key missing: %s (%s, %s)\n' \
                "$key" "$left" "$right" >&2
            return 1
        fi
        if [[ "$left_value" != "$right_value" ]]; then
            printf 'Reproducibility manifest mismatch: %s\n  canonical: %s\n  rebuild:   %s\n' \
                "$key" "$left_value" "$right_value" >&2
            return 1
        fi
    done
}
for component in m1n1 u-boot linux-dtb linux-full; do
    index=$(m0_component_index "$component")
    case "$component" in
        linux-full)
        keys=(source_url source_commit source_tree_commit source_ref upstream_url upstream_ref upstream_commit source_date_epoch source_clean config_fragment linux_config_fragment_sha256 linux_patch_series linux_patch_series_sha256 localversion build_environment rust_version rustup_version rustup_init_sha256 container_image container_image_id compiler linker dtschema_version warning_policy dt_schema_files dtbs_list_policy dtbs_inventory_policy dtbs_install_policy dtbs_install_inventory_policy dtbs_install_byte_equality dtbs_install_subset_policy headers_evidence_policy headers_archive_policy headers_archive_root headers_inventory_policy headers_source_filesystem headers_install_fresh_root headers_archive_byte_stable target_diagnostics_policy target_diagnostics_sha256 target_diagnostics_lines target_diagnostic_fingerprints) ;;
        *)
            keys=(source_url source_commit source_ref upstream_url upstream_ref upstream_commit source_date_epoch source_clean container_image container_image_id) ;;
    esac
    compare_manifest_keys "${canonical_paths[index]}/manifest.txt" "${rebuild_paths[index]}/manifest.txt" "${keys[@]}"
done
payload_index=$(m0_component_index boot-payload)
package_index=$(m0_component_index linux-packages)
linux_full_index=$(m0_component_index linux-full)
compare_manifest_keys "${canonical_paths[payload_index]}/manifest.txt" "${rebuild_paths[payload_index]}/manifest.txt" \
    status payload layout m1n1_commit linux_commit u_boot_commit
for tree in dtbs dtbs-install modules; do
    diff -qr "${canonical_paths[linux_full_index]}/$tree" \
        "${rebuild_paths[linux_full_index]}/$tree"
done
cmp "${canonical_paths[linux_full_index]}/headers.tar" \
    "${rebuild_paths[linux_full_index]}/headers.tar"
cmp "${canonical_paths[linux_full_index]}/headers.inventory" \
    "${rebuild_paths[linux_full_index]}/headers.inventory"
for package in "${canonical_paths[package_index]}"/*.pkg.tar.zst; do
    test -e "$package"
    cmp "$package" "${rebuild_paths[package_index]}/$(basename "$package")"
    for suffix in closure inventory pkginfo files; do
        cmp "$package.$suffix" "${rebuild_paths[package_index]}/$(basename "$package").$suffix"
    done
done
compare_manifest_keys "${canonical_paths[package_index]}/manifest.txt" "${rebuild_paths[package_index]}/manifest.txt" \
    source_commit source_tree_commit linux_patch_series linux_patch_series_sha256 linux_pkgbase linux_pkgver linux_pkgrel \
    pkgbuild_fork_url pkgbuild_fork_ref pkgbuild_fork_commit pkgbuild_upstream_url \
    pkgbuild_upstream_ref pkgbuild_upstream_commit arch_image arch_image_id source_date_epoch method kernel_image_transform kernel_image_verification module_transform module_metadata_policy
for index in "${!canonical_symlink_list[@]}"; do
    component=${canonical_symlink_list[index]}
    m0_component_assert_unchanged "$canonical_root" "$component" \
        "${canonical_symlinks[index]}" "${canonical_paths[index]}"
    m0_component_assert_unchanged "$rebuild_root/milestone0" "$component" \
        "${rebuild_symlinks[index]}" "${rebuild_paths[index]}"
done
printf 'clean_rebuild=byte-identical-release-artifact-closure\n'
printf 'milestone0.rebuild=%s\n' "$rebuild_root"
