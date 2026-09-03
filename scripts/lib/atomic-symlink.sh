#!/usr/bin/env bash

atomic_symlink_replace() {
    local target="$1" link="$2" temporary="$3"
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || return 1
    ln -s "$target" "$temporary"
    if mv -fh "$temporary" "$link" 2>/dev/null; then
        return 0
    fi
    mv -Tf "$temporary" "$link"
}
