#!/usr/bin/env bash
# shellcheck disable=SC1091
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/m8-coverage.sh"
command -v bsdtar >/dev/null 2>&1 || evidence_die 'bsdtar is required for package verification'
archive_tool=bsdtar
archive_list() { "$archive_tool" -tf "$1"; }
archive_extract_member() { "$archive_tool" -xOf "$1" "$2" 2>/dev/null || "$archive_tool" -xOf "$1" "./$2"; }
usage() { printf 'usage: %s (--input-dir|--repo) ABS [--required ABS] [--forbidden ABS]\n' "$0" >&2; exit 64; }
root=; required="$project_root/config/milestone8-required-packages.txt"; forbidden="$project_root/config/milestone8-forbidden-vm-tokens.txt"; coverage_contract="$project_root/config/milestone8-platform-coverage.tsv"
while (($#)); do
    case $1 in
        --input-dir|--repo) [[ -z $root ]] || usage; root=$2; shift 2;;
        --required) required=$2; shift 2;;
        --forbidden) forbidden=$2; shift 2;;
        --self-test) printf 'M8 package verifier self-test available\n'; exit 0;;
        *) usage;;
    esac
done
[[ -n $root ]] || usage
evidence_abs_dir "$root"; evidence_abs_regular "$required"; evidence_abs_regular "$forbidden"; evidence_abs_regular "$coverage_contract"
metadata="$root/packages.tsv"; evidence_abs_regular "$metadata"
IFS=$'\t' read -r -a header < "$metadata"
[[ ${header[*]} == 'package version architecture sha256 artifact' ]] || evidence_die 'invalid packages.tsv header'
required_count=$(awk 'NF && $1 !~ /^#/ {n++} END {print n + 0}' "$required")
((required_count > 0)) || evidence_die 'empty required package closure'
while IFS=$'\t' read -r package role extra; do
    [[ -z $package ]] && continue
    [[ -z ${extra:-} && $package =~ ^[a-z0-9][a-z0-9+._-]*$ && $role =~ ^[a-z0-9][a-z0-9-]*$ ]] || evidence_die "invalid required package row: $package"
    [[ $(awk -v p="$package" '$1 == p {n++} END {print n + 0}' "$required") -eq 1 ]] || evidence_die "duplicate required package: $package"
