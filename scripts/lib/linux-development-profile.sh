#!/usr/bin/env bash
# One explicit, pinned profile; not a general config-override mechanism.
readonly LINUX_DEVELOPMENT_FRAGMENT_SHA256=0642daa86c4c6fdffcfd354d692353d8facd11d1ce1d371d64a5a3cff1d12b3e

linux_development_framebuffer_init() {
    local project="$1"
    case "${MILESTONE0_OUTPUT_ROOT:-}" in
        "$project"/out/isolated/*) ;;
        *) printf 'Development kernels require an isolated MILESTONE0_OUTPUT_ROOT.\n' >&2; return 1 ;;
    esac
    export LINUX_COMPONENT=linux-development-framebuffer
    export LINUX_LOCALVERSION=.asahi1-m3devfb1
    linux_development_framebuffer_fragment "$project/config/linux-development-framebuffer.config"
}

linux_development_framebuffer_fragment() {
    local fragment="$1"
    test -f "$fragment" && test ! -L "$fragment" || return 1
    test "$(sha256sum "$fragment" | awk '{print $1}')" = "$LINUX_DEVELOPMENT_FRAGMENT_SHA256"
}

linux_development_framebuffer_config() {
    local config="$1" fragment="$2" setting
    linux_development_framebuffer_fragment "$fragment" || return 1
    while IFS= read -r setting; do
        case "$setting" in
            CONFIG_*=*) grep -Fx "$setting" "$config" || return 1 ;;
            '# CONFIG_'*' is not set')
                # Kconfig omits an invisible disabled symbol altogether.
                local symbol="${setting#\# }"
                symbol="${symbol% is not set}"
                if grep -q "^$symbol=" "$config"; then return 1; fi
                printf '%s\n' "$setting"
                ;;
        esac
    done < "$fragment"
    grep -Fx 'CONFIG_LOCALVERSION=".asahi1-m3devfb1"' "$config"
}
