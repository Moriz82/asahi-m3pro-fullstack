#!/usr/bin/env bash
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PYTHONDONTWRITEBYTECODE=1 python3 "$project_root/tests/usb-debug-self-test.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$project_root/tests/development-console-self-test.py"
