#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"

for value in BASE_IMAGE DEBIAN_SNAPSHOT RUST_VERSION RUSTUP_VERSION RUSTUP_INIT_SHA256 BUILD_IMAGE SOURCE_VOLUME LINUX_URL LINUX_REF LINUX_COMMIT LINUX_DEFCONFIG LINUX_DTB LINUX_UPSTREAM_URL LINUX_UPSTREAM_REF LINUX_UPSTREAM_COMMIT; do
    test -n "${!value:-}" || {
        printf 'Missing configuration value: %s\n' "$value" >&2
        exit 1
    }
done

[[ "$LINUX_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$LINUX_UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$LINUX_REF" =~ ^[A-Za-z0-9._/-]+$ ]]
[[ "$LINUX_UPSTREAM_REF" =~ ^[A-Za-z0-9._/-]+$ ]]
[[ "$LINUX_DTB" =~ ^apple/[A-Za-z0-9._+-]+\.dtb$ ]]
command -v docker >/dev/null
docker info >/dev/null

readonly cache_dir="${project_root}/out/cache"
readonly mirror="${cache_dir}/linux.git"
mkdir -p "$cache_dir"
if [[ ! -d "$mirror" ]]; then
    git clone --bare --depth=1 --branch "$LINUX_REF" "$LINUX_URL" "$mirror"
else
    test "$(git -C "$mirror" remote get-url origin)" = "$LINUX_URL"
    git -C "$mirror" fetch --depth=1 origin \
        "+refs/heads/${LINUX_REF}:refs/heads/${LINUX_REF}"
fi
if git -C "$mirror" remote get-url upstream >/dev/null 2>&1; then
    test "$(git -C "$mirror" remote get-url upstream)" = "$LINUX_UPSTREAM_URL"
else
    git -C "$mirror" remote add upstream "$LINUX_UPSTREAM_URL"
fi
git -C "$mirror" fetch --depth=1 upstream \
    "+refs/heads/${LINUX_UPSTREAM_REF}:refs/remotes/upstream/${LINUX_UPSTREAM_REF}"
test "$(git -C "$mirror" rev-parse "refs/heads/${LINUX_REF}")" = "$LINUX_COMMIT"
test "$(git -C "$mirror" rev-parse "refs/remotes/upstream/${LINUX_UPSTREAM_REF}")" = \
    "$LINUX_UPSTREAM_COMMIT"
readonly max_ancestry_depth=8192
ancestry_depth=1
while ! git -C "$mirror" merge-base --is-ancestor \
    "$LINUX_UPSTREAM_COMMIT" "$LINUX_COMMIT"; do
    test "$(git -C "$mirror" rev-parse --is-shallow-repository)" = true || {
        printf 'Configured upstream commit is not an ancestor of the Linux fork commit\n' >&2
        exit 1
    }
    (( ancestry_depth < max_ancestry_depth )) || {
        printf 'Linux ancestry exceeds the %s-commit verification limit\n' \
            "$max_ancestry_depth" >&2
        exit 1
    }
    ancestry_depth="$((ancestry_depth * 2))"
    git -C "$mirror" fetch --depth="$ancestry_depth" origin \
        "+refs/heads/${LINUX_REF}:refs/heads/${LINUX_REF}"
done

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

test "$(docker volume inspect --format '{{ index .Labels "com.moriz.project" }}' "$SOURCE_VOLUME")" = \
    asahi-m3pro-fullstack
readonly image_id="$(docker image inspect --format '{{.Id}}' "$BUILD_IMAGE")"

