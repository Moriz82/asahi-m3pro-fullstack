#!/usr/bin/env bash
# Aggregate static gate: syntax, shell policy, self-tests, and blocked exits.
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ $# -eq 1 && $1 == --static ]] || { printf 'usage: %s --static\n' "$0" >&2; exit 64; }
command -v shellcheck >/dev/null 2>&1 || { printf 'shellcheck is required\n' >&2; exit 1; }
readonly contract_file="$project_root/config/milestone-contracts.tsv"
[[ -f $contract_file && ! -L $contract_file ]] || { printf 'milestone contract is not a regular file\n' >&2; exit 1; }
contract_rows=$(awk -F '\t' '
    BEGIN {
        expected[0] = "M0"; expected[1] = "M1"; expected[2] = "M2";
        expected[3] = "M3"; expected[4] = "M4"; expected[5] = "M5";
        expected[6] = "M6"; expected[7] = "M7"; expected[8] = "M8";
        expected[9] = "M9"; header = "milestone\tpredecessor\tdocument\tverifier\thandoff"; count = 0
    }
    NR == 1 { if ($0 != header) invalid=1; next }
    NF != 5 || $1 !~ /^M[0-9]$/ || $2 !~ /^(none|M[0-8])$/ ||
        $3 == "" || $4 == "" || $5 == "" { invalid=1; next }
    {
        predecessor = count == 0 ? "none" : expected[count-1]
        if (++seen[$1] != 1 || $1 != expected[count] || $2 != predecessor) invalid=1
        print $1 "\t" $2
        count++
    }
    END {
        for (i=0; i<10; i++) if (seen[expected[i]] != 1) invalid=1
        if (invalid || count != 10) exit 1
    }
' "$contract_file") || { printf 'invalid milestone contract\n' >&2; exit 1; }
milestones=()
predecessors=()
while IFS=$'\t' read -r milestone predecessor; do
    milestones+=("$milestone")
    predecessors+=("$predecessor")
done <<< "$contract_rows"
test_root=${TEST_OUTPUT_ROOT:-${TMPDIR:-/tmp}/asahi-static-tools.$$}
mkdir -p -m 700 "$test_root" "$test_root/milestones" "$test_root/re" "$test_root/handoffs"
export TEST_OUTPUT_ROOT="$test_root"
export MILESTONE_EVIDENCE_ROOT="$test_root/milestones"
export RE_EVIDENCE_ROOT="$test_root/re"
export MILESTONE_HANDOFF_ROOT="$test_root/handoffs"
export SOFTWARE_OUTPUT_ROOT="$test_root"
export MILESTONE1_OUTPUT_ROOT="$test_root/m1"
export M0_INTEGRITY_REAL=0
scripts=()
while IFS= read -r script; do scripts+=("$script"); done < <(find "$project_root/scripts" "$project_root/tests" -type f -name '*.sh' -print | LC_ALL=C sort)
((${#scripts[@]} > 0))
for script in "${scripts[@]}" "$project_root"/config/*.env; do bash -n "$script"; done
sh -n "$project_root/initramfs/milestone1/init"
shellcheck --severity=error "${scripts[@]}"
shellcheck -s sh --severity=error "$project_root/initramfs/milestone1/init"
printf 'syntax_checked=%s_shell_files_plus_config_and_init\n' "${#scripts[@]}"
passed=0
for test_script in "$project_root"/scripts/test-*.sh; do
    [[ -f $test_script ]] || continue
    log="$test_root/$(basename "$test_script").log"
    if "$test_script" >"$log" 2>&1; then
        printf 'PASS %s\n' "${test_script##*/}"
        grep -E '^(SKIP |.* skipped:)' "$log" || :
        passed=$((passed + 1))
    else
        printf 'FAIL %s (log: %s)\n' "${test_script##*/}" "$log" >&2
        tail -40 "$log" >&2
        exit 1
    fi
done
printf 'fixture_suites_passed=%s\n' "$passed"
printf 'signed_fixture_suites=separate_CI_job_requires_pinned_Arch_repo_add_7_1\n'
printf 'source_contract_suites=not-run_requires_clean_pinned_source_and_M0_artifacts\n'
printf 'u_boot_artifact_suite=not-run_requires_M0_artifacts\n'
printf 'bootloader_source_suite=not-run_requires_pinned_m1n1_and_U_Boot_sources_and_AArch64_builder\n'
printf 'm2_driver_source_suite=not-run_requires_clean_pinned_Linux_and_AArch64_builder\n'
for index in "${!milestones[@]}"; do
    milestone=${milestones[index]}
    predecessor=${predecessors[index]}
    set +e
    gate_output=$("$project_root/scripts/check-milestone-gate.sh" \
        --milestone "$milestone" --dry-run 2>/dev/null)
    gate_status=$?
    set -e
    [[ $gate_status -eq 2 ]] || { printf 'gate did not remain blocked: %s (exit %s)\n' "$milestone" "$gate_status" >&2; exit 1; }
    printf '%s\n' "$gate_output" | grep -Fx "milestone=$milestone" >/dev/null
    printf '%s\n' "$gate_output" | grep -Fx "expected-predecessor=$predecessor" >/dev/null
    printf '%s\n' "$gate_output" | grep -Fx 'tooling_valid=not-run' >/dev/null
    printf '%s\n' "$gate_output" | grep -Fx 'evidence_valid=not-provided' >/dev/null
    printf '%s\n' "$gate_output" | grep -Fx 'hardware_acceptance=false' >/dev/null
    printf '%s\n' "$gate_output" | grep -Fx 'gate=blocked-for-native-execution' >/dev/null
    printf '%s expected-predecessor=%s tooling_valid=not-run evidence_valid=not-provided hardware_acceptance=false gate=blocked-for-native-execution\n' "$milestone" "$predecessor"
done
printf 'aggregate_tooling_valid=true\n'
