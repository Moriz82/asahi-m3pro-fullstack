#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/common-tools.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
input="$tmp/input"
mkdir "$input"
printf 'model=Mac15,6\nboard=J514s\nsoc=T6030\n' > "$input/identity.txt"
printf 'cycle\tstatus\n1\tsuccess\n' > "$input/power-thermal.tsv"
printf 'cycle\tstatus\n1\tsuccess\n' > "$input/suspend-resume.tsv"
printf 'clean boot\n' > "$input/kernel.log"
out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/common-test.XXXXXX")
rmdir "$out"
"$project_root/scripts/create-evidence-bundle.sh" --milestone M2 --dry-run --input-dir "$input" --out "$out"
"$project_root/scripts/verify-evidence-bundle.sh" --bundle "$out" --expect-milestone M2 --expect-status software-plan-only
symlink_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/common-symlink.XXXXXX")
rmdir "$symlink_out"
"$project_root/scripts/create-evidence-bundle.sh" --milestone M2 --dry-run --input-dir "$input" --out "$symlink_out"
ln -s "$input/kernel.log" "$symlink_out/evil-link"
expect_fail "$project_root/scripts/verify-evidence-bundle.sh" --bundle "$symlink_out" --expect-milestone M2 --expect-status software-plan-only
printf 'tamper\n' >> "$out/inputs/identity.txt"
expect_fail "$project_root/scripts/verify-evidence-bundle.sh" --bundle "$out" --expect-milestone M2 --expect-status software-plan-only
missing="$tmp/missing"
mkdir "$missing"
cp "$input/identity.txt" "$input/kernel.log" "$input/power-thermal.tsv" "$missing/"
missing_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/common-missing.XXXXXX")
rmdir "$missing_out"
expect_fail "$project_root/scripts/create-evidence-bundle.sh" --milestone M2 --dry-run --input-dir "$missing" --out "$missing_out"
printf 'M3-%s\n' "$RANDOM" > "$tmp/re.txt"
registered=$($project_root/scripts/register-re-input.sh --input "$tmp/re.txt" --origin https://example.com --lawful-basis public-licensed --authority 'public license' --operator 'test operator' | sed 's/^re-input=//')
re_verify=$($project_root/scripts/verify-re-input.sh --bundle "$registered")
printf '%s\n' "$re_verify" | grep -Fx 'provenance_trusted=false' >/dev/null
printf '%s\n' "$re_verify" | grep -Fx 'gate=blocked-for-untrusted-provenance' >/dev/null
printf 'tampered\n' >> "$registered/input.bin"
expect_fail "$project_root/scripts/verify-re-input.sh" --bundle "$registered"
forged_input="$tmp/forged.txt"
printf 'forged-%s\n' "$RANDOM" > "$forged_input"
forged=$($project_root/scripts/register-re-input.sh --input "$forged_input" --origin https://example.com --lawful-basis public-licensed --authority 'public license' --operator 'test operator' | sed 's/^re-input=//')
sed -i.bak 's/^authority=.*/authority=forged/' "$forged/manifest.txt"
rm -f "$forged/manifest.txt.bak"
evidence_write_sums "$forged" "$forged/SHA256SUMS"
expect_fail "$project_root/scripts/verify-re-input.sh" --bundle "$forged"
semantic_input="$tmp/semantic-forgery.txt"
printf 'semantic-%s\n' "$RANDOM" > "$semantic_input"
semantic_bundle=$($project_root/scripts/register-re-input.sh --input "$semantic_input" --origin https://example.com --lawful-basis public-licensed --authority 'public license' --operator 'test operator' | sed 's/^re-input=//')
semantic_hash=$(evidence_kv "$semantic_bundle/manifest.txt" input_sha256)
semantic_origin=$(evidence_kv "$semantic_bundle/manifest.txt" source_origin)
semantic_basis=$(evidence_kv "$semantic_bundle/manifest.txt" lawful_basis)
semantic_timestamp=$(evidence_kv "$semantic_bundle/manifest.txt" registration_timestamp)
semantic_operator=$(evidence_kv "$semantic_bundle/manifest.txt" operator)
semantic_id=$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$semantic_hash" "$semantic_origin" "$semantic_basis" 'reviewed-forgery' "$semantic_timestamp" "$semantic_operator" | evidence_sha256_stream)
sed -i.bak -e 's/^authority=.*/authority=reviewed-forgery/' -e "s/^registration_id=.*/registration_id=$semantic_id/" "$semantic_bundle/manifest.txt"
rm -f "$semantic_bundle/manifest.txt.bak"
evidence_write_sums "$semantic_bundle" "$semantic_bundle/SHA256SUMS"
semantic_verify=$($project_root/scripts/verify-re-input.sh --bundle "$semantic_bundle")
printf '%s\n' "$semantic_verify" | grep -Fx 'provenance_trusted=false' >/dev/null
printf '%s\n' "$semantic_verify" | grep -Fx 'gate=blocked-for-untrusted-provenance' >/dev/null
self_ledger="$tmp/self-trust-ledger"
printf 'self-authored\n' > "$self_ledger"
self_ledger_hash=$(evidence_sha256 "$self_ledger")
expect_fail env RE_TRUST_LEDGER="$self_ledger" RE_TRUST_LEDGER_SHA256="$self_ledger_hash" "$project_root/scripts/verify-re-input.sh" --bundle "$forged"
missing_input="$tmp/missing-provenance.txt"
printf 'missing-%s\n' "$RANDOM" > "$missing_input"
missing_bundle=$($project_root/scripts/register-re-input.sh --input "$missing_input" --origin https://example.com --lawful-basis public-licensed --authority 'public license' --operator 'test operator' | sed 's/^re-input=//')
sed -i.bak '/^authority=/d' "$missing_bundle/manifest.txt"
rm -f "$missing_bundle/manifest.txt.bak"
evidence_write_sums "$missing_bundle" "$missing_bundle/SHA256SUMS"
expect_fail "$project_root/scripts/verify-re-input.sh" --bundle "$missing_bundle"
for name in clean.log; do report="$tmp/$name.report"; "$project_root/scripts/analyze-kernel-log.sh" --input "$project_root/tests/fixtures/kernel/$name" --report "$report"; done
for name in panic.log dart-fault.log lockdep.log; do report="$tmp/$name.report"; expect_fail "$project_root/scripts/analyze-kernel-log.sh" --input "$project_root/tests/fixtures/kernel/$name" --report "$report"; done
# Synthetic lines quote error text from the pinned Apple PMGR/DART drivers;
# these exercise log validation only, never a device or driver C function.
power_case=0
while IFS= read -r line; do
    power_case=$((power_case + 1))
    printf '%s\n' "$line" >"$tmp/power-$power_case.log"
    expect_fail evidence_scan_fault_log "$tmp/power-$power_case.log"
    result=0
    "$project_root/scripts/analyze-kernel-log.sh" --input "$tmp/power-$power_case.log" --report "$tmp/power-$power_case.report" || result=$?
    [[ $result == 2 ]]
    grep -Fx status=blocked "$tmp/power-$power_case.report" >/dev/null
    grep -Fx matched_lines=1 "$tmp/power-$power_case.report" >/dev/null
done <"$project_root/tests/fixtures/kernel/apple-power-faults.log"
[[ $power_case == 7 ]]
printf '%s\n' \
    'apple-pmgr-pwrstate test-pmgr: PS test-domain: pwrstate = 0xf: 0xf' \
    'apple-pmgr-pwrstate test-pmgr: PS 0x0: assert reset' \
    'apple-pmgr-pwrstate test-pmgr: PS 0x0: deassert reset' \
    'apple-dart test-dart: command completed' >"$tmp/power-clean.log"
evidence_scan_fault_log "$tmp/power-clean.log"
"$project_root/scripts/analyze-kernel-log.sh" --input "$tmp/power-clean.log" --report "$tmp/power-clean.report"
grep -Fx status=clean "$tmp/power-clean.report" >/dev/null
# A scanner I/O/tool failure is not the same as grep's no-match status.
mkdir "$tmp/failing-tools"
printf '#!/bin/sh\nexit 2\n' >"$tmp/failing-tools/grep"
chmod 0755 "$tmp/failing-tools/grep"
PATH="$tmp/failing-tools:$PATH" expect_fail evidence_scan_fault_log "$tmp/power-clean.log"
expect_fail env PATH="$tmp/failing-tools:$PATH" "$project_root/scripts/analyze-kernel-log.sh" \
    --input "$tmp/power-clean.log" --report "$tmp/must-not-publish.report"
[[ ! -e $tmp/must-not-publish.report ]]
# Guards must also reject invalid paths when a caller tests their return status
# (a context where Bash disables implicit errexit within the function).
ln -s "$tmp/power-clean.log" "$tmp/linked.log"
expect_fail evidence_abs_regular "$tmp/linked.log"
expect_fail evidence_scan_fault_log "$tmp/linked.log"
expect_fail evidence_abs_regular tests/fixtures/kernel/clean.log
expect_fail evidence_scan_fault_log tests/fixtures/kernel/clean.log
expect_fail evidence_scan_fault_log "$tmp/missing.log"
# Caller readonly names must not collide with helper locals (notably Bash 3.2).
(
    readonly source="$tmp/atomic-source" destination="$tmp/atomic-destination"
    mkdir "$source"
    printf preserved >"$source/marker"
    evidence_atomic_publish_directory "$source" "$destination"
    [[ ! -e $source && $(cat "$destination/marker") == preserved ]]
    mkdir "$source"
    expect_fail evidence_atomic_publish_directory "$source" "$destination"
    [[ -d $source && $(cat "$destination/marker") == preserved ]]
)
printf 'common-tools=passed\n'
