#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
readonly trusted_ledger_path="$project_root/config/re-trust-ledger.tsv"
readonly trusted_ledger_sha256='7b4b63ddbeb9446d2be3906178c2d55b0f9fae59cb0db019a31e91d5ba1cf91e'
[[ $# -eq 2 && $1 == --bundle ]] || { printf 'usage: %s --bundle ABS\n' "$0" >&2; exit 64; }
bundle=$2
[[ -z ${RE_TRUST_LEDGER+x} && -z ${RE_TRUST_LEDGER_SHA256+x} ]] || evidence_die 'caller trust-ledger overrides are rejected'
evidence_abs_dir "$bundle"
evidence_path_under "$bundle" "$RE_EVIDENCE_ROOT"
for file in input.bin manifest.txt policy.txt SHA256SUMS; do evidence_abs_regular "$bundle/$file"; done
hash=$(evidence_kv "$bundle/manifest.txt" input_sha256)
size=$(evidence_kv "$bundle/manifest.txt" input_size_bytes)
input_type=$(evidence_kv "$bundle/manifest.txt" input_type)
origin=$(evidence_kv "$bundle/manifest.txt" source_origin)
basis=$(evidence_kv "$bundle/manifest.txt" lawful_basis)
authority=$(evidence_kv "$bundle/manifest.txt" authority)
operator=$(evidence_kv "$bundle/manifest.txt" operator)
timestamp=$(evidence_kv "$bundle/manifest.txt" registration_timestamp)
registration_id=$(evidence_kv "$bundle/manifest.txt" registration_id)
registration_method=$(evidence_kv "$bundle/manifest.txt" registration_method)
[[ $hash =~ ^[[:xdigit:]]{64}$ ]] || evidence_die 'invalid input hash schema'
[[ $size =~ ^[0-9]+$ ]] || evidence_die 'invalid input size schema'
[[ $input_type == regular-file ]] || evidence_die 'invalid input type schema'
[[ $origin =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ && $origin != *'@'* ]] || evidence_die 'invalid source origin schema'
[[ $basis == public-licensed || $basis == user-owned-authorized || $basis == public-device-observation ]] || evidence_die 'invalid lawful basis schema'
[[ -n $authority && $authority != *$'\r'* && $authority != *$'\n'* ]] || evidence_die 'invalid authority schema'
[[ -n $operator && $operator != *$'\r'* && $operator != *$'\n'* ]] || evidence_die 'invalid operator schema'
[[ $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || evidence_die 'invalid registration timestamp schema'
[[ $registration_id =~ ^[[:xdigit:]]{64}$ ]] || evidence_die 'invalid registration id schema'
[[ $registration_method == human-supplied ]] || evidence_die 'invalid registration method schema'
expected_registration_id=$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$hash" "$origin" "$basis" "$authority" "$timestamp" "$operator" | evidence_sha256_stream)
[[ $registration_id == "$expected_registration_id" ]] || evidence_die 'registration id does not match registration fields'
[[ $bundle == "$RE_EVIDENCE_ROOT/$hash" ]] || evidence_die 'bundle path does not match input hash'
[[ $(evidence_sha256 "$bundle/input.bin") == "$hash" ]] || evidence_die 'input tampered'
[[ $(wc -c < "$bundle/input.bin" | tr -d '[:space:]') == "$size" ]] || evidence_die 'input size changed'
[[ $(evidence_kv "$bundle/manifest.txt" mode) == read-only ]] || evidence_die 'mode is not read-only'
[[ $(evidence_kv "$bundle/manifest.txt" tamper_evident) == true ]] || evidence_die 'tamper evidence missing'
[[ $(evidence_kv "$bundle/manifest.txt" hardware_acceptance) == false ]] || evidence_die 'hardware acceptance must be false'
[[ $(evidence_kv "$bundle/manifest.txt" provenance_trusted) == false ]] || evidence_die 'self-authored trust claim is not accepted'
[[ $(evidence_kv "$bundle/manifest.txt" trust_source) == none ]] || evidence_die 'unconfigured trust source is not accepted'
grep -Eiq 'private|leaked|confidential|unreviewed|loopback|disposable' "$bundle/policy.txt" || evidence_die 'policy incomplete'
while IFS= read -r -d '' file; do evidence_die "extra RE member: ${file#"$bundle"/}"; done < <(find -P "$bundle" -type f ! -name input.bin ! -name manifest.txt ! -name policy.txt ! -name SHA256SUMS -print0)
while IFS= read -r -d '' link; do evidence_die "symlink member: $link"; done < <(find -P "$bundle" -type l -print0)
while IFS= read -r -d '' dir; do
    [[ $dir == "$bundle" ]] || evidence_die "extra RE directory: $dir"
done < <(find -P "$bundle" -type d -print0)
evidence_verify_sums "$bundle" "$bundle/SHA256SUMS"
provenance_trusted=false
evidence_abs_regular "$trusted_ledger_path"
evidence_hash_file "$trusted_ledger_path" "$trusted_ledger_sha256"
manifest_hash=$(evidence_sha256 "$bundle/manifest.txt")
if grep -F -x -- "$registration_id|$hash|$manifest_hash" "$trusted_ledger_path" >/dev/null; then provenance_trusted=true; fi
if [[ $provenance_trusted == true ]]; then
    printf 're-input=integrity-verified:%s\nprovenance_trusted=true\ngate=blocked-for-native-execution\n' "$bundle"
else
    printf 're-input=integrity-verified:%s\nprovenance_trusted=false\ngate=blocked-for-untrusted-provenance\n' "$bundle"
fi