docker run --rm \
    --env "BUILD_IMAGE=${BUILD_IMAGE}" \
    --env "BUILD_IMAGE_ID=${image_id}" \
    --env "DEBIAN_SNAPSHOT=${DEBIAN_SNAPSHOT}" \
    --env "LINUX_COMMIT=${LINUX_COMMIT}" \
    --env "LINUX_DEFCONFIG=${LINUX_DEFCONFIG}" \
    --env "LINUX_DTB=${LINUX_DTB}" \
    --env "LINUX_REF=${LINUX_REF}" \
    --env "LINUX_URL=${LINUX_URL}" \
    --env "RUSTUP_INIT_SHA256=${RUSTUP_INIT_SHA256}" \
    --env "RUSTUP_VERSION=${RUSTUP_VERSION}" \
    --env "LINUX_UPSTREAM_COMMIT=${LINUX_UPSTREAM_COMMIT}" \
    --env "LINUX_UPSTREAM_REF=${LINUX_UPSTREAM_REF}" \
    --env "LINUX_UPSTREAM_URL=${LINUX_UPSTREAM_URL}" \
    --mount "type=bind,src=${mirror},dst=/inputs/linux.git,readonly" \
    --mount "type=volume,src=${SOURCE_VOLUME},dst=/workspace" \
    --mount "type=bind,src=${project_root}/out,dst=/out" \
    "$BUILD_IMAGE" \
    bash -Eeuo pipefail -c '
        readonly repository=/workspace/src/linux
        readonly component_build=/workspace/build/linux-dtb
        readonly filesystem_type="$(stat -f -c %T /workspace)"
        readonly dtb_path="${component_build}/arch/arm64/boot/dts/${LINUX_DTB}"

        case "$filesystem_type" in
            apfs|hfs|hfsplus)
                printf "Workspace is not on a Linux filesystem: %s\n" "$filesystem_type" >&2
                exit 1
                ;;
        esac

        install -d /workspace/src /workspace/build /out/milestone0/linux-dtb
        if [[ -e "$repository" && ! -d "${repository}/.git" ]]; then
            rmdir "$repository"
        fi
        if [[ ! -d "${repository}/.git" ]]; then
            git clone --no-local /inputs/linux.git "$repository"
            git -C "$repository" remote set-url origin "$LINUX_URL"
        fi

        test "$(git -C "$repository" remote get-url origin)" = "$LINUX_URL"
        test -z "$(git -C "$repository" status --porcelain --untracked-files=all)"
        git -C "$repository" fetch --depth=1 /inputs/linux.git "$LINUX_COMMIT"
        git -C "$repository" checkout --detach "$LINUX_COMMIT"
        test "$(git -C "$repository" rev-parse HEAD)" = "$LINUX_COMMIT"

        make -C "$repository" O="$component_build" ARCH=arm64 mrproper
        make -C "$repository" O="$component_build" ARCH=arm64 "$LINUX_DEFCONFIG"

        readonly source_epoch="$(git -C "$repository" show -s --format=%ct HEAD)"
        export KBUILD_BUILD_HOST=milestone0
        export KBUILD_BUILD_TIMESTAMP="@${source_epoch}"
        export KBUILD_BUILD_USER=builder
        export SOURCE_DATE_EPOCH="$source_epoch"

        readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)"
        readonly stage="/out/milestone0/linux-dtb/.${run_id}.tmp"
        readonly destination="/out/milestone0/linux-dtb/${run_id}"
        install -d "$stage"

        LC_ALL=C make -C "$repository" O="$component_build" ARCH=arm64 \
            CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" "$LINUX_DTB" \
            2>&1 | tee "${stage}/build.log"

        install -m 0644 "$dtb_path" "${stage}/t6030-j514s.dtb"
        install -m 0644 "${component_build}/.config" "${stage}/config"
        "${component_build}/scripts/dtc/dtc" -I dtb -O dts "$dtb_path" \
            > "${stage}/t6030-j514s.dts" 2> "${stage}/dtc.log"
        fdtget -t s "$dtb_path" / compatible > "${stage}/compatible.txt"
        fdtget -t s "$dtb_path" / model > "${stage}/model.txt"
        dpkg-query -W -f="\${Package}=\${Version}\n" | LC_ALL=C sort > "${stage}/packages.txt"

        {
            printf "format=1\n"
            printf "built_utc=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf "target=Mac15,6/J514s/T6030\n"
            printf "component=linux-dtb\n"
            printf "source_url=%s\n" "$LINUX_URL"
            printf "source_commit=%s\n" "$(git -C "$repository" rev-parse HEAD)"
            printf "source_ref=%s\n" "$LINUX_REF"
            printf "upstream_url=%s\n" "$LINUX_UPSTREAM_URL"
            printf "upstream_ref=%s\n" "$LINUX_UPSTREAM_REF"
            printf "upstream_commit=%s\n" "$LINUX_UPSTREAM_COMMIT"
            printf "source_describe=%s\n" "$(git -C "$repository" describe --always --dirty)"
            printf "source_clean=%s\n" "$(test -z "$(git -C "$repository" status --porcelain --untracked-files=all)" && printf true || printf false)"
            printf "kernel_version=%s\n" "$(make -s -C "$repository" O="$component_build" ARCH=arm64 kernelversion)"
            printf "defconfig=%s\n" "$LINUX_DEFCONFIG"
            printf "dtb_target=%s\n" "$LINUX_DTB"
            printf "source_date_epoch=%s\n" "$source_epoch"
            printf "workspace_filesystem=%s\n" "$filesystem_type"
            printf "debian_snapshot=%s\n" "$DEBIAN_SNAPSHOT"
            printf "rustup_version=%s\n" "$RUSTUP_VERSION"
            printf "rustup_init_sha256=%s\n" "$RUSTUP_INIT_SHA256"
            printf "container_image=%s\n" "$BUILD_IMAGE"
            printf "container_image_id=%s\n" "$BUILD_IMAGE_ID"
            printf "gcc=%s\n" "$(aarch64-linux-gnu-gcc -dumpfullversion)"
            printf "dtc=%s\n" "$("${component_build}/scripts/dtc/dtc" --version)"
            printf "make=%s\n" "$(make --version | head -n 1)"
        } > "${stage}/manifest.txt"

        grep -Fx "source_clean=true" "${stage}/manifest.txt" >/dev/null
        file "${stage}/t6030-j514s.dtb" > "${stage}/file.txt"
        (
            cd "$stage"
            sha256sum build.log compatible.txt config dtc.log file.txt manifest.txt \
                model.txt packages.txt t6030-j514s.dtb t6030-j514s.dts > SHA256SUMS
        )

        mv "$stage" "$destination"
        ln -sfn "$run_id" /out/milestone0/linux-dtb/latest
        printf "linux-dtb.baseline=%s\n" "$destination"
    '

"${project_root}/scripts/verify-linux-dtb.sh"
