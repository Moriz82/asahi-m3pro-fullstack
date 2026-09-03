#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
source "${project_root}/scripts/lib/atomic-symlink.sh"
readonly tmp="$(mktemp -d "${TMPDIR:-/tmp}/milestone0-output.XXXXXX")"
readonly tmp_real="$(cd "$tmp" && pwd -P)"
readonly validator_project="$tmp_real/project"
readonly test_parent="$validator_project/out/isolated"
readonly test_leaf="test-output-$$"
readonly allowed="$test_parent/$test_leaf"
mkdir -p "$validator_project/out"
parent_created=0
cleanup() {
    test -f "${allowed:-}/sentinel" && rm -f "$allowed/sentinel"
    test -f "$allowed/.asahi-m3pro-milestone0-output-root" && rm -f "$allowed/.asahi-m3pro-milestone0-output-root"
    test -d "$allowed" && rmdir "$allowed" || true
    test -d "${empty_leaf:-}" && rmdir "$empty_leaf" || true
    test -f "${foreign:-}/sentinel" && rm -f "$foreign/sentinel"
    test -d "${foreign:-}" && rmdir "$foreign" || true
    test -L "${symlink:-}" && rm -f "$symlink"
    test -f "${race_leaf:-}/.asahi-m3pro-milestone0-output-root" && rm -f "$race_leaf/.asahi-m3pro-milestone0-output-root"
    test -d "${race_leaf:-}" && rmdir "$race_leaf" || true
    (( parent_created == 0 )) || rmdir "$test_parent" || true
    rm -rf "$tmp"
}
trap cleanup EXIT

if [[ ! -e "$test_parent" ]]; then
    mkdir "$test_parent"
    parent_created=1
fi

readonly m0_scripts=(
    assemble-boot-payload.sh build-linux-dtb.sh build-linux-full.sh build-m1n1.sh
    build-milestone0.sh build-u-boot.sh package-linux-asahi.sh rebuild-milestone0.sh
    verify-boot-payload.sh verify-linux-dtb.sh verify-linux-full.sh
    verify-linux-package.sh verify-m1n1.sh verify-milestone0.sh
)
for script in "${m0_scripts[@]}"; do
    grep -Fq 'scripts/lib/milestone0-output-root.sh' "${project_root}/scripts/$script"
    grep -Fq 'm0_validate_output_root "$project_root"' "${project_root}/scripts/$script"
done

unset MILESTONE0_OUTPUT_ROOT
m0_validate_output_root "$validator_project"
test "$MILESTONE0_OUTPUT_ROOT" = "$validator_project/out"

MILESTONE0_OUTPUT_ROOT="$allowed" m0_validate_output_root "$validator_project"
test -f "$allowed/.asahi-m3pro-milestone0-output-root"
printf 'sentinel\n' >"$allowed/sentinel"
MILESTONE0_OUTPUT_ROOT="$allowed" m0_validate_output_root "$validator_project"
test "$(cat "$allowed/sentinel")" = sentinel

reject_without_mutation() {
    local candidate="$1"
    if MILESTONE0_OUTPUT_ROOT="$candidate" m0_validate_output_root "$validator_project" >/dev/null 2>&1; then
        printf 'Unexpectedly accepted unsafe output root: %s\n' "$candidate" >&2
        exit 1
    fi
}
reject_without_mutation relative
reject_without_mutation /
reject_without_mutation "$HOME"
reject_without_mutation "$validator_project"
reject_without_mutation "$validator_project/out/not-isolated-$$"
reject_without_mutation "$test_parent/nested/leaf"
reject_without_mutation "$tmp_real"
test ! -e "$test_parent/nested"

empty_leaf="$test_parent/empty-$$"
mkdir "$empty_leaf"
reject_without_mutation "$empty_leaf"
test -d "$empty_leaf" && test ! -e "$empty_leaf/.asahi-m3pro-milestone0-output-root"
rmdir "$empty_leaf"

foreign="$test_parent/foreign-$$"
mkdir "$foreign"
printf 'do-not-remove\n' >"$foreign/sentinel"
reject_without_mutation "$foreign"
test -f "$foreign/sentinel" && test ! -e "$foreign/.asahi-m3pro-milestone0-output-root"

