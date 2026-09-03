#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
source "${project_root}/scripts/lib/milestone0-components.sh"
source "${project_root}/scripts/lib/evidence.sh"
m0_validate_output_root "$project_root"
readonly output_root="$MILESTONE0_OUTPUT_ROOT"
root="${output_root}/milestone0"; component_map=''
if (($#)); then root=$1; shift; fi
if (($#)); then
    [[ $# -eq 2 && $1 == --component-map ]] || { printf 'usage: %s [ROOT] [--component-map FILE]\n' "$0" >&2; exit 64; }
    component_map=$2
fi
readonly root component_map
if [[ -n $component_map ]]; then
    evidence_map_header='component	run_id	snapshot_path	manifest_sha256'
    evidence_path_under "$component_map" "$root"
    [[ -f "$component_map" && ! -L "$component_map" ]] || { printf 'Missing M0 component map.\n' >&2; exit 1; }
    [[ "$(head -n 1 "$component_map")" == "$evidence_map_header" ]] || { printf 'Invalid M0 component map header.\n' >&2; exit 1; }
    declare -a mapped_run_id mapped_path mapped_hash mapped_seen
    while IFS=$'\t' read -r map_component map_run_id map_path map_hash map_extra; do
        [[ -z ${map_extra:-} && $map_component != *'|'* && $map_run_id =~ ^[A-Za-z0-9._-]+$ &&
            $map_path == "$map_component/"* && $map_path != *'/'../* && $map_path != ../* &&
            $map_path != *$'\n'* && $map_hash =~ ^[[:xdigit:]]{64}$ ]] || exit 1
        map_index=$(m0_component_index "$map_component") || exit 1
        [[ -z ${mapped_seen[map_index]:-} ]] || exit 1
        mapped_run_id[map_index]=$map_run_id; mapped_path[map_index]=$map_path
        mapped_hash[map_index]=$map_hash; mapped_seen[map_index]=true
    done < <(tail -n +2 "$component_map")
    for index in "${!m0_component_names[@]}"; do
        [[ ${mapped_seen[index]:-} == true ]] || { printf 'M0 component missing from map.\n' >&2; exit 1; }
        mapped_snapshot="$root/${mapped_path[index]}"
        [[ "$(basename -- "$mapped_snapshot")" == "${mapped_run_id[index]}" &&
            -d "$mapped_snapshot" && ! -L "$mapped_snapshot" ]] || exit 1
        [[ "$(evidence_sha256 "$mapped_snapshot/manifest.txt")" == "${mapped_hash[index]}" ]] || exit 1
    done
fi
declare -a frozen_pointer frozen_path
for index in "${!m0_component_names[@]}"; do
    component=${m0_component_names[index]}
    if [[ -n $component_map ]]; then
        frozen_pointer[index]=''
        frozen_path[index]="$root/${mapped_path[index]}"
    elif [[ -L "$root/$component/latest" ]]; then
        snapshot=$(m0_component_snapshot "$root" "$component") || exit 1
        frozen_pointer[index]=${snapshot%%$'\t'*}
        frozen_path[index]=${snapshot#*$'\t'}
    else
        [[ -d "$root/$component/latest" && ! -L "$root/$component/latest" ]] || {
            printf 'Missing %s latest snapshot.\n' "$component" >&2
            exit 1
        }
        frozen_pointer[index]=''
        frozen_path[index]="$(cd -P -- "$root/$component/latest" && pwd -P)" || exit 1
        [[ "$(dirname -- "${frozen_path[index]}")" == "$(cd -P -- "$root/$component" && pwd -P)" ]] || exit 1
    fi
done
m1n1=${frozen_path[0]}
uboot=${frozen_path[1]}
linux_dtb=${frozen_path[2]}
linux_full=${frozen_path[3]}
linux_packages=${frozen_path[4]}
boot_payload=${frozen_path[5]}
readonly m1n1 uboot linux_dtb linux_full linux_packages boot_payload
"${project_root}/scripts/verify-m1n1.sh" "$m1n1"
"${project_root}/scripts/verify-u-boot.sh" "$uboot"
"${project_root}/scripts/verify-linux-dtb.sh" "$linux_dtb"
"${project_root}/scripts/verify-linux-full.sh" "$linux_full"
if [[ -n $component_map ]]; then
    "${project_root}/scripts/verify-linux-package.sh" "$linux_packages" "$linux_full" --handoff-snapshot
else
    "${project_root}/scripts/verify-linux-package.sh" "$linux_packages" "$linux_full"
fi
"${project_root}/scripts/verify-boot-payload.sh" "$boot_payload" \
    --m1n1-source "$m1n1" --linux-dtb-source "$linux_dtb" --u-boot-source "$uboot"
cmp "$linux_dtb/t6030-j514s.dtb" "$linux_full/dtbs/apple/t6030-j514s.dtb"
grep -Fx 'status=build-verified-not-hardware-booted' "$boot_payload/manifest.txt" >/dev/null
for index in "${!m0_component_names[@]}"; do
    if [[ -n ${frozen_pointer[index]} ]]; then
        m0_component_assert_unchanged "$root" "${m0_component_names[index]}" \
            "${frozen_pointer[index]}" "${frozen_path[index]}"
    fi
done
printf 'milestone0.baseline=verified\n'
