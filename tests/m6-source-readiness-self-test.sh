#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_root/config/milestone0.env"
[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly checker="$project_root/scripts/check-m6-source-readiness.sh"
readonly source_dir=$2 evidence=$4
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m6-source-readiness.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

set +e
output=$("$checker" --source-dir "$source_dir" --m0-evidence "$evidence")
result=$?
set -e
[[ $result -eq 2 ]]
for line in \
    'M6-source-readiness=checked-static-only' \
    'generic_apple_isp_driver_built=true' \
    'generic_apple_avd_driver_built=true' \
    'generic_apple_audio_stack_built=true' \
    'target_isp_device_match=true' \
    'target_camera_topology=true' \
    'target_avd_fallback_t8122=true' \
    'target_h264_decode_source=true' \
    'target_hevc_decode_source=true' \
    'target_vp9_decode_source=true' \
    'target_av1_decode_source=true' \
    'target_video_encode_source=false' \
    'target_prores_source=false' \
    'target_microphone_topology=true' \
    'target_headphone_topology=true' \
    'target_speaker_topology=true' \
    'generic_speaker_kernel_guard=true' \
    'j514_speaker_calibration_allowlisted=true' \
    'j514_speaker_dsp_graph_allowlisted=true' \
    'speakersafetyd_runtime_evidence=false' \
    'native_runtime_evidence=false' \
    'hardware_acceptance=false' \
    'm6_source_ready=false' \
    'gate=blocked-video-encode-prores-and-speaker-runtime'; do
    printf '%s\n' "$output" | grep -Fx "$line" >/dev/null
done

fixture="$tmp/source"
mkdir "$fixture"
for contract in milestone2-source-files.sha256 milestone6-source-files.sha256; do
    while read -r digest path extra; do
        [[ -n ${digest:-} && $digest != \#* ]] || continue
        [[ -z ${extra:-} ]]
        mkdir -p "$fixture/$(dirname -- "$path")"
        [[ -f $fixture/$path ]] || cp -p -- "$source_dir/$path" "$fixture/$path"
    done < "$project_root/config/$contract"
done
if "$checker" --source-dir "$fixture" --m0-evidence "$evidence" >/dev/null 2>&1; then
    printf 'non-Git partial source bypassed the pinned M6 gate\n' >&2
    exit 1
fi
printf '\n/* forged Apple encoder */\n' >> "$fixture/drivers/media/platform/apple/avd/avd-drv.c"
if "$checker" --source-dir "$fixture" --m0-evidence "$evidence" >/dev/null 2>&1; then
    printf 'tampered source bypassed the pinned M6 gate\n' >&2
    exit 1
fi

git_fixture="$tmp/git-source"
git clone --no-checkout --shared "$source_dir" "$git_fixture" >/dev/null 2>&1
git -C "$git_fixture" sparse-checkout init --no-cone
{
    printf '/Makefile\n'
    for contract in milestone2-source-files.sha256 milestone6-source-files.sha256; do
        awk '$1 !~ /^#/ && NF == 2 { print "/" $2 }' "$project_root/config/$contract"
    done
} | LC_ALL=C sort -u > "$git_fixture/.git/info/sparse-checkout"
git -C "$git_fixture" checkout --detach "$LINUX_SOURCE_TREE_COMMIT" >/dev/null 2>&1
set +e
sparse_output=$("$checker" --source-dir "$git_fixture" --m0-evidence "$evidence" 2>&1)
sparse_result=$?
set -e
[[ $sparse_result -eq 1 ]]
printf '%s\n' "$sparse_output" | grep -Fx 'M6 source worktree is sparse' >/dev/null
printf 'uncontracted dirty source\n' > "$git_fixture/uncontracted-dirty"
set +e
dirty_output=$("$checker" --source-dir "$git_fixture" --m0-evidence "$evidence" 2>&1)
dirty_result=$?
set -e
[[ $dirty_result -eq 1 ]]
printf '%s\n' "$dirty_output" | grep -Fx 'M6 source tree is not clean' >/dev/null

evidence_fixture="$tmp/evidence"
mkdir -p "$evidence_fixture"
for file in manifest.txt config config-input config-merged.sha256 source-status.txt modules.inventory; do
    cp -p -- "$evidence/$file" "$evidence_fixture/$file"
done
required_modules=(
    drivers/dma/apple-admac.ko
    drivers/media/platform/apple/avd/apple-avd.ko
    drivers/media/platform/apple/isp/apple-isp.ko
    sound/soc/apple/snd-soc-aop.ko
    sound/soc/apple/snd-soc-apple-mca.ko
    sound/soc/apple/snd-soc-macaudio.ko
    sound/soc/codecs/snd-soc-cs42l84.ko
    sound/soc/codecs/snd-soc-tas2764.ko
)
for relative in "${required_modules[@]}"; do
    suffix="/kernel/$relative"
    inventory_path=$(awk -v suffix="$suffix" '
        substr($0, length($0) - length(suffix) + 1) == suffix { path=$0; count++ }
        END { if (count != 1) exit 1; print path }
    ' "$evidence/modules.inventory")
    mkdir -p "$evidence_fixture/modules/$(dirname -- "$inventory_path")"
    cp -p -- "$evidence/modules/$inventory_path" "$evidence_fixture/modules/$inventory_path"
done
(
    cd "$evidence_fixture"
    find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
) > "$evidence_fixture/SHA256SUMS"
set +e
fixture_output=$("$checker" --source-dir "$source_dir" --m0-evidence "$evidence_fixture")
fixture_result=$?
set -e
[[ $fixture_result -eq 2 ]]
printf '%s\n' "$fixture_output" | grep -Fx 'generic_apple_avd_driver_built=true' >/dev/null
avd_module=$(awk '/\/kernel\/drivers\/media\/platform\/apple\/avd\/apple-avd[.]ko$/ { print; found++ } END { if (found != 1) exit 1 }' \
    "$evidence_fixture/modules.inventory")
rm -- "$evidence_fixture/modules/$avd_module"
if "$checker" --source-dir "$source_dir" --m0-evidence "$evidence_fixture" >/dev/null 2>&1; then
    printf 'missing M6 module artifact bypassed the built-module gate\n' >&2
    exit 1
fi
cp -p -- "$evidence/modules/$avd_module" "$evidence_fixture/modules/$avd_module"
avd_parent=$(dirname -- "$avd_module")
external_avd_parent="$tmp/external-avd-parent"
mv -- "$evidence_fixture/modules/$avd_parent" "$external_avd_parent"
ln -s -- "$external_avd_parent" "$evidence_fixture/modules/$avd_parent"
if "$checker" --source-dir "$source_dir" --m0-evidence "$evidence_fixture" >/dev/null 2>&1; then
    printf 'symlinked M6 module ancestor bypassed the evidence-root gate\n' >&2
    exit 1
fi
printf 'M6-source-readiness-tests=passed\n'
