#!/usr/bin/env bash

# Load the base U-Boot configuration and, when requested, one project-local
# candidate overlay. The overlay path is captured before the base config is
# sourced so the base cannot silently select a different file.
m0_load_u_boot_config() {
    local requested_overlay="${UBOOT_CONFIG_OVERLAY-}"
    local config_dir overlay_dir overlay_name resolved_overlay

    source "${project_root}/config/milestone0.env"
    [[ -n "$requested_overlay" ]] || return 0
    [[ "$requested_overlay" == /* ]] || {
        printf 'UBOOT_CONFIG_OVERLAY must be an absolute path.\n' >&2
        return 1
    }

    config_dir="$(cd -- "${project_root}/config" && pwd -P)"
    [[ -d "${project_root}/config" && ! -L "${project_root}/config" && "$config_dir" == "${project_root}/config" ]] || {
        printf 'Project config directory is not physically canonical.\n' >&2
        return 1
    }
    overlay_name="$(basename -- "$requested_overlay")"
    overlay_dir="$(cd -- "$(dirname -- "$requested_overlay")" 2>/dev/null && pwd -P)" || {
        printf 'UBOOT_CONFIG_OVERLAY parent is unavailable.\n' >&2
        return 1
    }
    resolved_overlay="${overlay_dir}/${overlay_name}"
    [[ "$resolved_overlay" == "$config_dir/"* ]] || {
        printf 'UBOOT_CONFIG_OVERLAY must be physically confined to config/.\n' >&2
        return 1
    }
    [[ -f "$resolved_overlay" && ! -L "$resolved_overlay" ]] || {
        printf 'UBOOT_CONFIG_OVERLAY must be a regular non-symlink file.\n' >&2
        return 1
    }
    source "$resolved_overlay"
}

u_boot_derive_patch_policy() {
    local patch_series="${UBOOT_PATCH_SERIES-}"
    local patch_sha256="${UBOOT_PATCH_SERIES_SHA256-}"

    if [[ -n "$patch_series" || -n "$patch_sha256" ]]; then
        [[ -n "$patch_series" && -n "$patch_sha256" ]] || {
            printf 'U-Boot patch series and checksum must be paired.\n' >&2
            return 1
        }
        [[ "$patch_series" =~ ^[A-Za-z0-9._-]+$ ]] || {
            printf 'U-Boot patch series path is unsafe.\n' >&2
            return 1
        }
        [[ "$patch_sha256" =~ ^[0-9a-f]{64}$ ]] || {
            printf 'U-Boot patch series checksum is invalid.\n' >&2
            return 1
        }
        UBOOT_PATCH_POLICY=legacy
    else
        [[ "${UBOOT_SOURCE_TREE_COMMIT-}" == "${UBOOT_COMMIT-}" ]] || {
            printf 'Upstream-integrated U-Boot source tree must equal source commit.\n' >&2
            return 1
        }
        UBOOT_PATCH_POLICY=upstream-integrated
    fi
}

u_boot_require_patch_file() {
    local project_root_arg=$1
    local patch_file="${project_root_arg}/patches/u-boot/${UBOOT_PATCH_SERIES}"

    [[ "$UBOOT_PATCH_POLICY" == legacy ]] || return 0
    [[ "$UBOOT_PATCH_SERIES" != */* ]] || return 1
    [[ -f "$patch_file" && ! -L "$patch_file" ]] || {
        printf 'U-Boot patch must be a regular non-symlink file.\n' >&2
        return 1
    }
    [[ "$(sha256sum "$patch_file" | awk '{print $1}')" == "$UBOOT_PATCH_SERIES_SHA256" ]] || {
        printf 'U-Boot patch checksum mismatch.\n' >&2
        return 1
    }
}

u_boot_require_candidate_isolation() {
    local project_root_arg=$1 output_root_arg=$2 source_volume_arg=$3

    [[ "$UBOOT_PATCH_POLICY" == upstream-integrated ]] || return 0
    [[ -n "${SOURCE_VOLUME_OVERRIDE-}" &&
        "$source_volume_arg" == "$SOURCE_VOLUME_OVERRIDE" &&
        "$source_volume_arg" != "$SOURCE_VOLUME" ]] || {
        printf 'Upstream-integrated U-Boot requires a distinct source-volume override.\n' >&2
        return 1
    }
    [[ "$output_root_arg" == "$project_root_arg/out/isolated/"* ]] || {
        printf 'Upstream-integrated U-Boot requires an isolated output root.\n' >&2
        return 1
    }
}
