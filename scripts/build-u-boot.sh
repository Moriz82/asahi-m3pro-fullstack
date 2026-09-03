#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
readonly source_volume="${SOURCE_VOLUME_OVERRIDE:-${SOURCE_VOLUME}}"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
m0_validate_output_root "$project_root"
readonly output_root="$MILESTONE0_OUTPUT_ROOT"

for value in BASE_IMAGE DEBIAN_SNAPSHOT RUST_VERSION RUSTUP_VERSION RUSTUP_INIT_SHA256 BUILD_IMAGE SOURCE_VOLUME UBOOT_URL UBOOT_REF UBOOT_COMMIT UBOOT_SOURCE_TREE_COMMIT UBOOT_DEFCONFIG UBOOT_UPSTREAM_URL UBOOT_UPSTREAM_REF UBOOT_UPSTREAM_COMMIT UBOOT_PATCH_SERIES UBOOT_PATCH_SERIES_SHA256; do
    test -n "${!value:-}" || {
        printf 'Missing configuration value: %s\n' "$value" >&2
        exit 1
    }
done
[[ "$UBOOT_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$UBOOT_SOURCE_TREE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$UBOOT_UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$UBOOT_REF" =~ ^[A-Za-z0-9._/-]+$ ]]
[[ "$UBOOT_UPSTREAM_REF" =~ ^[A-Za-z0-9._/-]+$ ]]
command -v docker >/dev/null
docker info >/dev/null
test "$(sha256sum "${project_root}/patches/u-boot/${UBOOT_PATCH_SERIES}" | awk '{print $1}')" = \
    "$UBOOT_PATCH_SERIES_SHA256"

readonly cache_dir="${output_root}/cache"
readonly mirror="${cache_dir}/u-boot.git"
readonly bundle="${cache_dir}/u-boot.bundle"
mkdir -p "$cache_dir"
if [[ ! -d "$mirror" ]]; then
    git clone --mirror "$UBOOT_URL" "$mirror"
else
    test "$(git -C "$mirror" remote get-url origin)" = "$UBOOT_URL"
    git -C "$mirror" fetch --prune origin '+refs/heads/*:refs/heads/*'
fi
if git -C "$mirror" remote get-url upstream >/dev/null 2>&1; then
    test "$(git -C "$mirror" remote get-url upstream)" = "$UBOOT_UPSTREAM_URL"
else
    git -C "$mirror" remote add upstream "$UBOOT_UPSTREAM_URL"
fi
git -C "$mirror" fetch upstream \
    "+refs/tags/${UBOOT_UPSTREAM_REF}:refs/tags/${UBOOT_UPSTREAM_REF}"
test "$(git -C "$mirror" rev-parse "refs/heads/${UBOOT_REF}")" = "$UBOOT_COMMIT"
test "$(git -C "$mirror" rev-parse "refs/tags/${UBOOT_UPSTREAM_REF}^{}")" = \
    "$UBOOT_UPSTREAM_COMMIT"
git -C "$mirror" merge-base --is-ancestor "$UBOOT_UPSTREAM_COMMIT" "$UBOOT_COMMIT"
git -C "$mirror" bundle create "${bundle}.tmp" "refs/heads/${UBOOT_REF}"
git -C "$mirror" bundle verify "${bundle}.tmp" >/dev/null
mv "${bundle}.tmp" "$bundle"

docker build \
    --provenance=false \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "DEBIAN_SNAPSHOT=${DEBIAN_SNAPSHOT}" \
    --build-arg "RUST_VERSION=${RUST_VERSION}" \
    --build-arg "RUSTUP_INIT_SHA256=${RUSTUP_INIT_SHA256}" \
    --build-arg "RUSTUP_VERSION=${RUSTUP_VERSION}" \
    --file "${project_root}/build/Containerfile" \
    --tag "$BUILD_IMAGE" \
    "${project_root}/build"

test "$(docker volume inspect --format '{{ index .Labels "com.moriz.project" }}' "$source_volume")" = \
    asahi-m3pro-fullstack
readonly image_id="$(docker image inspect --format '{{.Id}}' "$BUILD_IMAGE")"

