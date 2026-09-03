#!/usr/bin/env bash
# Verify a canonical handoff without performing native or reverse-engineering actions.
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/milestone0-components.sh"
[[ $# -eq 2 && $1 == --bundle ]] || { printf 'usage: %s --bundle ABS\n' "$0" >&2; exit 64; }
root=$2
evidence_abs_dir "$root"
evidence_path_under "$root" "$MILESTONE_HANDOFF_ROOT"
for file in manifest.txt inventory.tsv SHA256SUMS; do evidence_abs_regular "$root/$file"; done
while IFS= read -r -d '' entry; do evidence_die "handoff symlink member: $entry"; done < <(find -P "$root" -type l -print0)
while IFS= read -r -d '' entry; do evidence_die "non-regular handoff member: $entry"; done < <(find -P "$root" ! -type f ! -type d ! -type l -print0)
[[ $(evidence_kv "$root/manifest.txt" format) == 1 ]] || evidence_die 'invalid handoff format'
milestone=$(evidence_kv "$root/manifest.txt" milestone); [[ $milestone =~ ^M[0-8]$ ]] || evidence_die 'invalid handoff milestone'
for key in target_model target_board target_soc source_kind evidence_valid tooling_valid hardware_acceptance native_readiness backup_recovery dfu dedicated_hardware source_inventory_sha256 source_inventory_records verifier; do evidence_kv "$root/manifest.txt" "$key" >/dev/null; done
[[ $(evidence_kv "$root/manifest.txt" target_model) == Mac15,6 && $(evidence_kv "$root/manifest.txt" target_board) == J514s && $(evidence_kv "$root/manifest.txt" target_soc) == T6030 ]] || evidence_die 'handoff target mismatch'
[[ $(evidence_kv "$root/manifest.txt" evidence_valid) == true && $(evidence_kv "$root/manifest.txt" tooling_valid) == true ]] || evidence_die 'handoff evidence/tooling is not valid'
for key in hardware_acceptance native_readiness backup_recovery dfu dedicated_hardware; do [[ $(evidence_kv "$root/manifest.txt" "$key") == false ]] || evidence_die "$key must be false"; done
[[ $(evidence_kv "$root/manifest.txt" source_inventory_records) =~ ^[1-9][0-9]*$ ]] || evidence_die 'invalid handoff inventory count'
[[ $(evidence_kv "$root/manifest.txt" source_inventory_sha256) == "$(evidence_sha256 "$root/inventory.tsv")" ]] || evidence_die 'source inventory hash mismatch'
inventory_header=$(head -n 1 "$root/inventory.tsv")
[[ $inventory_header == $'path\tkind\tsha256\tsize_bytes' ]] || evidence_die 'invalid handoff inventory header'

seen='|'; count=0
while IFS=$'\t' read -r path kind hash size extra; do
    [[ -z ${extra:-} && $path == source/* && $path != *$'\n'* && $path != *'/'../* && $path != ../* && $path != *'/'.. && $path != *'|'* ]] || evidence_die 'unsafe handoff inventory path'
    [[ $kind == regular-file && $hash =~ ^[[:xdigit:]]{64}$ && $size =~ ^[0-9]+$ ]] || evidence_die 'invalid handoff inventory row'
    file="$root/$path"; evidence_abs_regular "$file"
    [[ $(evidence_sha256 "$file") == "$hash" && $(wc -c < "$file" | tr -d '[:space:]') == "$size" ]] || evidence_die "handoff source hash mismatch: $path"
    [[ $seen != *"|$path|"* ]] || evidence_die 'duplicate handoff inventory path'
    seen="${seen}${path}|"; count=$((count + 1))
done < <(tail -n +2 "$root/inventory.tsv")
[[ $count == "$(evidence_kv "$root/manifest.txt" source_inventory_records)" ]] || evidence_die 'handoff inventory count mismatch'

# The inventory is an exact file set. Every directory must be a parent of a
# declared file; this rejects undeclared and empty directories.
while IFS= read -r -d '' dir; do
    rel=${dir#"$root"/}
    [[ $rel == source || $seen == *"|$rel/"* ]] || evidence_die "undeclared or empty handoff directory: $rel"
done < <(find -P "$root" -mindepth 1 -type d -print0)
while IFS= read -r -d '' file; do
    rel=${file#"$root"/}
    case "$rel" in
        manifest.txt|inventory.tsv|SHA256SUMS) ;;
        source/*) [[ $seen == *"|$rel|"* ]] || evidence_die "undeclared handoff file: $rel";;
        *) evidence_die "undeclared handoff member: $rel";;
    esac
done < <(find -P "$root" -type f -print0)

evidence_verify_sums "$root" "$root/SHA256SUMS"

# Re-run the milestone-specific verifier against the copied source. This
# prevents a tampered source from passing by only re-hashing it.
case $milestone in
    M0)
        [[ $(evidence_kv "$root/manifest.txt" source_kind) == m0-component-manifest-set ]] || evidence_die 'M0 source kind mismatch'
        [[ $(evidence_kv "$root/manifest.txt" verifier) == verify-milestone0.sh ]] || evidence_die 'M0 verifier mismatch'
        map="$root/source/m0/component-map.tsv"
        evidence_abs_regular "$map"
        [[ $(head -n 1 "$map") == $'component\trun_id\tsnapshot_path\tmanifest_sha256' ]] || evidence_die 'invalid M0 component map header'
        map_seen='|'; map_count=0
        while IFS=$'\t' read -r component run_id snapshot_path hash extra; do
            [[ -z ${extra:-} && $component != *'|'* && $run_id =~ ^[A-Za-z0-9._-]+$ &&
                $snapshot_path == "$component/"* && $snapshot_path != *'/'../* && $snapshot_path != ../* &&
                $hash =~ ^[[:xdigit:]]{64}$ ]] || evidence_die 'invalid M0 component map row'
            case " ${m0_component_names[*]} " in *" $component "*) ;; *) evidence_die 'unknown M0 component in map';; esac
            [[ $map_seen != *"|$component|"* ]] || evidence_die 'duplicate M0 component map row'
            [[ "$snapshot_path" == "$component/${run_id}" ]] || evidence_die 'M0 map run/path mismatch'
            snapshot="$root/source/m0/$snapshot_path"
            evidence_abs_dir "$snapshot"
            [[ "$(evidence_sha256 "$snapshot/manifest.txt")" == "$hash" ]] || evidence_die "M0 snapshot manifest hash mismatch: $component"
            map_seen="${map_seen}${component}|"; map_count=$((map_count + 1))
        done < <(tail -n +2 "$map")
        [[ $map_count == "${#m0_component_names[@]}" ]] || evidence_die 'M0 component map count mismatch'
        for component in "${m0_component_names[@]}"; do
            [[ $map_seen == *"|$component|"* ]] || evidence_die "M0 component missing from map: $component"
        done
        "$project_root/scripts/verify-milestone0.sh" "$root/source/m0" --component-map "$map" >/dev/null
        ;;
    M1)
        [[ $(evidence_kv "$root/manifest.txt" source_kind) == m1-checksummed-session ]] || evidence_die 'M1 source kind mismatch'
        [[ $(evidence_kv "$root/manifest.txt" verifier) == verify-milestone1-session.sh ]] || evidence_die 'M1 verifier mismatch'
        "$project_root/scripts/verify-milestone1-session.sh" "$root/source/session" >/dev/null
        ;;
    M2)
        [[ $(evidence_kv "$root/manifest.txt" verifier) == verify-m2-core-power.sh ]] || evidence_die 'M2 verifier mismatch'
        MILESTONE_EVIDENCE_ROOT="$MILESTONE_HANDOFF_ROOT" "$project_root/scripts/verify-m2-core-power.sh" --bundle "$root/source/bundle" >/dev/null
        ;;
    M3)
        [[ $(evidence_kv "$root/manifest.txt" verifier) == verify-m3-display-dcp.sh ]] || evidence_die 'M3 verifier mismatch'
        MILESTONE_EVIDENCE_ROOT="$MILESTONE_HANDOFF_ROOT" "$project_root/scripts/verify-m3-display-dcp.sh" --bundle "$root/source/bundle" >/dev/null
        ;;
    M4)
        [[ $(evidence_kv "$root/manifest.txt" verifier) == verify-m4-gpu.sh ]] || evidence_die 'M4 verifier mismatch'
        MILESTONE_EVIDENCE_ROOT="$MILESTONE_HANDOFF_ROOT" "$project_root/scripts/verify-m4-gpu.sh" --bundle "$root/source/bundle" >/dev/null
        ;;
    M5)
        [[ $(evidence_kv "$root/manifest.txt" verifier) == verify-m5-ports.sh ]] || evidence_die 'M5 verifier mismatch'
        MILESTONE_EVIDENCE_ROOT="$MILESTONE_HANDOFF_ROOT" "$project_root/scripts/verify-m5-ports.sh" --bundle "$root/source/bundle" >/dev/null
        ;;
    M6)
        [[ $(evidence_kv "$root/manifest.txt" verifier) == verify-m6-media-audio.sh ]] || evidence_die 'M6 verifier mismatch'
        MILESTONE_EVIDENCE_ROOT="$MILESTONE_HANDOFF_ROOT" "$project_root/scripts/verify-m6-media-audio.sh" --bundle "$root/source/bundle" >/dev/null
        ;;
    M7)
        [[ $(evidence_kv "$root/manifest.txt" verifier) == verify-m7-security.sh ]] || evidence_die 'M7 verifier mismatch'
        MILESTONE_EVIDENCE_ROOT="$MILESTONE_HANDOFF_ROOT" "$project_root/scripts/verify-m7-security.sh" --bundle "$root/source/bundle" >/dev/null
        ;;
    M8)
        [[ $(evidence_kv "$root/manifest.txt" source_kind) == m8-verified-rollback-with-external-anchor ]] || evidence_die 'M8 source kind mismatch'
        [[ $(evidence_kv "$root/manifest.txt" verifier) == verify-m8-update-rollback.sh ]] || evidence_die 'M8 verifier mismatch'
        "$project_root/scripts/verify-m8-update-rollback.sh" --evidence "$root/source/m8/evidence" --anchor "$root/source/m8/anchor.txt" >/dev/null
        ;;
esac
printf '%s=handoff-verified tooling_valid=true evidence_valid=true hardware_acceptance=false\n' "$milestone"
