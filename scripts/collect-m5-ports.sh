#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 5 && $1 == --dry-run && $2 == --input-dir && $4 == --out ]] || { printf 'usage: %s --dry-run --input-dir ABS --out ABS\n' "$0" >&2; exit 64; }
input=$3; out=$5; evidence_abs_dir "$input"
for file in identity.txt kernel.log iommu.log inventory.tsv ports.tsv modes.tsv stress.tsv; do evidence_abs_regular "$input/$file"; done
evidence_validate_identity "$input/identity.txt"; evidence_require_clean_log "$input/kernel.log"; evidence_require_clean_log "$input/iommu.log"

check_fields() {
    local file=$1; shift; local header col
    IFS=$'\t' read -r -a header < "$file" || evidence_die "missing TSV header: $file"
    for col in "$@"; do printf '%s\n' "${header[@]}" | grep -Fx -- "$col" >/dev/null || evidence_die "missing $col in $file"; done
    evidence_validate_tsv "$file" "$*" 1
}
check_fields "$input/inventory.tsv" port connector required_orientations
check_fields "$input/ports.tsv" test_id port orientation interface operation status telemetry evidence
check_fields "$input/modes.tsv" test_id connector port orientation mode advertised width height status telemetry evidence
check_fields "$input/stress.tsv" test_id scenario duration_seconds status telemetry evidence device_class port orientation bytes source_sha256 destination_sha256 error_count data_loss association
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=3 || $1=="" || $2=="" || $3=="") bad=1} END {exit (bad || !(NR>1))}' "$input/inventory.tsv" || evidence_die 'invalid or duplicate inventory rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=8 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="") bad=1} END {exit (bad || !(NR>1))}' "$input/ports.tsv" || evidence_die 'invalid or duplicate port rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=11 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="" || $9=="" || $10=="" || $11=="") bad=1} END {exit (bad || !(NR>1))}' "$input/modes.tsv" || evidence_die 'invalid or duplicate mode rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=15 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="" || $9=="" || $10=="" || $11=="" || $12=="" || $13=="" || $14=="" || $15=="") bad=1} END {exit (bad || !(NR>1))}' "$input/stress.tsv" || evidence_die 'invalid or duplicate stress rows'
awk -F '\t' 'NR>1 && $6!="observed" {bad=1} END {exit bad}' "$input/ports.tsv" || evidence_die 'physical-port record is not observed'
for token in placeholder 'software-only' planned TODO unknown 'not tested' simulated; do if grep -Eiq -- "$token" "$input/inventory.tsv" "$input/ports.tsv" "$input/modes.tsv" "$input/stress.tsv"; then evidence_die "placeholder or software token: $token"; fi; done
if grep -Eiq '(^|\t)pass(\t|$)|(^|\t)passed(\t|$)' "$input/ports.tsv" "$input/modes.tsv" "$input/stress.tsv"; then evidence_die 'bare pass status is not evidence'; fi
required_ports=(magsafe usb-c-left-1 usb-c-left-2 usb-c-right-1 hdmi sdxc headphone)
for port in "${required_ports[@]}"; do
    awk -F '\t' -v p="$port" 'NR>1 && $1==p {f=1} END {exit !f}' "$input/inventory.tsv" || evidence_die "missing physical port: $port"
    awk -F '\t' -v p="$port" 'NR>1 && $2==p && $6=="observed" {f=1} END {exit !f}' "$input/ports.tsv" || evidence_die "missing observed port evidence: $port"
