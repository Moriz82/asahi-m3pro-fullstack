#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
shellcheck -s ash "$project_root/initramfs/development/init"
PYTHONDONTWRITEBYTECODE=1 python3 "$project_root/tests/development-self-test.py"
runtime_args=("$project_root/tests/development-init-self-test.py")
if [[ $(uname -s) == Linux && $(uname -m) == aarch64 ]]; then
    runtime_args+=(--busybox "$(command -v busybox)")
fi
PYTHONDONTWRITEBYTECODE=1 python3 "${runtime_args[@]}"
