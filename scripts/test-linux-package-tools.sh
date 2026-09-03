#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/scripts/lib/milestone0-package-paths.sh"
source "${project_root}/scripts/lib/atomic-symlink.sh"
source "${project_root}/scripts/lib/milestone0-package-closure.sh"
readonly tmp="$(mktemp -d "${TMPDIR:-/tmp}/linux-package-tools.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

test "$(m0_package_to_evidence_module_path usr/lib/modules/7.1/kernel/test.ko)" = \
    'lib/modules/7.1/kernel/test.ko'
test "$(m0_evidence_to_package_module_path lib/modules/7.1/kernel/test.ko)" = \
    'usr/lib/modules/7.1/kernel/test.ko'
for rejected in lib/modules/7.1/kernel/test.ko usr/lib/modules/../escape.ko usr/lib/modules//test.ko; do
    ! m0_package_to_evidence_module_path "$rejected"
done
for rejected in usr/lib/modules/7.1/kernel/test.ko lib/modules/../escape.ko lib/modules//test.ko; do
    ! m0_evidence_to_package_module_path "$rejected"
done
mkdir "$tmp/old" "$tmp/staged"
printf 'old\n' >"$tmp/old/marker"
printf 'new\n' >"$tmp/staged/marker"
ln -s old "$tmp/latest"
test "$(cat "$tmp/latest/marker")" = old
atomic_symlink_replace staged "$tmp/latest" "$tmp/.latest.tmp"
test "$(cat "$tmp/latest/marker")" = new
package_script="${project_root}/scripts/package-linux-asahi.sh"
verify_line="$(grep -nF 'verify-linux-package.sh" "$stage"' "$package_script" | cut -d: -f1)"
publish_line="$(grep -nF 'atomic_symlink_replace "$run_id" "$latest"' "$package_script" | cut -d: -f1)"
test -n "$verify_line" && test -n "$publish_line" && test "$verify_line" -lt "$publish_line"
grep -Fq 'Refusing colliding linux-package destination' "$package_script"
! grep -Fq 'rm -f "$out"' "$package_script"
grep -Fq 'kernel_image_transform=gzip' "$package_script"
grep -Fq 'gzip -dc "$packaged_tree/vmlinuz" | cmp - /evidence/Image' \
    "${project_root}/scripts/verify-linux-package.sh"
grep -Fq 'm0_package_closure_from_tree' "${project_root}/scripts/package-linux-asahi.sh"
grep -Fq 'm0_package_closure_add_makepkg_metadata' "${project_root}/scripts/package-linux-asahi.sh"
grep -Fq 'm0_archive_closure_verify' "${project_root}/scripts/verify-linux-package.sh"
grep -Fq '[[ $arch_image_id =~ ^sha256:[0-9a-f]{64}$ && $arch_image_id == "$full_image_id" ]]' \
    "${project_root}/scripts/verify-linux-package.sh"
grep -Fq 'docker image inspect "$arch_image_id"' "${project_root}/scripts/verify-linux-package.sh"
grep -Fq 'sed -n "s/^pkgname = //p"' "$package_script"
! grep -Fq "sed -n 's/^pkgname = //p'" "$package_script"

# Archive closures must detect every member-shape injection before extraction.
staging_root="$tmp/staging-root"
archive_root="$tmp/archive-root"
mkdir -p "$staging_root/usr/bin" "$staging_root/usr/lib"
printf 'base\n' > "$staging_root/usr/bin/base"
printf 'library\n' > "$staging_root/usr/lib/library"
ln -s ../bin/base "$staging_root/usr/lib/link"
mkdir -p "$archive_root"
cp -R "$staging_root/usr" "$archive_root/"
for metadata in .PKGINFO .BUILDINFO .MTREE; do printf '%s\n' "$metadata" > "$archive_root/$metadata"; done
m0_package_closure_from_tree "$staging_root" "$tmp/base.closure"
m0_package_closure_add_makepkg_metadata "$tmp/base.closure"
m0_package_closure_add_makepkg_metadata "$tmp/base.closure"
test -z "$(trap -p RETURN)"
bsdtar -cf "$tmp/base.tar" -C "$archive_root" usr
bsdtar -rf "$tmp/base.tar" -C "$archive_root" .PKGINFO .BUILDINFO .MTREE
m0_archive_closure_verify "$tmp/base.tar" "$tmp/base.closure"
for target in /etc/passwd ../../../outside; do
    unsafe_tree="$tmp/unsafe-tree-${target//\//_}"
    unsafe_archive="$tmp/unsafe-archive-${target//\//_}.tar"
    unsafe_closure="$tmp/unsafe-closure-${target//\//_}"
    cp -R "$staging_root" "$unsafe_tree"
    ln -s "$target" "$unsafe_tree/usr/lib/unsafe-link"
    ! m0_package_closure_from_tree "$unsafe_tree" "$unsafe_closure"
    cp -R "$archive_root" "$tmp/unsafe-root-${target//\//_}"
    unsafe_root="$tmp/unsafe-root-${target//\//_}"
    ln -s "$target" "$unsafe_root/usr/lib/unsafe-link"
    bsdtar -cf "$unsafe_archive" -C "$unsafe_root" usr
    bsdtar -rf "$unsafe_archive" -C "$unsafe_root" .PKGINFO .BUILDINFO .MTREE
    cp "$tmp/base.closure" "$unsafe_closure"
    printf 'usr/lib/unsafe-link\tl\t%s\n' "$target" >> "$unsafe_closure"
    LC_ALL=C sort -t $'\t' -k1,1 "$unsafe_closure" -o "$unsafe_closure"
    ! m0_archive_closure_verify "$unsafe_archive" "$unsafe_closure"

    # Keep the trusted closure safe while changing only the archive's existing
    # symlink target. This reaches the independent verbose-archive check.
    mismatch_root="$tmp/mismatch-root-${target//\//_}"
    mismatch_archive="$tmp/mismatch-archive-${target//\//_}.tar"
    cp -R "$archive_root" "$mismatch_root"
    rm "$mismatch_root/usr/lib/link"
    ln -s "$target" "$mismatch_root/usr/lib/link"
    bsdtar -cf "$mismatch_archive" -C "$mismatch_root" usr
    bsdtar -rf "$mismatch_archive" -C "$mismatch_root" .PKGINFO .BUILDINFO .MTREE
    ! m0_archive_closure_verify "$mismatch_archive" "$tmp/base.closure"
done
for kind in file dir symlink special; do
    bad_root="$tmp/bad-$kind"
    cp -R "$archive_root" "$bad_root"
    case "$kind" in
        file) printf 'injected\n' > "$bad_root/usr/bin/injected" ;;
        dir) mkdir "$bad_root/usr/bin/injected" ;;
        symlink) ln -s ../bin/base "$bad_root/usr/bin/injected" ;;
        special) mkfifo "$bad_root/usr/bin/injected" ;;
    esac
    bsdtar -cf "$tmp/$kind.tar" -C "$bad_root" usr
    bsdtar -rf "$tmp/$kind.tar" -C "$bad_root" .PKGINFO .BUILDINFO .MTREE
    ! m0_archive_closure_verify "$tmp/$kind.tar" "$tmp/base.closure"
done
bsdtar -cf "$tmp/duplicate.tar" -C "$archive_root" usr
bsdtar -rf "$tmp/duplicate.tar" -C "$archive_root" usr/bin/base
! m0_archive_closure_verify "$tmp/duplicate.tar" "$tmp/base.closure"
printf 'linux package path tests passed\n'
