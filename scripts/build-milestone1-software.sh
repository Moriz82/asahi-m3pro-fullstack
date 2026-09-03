#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/config/milestone1.env"
readonly cache_root="${MILESTONE0_OUTPUT_ROOT:-${project_root}/out}/cache/milestone1-busybox"
mkdir -p "$cache_root"
readonly stage="$(mktemp -d "${cache_root}/.download.XXXXXX")"
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT

command -v docker >/dev/null
docker info >/dev/null
docker build --provenance=false \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "DEBIAN_SNAPSHOT=${DEBIAN_SNAPSHOT}" \
    --build-arg "RUST_VERSION=${RUST_VERSION}" \
    --build-arg "RUSTUP_VERSION=${RUSTUP_VERSION}" \
    --build-arg "RUSTUP_INIT_SHA256=${RUSTUP_INIT_SHA256}" \
    --file "${project_root}/build/Containerfile" --tag "$BUILD_IMAGE" "${project_root}/build"
docker run --rm --user "$(id -u):$(id -g)" \
    --env "M1_BUSYBOX_DEB_URL=${M1_BUSYBOX_DEB_URL}" \
    --env "M1_BUSYBOX_DEB_SHA256=${M1_BUSYBOX_DEB_SHA256}" \
    --env "M1_BUSYBOX_SHA256=${M1_BUSYBOX_SHA256}" \
    --mount "type=bind,src=${stage},dst=/out" "$BUILD_IMAGE" bash -Eeuo pipefail -c '
        curl --proto "=https" --tlsv1.2 -fsSL "$M1_BUSYBOX_DEB_URL" -o /out/busybox-static.deb
        printf "%s  %s\n" "$M1_BUSYBOX_DEB_SHA256" /out/busybox-static.deb | sha256sum -c -
        dpkg-deb --fsys-tarfile /out/busybox-static.deb | tar -xOf - ./bin/busybox > /out/busybox
        chmod 0755 /out/busybox
        printf "%s  %s\n" "$M1_BUSYBOX_SHA256" /out/busybox | sha256sum -c -
    '
M1_BUSYBOX="$stage/busybox" "${project_root}/scripts/build-milestone1-initramfs.sh"
"${project_root}/scripts/verify-milestone1-initramfs.sh"
