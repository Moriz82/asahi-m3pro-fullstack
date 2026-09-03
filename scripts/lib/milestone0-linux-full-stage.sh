#!/usr/bin/env bash

# Remove only modules_install's non-runtime links, then reject every remaining
# symlink or special member before a privileged container writes stage files.
m0_make_linux_full_stage_portable() {
    local stage_root=$1 stage_kernel_release=$2 module_link unsafe expected_build expected_source
    [[ -d "$stage_root" && ! -L "$stage_root" ]] || return 1
    [[ "$stage_kernel_release" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1

    expected_build="$stage_root/modules/lib/modules/$stage_kernel_release/build"
    expected_source="$stage_root/modules/lib/modules/$stage_kernel_release/source"
    while IFS= read -r -d '' unsafe; do
        [[ "$unsafe" == "$expected_build" || "$unsafe" == "$expected_source" ]] || {
            printf 'Refusing symlink in Linux-full stage: %s\n' "$unsafe" >&2
            return 1
        }
    done < <(find -P "$stage_root" -type l -print0)
    unsafe="$(find -P "$stage_root" ! -type f ! -type d ! -type l -print -quit)"
    [[ -z "$unsafe" ]] || {
        printf 'Refusing special member in Linux-full stage: %s\n' "$unsafe" >&2
        return 1
    }

    for module_link in "$expected_build" "$expected_source"; do
        if [[ -L "$module_link" ]]; then
            rm -f -- "$module_link"
        elif [[ -e "$module_link" ]]; then
            printf 'Refusing non-symlink module build reference: %s\n' "$module_link" >&2
            return 1
        fi
    done

    unsafe="$(find -P "$stage_root" -type l -print -quit)"
    [[ -z "$unsafe" ]] || {
        printf 'Refusing symlink in Linux-full stage: %s\n' "$unsafe" >&2
        return 1
    }
}
