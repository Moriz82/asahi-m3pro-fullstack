#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m2-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
MILESTONE_EVIDENCE_ROOT="$tmp/evidence"
export MILESTONE_EVIDENCE_ROOT
mkdir -m 700 "$MILESTONE_EVIDENCE_ROOT"
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
make_input() {
    local dir=$1 count=$2 i
    mkdir "$dir"
    printf 'model=Mac15,6\nboard=J514s\nsoc=T6030\n' > "$dir/identity.txt"
    cp "$project_root/tests/fixtures/kernel/clean.log" "$dir/kernel.log"
    printf 'cycle\tstatus\ttemperature_c\n' > "$dir/power-thermal.tsv"
    printf 'cycle\tstatus\tresume_ms\n' > "$dir/suspend-resume.tsv"
    for i in $(seq 1 "$count"); do printf '%s\tsuccess\t40\n' "$i" >> "$dir/power-thermal.tsv"; printf '%s\tsuccess\t10\n' "$i" >> "$dir/suspend-resume.tsv"; done
}
valid="$tmp/valid"; make_input "$valid" 20
out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m2-test.XXXXXX"); rmdir "$out"
"$project_root/scripts/collect-m2-core-power.sh" --dry-run --input-dir "$valid" --out "$out"
"$project_root/scripts/verify-m2-core-power.sh" --bundle "$out"
sed -i.bak 's/^status=clean$/status=blocked/' "$out/analysis/kernel-log.txt"
rm -f "$out/analysis/kernel-log.txt.bak"
evidence_write_sums "$out" "$out/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m2-core-power.sh" --bundle "$out"
short="$tmp/short"; make_input "$short" 19
short_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m2-short.XXXXXX"); rmdir "$short_out"
expect_fail "$project_root/scripts/collect-m2-core-power.sh" --dry-run --input-dir "$short" --out "$short_out"
duplicate="$tmp/duplicate"
make_input "$duplicate" 20
sed -i.bak 's/^20\t/1\t/' "$duplicate/power-thermal.tsv"
rm -f "$duplicate/power-thermal.tsv.bak"
duplicate_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m2-duplicate.XXXXXX")
rmdir "$duplicate_out"
expect_fail "$project_root/scripts/collect-m2-core-power.sh" --dry-run --input-dir "$duplicate" --out "$duplicate_out"
for signature in panic.log dart-fault.log lockdep.log; do
    bad="$tmp/bad-$signature"
    cp -R "$valid" "$bad"
    cp "$project_root/tests/fixtures/kernel/$signature" "$bad/kernel.log"
    bad_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m2-$signature.XXXXXX")
    rmdir "$bad_out"
    "$project_root/scripts/create-evidence-bundle.sh" --milestone M2 --dry-run --input-dir "$bad" --out "$bad_out"
    expect_fail "$project_root/scripts/verify-m2-core-power.sh" --bundle "$bad_out"
done
for token in BUG Oops WARNING SError; do
    bad="$tmp/bad-$token"
    cp -R "$valid" "$bad"
    printf '[    2.000000] %s: test signature\n' "$token" > "$bad/kernel.log"
    bad_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m2-$token.XXXXXX")
    rmdir "$bad_out"
    "$project_root/scripts/create-evidence-bundle.sh" --milestone M2 --dry-run --input-dir "$bad" --out "$bad_out"
    expect_fail "$project_root/scripts/verify-m2-core-power.sh" --bundle "$bad_out"
done
printf 'M2-tests=passed\n'
