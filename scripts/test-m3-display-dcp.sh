#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m3-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
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
printf 'pass\n' >> "$valid/brightness.tsv"
pass_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m3-pass.XXXXXX"); rmdir "$pass_out"
expect_fail "$project_root/scripts/collect-m3-display-dcp.sh" --dry-run --input-dir "$valid" --out "$pass_out"
printf 'M3-tests=passed\n'