done < <(awk 'NF && $1 !~ /^#/ {print}' "$required")
forbidden_tokens=()
while IFS= read -r token || [[ -n $token ]]; do
    [[ -z $token || $token == \#* ]] && continue
    [[ $token != *$'\t'* && $token != *' '* ]] || evidence_die 'invalid forbidden token'
    forbidden_tokens+=("$token")
done < "$forbidden"
((${#forbidden_tokens[@]} > 0)) || evidence_die 'empty forbidden token list'
scan_forbidden() {
    local file=$1 token
    for token in "${forbidden_tokens[@]}"; do
        if grep -aFqi -- "$token" "$file"; then evidence_die "forbidden token '$token' in $file"; return 1; fi
    done
}
scan_forbidden_value() {
    local value=$1 token
    for token in "${forbidden_tokens[@]}"; do
        if printf '%s\n' "$value" | grep -Fqi -- "$token"; then evidence_die "forbidden token '$token' in declarative value"; return 1; fi
    done
}
scan_unsafe_actions() {
    local file=$1
    if grep -aEiq '(^|[[:space:]])(pacman|repo-add|makepkg|gpg|openssl|curl|wget|ssh|diskutil|bless|bputil|nvram|systemctl|chroot|mount|umount)([[:space:]]|$)|(^|[[:space:]])(install|publish|sign|boot)[[:space:]]*=[[:space:]]*(true|yes)' "$file"; then evidence_die "unsafe action declaration in $file"; fi
}
scan_archive_paths() {
    local archive=$1 path normalized listing
    listing=$(archive_list "$archive") || { evidence_die "invalid compressed package archive: $archive"; return 1; }
    if ! awk '
        NR == FNR { if ($0 != "" && $0 !~ /^#/) forbidden[tolower($0)]=1; next }
        {
            path=tolower($0)
            sub(/^\.\//, "", path)
            count=split(path, component, "/")
            for (i=1; i<=count; i++) if (component[i] in forbidden) bad=1
            if (path ~ /^(usr\/)?(s?bin|libexec)\//) {
                for (token in forbidden) if (index(component[count], token) == 1) bad=1
            }
        }
        END { exit bad }
    ' "$forbidden" <(printf '%s\n' "$listing"); then
        evidence_die "forbidden token in archive path: $archive"
    fi
    while IFS= read -r path; do
        normalized=${path#./}
        [[ -z $normalized ]] && normalized=.
        [[ -n $normalized && $normalized != /* && $normalized != .. && $normalized != ../* && $normalized != */../* && $normalized != */.. ]] || { evidence_die "unsafe archive path in $archive"; return 1; }
        case $normalized in
            .INSTALL|*/.INSTALL|usr/share/libalpm/hooks/*.hook|etc/pacman.d/hooks/*.hook) evidence_die "lifecycle hook in package archive: $archive:$normalized"; return 1;;
        esac
    done <<< "$listing"
}
scan_archive_types_and_links() {
    local archive=$1
    "$archive_tool" -cf - --format=mtree --no-xattrs "@$archive" | awk -v forbidden_file="$forbidden" '
        BEGIN {
            while ((getline token < forbidden_file) > 0) {
                if (token != "" && token !~ /^#/) forbidden_token[tolower(token)]=1
            }
            close(forbidden_file)
        }
        function forbidden_path(path, count, i, component, parts, token) {
            path=tolower(path)
            count=split(path, parts, "/")
            for (i=1; i<=count; i++) if (parts[i] in forbidden_token) return 1
            if (path ~ /^(usr\/)?(s?bin|libexec)\//) {
                component=parts[count]
                for (token in forbidden_token) if (index(component, token) == 1) return 1
            }
            return 0
        }
        function safe_link(path, target, combined, count, i, depth, component, parts) {
            if (path ~ /\\/ || target == "" || target ~ /\\/) return 0
            sub(/^\.\//, "", path)
            if (target ~ /^\//) {
                if (target == "/" || target ~ /(^|\/)\.\.?($|\/)/) return 0
                return 1
            } else {
                combined = path
                sub(/\/[^\/]*$/, "", combined)
                if (combined == path) combined = target
                else combined = combined "/" target
            }
            count = split(combined, parts, "/")
            depth = 0
            for (i = 1; i <= count; i++) {
                component = parts[i]
                if (component == "" || component == ".") continue
                if (component == "..") {
                    if (depth == 0) return 0
                    depth--
                } else depth++
            }
            return 1
        }
        NR == 1 { if ($0 != "#mtree") bad=1; next }
        {
            path=$1; type=""; link=""; type_count=0; link_count=0
            normalized_path=path
            sub(/^\.\//, "", normalized_path)
            members[normalized_path]=1
            for (i=2; i<=NF; i++) {
                if ($i ~ /^type=/) { type=substr($i, 6); type_count++ }
                if ($i ~ /^link=/) { link=substr($i, 6); link_count++ }
            }
            if (path ~ /\\/ || type_count != 1 || type !~ /^(file|dir|link)$/) bad=1
            if (type == "link") {
                if (link_count != 1 || !safe_link(path, link)) bad=1
                if (link ~ /^\//) {
                    absolute_target=link
                    sub(/^\/+/, "", absolute_target)
                    absolute_targets[normalized_path]=absolute_target
                }
            } else if (link_count != 0) bad=1
        }
        END {
            for (path in absolute_targets) {
                target=absolute_targets[path]
                if (!(target in members) || forbidden_path(target)) bad=1
            }
            exit bad
        }
    '
}
verify_archive() {
    local archive=$1 expected_package=$2 expected_version=$3 expected_arch=$4 list pkginfo_path pkginfo value magic
    magic=$(LC_ALL=C od -An -tx1 -N6 "$archive" | tr -d '[:space:]')
    case $archive in
        *.pkg.tar.zst) [[ ${magic:0:8} == 28b52ffd ]] || evidence_die "archive compression does not match .zst suffix: $archive";;
        *.pkg.tar.xz) [[ $magic == fd377a585a00 ]] || evidence_die "archive compression does not match .xz suffix: $archive";;
        *) evidence_die "unsupported package archive suffix: $archive";;
    esac
    list=$(archive_list "$archive") || evidence_die "invalid compressed package archive: $archive"
    [[ -n $list ]] || evidence_die "empty package archive: $archive"
    scan_archive_paths "$archive"
    scan_archive_types_and_links "$archive" || evidence_die "unsafe archive member or link: $archive"
    pkginfo_path=$(printf '%s\n' "$list" | awk 'substr($0,1,2)== "./" {$0=substr($0,3)} $0==".PKGINFO" {n++; p=$0} END {if(n != 1) exit 1; print p}') || evidence_die "archive must contain exactly one .PKGINFO: $archive"
    pkginfo=$(mktemp)
    archive_extract_member "$archive" "$pkginfo_path" > "$pkginfo" || { rm -f -- "$pkginfo"; evidence_die "cannot extract .PKGINFO: $archive"; }
    grep -Eiq '(^|[[:space:]])install[[:space:]]*=' "$pkginfo" && { rm -f -- "$pkginfo"; evidence_die "install action in .PKGINFO: $archive"; }
    for key in pkgname pkgver arch; do
        value=$(awk -F ' = ' -v wanted="$key" '$1 == wanted {n++; v=$2} END {if(n != 1) exit 1; print v}' "$pkginfo") || { rm -f -- "$pkginfo"; evidence_die "invalid $key in .PKGINFO: $archive"; }
        case $key in
            pkgname) [[ $value == "$expected_package" ]] || { rm -f -- "$pkginfo"; evidence_die "embedded package name mismatch: $archive"; };;
            pkgver) [[ $value == "$expected_version" ]] || { rm -f -- "$pkginfo"; evidence_die "embedded package version mismatch: $archive"; };;
            arch) [[ $value == "$expected_arch" ]] || { rm -f -- "$pkginfo"; evidence_die "embedded package architecture mismatch: $archive"; };;
        esac
    done
    while IFS= read -r value; do
        if ! scan_forbidden_value "$value"; then rm -f -- "$pkginfo"; return 1; fi
    done < <(awk -F ' = ' '$1 ~ /^(pkgname|pkgbase|pkgdesc|url|depend|optdepend|provides)$/ {print $2}' "$pkginfo")
    rm -f -- "$pkginfo"
}
rows=0
scan_forbidden "$metadata"
scan_unsafe_actions "$metadata"
metadata_header=true
while IFS=$'\t' read -r package version architecture hash artifact extra; do
    if [[ $metadata_header == true ]]; then metadata_header=false; continue; fi
    [[ -z $package ]] && continue
    [[ -z ${extra:-} && $package =~ ^[a-z0-9][a-z0-9+._-]*$ && $version =~ ^[A-Za-z0-9][A-Za-z0-9+._:-]*$ ]] || evidence_die 'invalid package metadata row'
    [[ $architecture == aarch64 ]] || evidence_die "package is not aarch64: $package"
    [[ $hash =~ ^[[:xdigit:]]{64}$ ]] || evidence_die "invalid package hash: $package"
    [[ $(awk -v p="$package" '$1 == p {n++} END {print n + 0}' "$required") -eq 1 ]] || evidence_die "package outside required closure: $package"
    [[ $(tail -n +2 "$metadata" | awk -F '\t' -v p="$package" '$1 == p {n++} END {print n + 0}') -eq 1 ]] || evidence_die "duplicate package metadata: $package"
    [[ $artifact != /* && $artifact != *'/'../* && $artifact != ../* && $artifact != *'/'.. && $artifact =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.pkg\.tar\.(zst|xz)$ ]] || evidence_die "unsafe artifact path: $artifact"
    scan_forbidden_value "$artifact"
    [[ $(tail -n +2 "$metadata" | awk -F '\t' -v a="$artifact" '$5 == a {n++} END {print n + 0}') -eq 1 ]] || evidence_die "duplicate artifact: $artifact"
    artifact_path="$root/$artifact"; [[ -d "$root/packages" && -f "$root/packages/$artifact" ]] && artifact_path="$root/packages/$artifact"
    evidence_abs_regular "$artifact_path"; [[ $(evidence_sha256 "$artifact_path") == "$hash" ]] || evidence_die "package hash mismatch: $package"
    verify_archive "$artifact_path" "$package" "$version" "$architecture"
    rows=$((rows + 1))
done < "$metadata"
((rows == required_count)) || evidence_die "package closure incomplete: $rows/$required_count"
while IFS=$'\t' read -r package role; do
    [[ $(tail -n +2 "$metadata" | awk -F '\t' -v p="$package" '$1 == p {n++} END {print n + 0}') -eq 1 ]] || evidence_die "missing required package: $package"
done < <(awk 'NF && $1 !~ /^#/ {print}' "$required")
repo_mode=false; [[ -d "$root/packages" ]] && repo_mode=true
if [[ $repo_mode == true ]]; then for file in manifest.txt repo.db coverage.tsv SHA256SUMS; do evidence_abs_regular "$root/$file"; done; m8_validate_platform_coverage "$root/coverage.tsv" "$coverage_contract"; fi
if [[ $repo_mode == true ]]; then scan_forbidden "$root/manifest.txt"; scan_forbidden "$root/repo.db"; scan_unsafe_actions "$root/manifest.txt"; scan_unsafe_actions "$root/repo.db"; fi
while IFS= read -r -d '' member; do
    rel=${member#"$root"/}
    case $rel in
        packages.tsv) ;;
        SHA256SUMS|manifest.txt|repo.db|coverage.tsv) [[ $repo_mode == true ]] || evidence_die "undeclared member: $rel";;
        packages/*) [[ $repo_mode == true ]] || evidence_die "undeclared member: $rel"; artifact=${rel#packages/}; [[ $(tail -n +2 "$metadata" | awk -F '\t' -v a="$artifact" '$5 == a {n++} END {print n + 0}') -eq 1 ]] || evidence_die "undeclared package artifact: $rel";;
        *) [[ $repo_mode != true ]] || evidence_die "undeclared member: $rel"; [[ $(tail -n +2 "$metadata" | awk -F '\t' -v a="$rel" '$5 == a {n++} END {print n + 0}') -eq 1 ]] || evidence_die "undeclared member: $rel";;
    esac
done < <(find -P "$root" -type f -print0)
while IFS= read -r -d '' dir; do
    rel=${dir#"$root"/}
    [[ $repo_mode == true && $rel == packages ]] || evidence_die "undeclared directory: $rel"
done < <(find -P "$root" -mindepth 1 -type d -print0)
while IFS= read -r -d '' link; do evidence_die "symlink member: $link"; done < <(find -P "$root" -type l -print0)
if [[ -f "$root/manifest.txt" ]]; then
    [[ $repo_mode == true ]] || evidence_die 'manifest requires repository layout'
    [[ $(evidence_kv "$root/manifest.txt" signed) == false ]] || evidence_die 'signed preview is not accepted'
    [[ $(evidence_kv "$root/manifest.txt" published) == false ]] || evidence_die 'published repo is not accepted'
    [[ $(evidence_kv "$root/manifest.txt" installed) == false ]] || evidence_die 'installed repo is not accepted'
    [[ $(evidence_kv "$root/manifest.txt" booted) == false ]] || evidence_die 'booted repo is not accepted'
    [[ $(evidence_kv "$root/manifest.txt" hardware_acceptance) == false ]] || evidence_die 'hardware acceptance must be false'
fi
printf 'M8=package-closure-verified packages=%s\n' "$rows"
