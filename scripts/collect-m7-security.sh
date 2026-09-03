#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P); source "$project_root/config/milestones.env"; source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 5 && $1 == --dry-run && $2 == --input-dir && $4 == --out ]] || { printf 'usage: %s --dry-run --input-dir ABS --out ABS\n' "$0" >&2; exit 64; }
input=$3; out=$5; evidence_abs_dir "$input"
for file in identity.txt kernel.log macos-security.tsv threat-model.tsv security-boundaries.tsv accelerators.tsv negative-tests.tsv recovery.tsv; do evidence_abs_regular "$input/$file"; done
evidence_validate_identity "$input/identity.txt"; evidence_require_clean_log "$input/kernel.log"
check_fields() { local file=$1; shift; local h c; IFS=$'\t' read -r -a h < "$file" || evidence_die "missing TSV header: $file"; for c in "$@"; do printf '%s\n' "${h[@]}" | grep -Fx -- "$c" >/dev/null || evidence_die "missing $c in $file"; done; evidence_validate_tsv "$file" "$*" 1; }
check_fields "$input/threat-model.tsv" threat_id asset boundary scenario control status reviewer evidence telemetry
check_fields "$input/macos-security.tsv" key value
check_fields "$input/security-boundaries.tsv" boundary asset exposed_to allowed denied status evidence
check_fields "$input/accelerators.tsv" test_id accelerator isolation firmware_trust rollback reset suspend multi_user status telemetry evidence
check_fields "$input/negative-tests.tsv" test_id threat action expected result recovery_evidence status telemetry
check_fields "$input/recovery.tsv" recovery_id trigger reset_path data_loss status evidence telemetry
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=9 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="" || $9=="") bad=1} END {exit (bad || !(NR>1))}' "$input/threat-model.tsv" || evidence_die 'invalid or duplicate threat rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=2 || $1=="" || $2=="") bad=1} END {exit (bad || !(NR>1))}' "$input/macos-security.tsv" || evidence_die 'invalid or duplicate macOS security rows'
awk -F '\t' 'NR>1 {if ($1 !~ /^(sip|filevault|boot_policy|raw_biometric_export)$/) bad=1; count++} END {exit (bad || count!=4)}' "$input/macos-security.tsv" || evidence_die 'macOS security record must contain exactly four approved keys'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=8 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="") bad=1} END {exit (bad || !(NR>1))}' "$input/security-boundaries.tsv" || evidence_die 'invalid or duplicate boundary rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=11 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="" || $9=="" || $10=="" || $11=="") bad=1} END {exit (bad || !(NR>1))}' "$input/accelerators.tsv" || evidence_die 'invalid or duplicate accelerator rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=8 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="") bad=1} END {exit (bad || !(NR>1))}' "$input/negative-tests.tsv" || evidence_die 'invalid or duplicate negative-test rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=8 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="") bad=1} END {exit (bad || !(NR>1))}' "$input/recovery.tsv" || evidence_die 'invalid or duplicate recovery rows'
if awk -F '\t' '{for (i=2; i<=NF; i++) print $i}' "$input/macos-security.tsv" "$input/security-boundaries.tsv" "$input/threat-model.tsv" "$input/accelerators.tsv" "$input/recovery.tsv" | grep -Eiq 'raw[[:space:]_-]*(biometric|template)|biometric[[:space:]_-]+(template|data|export)|fingerprint[[:space:]_-]+(template|data|export)|key[[:space:]_-]+export|disable[[:space:]_-]*(sip|filevault)|csrutil[[:space:]_-]+disable|security[[:space:]_-]*(reduction|bypass)|firmware[[:space:]_-]*trust[[:space:]_-]*bypass'; then evidence_die 'unsafe security claim or exposure in evidence'; fi
if awk -F '\t' '{print $1 "=" $2}' "$input/macos-security.tsv" | grep -Eiq '(sip|filevault|csrutil)[[:space:]_=:-]*(disabled|disable|off)'; then evidence_die 'macOS security reduction or bypass is present'; fi
for token in placeholder planned TODO unknown 'not tested' simulated; do if grep -Eiq -- "$token" "$input"/*.tsv; then evidence_die "placeholder token: $token"; fi; done
awk -F '\t' 'NR>1 && $6=="unsupported" && $8 !~ /reason/ {bad=1} END {exit bad}' "$input/threat-model.tsv" || evidence_die 'unsupported threat lacks explicit reason'
awk -F '\t' 'NR>1 && $9=="unsupported" && $11 !~ /reason/ {bad=1} END {exit bad}' "$input/accelerators.tsv" || evidence_die 'unsupported accelerator lacks explicit reason'
awk -F '\t' 'NR>1 && $6=="unsupported" && $7 !~ /reason/ {bad=1} END {exit bad}' "$input/security-boundaries.tsv" || evidence_die 'unsupported boundary lacks explicit reason'
required_threats=(sep-boundary touchid-boundary key-isolation pmu ane dma firmware-trust-rollback reset suspend multi-user)
for id in "${required_threats[@]}"; do awk -F '\t' -v i="$id" 'NR>1 && $1==i && ($6=="reviewed" || ($6=="unsupported" && $5 ~ /reason/)) && $7!="" && $8!="" && $9!="" {f=1} END {exit !f}' "$input/threat-model.tsv" || evidence_die "missing reviewed threat: $id"; done
for accelerator in sep touchid pmu ane; do awk -F '\t' -v a="$accelerator" 'NR>1 && $2==a && $3!="" && $4!="" && $5!="" && $6!="" && $7!="" && $8!="" && ($9=="reviewed" || $9=="unsupported") && $10!="" && $11!="" {f=1} END {exit !f}' "$input/accelerators.tsv" || evidence_die "missing accelerator boundary: $accelerator"; done
for key in sip filevault boot_policy raw_biometric_export; do awk -F '\t' -v k="$key" '$1==k {f=1} END {exit !f}' "$input/macos-security.tsv" || evidence_die "missing macOS security record: $key"; done
awk -F '\t' '$1=="sip" && $2=="enabled" {f=1} END {exit !f}' "$input/macos-security.tsv" || evidence_die 'SIP is not asserted enabled'
awk -F '\t' '$1=="filevault" && $2=="enabled" {f=1} END {exit !f}' "$input/macos-security.tsv" || evidence_die 'FileVault is not asserted enabled'
awk -F '\t' '$1=="boot_policy" && $2=="unchanged" {f=1} END {exit !f}' "$input/macos-security.tsv" || evidence_die 'boot policy is not asserted unchanged'
awk -F '\t' '$1=="raw_biometric_export" && $2=="false" {f=1} END {exit !f}' "$input/macos-security.tsv" || evidence_die 'raw biometric export is not explicitly false'
for id in no-biometric-export no-key-export firmware-rollback dma-boundary reset-recovery suspend-recovery multi-user-isolation; do awk -F '\t' -v i="$id" 'NR>1 && $1==i && ($4=="denied" || $4=="blocked") && $5==$4 && $6!="" && $7=="observed" && $8!="" {f=1} END {exit !f}' "$input/negative-tests.tsv" || evidence_die "missing negative security test: $id"; done
if ! awk -F '\t' 'NR>1 && tolower($5) ~ /^(granted|allowed|exported|success)$/ {bad=1} END {exit bad}' "$input/negative-tests.tsv"; then evidence_die 'negative test contains an acceptance result'; fi
for id in rollback reset suspend; do awk -F '\t' -v i="$id" 'NR>1 && $2 ~ i && $3!="" && $4=="no" && $5=="observed" && $6!="" && $7!="" {f=1} END {exit !f}' "$input/recovery.tsv" || evidence_die "missing recovery proof: $id"; done
mkdir -p -m 700 -- "$MILESTONE_EVIDENCE_ROOT"; evidence_abs_dir "$MILESTONE_EVIDENCE_ROOT"; evidence_path_under "$out" "$MILESTONE_EVIDENCE_ROOT"; evidence_new_dir "$out"; mkdir -m 700 -- "$out/inputs"
for file in identity.txt kernel.log macos-security.tsv threat-model.tsv security-boundaries.tsv accelerators.tsv negative-tests.tsv recovery.tsv; do cp -p -- "$input/$file" "$out/inputs/$file"; done
(umask 077; printf 'milestone=M7\nmodel=Mac15,6\nboard=J514s\nsoc=T6030\ncollection_status=software-plan-only\nhardware_acceptance=false\ninput_count=7\n' > "$out/manifest.txt")
(umask 077; printf 'mode=software-plan-only\nThis bundle packages a reviewed security evidence contract only.\nNo security processor, biometric, key, firmware, DMA, reset, suspend, or recovery command is performed.\nUnsupported entries do not count as acceptance.\n' > "$out/collection-plan.txt")
evidence_write_sums "$out" "$out/SHA256SUMS"; printf 'bundle=%s\n' "$out"
