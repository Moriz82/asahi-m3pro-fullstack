#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
[[ $# -eq 4 && $1 == --input && $3 == --report ]] || { printf 'usage: %s --input ABS --report ABS\n' "$0" >&2; exit 64; }
input=$2; report=$4
evidence_abs_regular "$input"
[[ $report == /* && ! -e $report && ! -L $report ]] || evidence_die "report must be a new absolute path"
parent=$(dirname -- "$report")
[[ -d $parent && ! -L $parent ]] || evidence_die "report parent must exist"
hash=$(evidence_sha256 "$input")
matches=$(mktemp "${TMPDIR:-/tmp}/kernel-log-matches.XXXXXX")
trap 'rm -f -- "$matches"' EXIT
grep -Ein \
    -e 'panic' \
    -e '(^|[^[:alnum:]_])(BUG|Oops|WARNING)([^[:alnum:]_]|$)' \
    -e 'KASAN|KCSAN|UBSAN' \
    -e 'lockdep' \
    -e 'DART[^[:cntrl:]]*fault' \
    -e 'IOMMU[^[:cntrl:]]*fault' \
    -e '(^|[^[:alnum:]_])SError([^[:alnum:]_]|$)' \
    -e 'unhandled[[:space:]]+fault' "$input" >"$matches" || true
status=clean
[[ ! -s $matches ]] || status=blocked
(umask 077; {
    printf 'input_sha256=%s\n' "$hash"
    printf 'status=%s\n' "$status"
    printf 'matched_lines=%s\n' "$(wc -l < "$matches" | tr -d ' ')"
    printf '%s\n' 'matches:'
    if [[ -s $matches ]]; then sed 's/^/  /' "$matches"; else printf '  none\n'; fi
} >"$report")
printf 'kernel-log=%s\n' "$status"
[[ $status == clean ]] || exit 2
