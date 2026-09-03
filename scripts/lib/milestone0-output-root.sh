#!/usr/bin/env bash

# Validate the output root before any caller performs output-root mutations.
# Explicit overrides are intentionally confined to one project-owned leaf.
# Keep this Bash-3.2-compatible for the macOS host.
m0_validate_output_root() {
    local project_root_arg="$1"
    local project_real user_home requested default_root override_parent
    local marker marker_text owner_uid lexical_real explicit_override leaf
    local marker_tmp
    [[ -n "$project_root_arg" && -d "$project_root_arg" && ! -L "$project_root_arg" ]] || {
        printf 'Unsafe project root for output validation.\n' >&2
        return 1
    }
    project_real="$(cd "$project_root_arg" && pwd -P)"
    user_home="$(cd ~ && pwd -P)"
    default_root="$project_real/out"
    override_parent="$default_root/isolated"
    marker=".asahi-m3pro-milestone0-output-root"
    marker_text="format=1 project_root=${project_real} owner_uid=$(id -u)"
    explicit_override=0
    if [[ "${MILESTONE0_OUTPUT_ROOT+x}" = x ]]; then
        requested="$MILESTONE0_OUTPUT_ROOT"
        explicit_override=1
    else
        requested="$default_root"
    fi
    [[ -n "$requested" && "$requested" = /* ]] || {
        printf 'MILESTONE0_OUTPUT_ROOT must be an absolute path.\n' >&2
        return 1
    }
    [[ "$requested" != / && "$requested" != */ && "$requested" != *'//'* && "$requested" != *'/./'* && "$requested" != *'/../'* && "$requested" != *'/..' ]] || {
        printf 'MILESTONE0_OUTPUT_ROOT is not a normalized non-root path.\n' >&2
        return 1
    }
    [[ "$requested" != "$user_home" && "$requested" != "$project_real" ]] || {
        printf 'MILESTONE0_OUTPUT_ROOT names a protected broad root.\n' >&2
        return 1
    }

    lexical="${requested%/}"
    if [[ "$lexical" = "$default_root" ]]; then
        # The canonical project default is the only permitted broad root.
        [[ "$explicit_override" = 0 || "$requested" = "$default_root" ]] || return 1
        if [[ -e "$lexical" ]]; then
            [[ -d "$lexical" && ! -L "$lexical" ]] || return 1
            owner_uid="$(stat -c '%u' "$lexical" 2>/dev/null || stat -f '%u' "$lexical")"
            [[ "$owner_uid" = "$(id -u)" ]] || return 1
            lexical_real="$(cd "$lexical" && pwd -P)"
            [[ "$lexical_real" = "$lexical" ]] || return 1
        fi
        MILESTONE0_OUTPUT_ROOT="$lexical"
        export MILESTONE0_OUTPUT_ROOT
        return 0
    fi

    # Every explicit override must be exactly one safe leaf beneath the fixed,
    # canonical project-owned parent. No marker can authorize an external path.
    [[ -d "$default_root" && ! -L "$default_root" && -d "$override_parent" && ! -L "$override_parent" ]] || {
        printf 'The project-owned isolated output parent is unavailable.\n' >&2
        return 1
    }
    [[ "$(cd "$default_root" && pwd -P)" = "$default_root" && "$(cd "$override_parent" && pwd -P)" = "$override_parent" ]] || {
        printf 'The project-owned isolated output parent is not canonical.\n' >&2
        return 1
    }
    owner_uid="$(stat -c '%u' "$default_root" 2>/dev/null || stat -f '%u' "$default_root")"
    [[ "$owner_uid" = "$(id -u)" ]] || return 1
    owner_uid="$(stat -c '%u' "$override_parent" 2>/dev/null || stat -f '%u' "$override_parent")"
    [[ "$owner_uid" = "$(id -u)" ]] || return 1
    case "$lexical" in
        "$override_parent"/*) leaf="${lexical#"$override_parent"/}" ;;
        *) printf 'Explicit output root is outside the project-owned isolated parent.\n' >&2; return 1 ;;
    esac
    [[ "$leaf" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "$leaf" != . && "$leaf" != .. ]] || {
        printf 'Explicit output root must be one safe leaf component.\n' >&2
        return 1
    }
    [[ ! -L "$lexical" ]] || {
        printf 'Explicit output root may not be a symlink.\n' >&2
        return 1
    }
    if [[ ! -e "$lexical" ]]; then
        # mkdir without -p is the first, race-safe claim of the exact leaf.
        mkdir "$lexical" || {
            printf 'Output-root leaf appeared during atomic claim.\n' >&2
            return 1
        }
        marker_tmp="$lexical/.${marker}.tmp.$$"
        (set -C; printf '%s\n' "$marker_text" >"$marker_tmp") || {
            rmdir "$lexical" 2>/dev/null || true
            return 1
        }
        if ! ln "$marker_tmp" "$lexical/$marker" 2>/dev/null; then
            rm -f "$marker_tmp"
            rmdir "$lexical" 2>/dev/null || true
            return 1
        fi
        rm -f "$marker_tmp"
    else
        [[ -d "$lexical" && ! -L "$lexical" ]] || return 1
        # Existing empty unmarked directories are not claimable; only the exact
        # marker from this project/user permits reuse.
        [[ -f "$lexical/$marker" && ! -L "$lexical/$marker" ]] || return 1
        [[ "$(cat "$lexical/$marker")" = "$marker_text" ]] || return 1
    fi
    owner_uid="$(stat -c '%u' "$lexical" 2>/dev/null || stat -f '%u' "$lexical")"
    [[ "$owner_uid" = "$(id -u)" ]] || return 1
    lexical_real="$(cd "$lexical" && pwd -P)"
    [[ "$lexical_real" = "$lexical" ]] || return 1
    MILESTONE0_OUTPUT_ROOT="$lexical"
    export MILESTONE0_OUTPUT_ROOT
}
