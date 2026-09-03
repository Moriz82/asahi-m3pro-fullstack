#!/usr/bin/env bash
# shellcheck disable=SC1091
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/m8-coverage.sh"
coverage_contract="$project_root/config/milestone8-platform-coverage.tsv"
forbidden_file="$project_root/config/milestone8-forbidden-vm-tokens.txt"
scan_forbidden_metadata() {
    local file=$1 token
    while IFS= read -r token || [[ -n $token ]]; do
        [[ -z $token || $token == \#* ]] && continue
        if grep -aFqi -- "$token" "$file"; then evidence_die "forbidden token '$token' in $file"; fi
    done < "$forbidden_file"
}
[[ $# -eq 4 && $1 == --evidence && $3 == --anchor ]] || { printf 'usage: %s --evidence ABS --anchor ABS\n' "$0" >&2; exit 64; }
root=$2; anchor=$4; evidence_abs_dir "$root"; evidence_abs_regular "$anchor"; evidence_abs_regular "$coverage_contract"
evidence_abs_regular "$forbidden_file"
[[ $anchor != "$root" && $anchor != "$root"/* ]] || evidence_die 'external anchor must be outside output bundle'
evidence_readonly "$anchor"
[[ $(evidence_kv "$anchor" format) == 1 ]] || evidence_die 'invalid external anchor format'
[[ $(evidence_kv "$anchor" anchor_type) == external-source-snapshot ]] || evidence_die 'invalid external anchor type'
scan_forbidden_metadata "$anchor"
for state in before candidate rollback; do "$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$root/$state" >/dev/null; done
for file in transaction.txt transactions.tsv SHA256SUMS; do evidence_abs_regular "$root/$file"; done
scan_forbidden_metadata "$root/transaction.txt"; scan_forbidden_metadata "$root/transactions.tsv"
[[ $(evidence_kv "$root/transaction.txt" hardware_acceptance) == false ]] || evidence_die 'hardware acceptance must be false'
[[ $(evidence_kv "$root/transaction.txt" status) == static-snapshot ]] || evidence_die 'transaction is not a static snapshot'
[[ $(evidence_kv "$root/transaction.txt" reversible) == true ]] || evidence_die 'transaction is not reversible'
[[ $(evidence_kv "$root/transaction.txt" mutated_source) == false ]] || evidence_die 'source mutation recorded'
for key in source_before_sha256 source_candidate_sha256 source_rollback_sha256 coverage_before_sha256 coverage_candidate_sha256 coverage_rollback_sha256; do [[ $(evidence_kv "$root/transaction.txt" "$key") =~ ^[[:xdigit:]]{64}$ ]] || evidence_die "invalid transaction hash: $key"; done
[[ $(evidence_kv "$root/transaction.txt" external_anchor_sha256) == "$(evidence_sha256 "$anchor")" ]] || evidence_die 'external anchor file changed'
[[ $(evidence_kv "$anchor" source_snapshot_sha256) == "$(evidence_sha256 "$root/before/SHA256SUMS")" ]] || evidence_die 'external anchor does not match before snapshot'
[[ $(evidence_kv "$root/transaction.txt" source_before_sha256) == "$(evidence_sha256 "$root/before/SHA256SUMS")" ]] || evidence_die 'before hash mismatch'
[[ $(evidence_kv "$root/transaction.txt" source_candidate_sha256) == "$(evidence_sha256 "$root/candidate/SHA256SUMS")" ]] || evidence_die 'candidate hash mismatch'
[[ $(evidence_kv "$root/transaction.txt" source_rollback_sha256) == "$(evidence_sha256 "$root/rollback/SHA256SUMS")" ]] || evidence_die 'rollback hash mismatch'
[[ $(evidence_kv "$root/transaction.txt" coverage_before_sha256) == "$(evidence_sha256 "$root/before/coverage.tsv")" ]] || evidence_die 'before coverage hash mismatch'
[[ $(evidence_kv "$root/transaction.txt" coverage_candidate_sha256) == "$(evidence_sha256 "$root/candidate/coverage.tsv")" ]] || evidence_die 'candidate coverage hash mismatch'
[[ $(evidence_kv "$root/transaction.txt" coverage_rollback_sha256) == "$(evidence_sha256 "$root/rollback/coverage.tsv")" ]] || evidence_die 'rollback coverage hash mismatch'
cmp -s "$root/before/packages.tsv" "$root/rollback/packages.tsv" || evidence_die 'rollback package metadata differs'
cmp -s "$root/before/repo.db" "$root/rollback/repo.db" || evidence_die 'rollback repo metadata differs'
cmp -s "$root/before/coverage.tsv" "$root/rollback/coverage.tsv" || evidence_die 'rollback platform coverage differs'
while IFS= read -r -d '' file; do rel=${file#"$root/before/"}; cmp -s "$file" "$root/rollback/$rel" || evidence_die "rollback differs: $rel"; done < <(find -P "$root/before" -type f -print0 | sort -z)
awk 'NR == 1 {next} $1 ~ /^[123]$/ {count++; if ($1 != count || $4 !~ /^[[:xdigit:]]{64}$/ || $5 !~ /^[[:xdigit:]]{64}$/ || $6 !~ /^(observed|planned)$/ || $7 != "yes") exit 2} END {exit !(count == 3)}' "$root/transactions.tsv" || evidence_die 'invalid transaction sequence'
while IFS=$'\t' read -r number operation state manifest_hash coverage_hash status reversible extra; do
    [[ $number == transaction || ( $number =~ ^[123]$ && $manifest_hash =~ ^[[:xdigit:]]{64}$ && $coverage_hash =~ ^[[:xdigit:]]{64}$ ) ]] || evidence_die 'invalid transaction coverage row'
done < "$root/transactions.tsv"
while IFS= read -r -d '' file; do
    if grep -aEiq '(^|[[:space:]])(pacman|repo-add|makepkg|gpg|curl|wget|ssh|diskutil|bless|bputil|nvram|systemctl|chroot|mount|umount)([[:space:]]|$)' "$file"; then evidence_die "unsafe action in rollback evidence: $file"; fi
done < <(find -P "$root" -type f -print0)
evidence_verify_sums "$root" "$root/SHA256SUMS"
printf 'M8=update-rollback-verified evidence=%s\n' "$root"
