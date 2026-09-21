#!/usr/bin/env bash
# Create one immutable, software-only canonical milestone handoff.
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/milestone0-components.sh"
usage() { printf 'usage: %s --milestone M0..M8 --source ABS --out ABS [M1: --expected-target-identity-sha256 HEX --target-readiness-anchors ABS]\n' "$0" >&2; exit 64; }
milestone='' source='' out='' expected_target='' anchors_file=''
while (($#)); do
    case $1 in
        --milestone) [[ $# -ge 2 ]] || usage; milestone=$2; shift 2;;
        --source|--input) [[ $# -ge 2 ]] || usage; source=$2; shift 2;;
        --out) [[ $# -ge 2 ]] || usage; out=$2; shift 2;;
        --expected-target-identity-sha256) [[ $# -ge 2 && -z $expected_target ]] || usage; expected_target=$2; shift 2;;
        --target-readiness-anchors) [[ $# -ge 2 && -z $anchors_file ]] || usage; anchors_file=$2; shift 2;;
        *) usage;;
    esac
done
[[ $milestone =~ ^M[0-8]$ && -n $source && -n $out ]] || usage
if [[ $milestone == M1 ]]; then
    [[ $expected_target =~ ^[0-9a-f]{64}$ && $anchors_file == /* ]] || usage
    evidence_abs_regular "$anchors_file"
else
    [[ -z $expected_target$anchors_file ]] || usage
fi
evidence_abs_dir "$source"
mkdir -p -m 700 -- "$MILESTONE_EVIDENCE_ROOT" "$MILESTONE_HANDOFF_ROOT"
evidence_abs_dir "$MILESTONE_EVIDENCE_ROOT"
evidence_abs_dir "$MILESTONE_HANDOFF_ROOT"
evidence_path_under "$out" "$MILESTONE_HANDOFF_ROOT"
[[ ! -e "$out" && ! -L "$out" ]] || evidence_die "handoff output already exists: $out"

verifier='' source_kind=''
case $milestone in
    M0) verifier=verify-milestone0.sh; source_kind=m0-component-manifest-set;;
    M1) verifier=verify-milestone1-session.sh; source_kind=m1-checksummed-session;;
    M2) verifier=verify-m2-core-power.sh; source_kind=m2-verified-bundle;;
    M3) verifier=verify-m3-display-dcp.sh; source_kind=m3-verified-bundle;;
    M4) verifier=verify-m4-gpu.sh; source_kind=m4-verified-bundle;;
    M5) verifier=verify-m5-ports.sh; source_kind=m5-verified-bundle;;
    M6) verifier=verify-m6-media-audio.sh; source_kind=m6-verified-bundle;;
    M7) verifier=verify-m7-security.sh; source_kind=m7-verified-bundle;;
    M8) verifier=verify-m8-update-rollback.sh; source_kind=m8-verified-rollback-with-external-anchor;;
esac

semantic=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/.handoff-verify.XXXXXX")
publish=$(mktemp -d "$MILESTONE_HANDOFF_ROOT/.handoff.XXXXXX")
copy_test_pause_fired=
cleanup() { rm -rf -- "$semantic" "$publish"; }
trap cleanup EXIT

reject_unsafe_tree() {
    local root=$1 entry
    evidence_abs_dir "$root"
    while IFS= read -r -d '' entry; do evidence_die "symlink is not allowed in copied source: $entry"; done < <(find -P "$root" -type l -print0)
    while IFS= read -r -d '' entry; do evidence_die "non-regular copied source member: $entry"; done < <(find -P "$root" ! -type f ! -type d ! -type l -print0)
    while IFS= read -r -d '' entry; do
        [[ -n "$(find -P "$entry" -mindepth 1 -maxdepth 1 -print -quit)" ]] || evidence_die "empty source directory: $entry"
    done < <(find -P "$root" -type d -print0)
}
copy_file() {
    local input=$1 target=$2
    evidence_abs_regular "$input"
    [[ $target != ../* && $target != *'/'../* && $target != *'/'.. && $target != *$'\n'* ]] || evidence_die "unsafe handoff path: $target"
    mkdir -p -m 700 -- "$(dirname -- "$target")"
    [[ ! -e "$target" && ! -L "$target" ]] || evidence_die "duplicate handoff member: $target"
    cp -p -- "$input" "$target"
}
copy_tree() {
    local input=$1 target_root=$2 file rel
    reject_unsafe_tree "$input"
    mkdir -p -m 700 -- "$target_root"
    while IFS= read -r -d '' file; do
        rel=${file#"$input"/}
        copy_file "$file" "$target_root/$rel"
        if [[ ${MILESTONE_HANDOFF_TEST_PAUSE_AFTER_FIRST_COPY:-0} == 1 && -z $copy_test_pause_fired ]]; then
            evidence_new_file "$target_root/.handoff-copy-test-paused"
            /bin/sleep 2
            rm -f -- "$target_root/.handoff-copy-test-paused"
            copy_test_pause_fired=true
        fi
    done < <(find -P "$input" -type f -print0 | sort -z)
}
copy_m0_component() {
    local component=$1 resolved=$2 run_id=$3
    evidence_abs_dir "$resolved"
    copy_tree "$resolved" "$semantic/m0/$component/$run_id"
}

declare -a m0_source_pointer m0_source_path
write_m0_component_map() {
    local map=$1 component path run_id hash index
    printf 'component\trun_id\tsnapshot_path\tmanifest_sha256\n' > "$map"
    for index in "${!m0_component_names[@]}"; do
        component=${m0_component_names[index]}
        path=${m0_source_path[index]}
        run_id=$(basename -- "$path")
        [[ $run_id =~ ^[A-Za-z0-9._-]+$ ]] || evidence_die "invalid M0 source run ID: $run_id"
        hash=$(evidence_sha256 "$semantic/m0/$component/$run_id/manifest.txt")
        printf '%s\t%s\t%s/%s\t%s\n' "$component" "$run_id" "$component" "$run_id" "$hash" >> "$map"
    done
}

# First make a private semantic-verification snapshot. The test-only pause
# touches only the private stage and never executes caller-supplied code.
case $milestone in
    M0)
        mkdir -m 700 "$semantic/m0"
        for index in "${!m0_component_names[@]}"; do
            component=${m0_component_names[index]}
            snapshot=$(m0_component_snapshot "$source" "$component")
            m0_source_pointer[index]=${snapshot%%$'\t'*}
            m0_source_path[index]=${snapshot#*$'\t'}
            resolved=${m0_source_path[index]}
            run_id=$(basename -- "$resolved")
            copy_m0_component "$component" "$resolved" "$run_id"
        done
        write_m0_component_map "$semantic/m0/component-map.tsv"
        for index in "${!m0_component_names[@]}"; do
            component=${m0_component_names[index]}
            m0_component_assert_unchanged "$source" "$component" \
                "${m0_source_pointer[index]}" "${m0_source_path[index]}"
        done
        ;;
    M1) copy_tree "$source" "$semantic/session";;
    M2|M3|M4|M5|M6|M7) copy_tree "$source" "$semantic/bundle";;
    M8)
        copy_tree "$source/evidence" "$semantic/m8/evidence"
        copy_file "$source/anchor.txt" "$semantic/m8/anchor.txt"
        evidence_readonly "$semantic/m8/anchor.txt"
        ;;
esac
case $milestone in
    M0) "$project_root/scripts/$verifier" "$semantic/m0" --component-map "$semantic/m0/component-map.tsv" >/dev/null;;
    M1) "$project_root/scripts/$verifier" "$semantic/session" "$expected_target" "$anchors_file" >/dev/null;;
    M2|M3|M4|M5|M6|M7) MILESTONE_EVIDENCE_ROOT="$MILESTONE_EVIDENCE_ROOT" "$project_root/scripts/$verifier" --bundle "$semantic/bundle" >/dev/null;;
    M8) "$project_root/scripts/$verifier" --evidence "$semantic/m8/evidence" --anchor "$semantic/m8/anchor.txt" >/dev/null;;
esac

# Publish only the verified snapshot. No manifest or checksum is emitted until
# semantic verification succeeds.
mkdir -m 700 "$publish/source"
case $milestone in
    M0) copy_tree "$semantic/m0" "$publish/source/m0";;
    M1) copy_tree "$semantic/session" "$publish/source/session";;
    M2|M3|M4|M5|M6|M7) copy_tree "$semantic/bundle" "$publish/source/bundle";;
    M8)
        copy_tree "$semantic/m8/evidence" "$publish/source/m8/evidence"
        copy_file "$semantic/m8/anchor.txt" "$publish/source/m8/anchor.txt"
        ;;
esac
inventory="$publish/inventory.tsv"
printf 'path\tkind\tsha256\tsize_bytes\n' > "$inventory"
while IFS= read -r -d '' file; do
    rel=${file#"$publish"/}
    [[ $rel == source/* ]] || evidence_die "unexpected handoff member: $rel"
    printf '%s\tregular-file\t%s\t%s\n' "$rel" "$(evidence_sha256 "$file")" "$(wc -c < "$file" | tr -d '[:space:]')" >> "$inventory"
done < <(find -P "$publish/source" -type f -print0 | sort -z)
(( $(wc -l < "$inventory") > 1 )) || evidence_die 'handoff source inventory is empty'
(umask 077; {
    printf 'format=1\nmilestone=%s\n' "$milestone"
    printf 'target_model=Mac15,6\ntarget_board=J514s\ntarget_soc=T6030\n'
    printf 'source_kind=%s\nevidence_valid=true\ntooling_valid=true\n' "$source_kind"
    printf 'hardware_acceptance=false\nnative_readiness=false\nbackup_recovery=false\ndfu=false\ndedicated_hardware=false\n'
    printf 'source_inventory_sha256=%s\nsource_inventory_records=%s\nverifier=%s\n' "$(evidence_sha256 "$inventory")" "$(( $(wc -l < "$inventory") - 1 ))" "$verifier"
} > "$publish/manifest.txt")
evidence_write_sums "$publish" "$publish/SHA256SUMS"
if [[ $milestone == M1 ]]; then
    "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$publish" \
        --expected-target-identity-sha256 "$expected_target" --target-readiness-anchors "$anchors_file" >/dev/null
else
    "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$publish" >/dev/null
fi
mv -- "$publish" "$out"
publish=
printf 'handoff=%s milestone=%s evidence_valid=true hardware_acceptance=false\n' "$out" "$milestone"
