#!/usr/bin/env bash

m0_package_to_evidence_module_path() {
    local package_path="$1" component
    [[ "$package_path" == usr/lib/modules/* ]] || return 1
    [[ "$package_path" != *//* ]] || return 1
    IFS=/ read -r -a components <<<"$package_path"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
    done
    printf 'lib/modules/%s\n' "${package_path#usr/lib/modules/}"
}

m0_evidence_to_package_module_path() {
    local evidence_path="$1" component
    [[ "$evidence_path" == lib/modules/* ]] || return 1
    [[ "$evidence_path" != *//* ]] || return 1
    IFS=/ read -r -a components <<<"$evidence_path"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
    done
    printf 'usr/%s\n' "$evidence_path"
}
