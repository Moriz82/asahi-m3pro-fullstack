#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_root/config/milestone0.env"
source "$project_root/scripts/lib/evidence.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }

[[ $# -eq 4 && $1 == --source-dir && $3 == --m0-evidence ]] || {
    printf 'usage: %s --source-dir ABS --m0-evidence ABS\n' "$0" >&2
    exit 64
}
readonly source_arg=$2 evidence_arg=$4
[[ $source_arg == /* && -d $source_arg && ! -L $source_arg ]] || die 'invalid source directory'
[[ $evidence_arg == /* && -d $evidence_arg && ! -L $evidence_arg ]] || die 'invalid M0 evidence directory'
readonly source_dir="$(cd -- "$source_arg" && pwd -P)"
readonly evidence="$(cd -- "$evidence_arg" && pwd -P)"
[[ $source_dir == "$source_arg" ]] || die 'source directory must be canonical'
command -v git >/dev/null || die 'git is required'
[[ $(git -C "$source_dir" rev-parse --is-inside-work-tree 2>/dev/null) == true ]] ||
    die 'M6 source directory must be a Git worktree'
readonly source_root="$(git -C "$source_dir" rev-parse --show-toplevel)"
[[ $source_root == "$source_dir" ]] || die 'M6 source directory must be the worktree root'
readonly source_head="$(git -C "$source_dir" rev-parse HEAD)"
[[ $source_head == "$LINUX_SOURCE_TREE_COMMIT" ]] || die 'M6 source HEAD is not the pinned tree'
source_status=$(git -C "$source_dir" status --porcelain=v1 --untracked-files=all --ignored=matching) ||
    die 'cannot inspect M6 source status'
readonly source_status
[[ -z $source_status ]] || die 'M6 source tree is not clean'
sparse_entries=$(git -C "$source_dir" ls-files -t | awk '$1 == "S" { count++ } END { print count + 0 }') ||
    die 'cannot inspect M6 sparse-checkout state'
readonly sparse_entries
[[ $sparse_entries -eq 0 ]] || die 'M6 source worktree is sparse'

"$project_root/scripts/verify-m2-source-contract.sh" \
    --source-dir "$source_dir" --m0-evidence "$evidence" >/dev/null

readonly contract="$project_root/config/milestone6-source-files.sha256"
[[ -f $contract && ! -L $contract ]] || die 'invalid M6 source contract'
[[ $(grep -c '^# format=1$' "$contract") -eq 1 ]] || die 'invalid M6 source contract format'
[[ $(grep -c '^# target=Mac15,6/J514s/T6030$' "$contract") -eq 1 ]] || die 'invalid M6 source contract target'
[[ $(sed -n 's/^# source_tree_commit=//p' "$contract") == "$LINUX_SOURCE_TREE_COMMIT" ]] ||
    die 'M6 source contract is not bound to the pinned tree'

expected_files=(
    arch/arm64/boot/dts/apple/isp-common.dtsi
    arch/arm64/boot/dts/apple/isp-imx558-cfg0.dtsi
    arch/arm64/boot/dts/apple/t6030-j514s.dts
    arch/arm64/boot/dts/apple/t6030.dtsi
    arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi
    drivers/dma/apple-admac.c
    drivers/media/platform/apple/avd/Kconfig
    drivers/media/platform/apple/avd/Makefile
    drivers/media/platform/apple/avd/avd-drv.c
    drivers/media/platform/apple/avd/avd-v4l2.c
    drivers/media/platform/apple/isp/Kconfig
    drivers/media/platform/apple/isp/Makefile
    drivers/media/platform/apple/isp/isp-drv.c
    sound/soc/apple/Kconfig
    sound/soc/apple/Makefile
    sound/soc/apple/aop_audio.rs
    sound/soc/apple/macaudio.c
    sound/soc/apple/mca.c
    sound/soc/codecs/cs42l84.c
    sound/soc/codecs/tas2764.c
)
contract_files=()
while read -r digest path extra; do
    [[ -n ${digest:-} && $digest != \#* ]] || continue
    [[ $digest =~ ^[0-9a-f]{64}$ && -n ${path:-} && -z ${extra:-} ]] || die 'invalid M6 source hash row'
    [[ $path != /* && $path != *..* && $path =~ ^[A-Za-z0-9._/+:-]+$ ]] || die 'unsafe M6 source path'
    contract_files+=("$path")
    [[ -f $source_dir/$path && ! -L $source_dir/$path ]] || die "missing M6 source file: $path"
    [[ $(sha256sum "$source_dir/$path" | awk '{print $1}') == "$digest" ]] || die "M6 source hash mismatch: $path"
done < "$contract"
cmp <(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort) \
    <(printf '%s\n' "${contract_files[@]}" | LC_ALL=C sort) >/dev/null ||
    die 'M6 source contract inventory mismatch'

for setting in \
    CONFIG_MEDIA_SUPPORT=m CONFIG_VIDEO_DEV=m CONFIG_MEDIA_CONTROLLER=y \
    CONFIG_V4L2_H264=m CONFIG_V4L2_VP9=m CONFIG_V4L2_MEM2MEM_DEV=m \
    CONFIG_VIDEO_APPLE_ISP=m CONFIG_VIDEO_APPLE_AVD=m CONFIG_APPLE_ADMAC=m \
    CONFIG_SND_SOC_APPLE_AOP_AUDIO=m CONFIG_SND_SOC_APPLE_MCA=m \
    CONFIG_SND_SOC_APPLE_MACAUDIO=m CONFIG_SND_SOC_CS42L84=m CONFIG_SND_SOC_TAS2764=m; do
    grep -Fx "$setting" "$evidence/config" >/dev/null || die "M6 config setting missing: $setting"
done

evidence_abs_regular "$evidence/modules.inventory"
modules_hash=$(awk '$2 == "./modules.inventory" { print $1; found++ } END { if (found != 1) exit 1 }' \
    "$evidence/SHA256SUMS") || die 'M0 checksum missing or duplicated: modules.inventory'
readonly modules_hash
[[ $(evidence_sha256 "$evidence/modules.inventory") == "$modules_hash" ]] || die 'M0 modules inventory hash mismatch'
require_module() {
    local relative=$1 suffix="/kernel/$1" inventory_path module_path checksum_path module_hash
    inventory_path=$(awk -v suffix="$suffix" '
        substr($0, length($0) - length(suffix) + 1) == suffix { path=$0; count++ }
        END { if (count != 1) exit 1; print path }
    ' "$evidence/modules.inventory") || die "M6 module missing or duplicated: $relative"
    module_path="$evidence/modules/$inventory_path"
    evidence_path_under "$module_path" "$evidence/modules"
    evidence_abs_regular "$module_path"
    checksum_path="./modules/$inventory_path"
    module_hash=$(awk -v path="$checksum_path" '$2 == path { print $1; found++ } END { if (found != 1) exit 1 }' \
        "$evidence/SHA256SUMS") || die "M0 checksum missing or duplicated: $checksum_path"
    [[ $(evidence_sha256 "$module_path") == "$module_hash" ]] ||
        die "M0 module checksum mismatch: $relative"
}
for module in \
    drivers/dma/apple-admac.ko \
    drivers/media/platform/apple/avd/apple-avd.ko \
    drivers/media/platform/apple/isp/apple-isp.ko \
    sound/soc/apple/snd-soc-aop.ko \
    sound/soc/apple/snd-soc-apple-mca.ko \
    sound/soc/apple/snd-soc-macaudio.ko \
    sound/soc/codecs/snd-soc-cs42l84.ko \
    sound/soc/codecs/snd-soc-tas2764.ko; do
    require_module "$module"
done

readonly soc_dtsi="$source_dir/arch/arm64/boot/dts/apple/t6030.dtsi"
readonly board_dts="$source_dir/arch/arm64/boot/dts/apple/t6030-j514s.dts"
readonly board_dtsi="$source_dir/arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi"
readonly isp_config="$source_dir/arch/arm64/boot/dts/apple/isp-imx558-cfg0.dtsi"
readonly isp_driver="$source_dir/drivers/media/platform/apple/isp/isp-drv.c"
readonly avd_driver="$source_dir/drivers/media/platform/apple/avd/avd-drv.c"
readonly avd_v4l2="$source_dir/drivers/media/platform/apple/avd/avd-v4l2.c"
readonly macaudio="$source_dir/sound/soc/apple/macaudio.c"
readonly aop_audio="$source_dir/sound/soc/apple/aop_audio.rs"
count_fixed() { awk -v text="$1" 'index($0, text) { n++ } END { print n + 0 }' "$2"; }

target_isp_device_match=false
grep -Fq '{ .compatible = "apple,t6030-isp", .data = &apple_isp_hw_t6030 }' "$isp_driver" &&
    target_isp_device_match=true
target_camera_topology=false
if [[ $target_isp_device_match == true ]] &&
    grep -Fq 'compatible = "apple,t6030-isp";' "$soc_dtsi" &&
    grep -Fq '#include "isp-imx558-cfg0.dtsi"' "$board_dtsi" &&
    grep -Fq 'apple,platform-id = <16>;' "$board_dts" &&
    grep -Fq 'apple,input-size = <1920 1920>;' "$isp_config"; then
    target_camera_topology=true
fi

target_avd_fallback_t8122=false
if grep -Fq 'compatible = "apple,t6030-avd", "apple,t8122-avd";' "$soc_dtsi" &&
    grep -Fq '.compatible = "apple,t8122-avd"' "$avd_driver"; then
    target_avd_fallback_t8122=true
fi
t8122_variant=$(awk '
    /^static const struct avd_variant avd_t8122_variant =/ { capture=1 }
    capture { print }
    capture && /^};$/ { exit }
' "$avd_driver")
readonly t8122_variant
codec_decode_source() {
    local codec=$1 fourcc=$2
    [[ $target_avd_fallback_t8122 == true ]] &&
        grep -Fq "AVD_CAPABILITY_$codec" <<< "$t8122_variant" &&
        grep -Fq ".fourcc = V4L2_PIX_FMT_$fourcc" "$avd_v4l2"
}
target_h264_decode_source=false
codec_decode_source H264 H264_SLICE && target_h264_decode_source=true
target_hevc_decode_source=false
codec_decode_source HEVC HEVC_SLICE && target_hevc_decode_source=true
target_vp9_decode_source=false
codec_decode_source VP9 VP9_FRAME && target_vp9_decode_source=true
target_av1_decode_source=false
codec_decode_source AV1 AV1_FRAME && target_av1_decode_source=true

target_video_encode_source=false
if grep -REq 'config VIDEO_APPLE_[A-Z0-9_]*ENCODER|Apple( Silicon)? Video Encoding driver' \
    "$source_dir/drivers/media/platform/apple"; then
    target_video_encode_source=true
fi
target_prores_source=false
if grep -REiq 'V4L2_PIX_FMT(_[A-Z0-9]+)?_?PRORES|AVD_CAPABILITY_PRORES|Apple.*ProRes' \
    "$source_dir/drivers/media/platform/apple"; then
    target_prores_source=true
fi

target_microphone_topology=false
if grep -Fq 'compatible = "apple,t6030-aop-audio";' "$soc_dtsi" &&
    grep -Fq 'apple,t6030-aop-audio' "$aop_audio"; then
    target_microphone_topology=true
fi
target_headphone_topology=false
if [[ $(count_fixed 'compatible = "cirrus,cs42l84";' "$board_dtsi") -eq 1 ]] &&
    grep -Fq 'compatible = "apple,j514-macaudio", "apple,j314-macaudio", "apple,macaudio";' "$board_dts" &&
    grep -Fq '.compatible = "apple,j314-macaudio"' "$macaudio"; then
    target_headphone_topology=true
fi
target_speaker_topology=false
if [[ $(count_fixed 'compatible = "ti,sn012776", "ti,tas2764";' "$board_dtsi") -eq 6 ]] &&
    grep -Fq 'j514    AID28   sn012776' "$macaudio"; then
    target_speaker_topology=true
fi
generic_speaker_kernel_guard=false
if grep -Fq "driver can't assure safety on this model, disabling speakers" "$macaudio" &&
    grep -Fq 'speaker_lock_owner' "$macaudio"; then
    generic_speaker_kernel_guard=true
fi

readonly calibration_allowlist="$project_root/config/milestone6-speaker-calibrations.tsv"
readonly graph_allowlist="$project_root/config/milestone6-speaker-dsp-graphs.tsv"
[[ -f $calibration_allowlist && ! -L $calibration_allowlist ]] || die 'invalid M6 speaker calibration allowlist'
[[ -f $graph_allowlist && ! -L $graph_allowlist ]] || die 'invalid M6 speaker DSP graph allowlist'
awk -F '\t' '
    /^#/ { if (header) bad=1; next }
    !header { if ($0 != "board\tcalibration_sha256") bad=1; header=1; next }
    NF != 2 || $1 !~ /^[A-Za-z0-9._-]+$/ || length($2) != 64 || $2 !~ /^[0-9a-f]+$/ { bad=1; next }
    { if (++seen[$1 FS $2] != 1) bad=1 }
    END { if (!header) bad=1; exit bad }
' "$calibration_allowlist" || die 'invalid M6 speaker calibration allowlist rows'
awk -F '\t' '
    /^#/ { if (header) bad=1; next }
    !header { if ($0 != "board\tgraph_id\tgraph_sha256") bad=1; header=1; next }
    NF != 3 || $1 !~ /^[A-Za-z0-9._-]+$/ || $2 !~ /^[A-Za-z0-9._-]+$/ || length($3) != 64 || $3 !~ /^[0-9a-f]+$/ { bad=1; next }
    { if (++seen[$1 FS $2 FS $3] != 1) bad=1 }
    END { if (!header) bad=1; exit bad }
' "$graph_allowlist" || die 'invalid M6 speaker DSP graph allowlist rows'
j514_speaker_calibration_allowlisted=false
if awk -F '\t' '$0 !~ /^#/ && $1 == "J514s" { count++ } END { exit !(count > 0) }' "$calibration_allowlist"; then
    j514_speaker_calibration_allowlisted=true
fi
j514_speaker_dsp_graph_allowlisted=false
if awk -F '\t' '$0 !~ /^#/ && $1 == "J514s" && $2 == "graph-j514" { count++ } END { exit !(count > 0) }' "$graph_allowlist"; then
    j514_speaker_dsp_graph_allowlisted=true
fi

printf 'M6-source-readiness=checked-static-only\n'
printf 'generic_apple_isp_driver_built=true\n'
printf 'generic_apple_avd_driver_built=true\n'
printf 'generic_apple_audio_stack_built=true\n'
printf 'target_isp_device_match=%s\n' "$target_isp_device_match"
printf 'target_camera_topology=%s\n' "$target_camera_topology"
printf 'target_avd_fallback_t8122=%s\n' "$target_avd_fallback_t8122"
printf 'target_h264_decode_source=%s\n' "$target_h264_decode_source"
printf 'target_hevc_decode_source=%s\n' "$target_hevc_decode_source"
printf 'target_vp9_decode_source=%s\n' "$target_vp9_decode_source"
printf 'target_av1_decode_source=%s\n' "$target_av1_decode_source"
printf 'target_video_encode_source=%s\n' "$target_video_encode_source"
printf 'target_prores_source=%s\n' "$target_prores_source"
printf 'target_microphone_topology=%s\n' "$target_microphone_topology"
printf 'target_headphone_topology=%s\n' "$target_headphone_topology"
printf 'target_speaker_topology=%s\n' "$target_speaker_topology"
printf 'generic_speaker_kernel_guard=%s\n' "$generic_speaker_kernel_guard"
printf 'j514_speaker_calibration_allowlisted=%s\n' "$j514_speaker_calibration_allowlisted"
printf 'j514_speaker_dsp_graph_allowlisted=%s\n' "$j514_speaker_dsp_graph_allowlisted"
printf 'speakersafetyd_runtime_evidence=false\n'
printf 'native_runtime_evidence=false\n'
printf 'hardware_acceptance=false\n'
if [[ $target_camera_topology == true && $target_h264_decode_source == true && \
    $target_hevc_decode_source == true && $target_vp9_decode_source == true && \
    $target_av1_decode_source == true && $target_video_encode_source == true && \
    $target_prores_source == true && $target_microphone_topology == true && \
    $target_headphone_topology == true && $target_speaker_topology == true && \
    $generic_speaker_kernel_guard == true && $j514_speaker_calibration_allowlisted == true && \
    $j514_speaker_dsp_graph_allowlisted == true ]]; then
    printf 'm6_source_ready=true\n'
    exit 0
fi
printf 'm6_source_ready=false\n'
printf 'gate=blocked-video-encode-prores-and-speaker-runtime\n'
exit 2
