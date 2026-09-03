#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
[[ $# -eq 3 && $1 == --milestone && $2 =~ ^M[0-9]$ && $3 == --dry-run ]] || {
    printf 'usage: %s --milestone M0..M9 --dry-run\n' "$0" >&2; exit 64;
}
milestone=$2
readonly contract_file="$project_root/config/milestone-contracts.tsv"
[[ -f $contract_file && ! -L $contract_file ]] || {
    printf 'error: milestone contract is not a regular file: %s\n' "$contract_file" >&2
    exit 1
}
predecessor=$(awk -F '\t' -v wanted="$milestone" '
    NR == 1 {
        if ($0 != "milestone\tpredecessor\tdocument\tverifier\thandoff") exit 1
        next
    }
    NF != 5 || $1 !~ /^M[0-9]$/ || $2 !~ /^(none|M[0-8])$/ { invalid=1; next }
    {
        seen[$1]++
        if ($1 == wanted) { match_count++; value=$2 }
    }
    END {
        for (milestone in seen) if (seen[milestone] != 1) invalid=1
        if (invalid || match_count != 1 || value == "") exit 1
        print value
    }
' "$contract_file") || {
    printf 'error: invalid milestone contract for %s: %s\n' "$milestone" "$contract_file" >&2
    exit 1
}
printf 'milestone=%s\n' "$milestone"
printf 'expected-predecessor=%s\n' "$predecessor"
printf 'tooling_valid=not-run\nevidence_valid=not-provided\nhardware_acceptance=false\n'
printf 'gate=blocked-for-native-execution\n'
exit 2
