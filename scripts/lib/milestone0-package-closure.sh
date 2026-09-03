#!/usr/bin/env bash

# Build a package closure from the pacman staging tree, before makepkg creates
# the archive.  Records are path, type (- regular, d directory, l symlink),
# and the exact symlink target.
m0_validate_symlink_target() {
    local link_path="$1" target="$2" parent combined component
    local -a resolved components
    [[ -n "$target" && "$target" != /* && "$target" != *'//'*
        && "$target" != *[[:space:]]* ]] || return 1
    if [[ "$link_path" == */* ]]; then
        parent="${link_path%/*}"
    else
        parent=
    fi
    combined="${parent:+$parent/}$target"
    IFS=/ read -r -a components <<< "$combined"
    resolved=()
    for component in "${components[@]}"; do
        case "$component" in
            ''|.) ;;
            ..)
                ((${#resolved[@]} > 0)) || return 1
                resolved=("${resolved[@]:0:${#resolved[@]}-1}")
                ;;
            *) resolved+=("$component") ;;
        esac
    done
}

m0_package_closure_from_tree() (
    local root="$1" output="$2" path rel type target records_tmp
    [[ -d "$root" && ! -L "$root" ]] || return 1
    records_tmp="$(mktemp)"
    trap 'rm -f -- "$records_tmp"' EXIT
    while IFS= read -r -d '' path; do
        rel="${path#"$root"/}"
        [[ -n "$rel" && "$rel" != /* && "$rel" != *'//'*
            && "$rel" != *[[:space:]]* ]] || return 1
        ! grep -Eq '(^|/)\.\.?(/|$)' <<< "$rel" || return 1
        target=
        if [[ -L "$path" ]]; then
            type=l
            target="$(readlink "$path")"
            m0_validate_symlink_target "$rel" "$target" || return 1
        elif [[ -d "$path" ]]; then
            type=d
        elif [[ -f "$path" ]]; then
            type=-
        else
            printf 'Unsupported package staging member: %s\n' "$rel" >&2
            return 1
        fi
        printf '%s\t%s\t%s\n' "$rel" "$type" "$target" >> "$records_tmp"
    done < <(find -P "$root" -mindepth 1 -print0 | LC_ALL=C sort -z)
    LC_ALL=C sort -t $'\t' -k1,1 "$records_tmp" > "$output"
    [[ -s "$output" ]] || return 1
    [[ -z "$(cut -f1 "$output" | uniq -d)" ]] || return 1
)

m0_package_closure_add_makepkg_metadata() {
    local closure="$1" metadata
    [[ -s "$closure" ]] || return 1
    for metadata in .PKGINFO .BUILDINFO .MTREE; do
        if awk -F $'\t' -v path="$metadata" '$1 == path { found = 1 } END { exit !found }' "$closure"; then
            grep -Fqx "$metadata"$'\t-\t' "$closure" || return 1
        else
            printf '%s\t-\t\n' "$metadata" >> "$closure"
        fi
    done
    LC_ALL=C sort -t $'\t' -k1,1 "$closure" -o "$closure"
    [[ -z "$(cut -f1 "$closure" | uniq -d)" ]]
}

m0_archive_member_paths() {
    local archive="$1" output="$2" member normalized
    : > "$output"
    while IFS= read -r member; do
        normalized="${member#./}"
        normalized="${normalized%/}"
        [[ -n "$normalized" && "$normalized" != /* && "$normalized" != *'//'*
            && "$normalized" != *[[:space:]]* ]] || return 1
        ! grep -Eq '(^|/)\.\.?(/|$)' <<< "$normalized" || return 1
        printf '%s\n' "$normalized" >> "$output"
    done < <(LC_ALL=C bsdtar -tf "$archive")
    LC_ALL=C sort "$output" -o "$output"
    [[ -z "$(uniq -d "$output")" ]]
}

# Independently inspect archive types and compare them to the tree-derived
# closure.  The path-only listing is checked separately to catch duplicate or
# normalized member names before any extraction is attempted.
m0_archive_closure_verify() (
    local archive="$1" closure="$2" tmpdir line path type target
    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' EXIT
    [[ -s "$closure" ]] || return 1
    while IFS=$'\t' read -r path type target; do
        [[ -n "$path" && "$path" != /* && "$path" != *'//'*
            && "$path" != *[[:space:]]* ]] || return 1
        ! grep -Eq '(^|/)\.\.?(/|$)' <<< "$path" || return 1
        case "$type" in
            -|d) [[ -z "$target" ]] || return 1 ;;
            l) m0_validate_symlink_target "$path" "$target" || return 1 ;;
            *) return 1 ;;
        esac
    done < "$closure"
    [[ -z "$(cut -f1 "$closure" | LC_ALL=C sort | uniq -d)" ]] || return 1

    m0_archive_member_paths "$archive" "$tmpdir/actual.paths"
    cut -f1 "$closure" | LC_ALL=C sort > "$tmpdir/closure.paths"
    cmp "$tmpdir/actual.paths" "$tmpdir/closure.paths"

    # bsdtar -tvf supplies type and link-target data independently of the
    # normalized path listing used above.
    LC_ALL=C bsdtar -tvf "$archive" > "$tmpdir/listing"
    : > "$tmpdir/actual.closure"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        type="${line:0:1}"
        case "$type" in -|d|l) ;; *) return 1 ;; esac
        path="$(awk -v record="$line" 'BEGIN {
            n = split(record, fields);
            if (substr(fields[1], 1, 1) == "l" && fields[n - 1] == "->")
                print fields[n - 2];
            else
                print fields[n];
        }')"
        target=
        if [[ "$type" = l ]]; then
            [[ "$line" == *' -> '* ]] || return 1
            target="${line##* -> }"
            m0_validate_symlink_target "$path" "$target" || return 1
        fi
        path="${path#./}"
        path="${path%/}"
        [[ -n "$path" ]] || continue
        printf '%s\t%s\t%s\n' "$path" "$type" "$target" >> "$tmpdir/actual.closure"
    done < "$tmpdir/listing"
    LC_ALL=C sort -t $'\t' -k1,1 "$tmpdir/actual.closure" -o "$tmpdir/actual.closure"
    [[ -z "$(cut -f1 "$tmpdir/actual.closure" | uniq -d)" ]] || return 1
    cmp "$tmpdir/actual.closure" "$closure"
)
