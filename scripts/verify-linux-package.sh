#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
source "${project_root}/scripts/lib/milestone0-package-paths.sh"
if [[ "${1:-}" == --self-test ]]; then
    "${project_root}/scripts/test-linux-package-tools.sh"
    exit 0
fi
m0_validate_output_root "$project_root"
readonly package_candidate="${1:-${MILESTONE0_OUTPUT_ROOT}/milestone0/linux-packages/latest}"
readonly evidence_candidate="${2:-${MILESTONE0_OUTPUT_ROOT}/milestone0/linux-full/latest}"
handoff_snapshot=0
if [[ "${3:-}" == --handoff-snapshot ]]; then
    handoff_snapshot=1
elif [[ $# -ge 3 ]]; then
    printf 'usage: %s [PACKAGE] [LINUX_FULL] [--handoff-snapshot]\n' "$0" >&2
    exit 64
fi
package_root="$(cd "$package_candidate" && pwd -P)" || { printf 'Missing Linux package evidence.\n' >&2; exit 1; }
full_evidence="$(cd "$evidence_candidate" && pwd -P)" || { printf 'Missing Linux full evidence.\n' >&2; exit 1; }
readonly package_root full_evidence
if (( handoff_snapshot == 0 )); then
    [[ "$(dirname "$full_evidence")" == "${MILESTONE0_OUTPUT_ROOT}/milestone0/linux-full" ]] || { printf 'Unsafe Linux full evidence binding.\n' >&2; exit 1; }
else
    [[ "$package_root" == */linux-packages/* && "$full_evidence" == */linux-full/* &&
        "$package_root" != */latest && "$full_evidence" != */latest ]] || {
        printf 'Unsafe handoff package evidence binding.\n' >&2
        exit 1
    }
fi
"${project_root}/scripts/verify-linux-full.sh" "$full_evidence"
command -v docker >/dev/null
command -v bsdtar >/dev/null
docker info >/dev/null
for required in manifest.txt SHA256SUMS pacman-Q.txt; do test -s "$package_root/$required"; done
(
    cd "$package_root"
    sha256sum -c SHA256SUMS
)
grep -Fx "source_commit=${LINUX_COMMIT}" "$package_root/manifest.txt" >/dev/null
grep -Fx "source_tree_commit=${LINUX_SOURCE_TREE_COMMIT}" "$package_root/manifest.txt" >/dev/null
grep -Fx "m0_run_id=$(basename "$full_evidence")" "$package_root/manifest.txt" >/dev/null
grep -Fx "m0_manifest_sha256=$(shasum -a 256 "$full_evidence/manifest.txt" | awk '{print $1}')" "$package_root/manifest.txt" >/dev/null
grep -Fx "linux_patch_series=${LINUX_PATCH_SERIES}" "$package_root/manifest.txt" >/dev/null
grep -Fx "linux_patch_series_sha256=${LINUX_PATCH_SERIES_SHA256}" "$package_root/manifest.txt" >/dev/null
grep -Fx "linux_pkgbase=${LINUX_PKGBASE}" "$package_root/manifest.txt" >/dev/null
grep -Fx "linux_pkgver=${LINUX_PKGVER}" "$package_root/manifest.txt" >/dev/null
grep -Fx "linux_pkgrel=${LINUX_PKGREL}" "$package_root/manifest.txt" >/dev/null
grep -Fx "pkgbuild_fork_url=${LINUX_PKG_FORK_URL}" "$package_root/manifest.txt" >/dev/null
grep -Fx "pkgbuild_fork_ref=${LINUX_PKG_FORK_REF}" "$package_root/manifest.txt" >/dev/null
grep -Fx "pkgbuild_fork_commit=${LINUX_PKG_FORK_COMMIT}" "$package_root/manifest.txt" >/dev/null
grep -Fx "pkgbuild_upstream_url=${LINUX_PKG_UPSTREAM_URL}" "$package_root/manifest.txt" >/dev/null
grep -Fx "pkgbuild_upstream_ref=${LINUX_PKG_UPSTREAM_REF}" "$package_root/manifest.txt" >/dev/null
grep -Fx "pkgbuild_upstream_commit=${LINUX_PKG_UPSTREAM_COMMIT}" "$package_root/manifest.txt" >/dev/null
grep -Fx "arch_image=${ARCH_BUILD_IMAGE}" "$package_root/manifest.txt" >/dev/null
test "$(grep -c '^arch_image_id=' "$package_root/manifest.txt")" -eq 1
readonly arch_image_id="$(sed -n 's/^arch_image_id=//p' "$package_root/manifest.txt")"
readonly full_image_id="$(sed -n 's/^container_image_id=//p' "$full_evidence/manifest.txt")"
[[ $arch_image_id =~ ^sha256:[0-9a-f]{64}$ && $arch_image_id == "$full_image_id" ]]
docker image inspect "$arch_image_id" >/dev/null
grep -Fx 'method=native-kernel-pacman-pkg' "$package_root/manifest.txt" >/dev/null
grep -Fx 'kernel_image_transform=gzip' "$package_root/manifest.txt" >/dev/null
grep -Fx 'kernel_image_verification=decompressed-byte-equality' "$package_root/manifest.txt" >/dev/null
grep -Fx 'module_transform=install-mod-strip-1' "$package_root/manifest.txt" >/dev/null
grep -Fx 'module_metadata_policy=depmod-generated-on-install' "$package_root/manifest.txt" >/dev/null
readonly package_root_abs="$package_root"
readonly evidence_abs="$full_evidence"
readonly package_paths_lib="${project_root}/scripts/lib/milestone0-package-paths.sh"
readonly package_closure_lib="${project_root}/scripts/lib/milestone0-package-closure.sh"
docker run --rm --env "LINUX_PKGBASE=${LINUX_PKGBASE}" --env "LINUX_PKGVER=${LINUX_PKGVER}" --env "LINUX_PKGREL=${LINUX_PKGREL}" \
    --mount "type=bind,src=${package_root_abs},dst=/packages,readonly" \
    --mount "type=bind,src=${evidence_abs},dst=/evidence,readonly" \
    --mount "type=bind,src=${package_paths_lib},dst=/verify/milestone0-package-paths.sh,readonly" \
    --mount "type=bind,src=${package_closure_lib},dst=/verify/milestone0-package-closure.sh,readonly" \
    "$arch_image_id" bash -Eeuo pipefail -c '
        source /verify/milestone0-package-paths.sh
        source /verify/milestone0-package-closure.sh
        mapfile -t packages < <(find /packages -maxdepth 1 -type f -name "*.pkg.tar.zst" -print | sort)
        test "${#packages[@]}" -eq 4
        extract_member() {
            member="$1"; bsdtar -xOf "$2" "$member" 2>/dev/null || bsdtar -xOf "$2" "./$member"
        }
        declare -A package_by_name=()
        for package in "${packages[@]}"; do
            archive_list="$(bsdtar -tf "$package" | sed "s#^\./##")"
            closure="/packages/$(basename "$package").closure"
            test -s "$closure"
            m0_archive_closure_verify "$package" "$closure"
            grep -Fxq ".PKGINFO" <<< "$archive_list"
            grep -Fxq ".BUILDINFO" <<< "$archive_list"
            grep -Fxq ".MTREE" <<< "$archive_list"
            metadata="$(extract_member .PKGINFO "$package")"
            grep -Fxq "pkgver = ${LINUX_PKGVER}-${LINUX_PKGREL}" <<< "$metadata"
            grep -Fxq "arch = aarch64" <<< "$metadata"
            grep -Eq "^packager = .+" <<< "$metadata"
            name="$(printf "%s\n" "$metadata" | sed -n "s/^pkgname = //p")"
            test -n "$name"
            test -z "${package_by_name[$name]:-}"
            package_by_name["$name"]="$package"
            inventory="/packages/$(basename "$package").inventory"
            test -s "$inventory"
            printf "%s\n" "$archive_list" | sort | cmp - <(sed "s#^\./##" "$inventory")
        done
        for expected_name in "$LINUX_PKGBASE" "$LINUX_PKGBASE-api-headers" "$LINUX_PKGBASE-debug" "$LINUX_PKGBASE-headers"; do
            test -n "${package_by_name[$expected_name]:-}"
        done
        kver="$(cat /evidence/kernelrelease)"
        kernel="${package_by_name[$LINUX_PKGBASE]}"
        headers="${package_by_name[$LINUX_PKGBASE-headers]}"
        api="${package_by_name[$LINUX_PKGBASE-api-headers]}"
        debug="${package_by_name[$LINUX_PKGBASE-debug]}"
        test -n "$kernel"; test -n "$headers"; test -n "$api"; test -n "$debug"
        tmp="$(mktemp -d /tmp/m0-package-verify.XXXXXX)"
        trap "rm -rf \"$tmp\"" EXIT
        archive_paths="$(bsdtar -tf "$kernel" | sed "s#^\./##")"
        grep -Fxq "usr/lib/modules/$kver/vmlinuz" <<< "$archive_paths"
        grep -Fxq "usr/lib/modules/$kver/dtb/apple/t6030-j514s.dtb" <<< "$archive_paths"
        mkdir "$tmp/kernel"
        bsdtar -xf "$kernel" -C "$tmp/kernel"
        test -z "$(find -P "$tmp/kernel" -type l -print -quit)"
        test -z "$(find -P "$tmp/kernel" ! -type f ! -type d -print -quit)"
        readonly packaged_tree="$tmp/kernel/usr/lib/modules/$kver"
        test -d "$packaged_tree"
        readonly package_module_pattern="^usr/lib/modules/.+\\.ko(\\.(gz|xz|zst))?$"
        readonly evidence_module_pattern="^lib/modules/.+\\.ko(\\.(gz|xz|zst))?$"
        printf "%s\n" "$archive_paths" \
            | grep -E "$package_module_pattern" \
            | sort > "$tmp/package-modules.inventory"
        while IFS= read -r evidence_module_path; do
            m0_evidence_to_package_module_path "$evidence_module_path"
        done < <(grep -E "$evidence_module_pattern" /evidence/modules.inventory) \
            | sort | cmp - "$tmp/package-modules.inventory"
        test -s "$tmp/package-modules.inventory"
        {
            printf "usr/lib/modules/%s/pkgbase\nusr/lib/modules/%s/vmlinuz\n" "$kver" "$kver"
            for metadata_name in modules.builtin modules.builtin.modinfo modules.order; do
                printf "usr/lib/modules/%s/%s\n" "$kver" "$metadata_name"
            done
            cat "$tmp/package-modules.inventory"
            while IFS= read -r dt_path; do
                printf "usr/lib/modules/%s/dtb/%s\n" "$kver" "$dt_path"
            done < /evidence/dtbs-install.inventory
        } | LC_ALL=C sort > "$tmp/expected-package-tree.inventory"
        find "$packaged_tree" -type f -printf "usr/lib/modules/$kver/%P\n" \
            | LC_ALL=C sort | cmp - "$tmp/expected-package-tree.inventory"
        mkdir -p "$tmp/modules-expected"
        while IFS= read -r module_path; do
            evidence_module_path="$(m0_package_to_evidence_module_path "$module_path")"
            actual="$tmp/kernel/$module_path"
            expected="$tmp/modules-expected/$module_path"
            mkdir -p "$(dirname "$expected")"
            cp "/evidence/modules/$evidence_module_path" "$expected"
            strip --strip-debug "$expected"
            cmp "$expected" "$actual"
            actual_file_type="$(file "$actual")"
            grep -Eiq "ELF 64-bit.*(ARM aarch64|aarch64)" <<< "$actual_file_type"
            actual_vermagic="$(modinfo -F vermagic "$actual")"
            grep -Fq "$kver" <<< "$actual_vermagic"
        done < "$tmp/package-modules.inventory"
        gzip -t "$packaged_tree/vmlinuz"
        gzip -dc "$packaged_tree/vmlinuz" | cmp - /evidence/Image
        test "$(cat "$packaged_tree/pkgbase")" = "$LINUX_PKGBASE"
        for metadata_name in modules.builtin modules.builtin.modinfo modules.order; do
            cmp "$packaged_tree/$metadata_name" "/evidence/modules/lib/modules/$kver/$metadata_name"
        done
        diff -qr "$packaged_tree/dtb" /evidence/dtbs-install
        extract_member "usr/lib/modules/$kver/build/.config" "$headers" > "$tmp/config"
        extract_member "usr/lib/modules/$kver/build/System.map" "$headers" > "$tmp/System.map"
        cmp "$tmp/config" /evidence/config
        cmp "$tmp/System.map" /evidence/System.map
        # Extract both header sources inside the pinned Linux container.  The
        # evidence archive is the canonical case-sensitive headers_install
        # result; compare the API package tree byte-for-byte, including names
        # that differ only by case.
        mkdir "$tmp/evidence-headers" "$tmp/api"
        header_paths="$(bsdtar -tf /evidence/headers.tar | sed "s#^\./##")"
        while IFS= read -r header_path; do
            [[ "$header_path" != /* ]]
            ! grep -Eq "(^|/)\.\.?(/|$)" <<< "$header_path"
            case "$header_path" in
                usr|usr/|usr/include|usr/include/|usr/include/*) ;;
                *) printf "Unsafe evidence headers member: %s\\n" "$header_path" >&2; exit 1 ;;
            esac
            [[ "$header_path" != *[[:space:]]* ]]
        done <<< "$header_paths"
        while IFS= read -r header_verbose; do
            case "${header_verbose:0:1}" in
                -|d) ;;
                *) printf "Non-file/non-directory evidence header: %s\\n" "$header_verbose" >&2; exit 1 ;;
            esac
        done < <(bsdtar -tvf /evidence/headers.tar)
        bsdtar -xf /evidence/headers.tar -C "$tmp/evidence-headers"
        test -d "$tmp/evidence-headers/usr/include"
        test -s "$tmp/evidence-headers/usr/include/linux/kernel.h"
        test -z "$(find -P "$tmp/evidence-headers" ! -type f ! -type d -print -quit)"
        (cd "$tmp/evidence-headers"; find usr/include -type f -printf "%P\\n" | sed "s#^#usr/include/#" | LC_ALL=C sort) | cmp - /evidence/headers.inventory
        api_archive_paths="$(bsdtar -tf "$api" | sed "s#^\./##")"
        printf "%s\\n" "$api_archive_paths" | LC_ALL=C sort -u | cmp - <(printf "%s\\n" "$api_archive_paths" | LC_ALL=C sort)
        while IFS= read -r api_path; do
            [[ "$api_path" != /* ]]
            ! grep -Eq "(^|/)\.\.?(/|$)" <<< "$api_path"
            case "$api_path" in
                .PKGINFO|.BUILDINFO|.MTREE|usr|usr/|usr/include|usr/include/|usr/include/*) ;;
                *) printf "Unexpected API package member: %s\\n" "$api_path" >&2; exit 1 ;;
            esac
            [[ "$api_path" != *[[:space:]]* ]]
        done <<< "$api_archive_paths"
        while IFS= read -r api_verbose; do
            case "${api_verbose:0:1}" in
                -|d) ;;
                *) printf "Non-file/non-directory API member: %s\\n" "$api_verbose" >&2; exit 1 ;;
            esac
        done < <(bsdtar -tvf "$api")
        bsdtar -xf "$api" -C "$tmp/api"
        test -d "$tmp/api/usr/include"
        test -z "$(find -P "$tmp/api" ! -type f ! -type d -print -quit)"
        (cd "$tmp/api"; find usr/include -type f -printf "%P\\n" | sed "s#^#usr/include/#" | LC_ALL=C sort) | cmp - /evidence/headers.inventory
        diff -qr "$tmp/api/usr/include" "$tmp/evidence-headers/usr/include"
        extract_member "usr/src/debug/$LINUX_PKGBASE/vmlinux" "$debug" > "$tmp/vmlinux"
        cmp "$tmp/vmlinux" /evidence/vmlinux
    '
printf 'linux-packages.baseline=verified\n'
