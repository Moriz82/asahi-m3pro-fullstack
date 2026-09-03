#!/usr/bin/env bash

# Resolve and freeze the six canonical M0 component pointers.  Callers keep
# the returned pointer target and physical directory, then call the assertion
# after any operation that must be TOCTOU-safe.
m0_component_names=(m1n1 u-boot linux-dtb linux-full linux-packages boot-payload)

m0_component_index() {
    local wanted=$1 i
    for i in "${!m0_component_names[@]}"; do
        [[ ${m0_component_names[i]} == "$wanted" ]] && { printf '%s\n' "$i"; return 0; }
    done
    return 1
}

m0_component_snapshot() {
    local m0_root=$1 component=$2 pointer resolved component_root
    [[ -L "$m0_root/$component/latest" ]] || {
        printf 'Missing %s latest pointer.\n' "$component" >&2
        return 1
    }
    component_root=$(cd -P -- "$m0_root/$component" && pwd -P) || return 1
    pointer=$(readlink -- "$m0_root/$component/latest") || return 1
    resolved=$(cd -P -- "$m0_root/$component/latest" && pwd -P) || return 1
    [[ "$(dirname -- "$resolved")" == "$component_root" ]] || {
        printf 'Unsafe %s latest binding.\n' "$component" >&2
        return 1
    }
    printf '%s\t%s\n' "$pointer" "$resolved"
}

m0_component_assert_unchanged() {
    local m0_root=$1 component=$2 expected_pointer=$3 expected_resolved=$4 current_pointer current_resolved
    current_pointer=$(readlink -- "$m0_root/$component/latest") || return 1
    current_resolved=$(cd -P -- "$m0_root/$component/latest" && pwd -P) || return 1
    [[ "$current_pointer" == "$expected_pointer" && "$current_resolved" == "$expected_resolved" ]] || {
        printf '%s latest pointer changed during verification.\n' "$component" >&2
        return 1
    }
}
