#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"

for value in BASE_IMAGE DEBIAN_SNAPSHOT RUST_VERSION RUSTUP_VERSION RUSTUP_INIT_SHA256 BUILD_IMAGE SOURCE_VOLUME M1N1_URL M1N1_REF M1N1_COMMIT M1N1_ARTWORK_COMMIT M1N1_UPSTREAM_URL M1N1_UPSTREAM_REF M1N1_UPSTREAM_COMMIT; do
    test -n "${!value:-}" || {
        printf 'Missing configuration value: %s\n' "$value" >&2
        exit 1
    }
done

[[ "$M1N1_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$M1N1_ARTWORK_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$M1N1_UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$M1N1_REF" =~ ^[A-Za-z0-9._/-]+$ ]]
[[ "$M1N1_UPSTREAM_REF" =~ ^[A-Za-z0-9._/-]+$ ]]
command -v docker >/dev/null
docker info >/dev/null

readonly bundle_dir="${project_root}/out/cache"
readonly mirror="${bundle_dir}/m1n1.git"
readonly bundle="${bundle_dir}/m1n1.bundle"
mkdir -p "$bundle_dir"
if [[ ! -d "$mirror" ]]; then
    git clone --mirror "$M1N1_URL" "$mirror"
else
    test "$(git -C "$mirror" remote get-url origin)" = "$M1N1_URL"
    git -C "$mirror" fetch --prune origin '+refs/heads/*:refs/heads/*'
fi
if git -C "$mirror" remote get-url upstream >/dev/null 2>&1; then
    test "$(git -C "$mirror" remote get-url upstream)" = "$M1N1_UPSTREAM_URL"
else
    git -C "$mirror" remote add upstream "$M1N1_UPSTREAM_URL"
fi
git -C "$mirror" fetch upstream \
    "+refs/heads/${M1N1_UPSTREAM_REF}:refs/remotes/upstream/${M1N1_UPSTREAM_REF}"
test "$(git -C "$mirror" rev-parse "refs/heads/${M1N1_REF}")" = "$M1N1_COMMIT"
test "$(git -C "$mirror" rev-parse "refs/remotes/upstream/${M1N1_UPSTREAM_REF}")" = \
    "$M1N1_UPSTREAM_COMMIT"
git -C "$mirror" merge-base --is-ancestor "$M1N1_UPSTREAM_COMMIT" "$M1N1_COMMIT"
git -C "$mirror" bundle create "${bundle}.tmp" "refs/heads/${M1N1_REF}"
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

if ! docker volume inspect "$SOURCE_VOLUME" >/dev/null 2>&1; then
    docker volume create \
        --label com.moriz.project=asahi-m3pro-fullstack \
        --label com.moriz.purpose=milestone0-source \
        "$SOURCE_VOLUME" >/dev/null
fi

test "$(docker volume inspect --format '{{ index .Labels "com.moriz.project" }}' "$SOURCE_VOLUME")" = \
    asahi-m3pro-fullstack

readonly image_id="$(docker image inspect --format '{{.Id}}' "$BUILD_IMAGE")"
mkdir -p "${project_root}/out"