external="$tmp_real/external"
mkdir "$external"
printf 'do-not-remove\n' >"$external/sentinel"
printf 'format=1 project_root=%s owner_uid=%s\n' "$project_root" "$(id -u)" >"$external/.asahi-m3pro-milestone0-output-root"
reject_without_mutation "$external"
test -f "$external/sentinel" && test -f "$external/.asahi-m3pro-milestone0-output-root"

outside="$tmp_real/outside"
mkdir "$outside"
symlink="$test_parent/symlink-$$"
ln -s "$outside" "$symlink"
reject_without_mutation "$symlink"
test ! -e "$outside/child"
if MILESTONE0_OUTPUT_ROOT="$foreign" "${project_root}/scripts/build-milestone0.sh" >/dev/null 2>&1; then
    printf 'Build accepted a foreign output root before Docker gate.\n' >&2
    exit 1
fi
test -f "$foreign/sentinel" && test ! -e "$foreign/.asahi-m3pro-milestone0-output-root"

# Rebuild must choose the validator's dedicated isolated leaf before Docker.
grep -Fq 'rebuild_root="${project_root}/out/isolated/rebuild-${run_id}"' \
    "${project_root}/scripts/rebuild-milestone0.sh"
! grep -Fq 'milestone0-rebuild/${run_id}' "${project_root}/scripts/rebuild-milestone0.sh"
if MILESTONE0_OUTPUT_ROOT="$project_root/out/rebuild-invalid-$$" \
    "${project_root}/scripts/rebuild-milestone0.sh" >/dev/null 2>&1; then
    printf 'Rebuild accepted an output root outside the isolated allowlist.\n' >&2
    exit 1
fi
test ! -e "$project_root/out/rebuild-invalid-$$"

# Publishers must use unique IDs, atomic stage claims, and temp-link renames.
for publisher in build-m1n1.sh build-linux-dtb.sh build-u-boot.sh build-linux-full.sh; do
    grep -Fq 'od -An -N8 -tx1 /dev/urandom' "${project_root}/scripts/$publisher"
    grep -Fq 'mkdir "$stage"' "${project_root}/scripts/$publisher"
    grep -Fq 'Refusing colliding' "${project_root}/scripts/$publisher"
    grep -Fq 'latest_tmp' "${project_root}/scripts/$publisher"
    grep -Fq 'flock -n 9' "${project_root}/scripts/$publisher"
done
grep -Fq 'flock -n 9' "${project_root}/scripts/package-linux-asahi.sh"
grep -Fq 'od -An -N8 -tx1 /dev/urandom' \
    "${project_root}/scripts/assemble-boot-payload.sh"
grep -Fq 'mkdir "$stage"' "${project_root}/scripts/assemble-boot-payload.sh"
grep -Fq 'Refusing colliding' "${project_root}/scripts/assemble-boot-payload.sh"

link_test="$tmp/latest"
mkdir "$tmp/first" "$tmp/second"
atomic_symlink_replace first "$link_test" "$tmp/.latest.first.tmp"
test "$(readlink "$link_test")" = first
atomic_symlink_replace second "$link_test" "$tmp/.latest.second.tmp"
test "$(readlink "$link_test")" = second
test ! -e "$tmp/first/.latest.second.tmp"

race_leaf="$test_parent/race-$$"
race_one="$tmp/race-one"
race_two="$tmp/race-two"
(
    if MILESTONE0_OUTPUT_ROOT="$race_leaf" m0_validate_output_root "$validator_project" >/dev/null 2>&1; then race_status=0; else race_status=$?; fi
    printf '%s\n' "$race_status" >"$race_one"
) &
(
    if MILESTONE0_OUTPUT_ROOT="$race_leaf" m0_validate_output_root "$validator_project" >/dev/null 2>&1; then race_status=0; else race_status=$?; fi
    printf '%s\n' "$race_status" >"$race_two"
) &
wait
test "$(sort "$race_one" "$race_two" | tr '\n' ' ')" = '0 1 '
test -f "$race_leaf/.asahi-m3pro-milestone0-output-root"
rm -f "$race_leaf/.asahi-m3pro-milestone0-output-root"
rmdir "$race_leaf"

printf 'output-root=verified:default-and-atomic-isolated-override\n'
printf 'output-root=verified:rejection-and-sentinel-preservation\n'
