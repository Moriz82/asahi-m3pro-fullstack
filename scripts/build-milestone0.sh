#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${project_root}/config/milestone0.env"
source "${project_root}/scripts/lib/milestone0-output-root.sh"
m0_validate_output_root "$project_root"
readonly output_root="$MILESTONE0_OUTPUT_ROOT"
"${project_root}/scripts/build-m1n1.sh"
"${project_root}/scripts/build-u-boot.sh"
"${project_root}/scripts/build-linux-dtb.sh"
CLEAN_BUILD=1 "${project_root}/scripts/build-linux-full.sh"
"${project_root}/scripts/package-linux-asahi.sh"
"${project_root}/scripts/assemble-boot-payload.sh"
"${project_root}/scripts/verify-milestone0.sh"
printf 'milestone0.baseline=%s\n' "$output_root/milestone0"