docker run --rm \
    --env "BUILD_IMAGE=${BUILD_IMAGE}" \
    --env "BUILD_IMAGE_ID=${image_id}" \
    --env "DEBIAN_SNAPSHOT=${DEBIAN_SNAPSHOT}" \
    --env "UBOOT_COMMIT=${UBOOT_COMMIT}" \
    --env "UBOOT_SOURCE_TREE_COMMIT=${UBOOT_SOURCE_TREE_COMMIT}" \
    --env "UBOOT_DEFCONFIG=${UBOOT_DEFCONFIG}" \
    --env "UBOOT_REF=${UBOOT_REF}" \
    --env "UBOOT_URL=${UBOOT_URL}" \
    --env "RUSTUP_INIT_SHA256=${RUSTUP_INIT_SHA256}" \
    --env "RUSTUP_VERSION=${RUSTUP_VERSION}" \
    --env "UBOOT_UPSTREAM_COMMIT=${UBOOT_UPSTREAM_COMMIT}" \
    --env "UBOOT_UPSTREAM_REF=${UBOOT_UPSTREAM_REF}" \
    --env "UBOOT_UPSTREAM_URL=${UBOOT_UPSTREAM_URL}" \
    --env "UBOOT_PATCH_SERIES=${UBOOT_PATCH_SERIES}" \
    --env "UBOOT_PATCH_SERIES_SHA256=${UBOOT_PATCH_SERIES_SHA256}" \
    --mount "type=bind,src=${bundle},dst=/inputs/u-boot.bundle,readonly" \
    --mount "type=bind,src=${project_root}/patches/u-boot,dst=/inputs/u-boot-patches,readonly" \
    --mount "type=volume,src=${source_volume},dst=/workspace" \
    --mount "type=bind,src=${output_root},dst=/out" \
    "$BUILD_IMAGE" \
    bash -Eeuo pipefail -c '
        exec 9>/workspace/.milestone0-build.lock
        flock -n 9 || { printf "Another Milestone 0 build owns the source volume\n" >&2; exit 1; }
        readonly repository=/workspace/src/u-boot
        readonly component_build=/workspace/build/u-boot
        readonly filesystem_type="$(stat -f -c %T /workspace)"

        case "$filesystem_type" in
            apfs|hfs|hfsplus)
                printf "Workspace is not on a Linux filesystem: %s\n" "$filesystem_type" >&2
                exit 1
                ;;
        esac

        install -d /workspace/src /workspace/build /out/milestone0/u-boot
        if [[ -e "$repository" && ! -d "${repository}/.git" ]]; then
            rmdir "$repository"
        fi
        if [[ ! -d "${repository}/.git" ]]; then
            git clone /inputs/u-boot.bundle "$repository"
            git -C "$repository" remote set-url origin "$UBOOT_URL"
        fi

        test "$(git -C "$repository" remote get-url origin)" = "$UBOOT_URL"
        test -z "$(git -C "$repository" status --porcelain --untracked-files=all)"
        git -C "$repository" fetch /inputs/u-boot.bundle "$UBOOT_COMMIT"
        git -C "$repository" checkout --detach "$UBOOT_COMMIT"
        test "$(git -C "$repository" rev-parse HEAD)" = "$UBOOT_COMMIT"
        readonly source_epoch="$(git -C "$repository" show -s --format=%ct "$UBOOT_COMMIT")"
        test "$(sha256sum "/inputs/u-boot-patches/$UBOOT_PATCH_SERIES" | cut -d " " -f1)" = \
            "$UBOOT_PATCH_SERIES_SHA256"
        git -C "$repository" -c user.name="M3 Pro Linux downstream" \
            -c user.email=m3pro-linux@localhost am --committer-date-is-author-date \
            "/inputs/u-boot-patches/$UBOOT_PATCH_SERIES"
        test "$(git -C "$repository" rev-parse HEAD)" = "$UBOOT_SOURCE_TREE_COMMIT"
        test -z "$(git -C "$repository" status --porcelain --untracked-files=all)"
        grep -Fq '\''of_machine_is_compatible("apple,t6030")'\'' \
            "${repository}/arch/arm/mach-apple/board.c"
        grep -Fq '\''mem_map = t6030_mem_map;'\'' \
            "${repository}/arch/arm/mach-apple/board.c"
        grep -Fq '\''{ .compatible = "apple,t8122-atcphy" },'\'' \
            "${repository}/drivers/phy/phy-apple-atc.c"

        make -C "$repository" O="$component_build" mrproper
        make -C "$repository" O="$component_build" \
            CROSS_COMPILE=aarch64-linux-gnu- "$UBOOT_DEFCONFIG"

        export KBUILD_BUILD_HOST=milestone0
        export KBUILD_BUILD_TIMESTAMP="$(date -u --date="@${source_epoch}" \
            "+%Y-%m-%d %H:%M:%S UTC")"
        export KBUILD_BUILD_USER=builder
        export SOURCE_DATE_EPOCH="$source_epoch"

        readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]")"
        readonly stage="/out/milestone0/u-boot/.${run_id}.tmp"
        readonly destination="/out/milestone0/u-boot/${run_id}"
        readonly latest="/out/milestone0/u-boot/latest"
        readonly latest_tmp="/out/milestone0/u-boot/.latest.${run_id}.tmp"
        if [[ -e "$stage" || -L "$stage" || -e "$destination" || -L "$destination" || -e "$latest_tmp" || -L "$latest_tmp" ]] ||
            [[ -e "$latest" && ! -L "$latest" ]]; then
            printf "Refusing colliding u-boot publication path for run %s\n" "$run_id" >&2
            exit 1
        fi
        mkdir "$stage"

        LC_ALL=C make -C "$repository" O="$component_build" \
            CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" \
            2>&1 | tee "${stage}/build.log"

        install -m 0644 "${component_build}/u-boot" "${stage}/u-boot"
        install -m 0644 "${component_build}/u-boot-nodtb.bin" \
            "${stage}/u-boot-nodtb.bin"
        install -m 0644 "${component_build}/.config" "${stage}/config"
        aarch64-linux-gnu-strings "${component_build}/u-boot" \
            | grep -E '\''^apple,t603(0|1|4)$'\'' \
            | LC_ALL=C sort -u > "${stage}/supported-socs.txt"
        aarch64-linux-gnu-strings "${component_build}/u-boot" \
            | grep -E '\''^apple,t(6000|8103|8122)-atcphy$'\'' \
            | LC_ALL=C sort -u > "${stage}/supported-atc-phys.txt"
        dpkg-query -W -f="\${Package}=\${Version}\n" | LC_ALL=C sort > "${stage}/packages.txt"

        {
            printf "format=1\n"
            printf "built_utc=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf "target=Mac15,6/J514s/T6030\n"
            printf "component=u-boot\n"
            printf "source_url=%s\n" "$UBOOT_URL"
            printf "source_commit=%s\n" "$UBOOT_COMMIT"
            printf "source_tree_commit=%s\n" "$UBOOT_SOURCE_TREE_COMMIT"
            printf "source_ref=%s\n" "$UBOOT_REF"
            printf "upstream_url=%s\n" "$UBOOT_UPSTREAM_URL"
            printf "upstream_ref=%s\n" "$UBOOT_UPSTREAM_REF"
            printf "upstream_commit=%s\n" "$UBOOT_UPSTREAM_COMMIT"
            printf "patch_series=%s\n" "$UBOOT_PATCH_SERIES"
            printf "patch_series_sha256=%s\n" "$UBOOT_PATCH_SERIES_SHA256"
            printf "source_describe=%s\n" "$(git -C "$repository" describe --always --dirty)"
            printf "source_clean=%s\n" "$(test -z "$(git -C "$repository" status --porcelain --untracked-files=all)" && printf true || printf false)"
            printf "defconfig=%s\n" "$UBOOT_DEFCONFIG"
            printf "t6030_memory_map=true\n"
            printf "t8122_atc_phy_match=true\n"
            printf "source_date_epoch=%s\n" "$source_epoch"
            printf "workspace_filesystem=%s\n" "$filesystem_type"
            printf "debian_snapshot=%s\n" "$DEBIAN_SNAPSHOT"
            printf "rustup_version=%s\n" "$RUSTUP_VERSION"
            printf "rustup_init_sha256=%s\n" "$RUSTUP_INIT_SHA256"
            printf "container_image=%s\n" "$BUILD_IMAGE"
            printf "container_image_id=%s\n" "$BUILD_IMAGE_ID"
            printf "gcc=%s\n" "$(aarch64-linux-gnu-gcc -dumpfullversion)"
            printf "ld=%s\n" "$(aarch64-linux-gnu-ld --version | head -n 1)"
            printf "make=%s\n" "$(make --version | head -n 1)"
        } > "${stage}/manifest.txt"

        grep -Fx "source_clean=true" "${stage}/manifest.txt" >/dev/null
        file "${stage}/u-boot" "${stage}/u-boot-nodtb.bin" > "${stage}/file.txt"
        (
            cd "$stage"
            sha256sum build.log config file.txt manifest.txt packages.txt \
                supported-atc-phys.txt supported-socs.txt u-boot u-boot-nodtb.bin > SHA256SUMS
        )

        mv "$stage" "$destination"
        ln -s "$run_id" "$latest_tmp"
        mv -Tf "$latest_tmp" "$latest"
        printf "u-boot.baseline=%s\n" "$destination"
    '

"${project_root}/scripts/verify-u-boot.sh" "${output_root}/milestone0/u-boot/latest"
