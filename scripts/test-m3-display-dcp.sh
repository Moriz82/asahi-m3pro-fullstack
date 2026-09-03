#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m3-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
MILESTONE_EVIDENCE_ROOT="$tmp/evidence"
export MILESTONE_EVIDENCE_ROOT
mkdir -m 700 "$MILESTONE_EVIDENCE_ROOT"
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
make_input() {
    local dir=$1 brightness=$2 suspend=$3 i
    mkdir "$dir"
    printf 'model=Mac15,6\nboard=J514s\nsoc=T6030\n' > "$dir/identity.txt"
    cp "$project_root/tests/fixtures/kernel/clean.log" "$dir/kernel.log"
    cp "$project_root/tests/fixtures/kernel/clean.log" "$dir/dcp.log"
    printf 'mode\twidth\theight\trefresh_hz\ninternal\t3024\t1964\t120\n' > "$dir/display-modes.tsv"
    printf 'cycle\tstatus\tbrightness_percent\n' > "$dir/brightness.tsv"
    printf 'cycle\tstatus\tresume_ms\n' > "$dir/suspend-resume.tsv"
    for i in $(seq 1 "$brightness"); do printf '%s\tsuccess\t50\n' "$i" >> "$dir/brightness.tsv"; done
    for i in $(seq 1 "$suspend"); do printf '%s\tsuccess\t10\n' "$i" >> "$dir/suspend-resume.tsv"; done
}
valid="$tmp/valid"; make_input "$valid" 100 50
out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m3-test.XXXXXX"); rmdir "$out"
"$project_root/scripts/collect-m3-display-dcp.sh" --dry-run --input-dir "$valid" --out "$out"
"$project_root/scripts/verify-m3-display-dcp.sh" --bundle "$out"
short="$tmp/short"; make_input "$short" 99 49
short_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m3-short.XXXXXX"); rmdir "$short_out"
expect_fail "$project_root/scripts/collect-m3-display-dcp.sh" --dry-run --input-dir "$short" --out "$short_out"
duplicate_brightness="$tmp/duplicate-brightness"
make_input "$duplicate_brightness" 100 50
sed -i.bak 's/^100\t/1\t/' "$duplicate_brightness/brightness.tsv"
rm -f "$duplicate_brightness/brightness.tsv.bak"
duplicate_brightness_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m3-duplicate-brightness.XXXXXX")
rmdir "$duplicate_brightness_out"
expect_fail "$project_root/scripts/collect-m3-display-dcp.sh" --dry-run --input-dir "$duplicate_brightness" --out "$duplicate_brightness_out"
duplicate_suspend="$tmp/duplicate-suspend"
make_input "$duplicate_suspend" 100 50
sed -i.bak 's/^50\t/1\t/' "$duplicate_suspend/suspend-resume.tsv"
rm -f "$duplicate_suspend/suspend-resume.tsv.bak"
duplicate_suspend_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m3-duplicate-suspend.XXXXXX")
rmdir "$duplicate_suspend_out"
expect_fail "$project_root/scripts/collect-m3-display-dcp.sh" --dry-run --input-dir "$duplicate_suspend" --out "$duplicate_suspend_out"
reject_mutation() {
    local name=$1 file=$2 expression=$3 candidate="$tmp/$1" candidate_out
    cp -R "$valid" "$candidate"
    sed -i.bak "$expression" "$candidate/$file"
    rm -f "$candidate/$file.bak"
    candidate_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m3-$name.XXXXXX")
    rmdir "$candidate_out"
    expect_fail "$project_root/scripts/collect-m3-display-dcp.sh" --dry-run --input-dir "$candidate" --out "$candidate_out"
}
reject_mutation invalid-width display-modes.tsv '2s/3024/wide/'
reject_mutation zero-height display-modes.tsv '2s/1964/0/'
reject_mutation zero-refresh display-modes.tsv '2s/120/0/'
reject_mutation over-brightness brightness.tsv '2s/50/101/'
reject_mutation invalid-resume suspend-resume.tsv '2s/10/not-a-time/'
duplicate_mode="$tmp/duplicate-mode"
cp -R "$valid" "$duplicate_mode"
duplicate_mode_row=$(tail -n 1 "$duplicate_mode/display-modes.tsv")
printf '%s\n' "$duplicate_mode_row" >> "$duplicate_mode/display-modes.tsv"
duplicate_mode_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m3-duplicate-mode.XXXXXX")
rmdir "$duplicate_mode_out"
expect_fail "$project_root/scripts/collect-m3-display-dcp.sh" --dry-run --input-dir "$duplicate_mode" --out "$duplicate_mode_out"
printf 'pass\n' >> "$valid/brightness.tsv"
pass_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m3-pass.XXXXXX"); rmdir "$pass_out"
expect_fail "$project_root/scripts/collect-m3-display-dcp.sh" --dry-run --input-dir "$valid" --out "$pass_out"
printf 'M3-tests=passed\n'
