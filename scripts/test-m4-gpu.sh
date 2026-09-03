#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/config/milestones.env"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m4-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
MILESTONE_EVIDENCE_ROOT="$tmp/evidence"
export MILESTONE_EVIDENCE_ROOT
mkdir -m 700 "$MILESTONE_EVIDENCE_ROOT"
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
make_input() {
    local dir=$1 renderer=$2 seconds=$3
    mkdir "$dir"
    printf 'model=Mac15,6\nboard=J514s\nsoc=T6030\n' > "$dir/identity.txt"
    cp "$project_root/tests/fixtures/kernel/clean.log" "$dir/kernel.log"
    printf 'renderer=%s\n' "$renderer" > "$dir/renderer.txt"
    printf 'api\tstatus\tnote\nOpenGL\tplanned\tawaits human conformance\nVulkan\tplanned\tawaits human conformance\n' > "$dir/conformance.tsv"
    printf 'duration_seconds\tstatus\n%s\tobserved\n' "$seconds" > "$dir/stress.tsv"
    printf 'reset=planned\nrecovery=planned\n' > "$dir/reset-recovery.txt"
}
valid="$tmp/valid"; make_input "$valid" 'Apple AGX (software-plan-only)' 86400
out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m4-test.XXXXXX"); rmdir "$out"
"$project_root/scripts/collect-m4-gpu.sh" --dry-run --input-dir "$valid" --out "$out"
"$project_root/scripts/verify-m4-gpu.sh" --bundle "$out"
software="$tmp/software"; make_input "$software" llvmpipe 86400
software_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m4-software.XXXXXX"); rmdir "$software_out"
expect_fail "$project_root/scripts/collect-m4-gpu.sh" --dry-run --input-dir "$software" --out "$software_out"
short="$tmp/short"; make_input "$short" 'Apple AGX' 86399
short_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m4-short.XXXXXX"); rmdir "$short_out"
expect_fail "$project_root/scripts/collect-m4-gpu.sh" --dry-run --input-dir "$short" --out "$short_out"
reject_mutation() {
    local name=$1 file=$2 expression=$3 candidate="$tmp/$1" candidate_out
    cp -R "$valid" "$candidate"
    sed -i.bak "$expression" "$candidate/$file"
    rm -f "$candidate/$file.bak"
    candidate_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m4-$name.XXXXXX")
    rmdir "$candidate_out"
    expect_fail "$project_root/scripts/collect-m4-gpu.sh" --dry-run --input-dir "$candidate" --out "$candidate_out"
}
reject_mutation unstructured-renderer renderer.txt 's/^renderer=/note=/'
reject_mutation conformance-claim conformance.tsv '2s/planned/passed/'
reject_mutation reset-claim reset-recovery.txt 's/reset=planned/reset=success/'
duplicate_renderer="$tmp/duplicate-renderer"
cp -R "$valid" "$duplicate_renderer"
printf 'renderer=Apple AGX\n' >> "$duplicate_renderer/renderer.txt"
duplicate_renderer_out=$(mktemp -d "$MILESTONE_EVIDENCE_ROOT/m4-duplicate-renderer.XXXXXX")
rmdir "$duplicate_renderer_out"
expect_fail "$project_root/scripts/collect-m4-gpu.sh" --dry-run --input-dir "$duplicate_renderer" --out "$duplicate_renderer_out"
printf 'M4-tests=passed\n'
