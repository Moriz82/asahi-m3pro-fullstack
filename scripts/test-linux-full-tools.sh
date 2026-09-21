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
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

# Development framebuffer mode must be explicit, pinned and outside canonical M0.
source "$project_root/scripts/lib/linux-development-profile.sh"
if (MILESTONE0_OUTPUT_ROOT="$project_root/out"; linux_development_framebuffer_init "$project_root") >/dev/null 2>&1; then exit 1; fi
(MILESTONE0_OUTPUT_ROOT="$project_root/out/isolated/dev-fixture"; linux_development_framebuffer_init "$project_root";
    test "$LINUX_COMPONENT" = linux-development-framebuffer; test "$LINUX_LOCALVERSION" = .asahi1-m3devfb1)
readonly development_fragment="$project_root/config/linux-development-framebuffer.config"
cp "$development_fragment" "$tmp/development.config"
printf '%s\n' 'CONFIG_LOCALVERSION=".asahi1-m3devfb1"' >> "$tmp/development.config"
linux_development_framebuffer_config "$tmp/development.config" "$development_fragment" > "$tmp/development-assertions"
while IFS= read -r setting; do
    grep -Fxv "$setting" "$tmp/development.config" > "$tmp/missing.config"
    if [[ "$setting" = '# CONFIG_'* ]]; then
        disabled_symbol="${setting#\# }"
        printf '%s=y\n' "${disabled_symbol% is not set}" >> "$tmp/missing.config"
    fi
    if linux_development_framebuffer_config "$tmp/missing.config" "$development_fragment" >/dev/null 2>&1; then exit 1; fi
done < "$tmp/development-assertions"
cp "$development_fragment" "$tmp/changed-fragment"
printf '# changed\n' >> "$tmp/changed-fragment"
if linux_development_framebuffer_config "$tmp/development.config" "$tmp/changed-fragment" >/dev/null 2>&1; then exit 1; fi
if "$build_script" --unknown-profile >/dev/null 2>&1; then exit 1; fi
if MILESTONE0_OUTPUT_ROOT="$project_root/out" "$build_script" --development-framebuffer >/dev/null 2>&1; then exit 1; fi
if "$verify_script" /not-evidence --unknown-profile >/dev/null 2>&1; then exit 1; fi
grep -Fq '"$stage" --development-framebuffer' "$build_script"
grep -Fq 'linux_development_framebuffer_config "$component_build/.config"' "$build_script"
grep -Fq 'linux_development_framebuffer_config "$evidence/config"' "$verify_script"
grep -Fq 'component=${LINUX_COMPONENT}' "$verify_script"
# Exercise the real argument-construction block, without invoking Docker/builds.
sed -n '/^profile_run_args=(/,/^docker run --rm/{ /^docker run --rm/d; p; }' "$build_script" > "$tmp/profile-args.sh"
test -s "$tmp/profile-args.sh"
for development_framebuffer in 0 1; do
    LINUX_COMPONENT=linux-full
    source "$tmp/profile-args.sh"
    printf '%s\n' "${profile_run_args[@]}" > "$tmp/profile-args.txt"
    if [[ "$development_framebuffer" = 0 ]]; then
        test "${#profile_run_args[@]}" -eq 4
        if grep -q 'development-profile\|development-framebuffer.config\|--mount' "$tmp/profile-args.txt"; then exit 1; fi
    else
        test "${#profile_run_args[@]}" -eq 8
        grep -Fq 'dst=/verify/linux-development-profile.sh,readonly' "$tmp/profile-args.txt"
        grep -Fq 'dst=/inputs/development-framebuffer.config,readonly' "$tmp/profile-args.txt"
    fi
done

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
grep -Fq 'm0_inspection_run "$evidence_abs"' "$verify_script"
grep -Fq '"$container_image_id"' "$verify_script"
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
grep -Fq 'm0_inspection_run "$evidence_abs" "$package_root_abs" "$arch_image_id"' "$package_script"
grep -Fq 'source "${project_root}/scripts/lib/milestone0-inspection.sh"' "$package_script"
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
# The static CI's /tmp is already a case-sensitive Linux filesystem. No nested
# Docker daemon or kernel build is needed to exercise the actual archive bytes.
if [[ $(uname -s) == Linux ]]; then
    headers="$tmp/headers"
    mkdir -p "$headers/usr/include/linux/netfilter"
    printf 'upper-case-bytes\n' >"$headers/usr/include/linux/netfilter/xt_CONNMARK.h"
    printf 'lower-case-bytes\n' >"$headers/usr/include/linux/netfilter/xt_connmark.h"
    printf 'kernel\n' >"$headers/usr/include/linux/kernel.h"
    (cd "$headers" && find usr/include -type f -print | LC_ALL=C sort) >"$tmp/headers.inventory"
    [[ $(wc -l <"$tmp/headers.inventory") -eq 3 ]]
    ! cmp -s "$headers/usr/include/linux/netfilter/xt_CONNMARK.h" "$headers/usr/include/linux/netfilter/xt_connmark.h"
    tar --sort=name --format=gnu --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$tmp/headers.tar" -C "$headers" usr
    touch "$headers/usr/include/linux/kernel.h"
    tar --sort=name --format=gnu --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$tmp/headers-again.tar" -C "$headers" usr
    cmp "$tmp/headers.tar" "$tmp/headers-again.tar"
    mkdir "$tmp/extracted"
    tar -xf "$tmp/headers.tar" -C "$tmp/extracted"
    diff -r "$headers/usr" "$tmp/extracted/usr"
    printf 'PASS case-distinct reproducible header archive\n'
else
    printf 'SKIP case-distinct header archive: requires Linux; mandatory in static CI\n'
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
