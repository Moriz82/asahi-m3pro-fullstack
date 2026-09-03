#!/usr/bin/env bash
# Shared M9 canonical-release provenance checks.
m9_validate_canonical_release_binding() {
    local release=$1 anchor=$2 map header milestone rel manifest_hash handoff_hash release_set
    evidence_abs_regular "$release/manifest.txt"
    [[ $(evidence_kv "$release/manifest.txt" format) == 2 ]] || evidence_die 'release must use format 2'
    release_set=$(awk -F= '$1 == "release_input_set" {print $2; exit}' "$release/manifest.txt")
    [[ $release_set == canonical-milestone-handoffs ]] || evidence_die 'release must use canonical milestone handoffs'
    [[ $(evidence_kv "$anchor" anchor_type) == external-milestone-handoffs ]] || evidence_die 'canonical release requires a milestone-handoff anchor'
    evidence_abs_regular "$release/canonical-handoff-map.tsv"
    evidence_abs_dir "$release/handoffs"
    while IFS= read -r -d '' entry; do evidence_die "canonical release handoff symlink: $entry"; done < <(find -P "$release/handoffs" -type l -print0)
    while IFS= read -r -d '' entry; do evidence_die "canonical release handoff has non-regular member: $entry"; done < <(find -P "$release/handoffs" ! -type f ! -type d ! -type l -print0)
    map="$release/canonical-handoff-map.tsv"
    header=$(head -n 1 "$map")
    [[ $header == $'milestone\tmanifest\tmanifest_sha256\thandoff_sha256' ]] || evidence_die 'invalid canonical handoff map header'
    expected=(M0 M1 M2 M3 M4 M5 M6 M7 M8)
    index=0
    while IFS=$'\t' read -r milestone rel manifest_hash handoff_hash extra; do
        [[ -z ${extra:-} && ${expected[index]:-} == "$milestone" ]] || evidence_die 'canonical handoff map is not ordered M0 through M8'
        [[ $rel == manifests/$milestone/manifest.txt && $manifest_hash =~ ^[[:xdigit:]]{64}$ && $handoff_hash =~ ^[[:xdigit:]]{64}$ ]] || evidence_die "invalid canonical handoff map row: $milestone"
        evidence_abs_regular "$release/$rel"
        [[ $(evidence_sha256 "$release/$rel") == "$manifest_hash" ]] || evidence_die "canonical manifest map hash mismatch: $milestone"
        evidence_abs_dir "$release/handoffs/$milestone"
        [[ $(evidence_sha256 "$release/handoffs/$milestone/manifest.txt") == "$manifest_hash" ]] || evidence_die "standalone canonical manifest differs from handoff: $milestone"
        MILESTONE_HANDOFF_ROOT="$release/handoffs" bash "$M9_PROJECT_ROOT/scripts/verify-milestone-handoff.sh" --bundle "$release/handoffs/$milestone" >/dev/null
        [[ $(evidence_sha256 "$release/handoffs/$milestone/SHA256SUMS") == "$handoff_hash" ]] || evidence_die "canonical handoff map bundle mismatch: $milestone"
        [[ $(evidence_kv "$anchor" "${milestone}_handoff_sha256") == "$handoff_hash" ]] || evidence_die "canonical handoff anchor mismatch: $milestone"
        [[ $(evidence_kv "$release/manifest.txt" "${milestone}_handoff_sha256") == "$handoff_hash" ]] || evidence_die "canonical release handoff mismatch: $milestone"
        index=$((index + 1))
    done < <(tail -n +2 "$map")
    [[ $index == 9 ]] || evidence_die 'canonical handoff map must contain exactly M0 through M8'
    [[ $(evidence_kv "$release/manifest.txt" canonical_handoff_map_sha256) == "$(evidence_sha256 "$map")" ]] || evidence_die 'canonical handoff map is not release-pinned'
    while IFS= read -r -d '' entry; do
        [[ $(basename "$entry") =~ ^M[0-8]$ ]] || evidence_die "unexpected canonical handoff directory: $entry"
    done < <(find -P "$release/handoffs" -mindepth 1 -maxdepth 1 -type d -print0)
}
