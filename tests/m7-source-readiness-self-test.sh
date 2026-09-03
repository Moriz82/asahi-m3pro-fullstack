#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_root/config/milestone0.env"
[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly checker="$project_root/scripts/check-m7-source-readiness.sh"
readonly source_dir=$2 evidence=$4
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m7-source-readiness.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

set +e
output=$("$checker" --source-dir "$source_dir" --m0-evidence "$evidence")
result=$?
set -e
[[ $result -eq 2 ]]
for line in \
    'M7-source-readiness=checked-static-only' \
    'generic_sep_stub_driver_built=true' \
    'target_sep_topology=false' \
    'sep_service_api=false' \
    'target_touchid_biometric_service=false' \
    'sep_backed_key_storage=false' \
    'target_ane_topology=false' \
    'target_ane_driver=false' \
    'target_pmu_compatible=false' \
    'generic_kvm_configured=true' \
    'target_virtual_timer_topology=true' \
    'target_dart_fallback_topology=true' \
    'kernel_lockdown_lsm=false' \
    'integrity_signatures=false' \
    'native_kvm_evidence=false' \
    'native_runtime_evidence=false' \
    'hardware_acceptance=false' \
    'm7_source_ready=false' \
    'gate=blocked-target-sep-touchid-ane-pmu-and-lockdown'; do
    printf '%s\n' "$output" | grep -Fx "$line" >/dev/null
done

fixture="$tmp/source"
mkdir "$fixture"
for contract in milestone2-source-files.sha256 milestone7-source-files.sha256; do
    while read -r digest source_path extra; do
        [[ -n ${digest:-} && $digest != \#* ]] || continue
        [[ -z ${extra:-} ]]
        mkdir -p "$fixture/$(dirname -- "$source_path")"
        [[ -f $fixture/$source_path ]] || cp -p -- "$source_dir/$source_path" "$fixture/$source_path"
    done < "$project_root/config/$contract"
done
if "$checker" --source-dir "$fixture" --m0-evidence "$evidence" >/dev/null 2>&1; then
    printf 'non-Git partial source bypassed the pinned M7 gate\n' >&2
    exit 1
fi
printf '\n/* forged SEP service */\n' >> "$fixture/drivers/soc/apple/sep.rs"
if "$checker" --source-dir "$fixture" --m0-evidence "$evidence" >/dev/null 2>&1; then
    printf 'tampered source bypassed the pinned M7 gate\n' >&2
    exit 1
fi

git_fixture="$tmp/git-source"
git clone --no-checkout --shared "$source_dir" "$git_fixture" >/dev/null 2>&1
git -C "$git_fixture" sparse-checkout init --no-cone
{
    printf '/Makefile\n'
    for contract in milestone2-source-files.sha256 milestone7-source-files.sha256; do
        awk '$1 !~ /^#/ && NF == 2 { print "/" $2 }' "$project_root/config/$contract"
    done
} | LC_ALL=C sort -u > "$git_fixture/.git/info/sparse-checkout"
git -C "$git_fixture" checkout --detach "$LINUX_SOURCE_TREE_COMMIT" >/dev/null 2>&1
set +e
sparse_output=$("$checker" --source-dir "$git_fixture" --m0-evidence "$evidence" 2>&1)
sparse_result=$?
set -e
[[ $sparse_result -eq 1 ]]
printf '%s\n' "$sparse_output" | grep -Fx 'M7 source worktree is sparse' >/dev/null
printf 'uncontracted dirty source\n' > "$git_fixture/uncontracted-dirty"
set +e
dirty_output=$("$checker" --source-dir "$git_fixture" --m0-evidence "$evidence" 2>&1)
dirty_result=$?
set -e
[[ $dirty_result -eq 1 ]]
printf '%s\n' "$dirty_output" | grep -Fx 'M7 source tree is not clean' >/dev/null

evidence_fixture="$tmp/evidence"
mkdir -p "$evidence_fixture"
for file in manifest.txt config config-input config-merged.sha256 source-status.txt modules.inventory; do
    cp -p -- "$evidence/$file" "$evidence_fixture/$file"
done
required_modules=(drivers/iommu/apple-dart.ko drivers/soc/apple/sep.ko)
for relative in "${required_modules[@]}"; do
    suffix="/kernel/$relative"
    inventory_path=$(awk -v suffix="$suffix" '
        substr($0, length($0) - length(suffix) + 1) == suffix { entry=$0; count++ }
        END { if (count != 1) exit 1; print entry }
    ' "$evidence/modules.inventory")
    mkdir -p "$evidence_fixture/modules/$(dirname -- "$inventory_path")"
    cp -p -- "$evidence/modules/$inventory_path" "$evidence_fixture/modules/$inventory_path"
done
(
    cd "$evidence_fixture"
    find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
) > "$evidence_fixture/SHA256SUMS"
set +e
fixture_output=$("$checker" --source-dir "$source_dir" --m0-evidence "$evidence_fixture")
fixture_result=$?
set -e
[[ $fixture_result -eq 2 ]]
printf '%s\n' "$fixture_output" | grep -Fx 'generic_sep_stub_driver_built=true' >/dev/null
sep_module=$(awk '/\/kernel\/drivers\/soc\/apple\/sep[.]ko$/ { print; found++ } END { if (found != 1) exit 1 }' \
    "$evidence_fixture/modules.inventory")
rm -- "$evidence_fixture/modules/$sep_module"
if "$checker" --source-dir "$source_dir" --m0-evidence "$evidence_fixture" >/dev/null 2>&1; then
    printf 'missing SEP module artifact bypassed the M7 gate\n' >&2
    exit 1
fi
cp -p -- "$evidence/modules/$sep_module" "$evidence_fixture/modules/$sep_module"
sep_parent=$(dirname -- "$sep_module")
external_sep_parent="$tmp/external-sep-parent"
mv -- "$evidence_fixture/modules/$sep_parent" "$external_sep_parent"
ln -s -- "$external_sep_parent" "$evidence_fixture/modules/$sep_parent"
if "$checker" --source-dir "$source_dir" --m0-evidence "$evidence_fixture" >/dev/null 2>&1; then
    printf 'symlinked SEP module ancestor bypassed the M7 evidence-root gate\n' >&2
    exit 1
fi
printf 'M7-source-readiness-tests=passed\n'
