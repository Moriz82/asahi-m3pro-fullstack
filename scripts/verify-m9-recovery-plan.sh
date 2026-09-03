#!/usr/bin/env bash
# Verify a declarative recovery record against independent release and plan pins.
# shellcheck disable=SC1091
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
M9_PROJECT_ROOT=$project_root
source "$project_root/scripts/lib/m9-canonical.sh"
output_root=${SOFTWARE_OUTPUT_ROOT:-$project_root/out}
usage() { printf 'usage: %s --plan ABS --release-inputs ABS --release-anchor ABS --anchor ABS\n' "$0" >&2; exit 64; }
[[ $# -eq 8 && $1 == --plan && $3 == --release-inputs && $5 == --release-anchor && $7 == --anchor ]] || usage
plan=$2; release=$4; release_anchor=$6; anchor=$8
evidence_abs_dir "$plan"; evidence_abs_dir "$release"; evidence_abs_regular "$release_anchor"; evidence_abs_regular "$anchor"
[[ $anchor != "$plan" && $anchor != "$plan"/* && $anchor != "$release" && $anchor != "$release"/* && $anchor != "$output_root" && $anchor != "$output_root"/* && $release_anchor != "$plan" && $release_anchor != "$plan"/* && $release_anchor != "$release" && $release_anchor != "$release"/* && $release_anchor != "$output_root" && $release_anchor != "$output_root"/* ]] || evidence_die 'anchors must be outside release and plan trees'
evidence_readonly "$anchor"; evidence_readonly "$release_anchor"
[[ $(evidence_kv "$anchor" format) == 1 && $(evidence_kv "$anchor" anchor_type) == external-recovery-plan ]] || evidence_die 'invalid recovery anchor'
[[ $(evidence_kv "$anchor" anchor_trust) == untrusted-declarative ]] || evidence_die 'recovery anchor is not a configured signed authority'
[[ $(evidence_kv "$anchor" plan_sha256) == "$(evidence_sha256 "$plan/plan.txt")" ]] || evidence_die 'recovery plan anchor mismatch'
[[ $(evidence_kv "$anchor" release_anchor_sha256) == "$(evidence_sha256 "$release_anchor")" ]] || evidence_die 'release anchor pin mismatch'
m9_validate_canonical_release_binding "$release" "$release_anchor"
for file in plan.txt policy.txt SHA256SUMS; do evidence_abs_regular "$plan/$file"; done
while IFS= read -r -d '' link; do evidence_die "symlink member: $link"; done < <(find -P "$plan" -type l -print0)
while IFS= read -r -d '' member; do evidence_die "extra recovery-plan member: ${member#"$plan"/}"; done < <(find -P "$plan" -type f ! -name plan.txt ! -name policy.txt ! -name SHA256SUMS -print0)
evidence_verify_sums "$plan" "$plan/SHA256SUMS"
[[ $(evidence_kv "$plan/plan.txt" target_model) == Mac15,6 ]] || evidence_die 'recovery model mismatch'
[[ $(evidence_kv "$plan/plan.txt" target_board) == J514s ]] || evidence_die 'recovery board mismatch'
[[ $(evidence_kv "$plan/plan.txt" target_soc) == T6030 ]] || evidence_die 'recovery SoC mismatch'
[[ $(evidence_kv "$plan/plan.txt" status) == declarative ]] || evidence_die 'recovery plan is not declarative'
for key in hardware_acceptance actuation macos_preserved recovery_proof_required backup_recovery_required dfu_required native_action; do value=$(evidence_kv "$plan/plan.txt" "$key"); [[ $value == true || $value == false ]] || evidence_die "invalid recovery field: $key"; done
[[ $(evidence_kv "$plan/plan.txt" hardware_acceptance) == false && $(evidence_kv "$plan/plan.txt" actuation) == false && $(evidence_kv "$plan/plan.txt" native_action) == false ]] || evidence_die 'recovery plan claims execution'
[[ $(evidence_kv "$plan/plan.txt" macos_preserved) == true ]] || evidence_die 'macOS preservation is required'
for key in recovery_proof_required backup_recovery_required dfu_required; do [[ $(evidence_kv "$plan/plan.txt" "$key") == true ]] || evidence_die "missing recovery proof: $key"; done
[[ $(evidence_kv "$plan/plan.txt" raw_commands) == none ]] || evidence_die 'raw commands are not accepted'
[[ $(evidence_kv "$plan/plan.txt" release_anchor_sha256) == "$(evidence_sha256 "$release_anchor")" ]] || evidence_die 'release anchor changed'
[[ $(evidence_kv "$plan/plan.txt" release_inputs_sha256) == "$(evidence_sha256 "$release/manifest.txt")" ]] || evidence_die 'release input pin mismatch'
if grep -Eiq 'password|token|private[[:space:]]+key|-----BEGIN' "$plan/plan.txt"; then evidence_die 'secret material in recovery plan'; fi
if grep -Eiq 'diskutil|partition|apfs|bless|bputil|nvram|firmware|startup|reboot|native-install|execute-install|modify-container|existing-container|remove-macos|erase-macos|mount|umount|systemctl|chroot|ssh|curl|wget' "$plan/plan.txt" "$plan/policy.txt"; then evidence_die 'unsafe recovery-plan token'; fi
printf 'M9=recovery-plan-verified plan=%s\n' "$plan"
