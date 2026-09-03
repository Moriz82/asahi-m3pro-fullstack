#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
source "${project_root}/scripts/lib/atomic-symlink.sh"
m0_validate_output_root "$project_root"
readonly output_root="$MILESTONE0_OUTPUT_ROOT"
readonly evidence_candidate="${1:-${output_root}/milestone0/linux-full/latest}"
evidence="$(cd "$evidence_candidate" && pwd -P)" || { printf 'Missing Linux full evidence.\n' >&2; exit 1; }
readonly evidence
[[ "$(dirname "$evidence")" == "${output_root}/milestone0/linux-full" ]] || { printf 'Unsafe Linux full evidence binding.\n' >&2; exit 1; }
[[ "$(basename "$evidence")" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && "$(basename "$evidence")" != latest ]] || { printf 'Invalid Linux full evidence run.\n' >&2; exit 1; }
readonly package_base="${output_root}/milestone0/linux-packages"
readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
readonly stage="${package_base}/.${run_id}.tmp"
readonly destination="${package_base}/${run_id}"
readonly latest="${package_base}/latest"
readonly latest_tmp="${package_base}/.latest.${run_id}.tmp"
readonly pkg_cache="${output_root}/cache/PKGBUILDs.git"
readonly arch_image="${ARCH_BUILD_IMAGE}"
readonly source_volume="${SOURCE_VOLUME_OVERRIDE:-${SOURCE_VOLUME}}"
readonly package_closure_lib="${project_root}/scripts/lib/milestone0-package-closure.sh"

"${project_root}/scripts/verify-linux-full.sh" "$evidence"
command -v docker >/dev/null
docker info >/dev/null
test "$(docker volume inspect --format '{{ index .Labels "com.moriz.project" }}' "$source_volume")" = asahi-m3pro-fullstack
mkdir -p "$output_root/cache" "$package_base"
if [[ -e "$stage" || -L "$stage" || -e "$destination" || -L "$destination" || -e "$latest_tmp" || -L "$latest_tmp" ]] ||
    [[ -e "$latest" && ! -L "$latest" ]]; then
    printf 'Refusing colliding linux-package publication path for run %s\n' "$run_id" >&2
    exit 1
fi
mkdir "$stage"

if [[ ! -d "$pkg_cache" ]]; then
    git clone --bare --depth=1 --branch "$LINUX_PKG_FORK_REF" "$LINUX_PKG_FORK_URL" "$pkg_cache"
else
    test "$(git -C "$pkg_cache" remote get-url origin)" = "$LINUX_PKG_FORK_URL"
    git -C "$pkg_cache" fetch --depth=1 origin "+refs/heads/${LINUX_PKG_FORK_REF}:refs/heads/${LINUX_PKG_FORK_REF}"
fi
if git -C "$pkg_cache" remote get-url upstream >/dev/null 2>&1; then
    test "$(git -C "$pkg_cache" remote get-url upstream)" = "$LINUX_PKG_UPSTREAM_URL"
else
    git -C "$pkg_cache" remote add upstream "$LINUX_PKG_UPSTREAM_URL"
fi
git -C "$pkg_cache" fetch --depth=1 upstream "+refs/heads/${LINUX_PKG_UPSTREAM_REF}:refs/remotes/upstream/${LINUX_PKG_UPSTREAM_REF}"
test "$(git -C "$pkg_cache" rev-parse "refs/heads/${LINUX_PKG_FORK_REF}")" = "$LINUX_PKG_FORK_COMMIT"
test "$(git -C "$pkg_cache" rev-parse "refs/remotes/upstream/${LINUX_PKG_UPSTREAM_REF}")" = "$LINUX_PKG_UPSTREAM_COMMIT"
ancestry_depth=1
while ! git -C "$pkg_cache" merge-base --is-ancestor "$LINUX_PKG_UPSTREAM_COMMIT" "$LINUX_PKG_FORK_COMMIT"; do
    test "$(git -C "$pkg_cache" rev-parse --is-shallow-repository)" = true
    test "$ancestry_depth" -lt 8192
    ancestry_depth=$((ancestry_depth * 2))
    git -C "$pkg_cache" fetch --depth="$ancestry_depth" origin "+refs/heads/${LINUX_PKG_FORK_REF}:refs/heads/${LINUX_PKG_FORK_REF}"
done

