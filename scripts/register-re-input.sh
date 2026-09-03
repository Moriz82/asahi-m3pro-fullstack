#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
usage() { printf 'usage: %s --input ABS --origin HTTPS_ORIGIN --lawful-basis BASIS --authority TEXT --operator TEXT\n' "$0" >&2; exit 64; }
[[ $# -eq 10 ]] || usage
input= origin= basis= authority= operator=
while [[ $# -gt 0 ]]; do
    case $1 in
        --input) input=$2;; --origin) origin=$2;; --lawful-basis) basis=$2;;
        --authority) authority=$2;; --operator) operator=$2;; *) usage;;
    esac
    shift 2
done
evidence_abs_regular "$input"
[[ $origin =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ && $origin != *'@'* ]] || evidence_die 'origin must be a credential-free HTTPS origin'
[[ $basis == public-licensed || $basis == user-owned-authorized || $basis == public-device-observation ]] || evidence_die 'invalid lawful basis'
[[ -n $authority && $authority != *$'\r'* && $authority != *$'\n'* ]] || evidence_die 'authority must be one line'
[[ -n $operator && $operator != *$'\r'* && $operator != *$'\n'* ]] || evidence_die 'operator must be one line'
mkdir -p -m 700 -- "$RE_EVIDENCE_ROOT"
hash=$(evidence_sha256 "$input")
size=$(wc -c < "$input" | tr -d '[:space:]')
timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
registration_id=$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$hash" "$origin" "$basis" "$authority" "$timestamp" "$operator" | evidence_sha256_stream)
out="$RE_EVIDENCE_ROOT/$hash"
evidence_new_dir "$out"
(umask 077; cp -- "$input" "$out/input.bin")
evidence_abs_regular "$out/input.bin"
[[ $(evidence_sha256 "$out/input.bin") == "$hash" ]] || evidence_die 'copied input hash changed'
(umask 077; {
    printf 'input_sha256=%s\ninput_size_bytes=%s\ninput_type=regular-file\nsource_origin=%s\nlawful_basis=%s\nauthority=%s\noperator=%s\n' "$hash" "$size" "$origin" "$basis" "$authority" "$operator"
    printf 'registration_timestamp=%s\nregistration_id=%s\nregistration_method=human-supplied\nprovenance_trusted=false\ntrust_source=none\n' "$timestamp" "$registration_id"
    printf 'mode=read-only\ntamper_evident=true\nsame_user_immutable=false\nhardware_acceptance=false\nida_execution=false\nbinary_ninja_execution=false\n'
} >"$out/manifest.txt")
(umask 077; {
    printf '%s\n' 'Use disposable workspace/ida and workspace/binary-ninja copies only.'
    printf '%s\n' 'Keep databases and decompiler output inside those disposable workspaces.'
    printf '%s\n' 'Loopback access only. Reject private, leaked, confidential, or unreviewed firmware and documentation.'
} >"$out/policy.txt")
evidence_write_sums "$out" "$out/SHA256SUMS"
printf 're-input=%s\n' "$out"
