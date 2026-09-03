#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly build_script="$project_root/scripts/build-linux-full.sh"
readonly verify_script="$project_root/scripts/verify-linux-full.sh"
readonly resume_script="$project_root/scripts/resume-linux-full-stage.sh"
readonly package_script="$project_root/scripts/verify-linux-package.sh"
readonly rebuild_script="$project_root/scripts/rebuild-milestone0.sh"
readonly stage_policy_lib="$project_root/scripts/lib/milestone0-linux-full-stage.sh"
source "$stage_policy_lib"
readonly full_inventory_pattern='^[^/[:space:]]+(/[^/[:space:]]+)*\.(dtb|dtbo)$'
readonly full_unsafe_pattern='(^|/)\.\.?(/|$)'
readonly tmp="$(mktemp -d "${TMPDIR:-/tmp}/linux-full-tools.XXXXXX")"
header_test_volume=
cleanup() {
    if [[ -n "$header_test_volume" ]] &&
        [[ "$(docker volume inspect --format '{{ index .Labels \"com.moriz.project\" }}:{{ index .Labels \"com.moriz.purpose\" }}' "$header_test_volume" 2>/dev/null || true)" = 'asahi-m3pro-fullstack:linux-full-tools' ]]; then
        docker volume rm "$header_test_volume" >/dev/null 2>&1 || :
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT

grep -Fq 'INSTALL_DTBS_PATH="$stage/dtbs-install" dtbs_install' "$build_script"
grep -Fq 'dtbs_inventory_policy=raw-build-superset' "$build_script"
grep -Fq 'dtbs_install_subset_policy=kernel-install-subset' "$build_script"
grep -Fq 'dtbs-list.inventory' "$build_script"
grep -Fq 'dtbs-install.inventory' "$build_script"
grep -Fq 'cmp "$stage/dtbs/$dt_path" "$stage/dtbs-install/$dt_path"' "$build_script"
grep -Fq 'headers_install' "$build_script"
grep -Fq 'headers_root="/workspace/build/linux-headers-install-${run_id}"' "$build_script"
grep -Fq 'tar --sort=name --format=gnu --mtime="@${source_epoch}" --owner=0 --group=0 --numeric-owner' "$build_script"
grep -Fq 'headers_archive_byte_stable=true' "$build_script"
grep -Fq 'artifact_symlink_policy=none-portable-handoff' "$build_script"
grep -Fq 'artifact_symlink_policy=none-portable-handoff' "$resume_script"
grep -Fq 'artifact_symlink_policy=none-portable-handoff' "$verify_script"
grep -Fq 'docker image inspect "$container_image_id"' "$verify_script"
grep -Fq '"$container_image_id" bash -Eeuo pipefail' "$verify_script"
grep -Fq 'm0_make_linux_full_stage_portable "$stage" "$kernel_release"' "$build_script"
grep -Fq 'm0_make_linux_full_stage_portable "$stage" "$kernel_release"' "$resume_script"
grep -Fq 'dst=/verify/milestone0-linux-full-stage.sh,readonly' "$build_script"
grep -Fq 'dst=/verify/milestone0-linux-full-stage.sh,readonly' "$resume_script"
grep -Fq 'test ! -s "$evidence/symlinks.inventory"' "$verify_script"
grep -Fq 'find -P "$stage" -mindepth 1 -type d -empty -print -quit' "$build_script"
grep -Fq 'find -P "$stage" -mindepth 1 -type d -empty -print -quit' "$resume_script"
grep -Fq 'find -P . -mindepth 1 -type d -empty -print -quit' "$verify_script"
! grep -Fq 'find "$stage/headers"' "$build_script"
grep -Fq 'dtbs-install.inventory' "$verify_script"
grep -Fq 'dtbs-install' "$verify_script"
grep -Fq '(dtb|dtbo)' "$verify_script"
grep -Fq 'dtbs-install.inventory' "$resume_script"
grep -Fq 'dt_path" "$stage/dtbs-install/$dt_path' "$resume_script"
grep -Fq '(dtb|dtbo)' "$resume_script"
grep -Fq 'headers.tar' "$resume_script"
grep -Fq 'cmp "$headers_archive" "$stage/headers.tar"' "$resume_script"
grep -Fq 'test ! -e "$stage/headers"' "$resume_script"
grep -Fq 'rm -rf -- "$headers_root" "$headers_archive"' "$resume_script"
grep -Fq 'cmp "$raw_inventory_tmp" "$stage/dtbs.inventory"' "$resume_script"
grep -Fq 'done < "$raw_inventory_tmp"' "$resume_script"
grep -Fq '^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9a-f]+$' "$resume_script"
grep -Fq 'dtbs-install.inventory' "$package_script"
grep -Fq 'docker image inspect "$arch_image_id"' "$package_script"
grep -Fq '"$arch_image_id" bash -Eeuo pipefail' "$package_script"
grep -Fq 'diff -qr "$packaged_tree/dtb" /evidence/dtbs-install' "$package_script"
grep -Fq 'diff -qr "$tmp/api/usr/include" "$tmp/evidence-headers/usr/include"' "$package_script"
grep -Fq 'Unexpected API package member' "$package_script"
grep -Fq 'Non-file/non-directory evidence header' "$package_script"
grep -Fq 'Non-file/non-directory API member' "$package_script"
grep -Fq 'headers.inventory' "$package_script"
grep -Fq 'headers.tar' "$verify_script"
grep -Fq 'Non-file/non-directory headers member' "$verify_script"
grep -Fq 'test ! -e "$evidence/headers"' "$verify_script"
grep -Fq '[[ "$member" != /* ]]' "$verify_script"
grep -Fq 'grep -Eq "(^|/)\.\.?(/|$)" <<< "$member"' "$verify_script"
grep -Fq '[[ "$header_path" != /* ]]' "$package_script"
grep -Fq 'grep -Eq "(^|/)\.\.?(/|$)" <<< "$header_path"' "$package_script"
grep -Fq 'sort -u | cmp' "$package_script"
grep -Fq 'linux-full/dtbs-list.inventory' "$rebuild_script"
grep -Fq 'linux-full/dtbs-install.inventory' "$rebuild_script"
grep -Fq 'for tree in dtbs dtbs-install modules' "$rebuild_script"
grep -Fq 'dtbs_install_policy' "$rebuild_script"
grep -Fq 'linux-full/headers.tar' "$rebuild_script"
grep -Fq 'cmp "${canonical_paths[linux_full_index]}/headers.tar"' "$rebuild_script"
grep -Fq 'headers_archive_policy' "$rebuild_script"
grep -Fq 'for suffix in closure inventory pkginfo files' "$rebuild_script"
! grep -Fq 'cmp "${canonical_paths[package_index]}/SHA256SUMS"' "$rebuild_script"
grep -Fq 'Reproducibility manifest mismatch:' "$rebuild_script"
grep -Fq 'Reproducibility manifest key missing:' "$rebuild_script"
grep -Fq 'clean_rebuild=byte-identical-release-artifact-closure' "$rebuild_script"
grep -Fq 'CLEAN_BUILD=1' "$project_root/scripts/build-milestone0.sh"
grep -Fq -- '--env "RUN_ID=${run_id}"' "$build_script"
grep -Fq 'verify-linux-full.sh" "$stage"' "$build_script"
grep -Fq 'mv "$stage" "$destination"' "$build_script"
grep -Fq 'Refusing colliding linux-full destination' "$build_script"
grep -Fq 'atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"' "$build_script"
grep -Fq 'exec 9>/workspace/.milestone0-build.lock' "$resume_script"
grep -Fq 'flock -n 9' "$resume_script"
grep -Fq 'verify-linux-full.sh" "$stage"' "$resume_script"
grep -Fq 'mv "$stage" "$destination"' "$resume_script"
grep -Fq 'atomic_symlink_replace "$run_id" "$latest" "$latest_tmp"' "$resume_script"

# The container programs are embedded in outer single-quoted arguments. Raw
# single quotes in these two expressions silently truncate that program while
# leaving the host script syntactically valid.
for embedded_script in "$build_script" "$resume_script"; do
    if grep -Fq "tr -d ' '" "$embedded_script"; then exit 1; fi
    if grep -Fq "printf 'dtbs_install_subset_policy=" "$embedded_script"; then exit 1; fi
done
grep -Fq 'printf "dtbs_install_subset_policy=kernel-install-subset\n"' "$build_script"
grep -Fq 'printf "dtbs_install_subset_policy=kernel-install-subset\n"' "$resume_script"

printf 'apple/t6030-j514s.dtb\napple/t6030-j514s.dtbo\n' > "$tmp/valid.inventory"
if grep -Evq "$full_inventory_pattern" "$tmp/valid.inventory"; then exit 1; fi
if grep -Eq "$full_unsafe_pattern" "$tmp/valid.inventory"; then exit 1; fi
printf '../escape.dtb\n' > "$tmp/unsafe.inventory"
grep -Eq "$full_unsafe_pattern" "$tmp/unsafe.inventory"
printf 'apple/not-a-dtb\n' > "$tmp/wrong-extension.inventory"
grep -Evq "$full_inventory_pattern" "$tmp/wrong-extension.inventory"

# Header archive contract: case-distinct UAPI names must remain distinct and
# retain their different bytes through archive extraction and inventorying.
# A Docker volume is required here because the host checkout may be APFS and
# therefore unable to represent the two case-distinct paths independently.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 &&
    source "$project_root/config/milestone0.env" &&
    docker image inspect "$ARCH_BUILD_IMAGE" >/dev/null 2>&1; then
    header_test_volume="asahi-m3pro-header-tools-$(od -An -N8 -tx1 /dev/urandom | tr -d '[:space:]')"
    docker volume create --label com.moriz.project=asahi-m3pro-fullstack \
        --label com.moriz.purpose=linux-full-tools "$header_test_volume" >/dev/null
    docker run --rm --mount "type=volume,src=${header_test_volume},dst=/case" \
        "$ARCH_BUILD_IMAGE" bash -Eeuo pipefail -c '
            mkdir -p /case/usr/include/linux/netfilter
            printf "upper-case-bytes\\n" > /case/usr/include/linux/netfilter/xt_CONNMARK.h
            printf "lower-case-bytes\\n" > /case/usr/include/linux/netfilter/xt_connmark.h
            printf "kernel\\n" > /case/usr/include/linux/kernel.h
            (cd /case; find usr/include -type f -printf "%P\\n" | sed "s#^#usr/include/#" | LC_ALL=C sort) > /case/headers.inventory
            grep -Fx "usr/include/linux/netfilter/xt_CONNMARK.h" /case/headers.inventory
            grep -Fx "usr/include/linux/netfilter/xt_connmark.h" /case/headers.inventory
            test "$(wc -l < /case/headers.inventory | tr -d " ")" -eq 3
            ! cmp /case/usr/include/linux/netfilter/xt_CONNMARK.h /case/usr/include/linux/netfilter/xt_connmark.h
            tar --sort=name --format=gnu --mtime=@0 --owner=0 --group=0 --numeric-owner \
                -cf /case/headers.tar -C /case usr
            mkdir /case/extracted
            tar -xf /case/headers.tar -C /case/extracted
            test -s /case/extracted/usr/include/linux/kernel.h
            cmp /case/usr/include/linux/netfilter/xt_CONNMARK.h /case/extracted/usr/include/linux/netfilter/xt_CONNMARK.h
            cmp /case/usr/include/linux/netfilter/xt_connmark.h /case/extracted/usr/include/linux/netfilter/xt_connmark.h
            while IFS= read -r member; do
                case "$member" in
                    usr|usr/|usr/include|usr/include/|usr/include/*) ;;
                    *) exit 1 ;;
                esac
            done < <(tar -tf /case/headers.tar)
        '
else
    # Static/read-only aggregate images do not expose Docker; retain the
    # source-contract assertions there and run the case-sensitive fixture on
    # the normal host where the pinned builder is available.
    grep -Fq 'case-sensitive ext4 Docker volume' "$build_script"
fi

# A resume may normalize only modules_install's two non-runtime links. Any
# other symlink must fail before later stage writes can follow it.
portable_stage="$tmp/portable-stage"
kernel_release='7.1.test'
mkdir -p "$portable_stage/modules/lib/modules/$kernel_release"
ln -s /workspace/build/linux-full "$portable_stage/modules/lib/modules/$kernel_release/build"
m0_make_linux_full_stage_portable "$portable_stage" "$kernel_release"
test -z "$(find -P "$portable_stage" -type l -print -quit)"
(
    readonly kernel_release='7.1.test'
    m0_make_linux_full_stage_portable "$portable_stage" "$kernel_release"
)

unsafe_stage="$tmp/unsafe-stage"
sentinel="$tmp/outside-sentinel"
mkdir -p "$unsafe_stage/modules/lib/modules/$kernel_release"
printf 'unchanged\n' > "$sentinel"
ln -s "$sentinel" "$unsafe_stage/config-input"
if m0_make_linux_full_stage_portable "$unsafe_stage" "$kernel_release" >/dev/null 2>&1; then exit 1; fi
grep -Fx 'unchanged' "$sentinel" >/dev/null

ancestor_stage="$tmp/ancestor-stage"
outside_modules="$tmp/outside-modules"
mkdir -p "$ancestor_stage" "$outside_modules/lib/modules/$kernel_release"
ln -s sentinel-target "$outside_modules/lib/modules/$kernel_release/build"
ln -s "$outside_modules" "$ancestor_stage/modules"
if m0_make_linux_full_stage_portable "$ancestor_stage" "$kernel_release" >/dev/null 2>&1; then exit 1; fi
test -L "$outside_modules/lib/modules/$kernel_release/build"
test "$(readlink "$outside_modules/lib/modules/$kernel_release/build")" = sentinel-target

wrong_stage="$tmp/wrong-stage"
mkdir -p "$wrong_stage/modules/lib/modules/$kernel_release/build"
if m0_make_linux_full_stage_portable "$wrong_stage" "$kernel_release" >/dev/null 2>&1; then exit 1; fi

# Regression: a stage attacker can rewrite raw non-installed DTBO bytes or its
# complete inventory and rehash the stage, but resume must bind it to the
# immutable current component-build output before publication.
raw_source="$tmp/raw-source"
raw_stage="$tmp/raw-stage"
mkdir -p "$raw_source/apple" "$raw_stage/dtbs/apple"
printf 'base\n' > "$raw_source/apple/base.dtb"
printf 'extra\n' > "$raw_source/apple/extra.dtbo"
cp "$raw_source/apple/base.dtb" "$raw_stage/dtbs/apple/base.dtb"
cp "$raw_source/apple/extra.dtbo" "$raw_stage/dtbs/apple/extra.dtbo"
snapshot_inventory() {
    local root="$1" output="$2"
    (cd "$root"; find . -type f \( -name '*.dtb' -o -name '*.dtbo' \) -print | sed 's#^\./##' | LC_ALL=C sort) > "$output"
}
snapshot_checksums() {
    (cd "$raw_stage"; { find dtbs -type f \( -name '*.dtb' -o -name '*.dtbo' \) -print; printf '%s\n' dtbs.inventory; } | LC_ALL=C sort | xargs shasum -a 256) > "$raw_stage/SHA256SUMS"
}
raw_snapshot_gate() {
    local current_inventory="$tmp/current-raw.inventory" path
    (cd "$raw_source"; find . -type f \( -name '*.dtb' -o -name '*.dtbo' \) -print | sed 's#^\./##' | LC_ALL=C sort) > "$current_inventory"
    (cd "$raw_stage"; shasum -a 256 -c SHA256SUMS >/dev/null)
    cmp "$current_inventory" "$raw_stage/dtbs.inventory" || return 1
    while IFS= read -r path; do cmp "$raw_source/$path" "$raw_stage/dtbs/$path" || return 1; done < "$current_inventory"
}
snapshot_inventory "$raw_stage/dtbs" "$raw_stage/dtbs.inventory"
snapshot_checksums
raw_snapshot_gate
printf 'tampered-extra\n' > "$raw_stage/dtbs/apple/extra.dtbo"
snapshot_checksums
if raw_snapshot_gate >/dev/null 2>&1; then exit 1; fi
cp "$raw_source/apple/extra.dtbo" "$raw_stage/dtbs/apple/extra.dtbo"
printf 'added\n' > "$raw_stage/dtbs/apple/added.dtbo"
snapshot_inventory "$raw_stage/dtbs" "$raw_stage/dtbs.inventory"
snapshot_checksums
if raw_snapshot_gate >/dev/null 2>&1; then exit 1; fi
rm "$raw_stage/dtbs/apple/added.dtbo"
rm "$raw_stage/dtbs/apple/extra.dtbo"
snapshot_inventory "$raw_stage/dtbs" "$raw_stage/dtbs.inventory"
snapshot_checksums
if raw_snapshot_gate >/dev/null 2>&1; then exit 1; fi

printf 'linux-full tooling contract tests passed\n'
