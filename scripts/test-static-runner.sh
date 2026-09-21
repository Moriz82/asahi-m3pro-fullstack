#!/usr/bin/env bash
# Test the real aggregate's discovery with a miniature, non-hardware project.
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/static-runner.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/project"
mkdir -p "$fixture/scripts" "$fixture/tests" "$fixture/config" "$fixture/initramfs/milestone1" "$tmp/tools"
cp "$project_root/scripts/verify-all-software-tooling.sh" "$fixture/scripts/verify-all-software-tooling.sh"
cp "$project_root/config/milestone-contracts.tsv" "$fixture/config/milestone-contracts.tsv"
printf '#!/bin/sh\nexit 0\n' >"$tmp/tools/shellcheck"
chmod +x "$tmp/tools/shellcheck"
printf '#!/bin/bash\n:\n' >"$fixture/scripts/a-valid.sh"
printf '#!/bin/bash\n:\n' >"$fixture/config/test.env"
printf '#!/bin/sh\n:\n' >"$fixture/initramfs/milestone1/init"
printf '#!/bin/bash\n:\n' >"$fixture/scripts/test-sentinel.sh"
printf '#!/bin/bash\n:\n' >"$fixture/tests/m8-signed-fixture-self-test.sh"
cat >"$fixture/scripts/check-milestone-gate.sh" <<'SH'
#!/usr/bin/env bash
set -eu
milestone=$2
number=${milestone#M}
if [[ $number == 0 ]]; then predecessor=none; else predecessor=M$((number - 1)); fi
printf 'milestone=%s\nexpected-predecessor=%s\n' "$milestone" "$predecessor"
printf 'tooling_valid=not-run\nevidence_valid=not-provided\nhardware_acceptance=false\ngate=blocked-for-native-execution\n'
exit 2
SH
chmod +x "$fixture/scripts/"*.sh "$fixture/tests/"*.sh
run_fixture() {
    PATH="$tmp/tools:$PATH" TEST_OUTPUT_ROOT="$tmp/results" \
        bash "$fixture/scripts/verify-all-software-tooling.sh" --static >"$tmp/runner.log" 2>&1
}
run_fixture
grep -Fx aggregate_tooling_valid=true "$tmp/runner.log" >/dev/null
grep -Fx m2_driver_source_suite=not-run_requires_clean_pinned_Linux_and_AArch64_builder "$tmp/runner.log" >/dev/null
for path in scripts/z-broken.sh tests/z-broken.sh config/broken.env initramfs/milestone1/init; do
    printf '#!/bin/sh\nif\n' >"$fixture/$path"
    if run_fixture; then printf 'syntax error escaped discovery: %s\n' "$path" >&2; exit 1; fi
    grep -qi 'syntax error' "$tmp/runner.log"
    ! grep -q '^PASS ' "$tmp/runner.log"
    if [[ $path == initramfs/milestone1/init ]]; then
        printf '#!/bin/sh\n:\n' >"$fixture/$path"
    else
        rm "$fixture/$path"
    fi
done
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "M5" {$2="M0"} {print}' \
    "$fixture/config/milestone-contracts.tsv" >"$tmp/bad-contract"
mv "$tmp/bad-contract" "$fixture/config/milestone-contracts.tsv"
if run_fixture; then printf 'broken predecessor chain accepted\n' >&2; exit 1; fi
grep -Fx 'invalid milestone contract' "$tmp/runner.log" >/dev/null
printf 'static runner discovery self-tests passed\n'