docker run --rm \
    --env "BUILD_IMAGE=${BUILD_IMAGE}" \
    --env "BUILD_IMAGE_ID=${image_id}" \
    --env "DEBIAN_SNAPSHOT=${DEBIAN_SNAPSHOT}" \
    --env "M1N1_ARTWORK_COMMIT=${M1N1_ARTWORK_COMMIT}" \
    --env "M1N1_COMMIT=${M1N1_COMMIT}" \
    --env "M1N1_REF=${M1N1_REF}" \
    --env "M1N1_URL=${M1N1_URL}" \
    --env "RUST_VERSION=${RUST_VERSION}" \
    --env "RUSTUP_INIT_SHA256=${RUSTUP_INIT_SHA256}" \
    --env "RUSTUP_VERSION=${RUSTUP_VERSION}" \
    --env "M1N1_UPSTREAM_COMMIT=${M1N1_UPSTREAM_COMMIT}" \
    --env "M1N1_UPSTREAM_REF=${M1N1_UPSTREAM_REF}" \
    --env "M1N1_UPSTREAM_URL=${M1N1_UPSTREAM_URL}" \
    --mount "type=bind,src=${bundle},dst=/inputs/m1n1.bundle,readonly" \
    --mount "type=volume,src=${SOURCE_VOLUME},dst=/workspace" \
    --mount "type=bind,src=${project_root}/out,dst=/out" \
    "$BUILD_IMAGE" \
    bash -Eeuo pipefail -c '
        readonly source_root=/workspace/src
        readonly build_root=/workspace/build
        readonly repository=${source_root}/m1n1
        readonly component_build=${build_root}/m1n1
        readonly filesystem_type="$(stat -f -c %T /workspace)"

        source_status() {
            git -C "$repository" status --porcelain --untracked-files=all -- . \
                ":(exclude)build"
        }

        case "$filesystem_type" in
            apfs|hfs|hfsplus)
                printf "Workspace is not on a Linux filesystem: %s\n" "$filesystem_type" >&2
                exit 1
                ;;
        esac

        install -d "$source_root" "$component_build" /out/milestone0/m1n1
        if [[ -e "$repository" && ! -d "${repository}/.git" ]]; then
            rmdir "$repository"
        fi
        if [[ ! -d "${repository}/.git" ]]; then
            git clone /inputs/m1n1.bundle "$repository"
            git -C "$repository" remote set-url origin "$M1N1_URL"
        fi

        test "$(git -C "$repository" remote get-url origin)" = "$M1N1_URL"
        test -z "$(source_status)"
        git -C "$repository" checkout --detach "$M1N1_COMMIT"
        git -C "$repository" submodule sync --recursive
        git -C "$repository" submodule update --init --recursive
        test "$(git -C "$repository" rev-parse HEAD)" = "$M1N1_COMMIT"
        test "$(git -C "${repository}/artwork" rev-parse HEAD)" = "$M1N1_ARTWORK_COMMIT"

        if [[ -e "${repository}/build" && ! -L "${repository}/build" ]]; then
            printf "Refusing non-symlink source build path: %s\n" "${repository}/build" >&2
            exit 1
        fi
        if [[ ! -L "${repository}/build" ]]; then
            ln -s ../../build/m1n1 "${repository}/build"
        fi
        test "$(readlink "${repository}/build")" = ../../build/m1n1

        make -C "$repository" clean
        readonly run_id="$(date -u +%Y%m%dT%H%M%SZ)"
        readonly stage="/out/milestone0/m1n1/.${run_id}.tmp"
        readonly destination="/out/milestone0/m1n1/${run_id}"
        install -d "$stage"

        LC_ALL=C make -C "$repository" ARCH= RELEASE=1 -j"$(nproc)" \
            2>&1 | tee "${stage}/build.log"

        install -m 0644 "${component_build}/m1n1.macho" "${stage}/m1n1.macho"
        install -m 0644 "${component_build}/m1n1.bin" "${stage}/m1n1.bin"
        dpkg-query -W -f="\${Package}=\${Version}\n" | LC_ALL=C sort > "${stage}/packages.txt"
        git -C "$repository" submodule status --recursive > "${stage}/submodules.txt"

        {
            printf "format=1\n"
            printf "built_utc=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf "target=Mac15,6/J514s/T6030\n"
            printf "component=m1n1\n"
            printf "source_url=%s\n" "$M1N1_URL"
            printf "source_commit=%s\n" "$(git -C "$repository" rev-parse HEAD)"
            printf "source_ref=%s\n" "$M1N1_REF"
            printf "upstream_url=%s\n" "$M1N1_UPSTREAM_URL"
            printf "upstream_ref=%s\n" "$M1N1_UPSTREAM_REF"
            printf "upstream_commit=%s\n" "$M1N1_UPSTREAM_COMMIT"
            printf "source_describe=%s\n" "$(git -C "$repository" describe --always --dirty)"
            printf "source_clean=%s\n" "$(test -z "$(source_status)" && printf true || printf false)"
            printf "artwork_commit=%s\n" "$(git -C "${repository}/artwork" rev-parse HEAD)"
            printf "workspace_filesystem=%s\n" "$filesystem_type"
            printf "debian_snapshot=%s\n" "$DEBIAN_SNAPSHOT"
            printf "rustup_version=%s\n" "$RUSTUP_VERSION"
            printf "rustup_init_sha256=%s\n" "$RUSTUP_INIT_SHA256"
            printf "container_image=%s\n" "$BUILD_IMAGE"
            printf "container_image_id=%s\n" "$BUILD_IMAGE_ID"
            printf "rustc=%s\n" "$(rustc --version)"
            printf "cargo=%s\n" "$(cargo --version)"
            printf "gcc=%s\n" "$(aarch64-linux-gnu-gcc -dumpfullversion)"
            printf "ld=%s\n" "$(aarch64-linux-gnu-ld --version | head -n 1)"
            printf "objcopy=%s\n" "$(aarch64-linux-gnu-objcopy --version | head -n 1)"
            printf "make=%s\n" "$(make --version | head -n 1)"
        } > "${stage}/manifest.txt"

        grep -Fx "source_clean=true" "${stage}/manifest.txt" >/dev/null
        file "${stage}/m1n1.macho" "${stage}/m1n1.bin" > "${stage}/file.txt"
        (
            cd "$stage"
            sha256sum build.log file.txt m1n1.bin m1n1.macho manifest.txt packages.txt submodules.txt > SHA256SUMS
        )

        mv "$stage" "$destination"
        ln -sfn "$run_id" /out/milestone0/m1n1/latest
        printf "m1n1.baseline=%s\n" "$destination"
    '

"${project_root}/scripts/verify-m1n1.sh"
