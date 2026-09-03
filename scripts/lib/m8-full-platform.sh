#!/usr/bin/env bash
# Shared read-only helpers for the M8 full-platform package candidate.

m8_full_contract_rows() {
    awk 'NF && $1 !~ /^#/ {print}' "$1"
}

m8_full_validate_contract() {
    local contract=$1 package role source extra rows local_count arch_count asahi_count
    evidence_abs_regular "$contract"
    [[ $(head -n 1 "$contract") == '# package<TAB>role<TAB>source' ]] || evidence_die 'invalid full-platform contract header'
    LC_ALL=C m8_full_contract_rows "$contract" | sort -c || evidence_die 'full-platform contract is not sorted'
    rows=$(m8_full_contract_rows "$contract" | awk 'END {print NR + 0}')
    [[ $rows -eq 23 ]] || evidence_die "full-platform contract requires exactly 23 packages: $rows"
    while IFS=$'\t' read -r package role source extra; do
        [[ -z ${extra:-} && $package =~ ^[a-z0-9][a-z0-9+._-]*$ && $role =~ ^[a-z0-9][a-z0-9-]*$ ]] || evidence_die "invalid full-platform contract row: $package"
        [[ $source == local-m0 || $source == archlinuxarm || $source == asahi-alarm ]] || evidence_die "invalid full-platform package source: $package"
        [[ $(m8_full_contract_rows "$contract" | awk -F '\t' -v p="$package" '$1 == p {n++} END {print n + 0}') -eq 1 ]] || evidence_die "duplicate full-platform package: $package"
    done < <(m8_full_contract_rows "$contract")
    local_count=$(m8_full_contract_rows "$contract" | awk -F '\t' '$3 == "local-m0" {n++} END {print n + 0}')
    arch_count=$(m8_full_contract_rows "$contract" | awk -F '\t' '$3 == "archlinuxarm" {n++} END {print n + 0}')
    asahi_count=$(m8_full_contract_rows "$contract" | awk -F '\t' '$3 == "asahi-alarm" {n++} END {print n + 0}')
    [[ $local_count -eq 2 && $arch_count -eq 5 && $asahi_count -eq 16 ]] || evidence_die "invalid full-platform source split: $local_count/$arch_count/$asahi_count"
}

m8_full_manifest_row() {
    local manifest=$1 expected=$2
    awk -F '\t' -v expected="$expected" '
        NR > 1 && $1 == expected {found++; row=$0}
        END {if (found != 1) exit 1; print row}
    ' "$manifest" || evidence_die "package missing or duplicated in manifest: $expected"
}

m8_full_validate_archive_paths() {
    local archive=$1
    bsdtar -tf "$archive" | awk '
        {
            path=$0
            sub(/^\.\//, "", path)
            if (path == "" || path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/ || path ~ /[[:cntrl:]]/) bad=1
        }
        END {exit bad}
    ' || evidence_die "unsafe package archive path: $archive"
}

m8_full_package_field() {
    local archive=$1 wanted=$2 record index
    record=$(m8_full_package_record "$archive") || return
    case $wanted in
        pkgname) index=1 ;;
        pkgver) index=2 ;;
        arch) index=3 ;;
        *) evidence_die "unsupported package field: $wanted"; return 1 ;;
    esac
    cut -f "$index" <<<"$record"
}

m8_full_package_record() {
    local archive=$1 listing member
    listing=$(bsdtar -tf "$archive") || evidence_die "invalid package archive: $archive"
    member=$(printf '%s\n' "$listing" | awk '
        {path=$0; sub(/^\.\//, "", path)}
        path == ".PKGINFO" {found++; selected=$0}
        END {if (found != 1) exit 1; print selected}
    ') || evidence_die "package archive must contain exactly one .PKGINFO: $archive"
    bsdtar -xOf "$archive" "$member" | awk -F ' = ' '
        $1 == "pkgname" {name_count++; name=$2}
        $1 == "pkgver" {version_count++; version=$2}
        $1 == "arch" {arch_count++; architecture=$2}
        END {
            if (name_count != 1 || version_count != 1 || arch_count != 1) exit 1
            printf "%s\t%s\t%s\n", name, version, architecture
        }
    ' || evidence_die "invalid package identity metadata: $archive"
}

m8_full_find_package() {
    local root=$1 expected=$2 candidate embedded _ found=0 selected=
    while IFS= read -r -d '' candidate; do
        IFS=$'\t' read -r embedded _ <<<"$(m8_full_package_record "$candidate")"
        if [[ $embedded == "$expected" ]]; then
            found=$((found + 1))
            selected=$candidate
        fi
    done < <(find -P "$root" -maxdepth 1 -type f \( -name '*.pkg.tar.xz' -o -name '*.pkg.tar.zst' \) -print0)
    [[ $found -eq 1 ]] || evidence_die "source package missing or duplicated: $expected"
    printf '%s\n' "$selected"
}

m8_full_write_directory_manifest() {
    local root=$1 output=$2 candidate package version architecture artifact hash extra
    printf 'package\tversion\tarchitecture\tsha256\tartifact\n' >"$output"
    while IFS= read -r -d '' candidate; do
        IFS=$'\t' read -r package version architecture extra <<<"$(m8_full_package_record "$candidate")"
        [[ -z ${extra:-} ]] || evidence_die "invalid package identity metadata: $candidate"
        artifact=$(basename -- "$candidate")
        hash=$(evidence_sha256 "$candidate")
        printf '%s\t%s\t%s\t%s\t%s\n' "$package" "$version" "$architecture" "$hash" "$artifact" >>"$output"
    done < <(find -P "$root" -maxdepth 1 -type f \( -name '*.pkg.tar.xz' -o -name '*.pkg.tar.zst' \) -print0 | sort -z)
}

m8_full_write_lifecycle_manifest() {
    local packages=$1 packages_root=$2 output=$3 package artifact archive listing member normalized hash
    printf 'package\tpath\tsha256\n' >"$output"
    while IFS=$'\t' read -r package _ _ _ artifact extra; do
        [[ -z $package ]] && continue
        [[ -z ${extra:-} ]] || evidence_die "invalid package row: $package"
        archive="$packages_root/$artifact"
        evidence_abs_regular "$archive"
        listing=$(bsdtar -tf "$archive") || evidence_die "invalid package archive: $archive"
        while IFS= read -r member; do
            normalized=${member#./}
            case $normalized in
                .INSTALL|*/.INSTALL|usr/share/libalpm/hooks/*.hook|etc/pacman.d/hooks/*.hook) ;;
                *) continue ;;
            esac
            [[ $normalized != /* && $normalized != .. && $normalized != ../* && $normalized != */../* && $normalized != */.. && $normalized != *$'\t'* ]] || evidence_die "unsafe lifecycle path: $archive:$normalized"
            hash=$(bsdtar -xOf "$archive" "$member" | evidence_sha256_stream) || evidence_die "cannot hash lifecycle member: $archive:$normalized"
            printf '%s\t%s\t%s\n' "$package" "$normalized" "$hash" >>"$output"
        done <<<"$listing"
    done < <(tail -n +2 "$packages")
    { head -n 1 "$output"; tail -n +2 "$output" | LC_ALL=C sort; } >"$output.sorted"
    mv -- "$output.sorted" "$output"
}
