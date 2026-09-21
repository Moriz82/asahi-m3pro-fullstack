#!/usr/bin/env bash
# Shared M9 canonical-release provenance checks.
m9_require_m1_anchor_args() {
    [[ $# -ge 4 && $1 == --expected-target-identity-sha256 && $3 == --target-readiness-anchors &&
       $2 =~ ^[0-9a-f]{64}$ && $4 == /* ]] || {
        evidence_die 'M9 requires explicit M1 target identity and independent readiness anchors'; return 1;
    }
    M9_EXPECTED_TARGET=$2
    M9_TARGET_ANCHORS=$4
    evidence_abs_regular "$M9_TARGET_ANCHORS"
}

m9_validate_canonical_release_binding() {
    local release=$1 anchor=$2 map inputs header milestone rel manifest_hash handoff_hash release_set
    local hardware_acceptance native_readiness backup_recovery dfu dedicated_hardware extra index entry
    local expected_target=$3 target_anchors=$4
    evidence_abs_regular "$release/manifest.txt"
    evidence_abs_regular "$release/identity.txt"
    evidence_abs_regular "$release/release-inputs.tsv"
    [[ $(evidence_kv "$release/manifest.txt" format) == 2 ]] || evidence_die 'release must use format 2'
    release_set=$(awk -F= '$1 == "release_input_set" {print $2; exit}' "$release/manifest.txt")
    [[ $release_set == canonical-milestone-handoffs ]] || evidence_die 'release must use canonical milestone handoffs'
    [[ $(evidence_kv "$anchor" anchor_type) == external-milestone-handoffs ]] || evidence_die 'canonical release requires a milestone-handoff anchor'
    [[ $(evidence_kv "$release/manifest.txt" target_model) == Mac15,6 && $(evidence_kv "$release/manifest.txt" target_board) == J514s && $(evidence_kv "$release/manifest.txt" target_soc) == T6030 ]] || evidence_die 'canonical release target mismatch'
    [[ $(wc -l < "$release/identity.txt" | tr -d '[:space:]') == 3 ]] || evidence_die 'canonical release identity must contain exactly three rows'
    [[ $(evidence_kv "$release/identity.txt" model) == Mac15,6 && $(evidence_kv "$release/identity.txt" board) == J514s && $(evidence_kv "$release/identity.txt" soc) == T6030 ]] || evidence_die 'canonical release identity mismatch'
    inputs="$release/release-inputs.tsv"
    [[ $(evidence_kv "$release/manifest.txt" release_input_set_sha256) == "$(evidence_sha256 "$inputs")" ]] || evidence_die 'canonical release input set is not release-pinned'
    header=$(head -n 1 "$inputs")
    [[ $header == $'milestone\tmanifest\tmanifest_sha256\thardware_acceptance\tnative_readiness\tbackup_recovery\tdfu\tdedicated_hardware' ]] || evidence_die 'invalid canonical release-input header'
    expected=(M0 M1 M2 M3 M4 M5 M6 M7 M8)
    index=0
    while IFS=$'\t' read -r milestone rel manifest_hash hardware_acceptance native_readiness backup_recovery dfu dedicated_hardware extra; do
        [[ -z ${extra:-} && ${expected[index]:-} == "$milestone" ]] || evidence_die 'canonical release inputs are not ordered M0 through M8'
        [[ $rel == manifests/$milestone/manifest.txt && $manifest_hash =~ ^[[:xdigit:]]{64}$ ]] || evidence_die "invalid canonical release-input row: $milestone"
        [[ $hardware_acceptance == false && $native_readiness == false && $backup_recovery == false && $dfu == false && $dedicated_hardware == false ]] || evidence_die "canonical release input claims readiness: $milestone"
        evidence_abs_regular "$release/$rel"
        [[ $(evidence_sha256 "$release/$rel") == "$manifest_hash" ]] || evidence_die "canonical release-input manifest mismatch: $milestone"
        index=$((index + 1))
    done < <(tail -n +2 "$inputs")
    [[ $index == 9 ]] || evidence_die 'canonical release inputs must contain exactly M0 through M8'
    evidence_abs_regular "$release/canonical-handoff-map.tsv"
    evidence_abs_dir "$release/handoffs"
    while IFS= read -r -d '' entry; do evidence_die "canonical release handoff symlink: $entry"; done < <(find -P "$release/handoffs" -type l -print0)
    while IFS= read -r -d '' entry; do evidence_die "canonical release handoff has non-regular member: $entry"; done < <(find -P "$release/handoffs" ! -type f ! -type d ! -type l -print0)
    map="$release/canonical-handoff-map.tsv"
    header=$(head -n 1 "$map")
    [[ $header == $'milestone\tmanifest\tmanifest_sha256\thandoff_sha256' ]] || evidence_die 'invalid canonical handoff map header'
    index=0
    while IFS=$'\t' read -r milestone rel manifest_hash handoff_hash extra; do
        [[ -z ${extra:-} && ${expected[index]:-} == "$milestone" ]] || evidence_die 'canonical handoff map is not ordered M0 through M8'
        [[ $rel == manifests/$milestone/manifest.txt && $manifest_hash =~ ^[[:xdigit:]]{64}$ && $handoff_hash =~ ^[[:xdigit:]]{64}$ ]] || evidence_die "invalid canonical handoff map row: $milestone"
        evidence_abs_regular "$release/$rel"
        [[ $(evidence_sha256 "$release/$rel") == "$manifest_hash" ]] || evidence_die "canonical manifest map hash mismatch: $milestone"
        evidence_abs_dir "$release/handoffs/$milestone"
        [[ $(evidence_sha256 "$release/handoffs/$milestone/manifest.txt") == "$manifest_hash" ]] || evidence_die "standalone canonical manifest differs from handoff: $milestone"
        if [[ $milestone == M1 ]]; then
            MILESTONE_HANDOFF_ROOT="$release/handoffs" bash "$M9_PROJECT_ROOT/scripts/verify-milestone-handoff.sh" \
                --bundle "$release/handoffs/$milestone" --expected-target-identity-sha256 "$expected_target" \
                --target-readiness-anchors "$target_anchors" >/dev/null
        else
            MILESTONE_HANDOFF_ROOT="$release/handoffs" bash "$M9_PROJECT_ROOT/scripts/verify-milestone-handoff.sh" --bundle "$release/handoffs/$milestone" >/dev/null
        fi
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