docker build --provenance=false \
    --build-arg "BC_VERSION=1.08.2-1" \
    --build-arg "RSYNC_VERSION=3.5.0-1" \
    --build-arg "PAHOLE_VERSION=1:1.31-2" \
    --build-arg "RUST_VERSION=${RUST_VERSION}" \
    --build-arg "RUSTUP_VERSION=${RUSTUP_VERSION}" \
    --build-arg "RUSTUP_INIT_SHA256=${RUSTUP_INIT_SHA256}" \
    --file "${project_root}/build/Containerfile.arch" --tag "$arch_image" "${project_root}/build"
readonly arch_image_id="$(docker image inspect --format '{{.Id}}' "$arch_image")"
readonly package_root_abs="$(cd "$stage" && pwd -P)"

readonly source_tree_commit="$(sed -n 's/^source_tree_commit=//p' "$evidence/manifest.txt")"
test "$source_tree_commit" = "$LINUX_SOURCE_TREE_COMMIT"
readonly kernelrelease="$(cat "$evidence/kernelrelease")"
readonly m0_run_id="$(basename "$evidence")"
readonly m0_manifest_sha256="$(shasum -a 256 "$evidence/manifest.txt" | awk '{print $1}')"
[[ "$kernelrelease" =~ ^[0-9A-Za-z._+-]+$ ]]
test "$kernelrelease" = "$LINUX_PKGVER"
docker run --rm --env "LINUX_SOURCE_TREE_COMMIT=${source_tree_commit}" \
    --mount "type=volume,src=${source_volume},dst=/workspace" \
    "$arch_image" bash -Eeuo pipefail -c '
        test "$(git -C /workspace/src/linux rev-parse HEAD)" = "$LINUX_SOURCE_TREE_COMMIT"
        test -z "$(git -C /workspace/src/linux status --porcelain --untracked-files=all)"
    '

