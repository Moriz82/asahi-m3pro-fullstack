#!/usr/bin/env bash
# Create a declarative recovery record; no host action is performed.
# shellcheck disable=SC1091
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
M9_PROJECT_ROOT=$project_root
source "$project_root/scripts/lib/m9-canonical.sh"
output_root=${SOFTWARE_OUTPUT_ROOT:-$project_root/out}
denylist="$project_root/config/milestone9-action-denylist.txt"
usage() { printf 'usage: %s --release-inputs ABS --release-anchor ABS --authority TEXT --operator TEXT --out ABS\n' "$0" >&2; exit 64; }
[[ $# -eq 10 && $1 == --release-inputs && $3 == --release-anchor && $5 == --authority && $7 == --operator && $9 == --out ]] || usage
release=$2; release_anchor=$4; authority=$6; operator=$8; out=${10}
evidence_abs_dir "$release"; evidence_abs_regular "$release/manifest.txt"; evidence_abs_regular "$release_anchor"; evidence_abs_regular "$denylist"
deny=()
while IFS= read -r line || [[ -n $line ]]; do [[ -z $line || $line == \#* ]] && continue; [[ $line != *$'\t'* && $line != *' '* ]] || evidence_die 'invalid denylist row'; deny+=("$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"); done < "$denylist"
scan_unsafe_metadata() { local value blocked; value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); for blocked in "${deny[@]}"; do [[ $value != *"$blocked"* ]] || evidence_die "denied metadata token: $blocked"; done; }
for metadata in "$authority" "$operator"; do scan_unsafe_metadata "$metadata"; done
[[ $authority =~ ^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,127}$ ]] || evidence_die 'authority must be a structured identifier without whitespace'
[[ $operator =~ ^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,127}$ ]] || evidence_die 'operator must be a structured identifier without whitespace'
evidence_path_under "$out" "$output_root"
[[ $release_anchor != "$release" && $release_anchor != "$release"/* && $release_anchor != "$out" && $release_anchor != "$out"/* && $release_anchor != "$output_root" && $release_anchor != "$output_root"/* ]] || evidence_die 'release anchor must be outside release and output trees'
evidence_readonly "$release_anchor"
[[ $(evidence_kv "$release_anchor" anchor_trust) == untrusted-declarative ]] || evidence_die 'release anchor is not a configured signed authority'
[[ $(evidence_kv "$release/manifest.txt" release_gate) == blocked ]] || evidence_die 'release gate is not blocked'
[[ $(evidence_kv "$release/manifest.txt" hardware_acceptance) == false ]] || evidence_die 'hardware acceptance must remain false'
[[ $(evidence_kv "$release/manifest.txt" external_anchor_sha256) == "$(evidence_sha256 "$release_anchor")" ]] || evidence_die 'release anchor changed or is not externally pinned'
m9_validate_canonical_release_binding "$release" "$release_anchor"
if printf '%s\n%s\n' "$authority" "$operator" | grep -Eiq 'password|secret|token|private[[:space:]]+key|-----BEGIN'; then evidence_die 'secrets are not accepted in recovery metadata'; fi
evidence_new_dir "$out"
(umask 077; {
    printf 'format=1\nstatus=declarative\ntarget_model=Mac15,6\ntarget_board=J514s\ntarget_soc=T6030\n'
    printf 'release_inputs_sha256=%s\nrelease_anchor_sha256=%s\nhardware_acceptance=false\nactuation=false\n' "$(evidence_sha256 "$release/manifest.txt")" "$(evidence_sha256 "$release_anchor")"
    printf 'macos_preserved=true\nrecovery_proof_required=true\nbackup_recovery_required=true\ndfu_required=true\n'
    printf 'native_action=false\noperator_authority=%s\noperator=%s\n' "$authority" "$operator"
    printf 'operator_steps=review-authority,preserve-macos,verify-backup,verify-dfu,stop-on-failure\n'
    printf 'scope=static-record-only\nraw_commands=none\n'
} > "$out/plan.txt")
(umask 077; {
    printf 'mode=declarative-recovery-plan\n'
    printf 'The plan records operator gates and preserves macOS. It contains no secrets or raw commands.\n'
    printf 'An independent read-only recovery-plan anchor must pin plan.txt before simulation.\n'
} > "$out/policy.txt")
evidence_write_sums "$out" "$out/SHA256SUMS"
printf 'M9=recovery-plan-created plan=%s\n' "$out"
