#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P); source "$project_root/config/milestones.env"; source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 5 && $1 == --dry-run && $2 == --input-dir && $4 == --out ]] || { printf 'usage: %s --dry-run --input-dir ABS --out ABS\n' "$0" >&2; exit 64; }
input=$3; out=$5; evidence_abs_dir "$input"
calibration_allowlist="$project_root/config/milestone6-speaker-calibrations.tsv"; evidence_abs_regular "$calibration_allowlist"
for file in identity.txt kernel.log camera.tsv audio.tsv codecs.tsv speaker-safety.tsv; do evidence_abs_regular "$input/$file"; done
evidence_validate_identity "$input/identity.txt"; evidence_require_clean_log "$input/kernel.log"
check_fields() { local file=$1; shift; local h c; IFS=$'\t' read -r -a h < "$file" || evidence_die "missing TSV header: $file"; for c in "$@"; do printf '%s\n' "${h[@]}" | grep -Fx -- "$c" >/dev/null || evidence_die "missing $c in $file"; done; evidence_validate_tsv "$file" "$*" 1; }
check_fields "$input/camera.tsv" test_id path mode width height fps status telemetry evidence
check_fields "$input/audio.tsv" test_id path direction rate channels status telemetry evidence action
check_fields "$input/codecs.tsv" test_id codec direction width height status hardware_codec software_fallback telemetry evidence hardware_reason
check_fields "$input/speaker-safety.tsv" check value
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=9 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="" || $9=="") bad=1} END {exit (bad || !(NR>1))}' "$input/camera.tsv" || evidence_die 'invalid or duplicate camera rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=9 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="" || $9=="") bad=1} END {exit (bad || !(NR>1))}' "$input/audio.tsv" || evidence_die 'invalid or duplicate audio rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=11 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8=="" || $9=="" || $10=="" || $11=="") bad=1} END {exit (bad || !(NR>1))}' "$input/codecs.tsv" || evidence_die 'invalid or duplicate codec rows'
awk -F '\t' 'NR>1 {if (++x[$1]!=1 || NF!=2 || $1=="" || $2=="") bad=1} END {exit (bad || !(NR>1))}' "$input/speaker-safety.tsv" || evidence_die 'invalid speaker safety rows'
for token in placeholder planned TODO unknown 'not tested' simulated 'software fallback' 'cpu codec'; do if grep -Eiq -- "$token" "$input/camera.tsv" "$input/audio.tsv" "$input/codecs.tsv"; then evidence_die "placeholder or software fallback: $token"; fi; done
if grep -Eiq 'virtual|software|dummy|v4l|synthetic' "$input/camera.tsv"; then evidence_die 'virtual or software camera is not accepted'; fi
awk -F '\t' 'NR>1 && $2=="camera" && ($3!="capture" || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+([.][0-9]+)?$/ || $4<=0 || $5<=0 || $6<=0 || $7!="observed" || tolower($8) !~ /device=t6030/ || tolower($8) !~ /isp=apple/ || $9=="") {bad=1} END {exit bad}' "$input/camera.tsv" || evidence_die 'camera record is not a positive Apple ISP capture'
awk -F '\t' '$2=="camera" && $3=="capture" && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+([.][0-9]+)?$/ && $4>0 && $5>0 && $6>0 && $7=="observed" && tolower($8) ~ /device=t6030/ && tolower($8) ~ /isp=apple/ && $9!="" {f=1} END {exit !f}' "$input/camera.tsv" || evidence_die 'camera lacks positive T6030 ISP capture evidence'
awk -F '\t' '$2=="microphone" && $3=="capture" && $6=="observed" && $7!="" && $8!="" && $9!="" {f=1} END {exit !f}' "$input/audio.tsv" || evidence_die 'microphone must have observed capture evidence'
awk -F '\t' '$2=="headphone" && $3=="playback" && $6=="observed" && $7!="" && $8!="" && $9!="" {f=1} END {exit !f}' "$input/audio.tsv" || evidence_die 'headphone must have observed playback evidence'
awk -F '\t' 'NR>1 && ($2=="av1" || $2=="prores") && ($6=="observed" || $6=="unsupported") && $8!="no" {bad=1} END {exit bad}' "$input/codecs.tsv" || evidence_die 'AV1/ProRes software fallback must be no'
awk -F '\t' 'NR>1 && tolower($7) !~ /^t6030-(h264|hevc|vp9|av1|prores)-(decoder|encoder|unsupported)$/ {bad=1} END {exit bad}' "$input/codecs.tsv" || evidence_die 'codec hardware identifier is not an approved T6030 identifier'
for dir in decode encode; do for codec in h264 hevc vp9; do awk -F '\t' -v d="$dir" -v c="$codec" 'NR>1 && $2==c && $3==d && $4==3840 && $5==2160 && $6=="observed" && tolower($7)==("t6030-" c "-" (d=="decode" ? "decoder" : "encoder")) && $8=="no" && tolower($9) ~ /device=t6030/ && $9 ~ /utilization=/ && $10!="" {f=1} END {exit !f}' "$input/codecs.tsv" || evidence_die "missing approved 4K hardware $codec $dir"; done; done
for codec in av1 prores; do awk -F '\t' -v c="$codec" 'NR>1 && $2==c && $4==3840 && $5==2160 && (($6=="observed" && tolower($7) ~ ("^t6030-" c "-(decoder|encoder)$") && $8=="no" && tolower($9) ~ /device=t6030/ && $9 ~ /utilization=/ && $10!="") || ($6=="unsupported" && tolower($7)==("t6030-" c "-unsupported") && $8=="no" && $11!="" && tolower($11) !~ /^(unknown|planned|placeholder)$/)) {f=1} END {exit !f}' "$input/codecs.tsv" || evidence_die "AV1/ProRes lacks explicit approved hardware branch: $codec"; done
speaker_status=$(awk -F '\t' '$1=="status" {print $2}' "$input/speaker-safety.tsv"); [[ $speaker_status == unsupported ]] || {
    [[ $speaker_status == supported ]] || evidence_die 'speaker status must be supported or unsupported'
    for check in calibration_sha256 speakersafetyd_active dsp_graph_id dsp_graph_sha256 amplifier_thermal_telemetry amplifier_thermal_limit negative_safety_result; do awk -F '\t' -v c="$check" '$1==c && $2!="" {f=1} END {exit !f}' "$input/speaker-safety.tsv" || evidence_die "missing speaker safety proof: $check"; done
    awk -F '\t' '$1=="calibration_board" && $2=="J514s" {f=1} END {exit !f}' "$input/speaker-safety.tsv" || evidence_die 'speaker calibration board is not J514s'
    speaker_hash=$(awk -F '\t' '$1=="calibration_sha256" {print $2}' "$input/speaker-safety.tsv"); [[ $speaker_hash =~ ^[[:xdigit:]]{64}$ ]] || evidence_die 'exact speaker calibration hash required'
    awk -F '\t' '$1=="speakersafetyd_active" && $2=="true" {f=1} END {exit !f}' "$input/speaker-safety.tsv" || evidence_die 'speakersafetyd active proof missing'
    awk -F '\t' '$1=="dsp_graph_id" && $2!="" {f=1} END {exit !f}' "$input/speaker-safety.tsv" || evidence_die 'approved DSP graph ID missing'
    awk -F '\t' '$1=="dsp_graph_sha256" && $2 ~ /^[[:xdigit:]]{64}$/ {f=1} END {exit !f}' "$input/speaker-safety.tsv" || evidence_die 'approved DSP graph hash missing'
    awk -F '\t' '$1=="amplifier_thermal_telemetry" && $2 ~ /^device=[^;]+;temperature_c=[0-9]+([.][0-9]+)?$/ {f=1} END {exit !f}' "$input/speaker-safety.tsv" || evidence_die 'amplifier thermal telemetry missing'
    awk -F '\t' '$1=="amplifier_thermal_limit" && $2 ~ /^max_c=[0-9]+([.][0-9]+)?$/ {f=1} END {exit !f}' "$input/speaker-safety.tsv" || evidence_die 'amplifier thermal limit missing'
    awk -F '\t' '
        $1=="amplifier_thermal_telemetry" {n=split($2,a,";"); for (i=1; i<=n; i++) {m=split(a[i],v,"="); if (v[1]=="temperature_c") temp=v[2]}}
        $1=="amplifier_thermal_limit" {n=split($2,a,"="); if (a[1]=="max_c") limit=a[2]}
        END {if (temp !~ /^[0-9]+([.][0-9]+)?$/ || limit !~ /^[0-9]+([.][0-9]+)?$/) exit 1; exit !(temp <= limit)}
    ' "$input/speaker-safety.tsv" || evidence_die 'amplifier temperature exceeds safety limit'
    awk -F '\t' -v h="$speaker_hash" '$1=="J514s" && $2==h {f=1} END {exit !f}' "$calibration_allowlist" || evidence_die 'speaker calibration is not in the reviewed J514s allowlist'
    awk -F '\t' '$1=="negative_safety_result" && $2=="blocked" {f=1} END {exit !f}' "$input/speaker-safety.tsv" || evidence_die 'negative speaker safety result is not blocked'
}
mkdir -p -m 700 -- "$MILESTONE_EVIDENCE_ROOT"; evidence_abs_dir "$MILESTONE_EVIDENCE_ROOT"; evidence_path_under "$out" "$MILESTONE_EVIDENCE_ROOT"; evidence_new_dir "$out"; mkdir -m 700 -- "$out/inputs"
for file in identity.txt kernel.log camera.tsv audio.tsv codecs.tsv speaker-safety.tsv; do cp -p -- "$input/$file" "$out/inputs/$file"; done
(umask 077; printf 'milestone=M6\nmodel=Mac15,6\nboard=J514s\nsoc=T6030\ncollection_status=software-plan-only\nhardware_acceptance=false\ninput_count=6\n' > "$out/manifest.txt")
(umask 077; printf 'mode=software-plan-only\nThis bundle packages supplied media evidence only.\nNo camera, microphone, speaker, headphone, mixer, codec, or hardware command is performed.\nInternal speakers are not actuated by this tool.\n' > "$out/collection-plan.txt")
evidence_write_sums "$out" "$out/SHA256SUMS"; printf 'bundle=%s\n' "$out"