docker run --rm \
    --env "ARCH_BUILD_IMAGE=${arch_image}" --env "ARCH_IMAGE_ID=${arch_image_id}" \
    --env "LINUX_COMMIT=${LINUX_COMMIT}" --env "LINUX_SOURCE_TREE_COMMIT=${source_tree_commit}" \
    --env "LINUX_KERNELRELEASE=${kernelrelease}" \
    --env "M0_RUN_ID=${m0_run_id}" --env "M0_MANIFEST_SHA256=${m0_manifest_sha256}" \
    --env "LINUX_PATCH_SERIES=${LINUX_PATCH_SERIES}" --env "LINUX_PATCH_SERIES_SHA256=${LINUX_PATCH_SERIES_SHA256}" \
    --env "LINUX_PKGBASE=${LINUX_PKGBASE}" \
    --env "LINUX_PKGVER=${LINUX_PKGVER}" --env "LINUX_PKGREL=${LINUX_PKGREL}" \
    --env "LINUX_PKG_FORK_URL=${LINUX_PKG_FORK_URL}" --env "LINUX_PKG_FORK_REF=${LINUX_PKG_FORK_REF}" --env "LINUX_PKG_FORK_COMMIT=${LINUX_PKG_FORK_COMMIT}" \
    --env "LINUX_PKG_UPSTREAM_URL=${LINUX_PKG_UPSTREAM_URL}" --env "LINUX_PKG_UPSTREAM_REF=${LINUX_PKG_UPSTREAM_REF}" --env "LINUX_PKG_UPSTREAM_COMMIT=${LINUX_PKG_UPSTREAM_COMMIT}" \
    --env "SOURCE_DATE_EPOCH=$(sed -n 's/^source_date_epoch=//p' "$evidence/manifest.txt")" \
    --mount "type=volume,src=${source_volume},dst=/workspace" \
    --mount "type=bind,src=${package_root_abs},dst=/out/linux-packages" \
    --mount "type=bind,src=${package_closure_lib},dst=/verify/milestone0-package-closure.sh,readonly" \
    "$arch_image" bash -Eeuo pipefail -c '
        source /verify/milestone0-package-closure.sh
        exec 9>/workspace/.milestone0-build.lock
        flock -n 9 || { printf "Another Milestone 0 build owns the source volume\n" >&2; exit 1; }
        readonly repository=/workspace/src/linux
        readonly component_build=/workspace/build/linux-full
        readonly out=/out/linux-packages
        readonly source_epoch="$SOURCE_DATE_EPOCH"
        readonly pkg_stage_root="$component_build/pacman/$LINUX_PKGBASE/pkg"
        readonly build_timestamp="$(date -u --date="@${source_epoch}" "+%Y-%m-%d %H:%M:%S UTC")"
        test "$(git -C "$repository" rev-parse HEAD)" = "$LINUX_SOURCE_TREE_COMMIT"
        test -z "$(git -C "$repository" status --porcelain --untracked-files=all)"
        test -s "$component_build/.config"
        rm -f "$component_build"/*.pkg.tar.zst "$component_build"/*.pkg.tar.xz "$component_build/.version"
        chown -R makepkg:makepkg "$component_build"
        runuser -u makepkg -- env HOME=/home/makepkg LANG=C.UTF-8 LC_ALL=C.UTF-8 \
            PATH=/opt/cargo/bin:/opt/dtschema/bin:/usr/local/sbin:/usr/local/bin:/usr/bin \
            RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo LIBCLANG_PATH=/usr/lib \
            PKGEXT=.pkg.tar.zst \
            SOURCE_DATE_EPOCH="$source_epoch" KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=milestone0 \
            KBUILD_BUILD_TIMESTAMP="$build_timestamp" \
            PACMAN_PKGBASE="$LINUX_PKGBASE" PACMAN_EXTRAPACKAGES="headers api-headers debug" \
            make -j"$(nproc)" -C "$repository" O="$component_build" ARCH=arm64 W=1 \
                KERNELRELEASE="$LINUX_KERNELRELEASE" pacman-pkg
        test "$(cat "$component_build/.version")" = "$LINUX_PKGREL"
        mapfile -t packages < <(find "$component_build" -maxdepth 1 -type f -name "*.pkg.tar.zst" -print | LC_ALL=C sort)
        test "${#packages[@]}" -eq 4
        for package in "${packages[@]}"; do
            cp -a "$package" "$out/"
        done
        printf "format=1\nsource_commit=%s\nsource_tree_commit=%s\nm0_run_id=%s\nm0_manifest_sha256=%s\nlinux_patch_series=%s\nlinux_patch_series_sha256=%s\nlinux_pkgbase=%s\nlinux_pkgver=%s\nlinux_pkgrel=%s\npkgbuild_fork_url=%s\npkgbuild_fork_ref=%s\npkgbuild_fork_commit=%s\npkgbuild_upstream_url=%s\npkgbuild_upstream_ref=%s\npkgbuild_upstream_commit=%s\narch_image=%s\narch_image_id=%s\nsource_date_epoch=%s\nmethod=native-kernel-pacman-pkg\nkernel_image_transform=gzip\nkernel_image_verification=decompressed-byte-equality\nmodule_transform=install-mod-strip-1\nmodule_metadata_policy=depmod-generated-on-install\n" \
            "$LINUX_COMMIT" "$LINUX_SOURCE_TREE_COMMIT" "$M0_RUN_ID" "$M0_MANIFEST_SHA256" "$LINUX_PATCH_SERIES" "$LINUX_PATCH_SERIES_SHA256" "$LINUX_PKGBASE" "$LINUX_PKGVER" "$LINUX_PKGREL" \
            "$LINUX_PKG_FORK_URL" "$LINUX_PKG_FORK_REF" "$LINUX_PKG_FORK_COMMIT" \
            "$LINUX_PKG_UPSTREAM_URL" "$LINUX_PKG_UPSTREAM_REF" "$LINUX_PKG_UPSTREAM_COMMIT" \
            "$ARCH_BUILD_IMAGE" "$ARCH_IMAGE_ID" "$source_epoch" > "$out/manifest.txt"
        pacman -Q > "$out/pacman-Q.txt"
        for package in "$out"/*.pkg.tar.zst; do
            name="$(basename "$package")"
            pacman -Qip "$package" > "$out/$name.pkginfo"
            pacman -Qlp "$package" > "$out/$name.files"
            bsdtar -tf "$package" | LC_ALL=C sort > "$out/$name.inventory"
            package_name="$(bsdtar -xOf "$package" .PKGINFO | sed -n "s/^pkgname = //p")"
            test -n "$package_name"
            m0_package_closure_from_tree "$pkg_stage_root/$package_name" "$out/$name.closure"
            m0_package_closure_add_makepkg_metadata "$out/$name.closure"
        done
        (cd "$out"; sha256sum *.pkg.tar.zst *.pkginfo *.files *.inventory *.closure manifest.txt pacman-Q.txt > SHA256SUMS)
    '

"${project_root}/scripts/verify-linux-package.sh" "$stage" "$evidence"
if [[ -e "$destination" || -L "$destination" ]]; then
    printf 'Refusing colliding linux-package destination for run %s\n' "$run_id" >&2
    exit 1
fi
mv "$stage" "$destination"
atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"
