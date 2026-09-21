#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/milestone0-inspection.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m0-inspection-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
contract="$project_root/config/milestone0-inspection-packages.txt"
builder_id=sha256:175b095ef204602c43b99438fbc96c34895d19128fc38dca5b1e19f0e529964d
mkdir "$tmp/full" "$tmp/packages"
cp "$contract" "$tmp/full/packages.txt"
cp "$contract" "$tmp/packages/pacman-Q.txt"
rehash() {
    (cd "$tmp/full" && sha256sum packages.txt > SHA256SUMS)
    (cd "$tmp/packages" && sha256sum pacman-Q.txt > SHA256SUMS)
}
expect_fail() { if "$@" >"$tmp/rejected.log" 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
rehash
m0_inspection_inventory_check "$tmp/full" packages.txt "$contract"
for mutation in short extra unsorted duplicate malformed; do
    case "$mutation" in
        short) sed '/^bash /d' "$contract" >"$tmp/bad-contract" ;;
        extra) cp "$contract" "$tmp/bad-contract"; printf 'zz-extra 1-1\n' >>"$tmp/bad-contract" ;;
        unsorted) LC_ALL=C sort -r "$contract" >"$tmp/bad-contract" ;;
        duplicate) sed 's/^bash .*/attr 2.6.0-1/' "$contract" >"$tmp/bad-contract" ;;
        malformed) sed 's/^bash .*/bash  multiple fields/' "$contract" >"$tmp/bad-contract" ;;
    esac
    expect_fail m0_inspection_packages_match "$tmp/bad-contract" "$tmp/full/packages.txt"
done
for mutation in changed missing duplicate malformed; do
    case "$mutation" in
        changed) sed 's/^bash .*/bash 0.0-1/' "$contract" >"$tmp/full/packages.txt" ;;
        missing) sed '/^bash /d' "$contract" >"$tmp/full/packages.txt" ;;
        duplicate) cp "$contract" "$tmp/full/packages.txt"; head -n 1 "$contract" >>"$tmp/full/packages.txt" ;;
        malformed) cp "$contract" "$tmp/full/packages.txt"; printf 'invalid record fields\n' >>"$tmp/full/packages.txt" ;;
    esac
    rehash
    expect_fail m0_inspection_inventory_check "$tmp/full" packages.txt "$contract"
done
cp "$contract" "$tmp/full/packages.txt"
rehash
printf 'extra-package 1-1\n' >>"$tmp/full/packages.txt"
expect_fail m0_inspection_inventory_check "$tmp/full" packages.txt "$contract"
rehash
m0_inspection_inventory_check "$tmp/full" packages.txt "$contract"
head -n 1 "$tmp/full/SHA256SUMS" >"$tmp/duplicate-sum"
cat "$tmp/duplicate-sum" >>"$tmp/full/SHA256SUMS"
expect_fail m0_inspection_inventory_check "$tmp/full" packages.txt "$contract"
rehash
mv "$tmp/full/packages.txt" "$tmp/kept-inventory"
ln -s ../kept-inventory "$tmp/full/packages.txt"
expect_fail m0_inspection_inventory_check "$tmp/full" packages.txt "$contract"
rm "$tmp/full/packages.txt"
mv "$tmp/kept-inventory" "$tmp/full/packages.txt"