done
for port in usb-c-left-1 usb-c-left-2 usb-c-right-1; do for orientation in normal flipped; do for operation in usb2-data usb3-data charging usb-pd role-switch dp-alt-mode thunderbolt dock; do awk -F '\t' -v p="$port" -v o="$orientation" -v x="$operation" 'NR>1 && $2==p && $3==o && $5==x && $6=="observed" {f=1} END {exit !f}' "$input/ports.tsv" || evidence_die "missing USB evidence: $port/$orientation/$operation"; done; done; done
for port in usb-c-left-1 usb-c-left-2 usb-c-right-1; do for orientation in normal flipped; do awk -F '\t' -v p="$port" -v o="$orientation" 'NR>1 && $2=="dp" && $3==p && $4==o && $6=="yes" && $7 ~ /^[0-9]+$/ && $8 ~ /^[0-9]+$/ && $7>0 && $8>0 && $9=="observed" {f=1} END {exit !f}' "$input/modes.tsv" || evidence_die "missing observed advertised DP mode: $port/$orientation"; done; done
awk -F '\t' 'NR>1 && $2=="hdmi" && $3=="hdmi" && $4=="n/a" && $6=="yes" && $7 ~ /^[0-9]+$/ && $8 ~ /^[0-9]+$/ && $7>0 && $8>0 && $9=="observed" {f=1} END {exit !f}' "$input/modes.tsv" || evidence_die 'missing observed advertised HDMI mode'
awk -F '\t' 'NR>1 && $6=="yes" && $9!="observed" {bad=1} END {exit bad}' "$input/modes.tsv" || evidence_die 'advertised mode is not observed'
for scenario in hotplug unplug-under-load suspend-resume over-current-recovery; do awk -F '\t' -v s="$scenario" 'NR>1 && $2==s && $4=="observed" && $3 ~ /^[0-9]+([.][0-9]+)?$/ && $3>0 {f=1} END {exit !f}' "$input/stress.tsv" || evidence_die "missing stress evidence: $scenario"; done
awk -F '\t' 'NR>1 && $2=="thunderbolt-sustained-io" && $11 ~ /^[[:xdigit:]]{64}$/ && $12 ~ /^[[:xdigit:]]{64}$/ && $11 != $12 {bad=1} END {exit bad}' "$input/stress.tsv" || evidence_die 'Thunderbolt source/destination hash mismatch'
for port in usb-c-left-1 usb-c-left-2 usb-c-right-1; do for class in storage network; do for orientation in normal flipped; do awk -F '\t' -v p="$port" -v c="$class" -v o="$orientation" 'NR>1 && $2=="thunderbolt-sustained-io" && $4=="observed" && $3 ~ /^[0-9]+([.][0-9]+)?$/ && $3>0 && $7==c && $8==p && $9==o && $10 ~ /^[0-9]+$/ && $10>0 && $11 ~ /^[[:xdigit:]]{64}$/ && $12 ~ /^[[:xdigit:]]{64}$/ && $11==$12 && $13=="0" && $14=="no" && $15 ~ /hotplug/ && $15 ~ /suspend/ {f=1} END {exit !f}' "$input/stress.tsv" || evidence_die "missing structured Thunderbolt $class/$port/$orientation evidence"; done; done; done
mkdir -p -m 700 -- "$MILESTONE_EVIDENCE_ROOT"; evidence_abs_dir "$MILESTONE_EVIDENCE_ROOT"; evidence_path_under "$out" "$MILESTONE_EVIDENCE_ROOT"; evidence_new_dir "$out"; mkdir -m 700 -- "$out/inputs"
for file in identity.txt kernel.log iommu.log inventory.tsv ports.tsv modes.tsv stress.tsv; do cp -p -- "$input/$file" "$out/inputs/$file"; done
(umask 077; { printf 'milestone=M5\nmodel=Mac15,6\nboard=J514s\nsoc=T6030\ncollection_status=software-plan-only\nhardware_acceptance=false\ninput_count=7\n'; } > "$out/manifest.txt")
(umask 077; { printf 'mode=software-plan-only\nThis bundle packages supplied structured port evidence only.\nNo hardware enumeration, port actuation, power transition, display command, or dock command is performed.\nNative acceptance requires human-authorized execution and review.\n'; } > "$out/collection-plan.txt")
evidence_write_sums "$out" "$out/SHA256SUMS"; printf 'bundle=%s\n' "$out"
