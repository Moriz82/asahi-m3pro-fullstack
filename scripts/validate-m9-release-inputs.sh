#!/usr/bin/env bash
# Validate a release-input set without executing or emitting host actions.
# shellcheck disable=SC1091,SC2174,SC2329
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
M9_PROJECT_ROOT=$project_root
source "$project_root/scripts/lib/m9-canonical.sh"
m9_require_m1_anchor_args "$@"
shift 4
output_root=${SOFTWARE_OUTPUT_ROOT:-$project_root/out}
usage() {
    printf '       %s --expected-target-identity-sha256 HEX --target-readiness-anchors ABS --handoffs-root ABS --anchor ABS --out ABS\n' "$0" >&2
    exit 64
}
copy_tree() {
    local input=$1 destination=$2 file rel entry
    evidence_abs_dir "$input"
    while IFS= read -r -d '' entry; do evidence_die "handoff source symlink: $entry"; done < <(find -P "$input" -type l -print0)
    while IFS= read -r -d '' entry; do evidence_die "handoff source has non-regular member: $entry"; done < <(find -P "$input" ! -type f ! -type d ! -type l -print0)
    while IFS= read -r -d '' entry; do
        [[ -n "$(find -P "$entry" -mindepth 1 -maxdepth 1 -print -quit)" ]] || evidence_die "handoff source has empty directory: $entry"
    done < <(find -P "$input" -type d -print0)
    mkdir -p -m 700 -- "$destination"
    while IFS= read -r -d '' file; do
        rel=${file#"$input"/}
        [[ $rel != /* && $rel != ../* && $rel != *'/'../* && $rel != *'/'.. && $rel != *$'\n'* ]] || evidence_die 'unsafe handoff copy path'
        mkdir -p -m 700 -- "$(dirname -- "$destination/$rel")"
        [[ ! -e "$destination/$rel" && ! -L "$destination/$rel" ]] || evidence_die "duplicate handoff copy path: $rel"
        cp -p -- "$file" "$destination/$rel"
        if [[ ${M9_HANDOFF_TEST_PAUSE_AFTER_FIRST_COPY:-0} == 1 && -z ${m9_copy_test_pause_fired:-} ]]; then
            evidence_new_file "$destination/.m9-copy-test-paused"
            /bin/sleep 2
            rm -f -- "$destination/.m9-copy-test-paused"
            m9_copy_test_pause_fired=true
        fi
    done < <(find -P "$input" -type f -print0 | sort -z)
}
validate_canonical_handoffs() {
    local handoffs=$1 anchor=$2 out=$3 milestone hash source anchor_hash out_parent handoffs_parent
    evidence_abs_dir "$handoffs"; evidence_abs_regular "$anchor"
    handoffs_parent=$(dirname -- "$handoffs")
    evidence_abs_dir "$handoffs_parent"
    out_parent=$(dirname -- "$out")
    mkdir -p -m 700 -- "$output_root" "$out_parent" "$MILESTONE_HANDOFF_ROOT"
    evidence_abs_dir "$output_root"; evidence_abs_dir "$out_parent"; evidence_abs_dir "$MILESTONE_HANDOFF_ROOT"
    evidence_path_under "$out" "$output_root"
    [[ ! -e "$out" && ! -L "$out" ]] || evidence_die "release output already exists: $out"
    [[ $anchor != "$handoffs" && $anchor != "$handoffs"/* && $anchor != "$out" && $anchor != "$out"/* ]] || evidence_die 'anchor must be external'
    stage=$(mktemp -d "$handoffs_parent/.m9-verify.XXXXXX")
    cleanup_canonical() { rm -rf -- "${stage:-}" "${publish:-}"; }
    trap cleanup_canonical EXIT
    publish=$(mktemp -d "$out_parent/.m9-release.XXXXXX")
    m9_copy_test_pause_fired=
    # Copy the anchor explicitly and retain its read-only mode in the private
    # verification stage. It is copied before the handoff snapshots.
    mkdir -m 700 "$stage/handoffs"
    cp -p -- "$anchor" "$stage/anchor.txt"
    evidence_readonly "$stage/anchor.txt"
    [[ $(evidence_kv "$stage/anchor.txt" format) == 1 && $(evidence_kv "$stage/anchor.txt" anchor_type) == external-milestone-handoffs ]] || evidence_die 'invalid handoff anchor'
    [[ $(evidence_kv "$stage/anchor.txt" anchor_trust) == untrusted-declarative ]] || evidence_die 'handoff anchor is not signed authority'
    [[ $(evidence_kv "$stage/anchor.txt" target_model) == Mac15,6 && $(evidence_kv "$stage/anchor.txt" target_board) == J514s && $(evidence_kv "$stage/anchor.txt" target_soc) == T6030 ]] || evidence_die 'handoff anchor target mismatch'
    expected=(M0 M1 M2 M3 M4 M5 M6 M7 M8)
    for milestone in "${expected[@]}"; do
        source="$handoffs/$milestone"
        evidence_abs_dir "$source"
        copy_tree "$source" "$stage/handoffs/$milestone"
    done
    while IFS= read -r -d '' entry; do
        [[ -d $entry && ! -L $entry ]] || evidence_die 'handoff root contains non-directory member'
        [[ $(basename "$entry") =~ ^M[0-8]$ ]] || evidence_die "unexpected handoff member: $entry"
    done < <(find -P "$handoffs" -mindepth 1 -maxdepth 1 -print0)
    for milestone in "${expected[@]}"; do
        source="$stage/handoffs/$milestone"
        if [[ $milestone == M1 ]]; then
            MILESTONE_HANDOFF_ROOT="$stage/handoffs" bash "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$source" \
                --expected-target-identity-sha256 "$M9_EXPECTED_TARGET" --target-readiness-anchors "$M9_TARGET_ANCHORS" >/dev/null
        else
            MILESTONE_HANDOFF_ROOT="$stage/handoffs" bash "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$source" >/dev/null
        fi
        [[ $(evidence_kv "$source/manifest.txt" milestone) == "$milestone" ]] || evidence_die "handoff milestone mismatch: $milestone"
        hash=$(evidence_sha256 "$source/SHA256SUMS")
        [[ $(evidence_kv "$stage/anchor.txt" "${milestone}_handoff_sha256") == "$hash" ]] || evidence_die "external handoff hash mismatch: $milestone"
    done
    anchor_hash=$(evidence_sha256 "$stage/anchor.txt")
    mkdir -m 700 "$publish/manifests" "$publish/handoffs"
    printf 'model=Mac15,6\nboard=J514s\nsoc=T6030\n' > "$publish/identity.txt"
    printf 'milestone\tmanifest\tmanifest_sha256\thardware_acceptance\tnative_readiness\tbackup_recovery\tdfu\tdedicated_hardware\n' > "$publish/release-inputs.tsv"
    printf 'milestone\tmanifest\tmanifest_sha256\thandoff_sha256\n' > "$publish/canonical-handoff-map.tsv"
    for milestone in "${expected[@]}"; do
        mkdir -m 700 "$publish/manifests/$milestone"
        cp -p -- "$stage/handoffs/$milestone/manifest.txt" "$publish/manifests/$milestone/manifest.txt"
        copy_tree "$stage/handoffs/$milestone" "$publish/handoffs/$milestone"
        printf '%s\tmanifests/%s/manifest.txt\t%s\tfalse\tfalse\tfalse\tfalse\tfalse\n' "$milestone" "$milestone" "$(evidence_sha256 "$publish/manifests/$milestone/manifest.txt")" >> "$publish/release-inputs.tsv"
        printf '%s\tmanifests/%s/manifest.txt\t%s\t%s\n' "$milestone" "$milestone" "$(evidence_sha256 "$publish/manifests/$milestone/manifest.txt")" "$(evidence_sha256 "$publish/handoffs/$milestone/SHA256SUMS")" >> "$publish/canonical-handoff-map.tsv"
    done
    (umask 077; {
        printf 'format=2\nrelease_input_set=canonical-milestone-handoffs\n'
        printf 'target_model=Mac15,6\ntarget_board=J514s\ntarget_soc=T6030\n'
        printf 'milestones=M0,M1,M2,M3,M4,M5,M6,M7,M8\n'
        for milestone in "${expected[@]}"; do printf '%s_handoff_sha256=%s\n' "$milestone" "$(evidence_sha256 "$stage/handoffs/$milestone/SHA256SUMS")"; done
        printf 'external_anchor_sha256=%s\nrelease_input_set_sha256=%s\ncanonical_handoff_map_sha256=%s\ntooling_valid=true\nevidence_valid=true\nhardware_acceptance=false\nnative_readiness=false\nbackup_recovery=false\ndfu=false\ndedicated_hardware=false\nrelease_gate=blocked\nanchor_trust=untrusted-declarative\nactuation=false\n' "$anchor_hash" "$(evidence_sha256 "$publish/release-inputs.tsv")" "$(evidence_sha256 "$publish/canonical-handoff-map.tsv")"
    } > "$publish/manifest.txt")
    (umask 077; {
        printf 'mode=canonical-handoff-validation\n'
        printf 'Only verifier-approved canonical M0-M8 handoffs and the external per-milestone hash anchor are accepted.\n'
        printf 'No installer, storage, APFS, firmware, startup, reboot, or package action is performed.\n'
        printf 'hardware_acceptance=false; native execution remains blocked.\n'
    } > "$publish/policy.txt")
    evidence_write_sums "$publish" "$publish/SHA256SUMS"
    evidence_verify_sums "$publish" "$publish/SHA256SUMS"
    evidence_atomic_publish_directory "$publish" "$out"
    [[ -d $out && ! -L $out && ! -e $publish && ! -L $publish ]] || evidence_die 'published release is not exactly the verified stage'
    publish=
    printf 'M9=canonical-handoffs-validated gate=blocked hardware_acceptance=false evidence=%s\n' "$out"
}
if [[ $# -eq 6 && $1 == --handoffs-root && $3 == --anchor && $5 == --out ]]; then
    validate_canonical_handoffs "$2" "$4" "$6"
    exit 0
fi
usage