if [[ ${1:-} == --container ]]; then
    # This executes the real pinned runner with synthetic evidence only.
    m0_inspection_run "$tmp/full" "$tmp/packages" "$builder_id" '
        [[ $(uname -m) == aarch64 ]]
        if touch /inspection-root-write 2>/dev/null; then exit 1; fi
        if touch /evidence/inspection-input-write 2>/dev/null; then exit 1; fi
        if touch /packages/inspection-input-write 2>/dev/null; then exit 1; fi
        if { printf corrupted > /evidence/packages.txt; } 2>/dev/null; then exit 1; fi
        if chmod 0600 /evidence/packages.txt 2>/dev/null; then exit 1; fi
        printf upper > /tmp/Case
        printf lower > /tmp/case
        if cmp -s /tmp/Case /tmp/case; then exit 1; fi
        printf "#!/bin/sh\nexit 0\n" > /tmp/noexec
        chmod +x /tmp/noexec
        if /tmp/noexec 2>/dev/null; then exit 1; fi
        printf "inspection-runtime-isolation=passed\n"
    '
    failure_status=0
    m0_inspection_run "$tmp/full" '' "$builder_id" 'exit 23' >"$tmp/rejected.log" 2>&1 || failure_status=$?
    [[ $failure_status == 23 ]]
    [[ ! -e $tmp/full/inspection-input-write && ! -e $tmp/packages/inspection-input-write ]]
    m0_inspection_inventory_check "$tmp/full" packages.txt "$contract"
    m0_inspection_inventory_check "$tmp/packages" pacman-Q.txt "$contract"
    mkdir -p "$tmp/project/scripts/lib" "$tmp/project/config"
    cp "$project_root/scripts/lib/milestone0-inspection.sh" "$tmp/project/scripts/lib/"
    sed 's/^bash .*/bash 0.0-1/' "$contract" >"$tmp/project/config/milestone0-inspection-packages.txt"
    cp "$tmp/project/config/milestone0-inspection-packages.txt" "$tmp/full/packages.txt"
    rehash
    (
        source "$tmp/project/scripts/lib/milestone0-inspection.sh"
        expect_fail m0_inspection_run "$tmp/full" '' "$builder_id" 'printf unexpected-body-execution'
        if grep -Fq unexpected-body-execution "$tmp/rejected.log"; then exit 1; fi
    )
    printf 'M0 inspection real-container tests passed\n'
    exit 0
fi
[[ $# == 0 ]] || exit 64

# The static tier checks dispatch without needing a Docker socket or container.
docker() {
    if [[ $1 == image && $2 == inspect ]]; then
        [[ ${!#} == menci/archlinuxarm@sha256:55b83fc04a09f1e2e08644b4548b95c974ed1108fa8f0a34647af36a4b1c7f60 ]] || return 1
        [[ ${fake_inspect_failure:-0} == 0 ]] || return 1
        printf '%s\n' "${fake_image_info:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa linux arm64}"
    elif [[ $1 == run ]]; then
        printf '%s\n' "$@" >"$tmp/docker-args"
        return "${fake_run_status:-0}"
    else
        return 1
    fi
}
m0_inspection_run "$tmp/full" "$tmp/packages" "$builder_id" ':' >"$tmp/dispatch.log"
for argument in --pull=never --read-only --network none --cap-drop ALL --security-opt no-new-privileges \
    /tmp:rw,nosuid,nodev,noexec,size=2g linux/arm64 /bin/bash \
    sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
    grep -Fx -- "$argument" "$tmp/docker-args" >/dev/null
done
grep -Fx "type=bind,src=$tmp/full,dst=/evidence,readonly" "$tmp/docker-args" >/dev/null
grep -Fx "type=bind,src=$tmp/packages,dst=/packages,readonly" "$tmp/docker-args" >/dev/null
if grep -Fx -- "$builder_id" "$tmp/docker-args"; then exit 1; fi
grep -Fx "m0_inspection.recorded_builder_image_id=$builder_id" "$tmp/dispatch.log" >/dev/null
M0_INSPECTION_IMAGE=untrusted:latest m0_inspection_run "$tmp/full" '' "$builder_id" ':' >/dev/null
if grep -q 'dst=/packages' "$tmp/docker-args"; then exit 1; fi
fake_image_info='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa linux amd64' \
    expect_fail m0_inspection_run "$tmp/full" '' "$builder_id" ':'
fake_inspect_failure=1 expect_fail m0_inspection_run "$tmp/full" '' "$builder_id" ':'
fake_run_status=23 expect_fail m0_inspection_run "$tmp/full" '' "$builder_id" ':'
expect_fail m0_inspection_run "$tmp/full" '' untrusted ':'
mkdir "$tmp/unsafe,mount"
expect_fail m0_inspection_run "$tmp/unsafe,mount" '' "$builder_id" ':'
ln -s full "$tmp/linked"
expect_fail m0_inspection_run "$tmp/linked" '' "$builder_id" ':'
sed 's/^bash .*/bash 0.0-1/' "$contract" >"$tmp/packages/pacman-Q.txt"
rehash
expect_fail m0_inspection_run "$tmp/full" "$tmp/packages" "$builder_id" ':'
printf 'M0 inspection static tests passed\n'
