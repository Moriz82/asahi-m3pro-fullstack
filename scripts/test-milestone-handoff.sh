#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
test_root=${TEST_OUTPUT_ROOT:-${TMPDIR:-/tmp}/asahi-handoff-tests}
mkdir -p -m 700 "$test_root"
tmp=$(mktemp -d "$test_root/handoff.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
MILESTONE_EVIDENCE_ROOT="$tmp/evidence"
MILESTONE_HANDOFF_ROOT="$tmp/handoffs"
export MILESTONE_EVIDENCE_ROOT MILESTONE_HANDOFF_ROOT
mkdir -m 700 "$MILESTONE_EVIDENCE_ROOT" "$MILESTONE_HANDOFF_ROOT"
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
input="$tmp/m2-input"; mkdir -m 700 "$input"
printf 'model=Mac15,6\nboard=J514s\nsoc=T6030\n' > "$input/identity.txt"
cp "$project_root/tests/fixtures/kernel/clean.log" "$input/kernel.log"
printf 'cycle\tstatus\ttemperature_c\n' > "$input/power-thermal.tsv"
printf 'cycle\tstatus\tresume_ms\n' > "$input/suspend-resume.tsv"
for i in $(seq 1 20); do printf '%s\tsuccess\t40\n' "$i" >> "$input/power-thermal.tsv"; printf '%s\tsuccess\t10\n' "$i" >> "$input/suspend-resume.tsv"; done
bundle="$MILESTONE_EVIDENCE_ROOT/handoff-m2-bundle.$$"; "$project_root/scripts/collect-m2-core-power.sh" --dry-run --input-dir "$input" --out "$bundle" >/dev/null
handoff="$MILESTONE_HANDOFF_ROOT/M2-test.$$"; "$project_root/scripts/create-milestone-handoff.sh" --milestone M2 --source "$bundle" --out "$handoff" >/dev/null
"$project_root/scripts/verify-milestone-handoff.sh" --bundle "$handoff" >/dev/null
outside_parent="$tmp/outside-handoff-parent"; mkdir "$outside_parent"
cp -R -- "$handoff" "$outside_parent/existing"
symlink_parent="$MILESTONE_HANDOFF_ROOT/symlink-parent.$$"
ln -s "$outside_parent" "$symlink_parent"
if evidence_path_under "$symlink_parent/existing" "$MILESTONE_HANDOFF_ROOT" >/dev/null 2>&1; then
    printf 'direct containment helper accepted a symlinked ancestor\n' >&2
    exit 1
fi
expect_fail "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$symlink_parent/existing"
expect_fail "$project_root/scripts/create-milestone-handoff.sh" --milestone M2 --source "$bundle" --out "$symlink_parent/new"
physical_alias_parent="$tmp/physical-alias-parent"
logical_alias_parent="$tmp/logical-alias-parent"
mkdir "$physical_alias_parent" "$physical_alias_parent/root" "$physical_alias_parent/root/child"
ln -s "$physical_alias_parent" "$logical_alias_parent"
physical_alias_root="$physical_alias_parent/root"
logical_alias_root="$logical_alias_parent/root"
evidence_path_under "$logical_alias_root/child" "$physical_alias_root"
evidence_path_under "$physical_alias_root/child" "$logical_alias_root"
bad="$MILESTONE_HANDOFF_ROOT/M2-bad.$$"; cp -R -- "$handoff" "$bad"; ln -s "$handoff/source/bundle/identity.txt" "$bad/source/escape"; expect_fail "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$bad"
race_source="$tmp/m2-race"; cp -R -- "$bundle" "$race_source"
before=$(evidence_sha256 "$race_source/SHA256SUMS")
race_mutated="$tmp/race-mutated"
(
    pause_marker=
    for _ in $(seq 1 400); do
        pause_marker=$(find -P "$MILESTONE_EVIDENCE_ROOT" -type f -name .handoff-copy-test-paused -print -quit)
        [[ -z $pause_marker ]] || break
        /bin/sleep 0.01
    done
    [[ -n $pause_marker ]]
    printf changed >> "$race_source/SHA256SUMS"
    : > "$race_mutated"
) &
race_mutator_pid=$!
race_handoff="$MILESTONE_HANDOFF_ROOT/M2-race.$$"
MILESTONE_HANDOFF_TEST_PAUSE_AFTER_FIRST_COPY=1 "$project_root/scripts/create-milestone-handoff.sh" --milestone M2 --source "$race_source" --out "$race_handoff" >/dev/null
wait "$race_mutator_pid"
[[ -f $race_mutated ]] || { printf 'copy-pause mutator did not run\n' >&2; exit 1; }
[[ $(evidence_sha256 "$race_handoff/source/bundle/SHA256SUMS") == "$before" ]] || { printf 'copied snapshot changed during source mutation\n' >&2; exit 1; }
bad_rehashed="$MILESTONE_HANDOFF_ROOT/M2-rehashed.$$"; cp -R -- "$handoff" "$bad_rehashed"
printf 'model=Mac15,7\nboard=J514s\nsoc=T6030\n' > "$bad_rehashed/source/bundle/inputs/identity.txt"
identity_hash=$(evidence_sha256 "$bad_rehashed/source/bundle/inputs/identity.txt"); identity_size=$(wc -c < "$bad_rehashed/source/bundle/inputs/identity.txt" | tr -d '[:space:]')
awk -F '\t' -v OFS='\t' -v h="$identity_hash" -v s="$identity_size" '$1 == "source/bundle/inputs/identity.txt" {$3=h; $4=s} {print}' "$bad_rehashed/inventory.tsv" > "$bad_rehashed/inventory.new"
mv "$bad_rehashed/inventory.new" "$bad_rehashed/inventory.tsv"
inv_hash=$(evidence_sha256 "$bad_rehashed/inventory.tsv")
sed -i.bak "s/^source_inventory_sha256=.*/source_inventory_sha256=$inv_hash/" "$bad_rehashed/manifest.txt"; rm -f "$bad_rehashed/manifest.txt.bak"
evidence_write_sums "$bad_rehashed" "$bad_rehashed/SHA256SUMS"
expect_fail "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$bad_rehashed"
empty="$MILESTONE_HANDOFF_ROOT/M2-empty.$$"; cp -R -- "$handoff" "$empty"; mkdir "$empty/source/undeclared-empty"; expect_fail "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$empty"
printf 'milestone handoff tests passed\n'
