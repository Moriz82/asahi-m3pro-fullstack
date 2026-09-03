#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly source_dir=$2
readonly evidence=$4
readonly verifier="$project_root/scripts/verify-m2-source-contract.sh"
readonly contract="$project_root/config/milestone2-source-files.sha256"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m2-source-contract.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }

"$verifier" --source-dir "$source_dir" --m0-evidence "$evidence" >/dev/null
fixture="$tmp/source"
mkdir "$fixture"
while read -r digest path extra; do
    [[ -n ${digest:-} && $digest != \#* ]] || continue
    [[ -z ${extra:-} ]]
    mkdir -p "$fixture/$(dirname -- "$path")"
    cp -p -- "$source_dir/$path" "$fixture/$path"
done < "$contract"
"$verifier" --source-dir "$fixture" --m0-evidence "$evidence" >/dev/null

printf '\n' >> "$fixture/arch/arm64/boot/dts/apple/t6030.dtsi"
expect_fail "$verifier" --source-dir "$fixture" --m0-evidence "$evidence"
ln -s "$source_dir" "$tmp/source-link"
expect_fail "$verifier" --source-dir "$tmp/source-link" --m0-evidence "$evidence"
expect_fail "$verifier" --source-dir "$source_dir" --m0-evidence "$source_dir"
printf 'M2-source-contract-tests=passed\n'
