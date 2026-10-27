#!/usr/bin/env bash
# Drives scripts/verify-m4-gpu-source-candidate.sh against a well-formed
# fixture candidate (identity from the real silicon profile, every RE-gated
# field a zero, poison or RE_GATED_* sentinel), the repository's real candidate
# series and deliberately fabricated or malformed mutants of both. Each
# non-zero, non-poison value placed in a gated field below is a synthetic
# negative test vector the gate must reject; none is a T6030 constant. Hunk
# context lines mirror the pinned tree only for realism. When the pinned Linux
# tree (M4_GPU_LINUX_PIN) is present, the real candidate and its board-level
# mutants are also replayed and built; otherwise those cases are skipped.
set -Eeuo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly project_root
[[ $# -eq 0 ]] || { printf 'usage: %s\n' "$0" >&2; exit 64; }
readonly verifier="$project_root/scripts/verify-m4-gpu-source-candidate.sh"
readonly profile="$project_root/config/milestone4-gpu-silicon-profile.tsv"
[[ -f $verifier && -f $profile ]] || { printf 'missing M4 GPU candidate verifier or silicon profile\n' >&2; exit 1; }
command -v dtc >/dev/null 2>&1 || { printf 'dtc is required\n' >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/m4-gpu-candidate-self-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
readonly verifier_tmp="$tmp/verifier-tmp"
mkdir "$verifier_tmp"
readonly no_pin="$tmp/no-linux-pin"
readonly default_linux_pin=/private/tmp/claude-501/-private-tmp-work/9d625c24-f09f-4f1f-aa5d-7f33f13cb9df/scratchpad/linux-pin
readonly linux_pin=${M4_GPU_LINUX_PIN-$default_linux_pin}

detab() { awk '{ match($0, /^(    )*/); lead = ""; for (i = 0; i < RLENGTH / 4; i++) lead = lead "\t"; print lead substr($0, RLENGTH + 1) }'; }
lines_in() { if [[ -z $1 ]]; then printf '0\n'; else printf '%s\n' "$1" | wc -l | tr -d '[:space:]'; fi; }
prefix_lines() { [[ -z $2 ]] || printf '%s\n' "$2" | sed "s/^/$1/"; }
file_header() { printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n' "$1" "$1" "$1" "$1"; }
hunk() {
    local old_start=$1 new_start=$2 before=$3 added=$4 after=${5-} old new old_range new_range
    old=$(($(lines_in "$before") + $(lines_in "$after")))
    new=$((old + $(lines_in "$added")))
    old_range=$old_start
    ((old == 1)) || old_range="$old_start,$old"
    new_range=$new_start
    ((new == 1)) || new_range="$new_start,$new"
    printf '@@ -%s +%s @@\n' "$old_range" "$new_range"
    prefix_lines ' ' "$before"
    prefix_lines '+' "$added"
    prefix_lines ' ' "$after"
}
new_file_patch() {
    local path=$1 body=$2 count
    count=$(wc -l < "$body" | tr -d '[:space:]')
    printf 'diff --git a/%s b/%s\nnew file mode 100644\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1,%s @@\n' \
        "$path" "$path" "$path" "$count"
    sed 's/^/+/' "$body"
}
edit() {
    sed -i.bak "$2" "$1"
    if cmp -s -- "$1" "$1.bak"; then
        printf 'fixture mutation did not apply: %s: %s\n' "$1" "$2" >&2
        exit 1
    fi
    rm -f -- "$1.bak"
}
insert_after() {
    INSERT_TEXT=$3 awk -v anchor="$2" \
        '{ print } index($0, anchor) && !done { print ENVIRON["INSERT_TEXT"]; done = 1 }' "$1" > "$1.new"
    mv -- "$1.new" "$1"
}
# Inserts a line after an exact anchor line of a patch and grows the new-line
# count of the hunk holding it, so the mutant stays a well-formed patch.
patch_insert_after() {
    ANCHOR=$2 INSERT_TEXT=$3 awk '
        { line[NR] = $0 }
        /^@@ / && !hit { header = NR }
        $0 == ENVIRON["ANCHOR"] && !hit { hit = NR }
        END {
            if (!hit || !header) exit 1
            h = line[header]; match(h, /[+][0-9]+(,[0-9]+)?/); range = substr(h, RSTART + 1, RLENGTH - 1)
            split(range, parts, ","); count = (index(range, ",") ? parts[2] : 1) + 1
            line[header] = substr(h, 1, RSTART - 1) "+" parts[1] "," count substr(h, RSTART + RLENGTH)
            for (i = 1; i <= NR; i++) { print line[i]; if (i == hit) print ENVIRON["INSERT_TEXT"] }
        }' "$1" > "$1.new" || { printf 'patch insertion anchor not found: %s: %s\n' "$1" "$2" >&2; exit 1; }
    mv -- "$1.new" "$1"
}
set_profile() {
    awk -F '\t' -v OFS='\t' -v key="$2" -v column="$3" -v value="$4" \
        '$1 == key { $column = value } { print }' "$1" > "$1.new"
    mv -- "$1.new" "$1"
}

# --- fixture sources: identity from the silicon profile, RE-gated fields as sentinels
readonly bodies="$tmp/bodies"
mkdir "$bodies"
detab > "$bodies/t6030-gpu.dtsi" <<'EOF'
// SPDX-License-Identifier: GPL-2.0+ OR MIT
/*
 * Self-test fixture: T6030 (M3 Pro) G15 GPU candidate node. Identity only;
 * the interrupt cells are fixture zeros, not T6030 values.
 */

#ifndef GPU_REPEAT
# define GPU_REPEAT(x) <x x>
#endif

// TODO(adt): extract the GPU windows from the T6030 ADT; NOT a working value
#define FIXTURE_ADT_GATED_GPU_REG 0x0 0x0 0x0 0x0
// TODO(adt): mailbox window; poison base only keeps mbox@deadbeef apart from gpu@0
#define FIXTURE_ADT_GATED_MBOX_REG 0x0 0xdeadbeef 0x0 0x0
/* TODO(re): apple_firmware_abi UNKNOWN; extract from macOS AGX firmware trace on T6030; NOT a working value */
#define RE_GATED_FIRMWARE_ABI 0 0 0
// TODO(re): apple_firmware_version UNKNOWN; NOT a working value
#define T6030_AGX_RE_GATED_FIRMWARE_VERSION 0 0 0

/ {
    gpu_opp: opp-table-gpu {
        compatible = "operating-points-v2";

        /* TODO(re): gpu_opp_dvfs_table UNKNOWN; NOT a working value */
        opp00 {
            opp-hz = /bits/ 64 <0>; /* TODO(re) */
            opp-microvolt = GPU_REPEAT(0); /* TODO(re) */
        };
    };

    reserved-memory {
        gpu_globals: globals {
            status = "disabled"; // placeholder
        };
    };
};

&soc {
    gpu: gpu@0 {
        compatible = "apple,agx-t6030", "apple,agx-g15s";
        reg = <FIXTURE_ADT_GATED_GPU_REG>;
        mboxes = <&agx_mbox>;
        power-domains = <&ps_gfx>;
        interrupt-parent = <&aic>;
        interrupts = <AIC_IRQ 0 IRQ_TYPE_LEVEL_HIGH>; /* TODO(adt): NOT a working value */
        operating-points-v2 = <&gpu_opp>;

        apple,firmware-abi = <RE_GATED_FIRMWARE_ABI>;
        apple,firmware-version = <T6030_AGX_RE_GATED_FIRMWARE_VERSION>;
        apple,firmware-compat = <0 0 0>; /* TODO(re): apple_firmware_version UNKNOWN */

        status = "disabled";
    };

    agx_mbox: mbox@deadbeef {
        compatible = "apple,asc-mailbox-v4";
        reg = <FIXTURE_ADT_GATED_MBOX_REG>;
        #mbox-cells = <0>;
        status = "disabled"; // mailbox
    };
};
EOF
detab > "$bodies/board-gpu-override.dtsi" <<'EOF'
&gpu {
    status = "disabled";
};
EOF
cat > "$bodies/t603x.rs" <<'EOF'
// SPDX-License-Identifier: GPL-2.0-only OR MIT

//! Self-test fixture: hardware configuration candidate for t6030 (M3 Pro).
//! Identity comes from config/milestone4-gpu-silicon-profile.tsv only; the
//! struct is abbreviated and never compiled.

use super::*;

// TODO(re): preempt_buffer_sizes UNKNOWN; extract from macOS AGX firmware trace on T6030; NOT a working value
const RE_GATED_PREEMPT_SIZE: usize = 0;

/// Poison for an RE-gated `u32`, chosen so it cannot pass for a tuned number.
const RE_GATED_U32: u32 = 0xdead_beef;

/// Poison quiet NaN for an F32 that is still unknown. NOT a working value.
const RE_GATED_F32: F32 = F32::from_bits(0x7fc0_dead);

// TODO(re): hwconfig_unk_coef_a UNKNOWN; NOT a working value
const RE_GATED_UNK_COEF: &[&[F32]] = &[];

// TODO(re): hwconfig_da_db UNKNOWN; NOT a working value
const RE_GATED_HWCONFIG_A: HwConfigA = HwConfigA {
    unk_87c: 0,
    unk_8cc: 0,
    unk_e24: 0,
};

pub(crate) const HWCONFIG_T6030: super::HwConfig = HwConfig {
    chip_id: 0x6030,
    gpu_gen: GpuGen::G15,
    gpu_variant: GpuVariant::S,
    base_clock_hz: RE_GATED_U32,
    preempt1_size: RE_GATED_PREEMPT_SIZE,
    preempt2_size: 0x0, // TODO(re): preempt_buffer_sizes UNKNOWN
    clustering: Some(HwClusteringConfig {
        meta1_blocksize: RE_GATED_PREEMPT_SIZE,
    }),
    render: HwRenderConfig {
        tiling_control: RE_GATED_U32,
    },
    da: RE_GATED_HWCONFIG_A,
    unk_coef_a: RE_GATED_UNK_COEF,
    // TODO(re): hwconfig_unk_coef_b UNKNOWN; NOT a working value
    unk_coef_b: &[],
    // TODO(re): hwdata_shared_tables UNKNOWN; NOT a working value
    shared1_tab: &[0; 16],
    shared1_a4: RE_GATED_U32,
    sram_k: RE_GATED_F32,
    fast_sensor_mask: [0, 0], // TODO(re): temp_sensor_mask UNKNOWN
    fast_sensor_mask_alt: [0b0, 0o0_0], // TODO(re): temp_sensor_mask UNKNOWN
    global_tab: Some(&[]), // TODO(re): globals table UNKNOWN
    io_mappings: &[], // TODO(re): firmware MMIO mappings UNKNOWN
    sram_base: Some(0x0_0), // TODO(re): SRAM window UNKNOWN
};
EOF
cat > "$bodies/README.md" <<'EOF'
# Self-test fixture: development-only T6030 GPU candidate

hardware_acceptance=false. Source candidate only; no builder selects it and
the GPU node stays disabled.

RE-gated items, each still a TODO(re) sentinel:

- apple_firmware_version: UNKNOWN
- apple_firmware_abi: UNKNOWN
- gpu_opp_dvfs_table: UNKNOWN
- hwconfig_unk_coef_a: UNKNOWN
- hwconfig_unk_coef_b: UNKNOWN
- hwconfig_da_db: UNKNOWN
- hwdata_shared_tables: UNKNOWN
- preempt_buffer_sizes: UNKNOWN
- temp_sensor_mask: UNKNOWN
EOF

# Builds a disposable project root holding a copy of the verifier, the real
# silicon profile and a patch series generated from a bodies directory.
build_fixture() {
    local source=$1 root=$2 series board_context override dt_patch driver_patch
    mkdir -p "$root/config" "$root/scripts"
    cp -p -- "$verifier" "$root/scripts/verify-m4-gpu-source-candidate.sh"
    cp -p -- "$profile" "$root/config/milestone4-gpu-silicon-profile.tsv"
    series="$root/patches/linux-gpu-development"
    mkdir -p "$series"
    cp -p -- "$source/README.md" "$series/README.md"
    printf '01-t6030-gpu-node.patch\n02-t6030-hwconfig.patch\n' > "$series/series"
    printf 'Subject: [DEVELOPMENT PATCH 0/2] self-test fixture cover letter\n\nNo diff here; hardware_acceptance=false.\n' \
        > "$series/00-cover-letter.patch"
    board_context=$'&isp {\n\tapple,platform-id = <16>;\n};'
    override=$'\n'$(cat "$source/board-gpu-override.dtsi")
    dt_patch="$series/01-t6030-gpu-node.patch"
    {
        new_file_patch arch/arm64/boot/dts/apple/t6030-gpu.dtsi "$source/t6030-gpu.dtsi"
        file_header arch/arm64/boot/dts/apple/t6030.dtsi
        hunk 2073 2073 '#include "t6030-pmgr.dtsi"' '#include "t6030-gpu.dtsi"'
        for board in j514s j516s; do
            file_header "arch/arm64/boot/dts/apple/t6030-$board.dts"
            hunk 81 81 "$board_context" "$override"
        done
    } > "$dt_patch"
    driver_patch="$series/02-t6030-hwconfig.patch"
    {
        new_file_patch drivers/gpu/drm/asahi/hw/t603x.rs "$source/t603x.rs"
        file_header drivers/gpu/drm/asahi/hw/mod.rs
        hunk 14 14 $'pub(crate) mod t600x;\npub(crate) mod t602x;' 'pub(crate) mod t603x;'
        hunk 22 23 $'pub(crate) enum GpuGen {\n    G13 = 13,\n    G14 = 14,' '    G15 = 15,' '}'
        file_header drivers/gpu/drm/asahi/driver.rs
        hunk 143 143 \
            $'        ),\n        (\n            of::DeviceId::new(c_str!("apple,agx-t6022")),\n            &hw::t602x::HWCONFIG_T6022\n        ),' \
            $'        (\n            of::DeviceId::new(c_str!("apple,agx-t6030")),\n            &hw::t603x::HWCONFIG_T6030\n        ),' \
            '    ]'
    } > "$driver_patch"
}
copy_bodies() { cp -pR -- "$bodies" "$tmp/bodies-$1"; printf '%s\n' "$tmp/bodies-$1"; }
copy_project() { cp -pR -- "$good" "$tmp/$1"; printf '%s\n' "$tmp/$1"; }

assert_clean_tmp() {
    [[ -z $(find "$verifier_tmp" -mindepth 1 -print -quit) ]] || {
        printf 'verifier left files in its temporary root: %s\n' "$1" >&2
        exit 1
    }
}
run_candidate() {
    local name=$1 root=$2 pin=${3-$no_pin} result
    set +e
    M4_GPU_LINUX_PIN=$pin TMPDIR="$verifier_tmp" "$root/scripts/verify-m4-gpu-source-candidate.sh" --static \
        > "$tmp/$name.out" 2> "$tmp/$name.err"
    result=$?
    set -e
    assert_clean_tmp "$name"
    printf '%s\n' "$result"
}
expect_blocked() {
    local name=$1 root=$2 result line
    result=$(run_candidate "$name" "$root" "${pin_for_run:-$no_pin}")
    [[ $result -eq 2 ]] || {
        printf 'well-formed candidate did not stay blocked: %s (exit %s)\n' "$name" "$result" >&2
        cat "$tmp/$name.err" >&2
        exit 1
    }
    shift 2
    for line in "$@"; do
        grep -Fx -- "$line" "$tmp/$name.out" >/dev/null || {
            printf 'missing gate line for %s: %s\n' "$name" "$line" >&2
            cat "$tmp/$name.out" >&2
            exit 1
        }
    done
}
rejected=0
# Every expected substring must appear in the verifier's stderr.
expect_reject() {
    local name=$1 root=$2 result expected
    result=$(run_candidate "$name" "$root" "${pin_for_run:-$no_pin}")
    [[ $result -eq 1 ]] || {
        printf 'fabricated or malformed candidate was not rejected: %s (exit %s)\n' "$name" "$result" >&2
        cat "$tmp/$name.err" >&2
        exit 1
    }
    for expected in "${@:3}"; do
        grep -Fq -- "$expected" "$tmp/$name.err" || {
            printf 'candidate rejected for the wrong reason: %s\nexpected: %s\n' "$name" "$expected" >&2
            cat "$tmp/$name.err" >&2
            exit 1
        }
    done
    if grep -Fx 'tooling_valid=true' "$tmp/$name.out" >/dev/null; then
        printf 'rejected candidate still printed tooling_valid=true: %s\n' "$name" >&2
        exit 1
    fi
    rejected=$((rejected + 1))
}
body_mutant() {
    local name=$1 file=$2 expression=$3 expected=$4 source
    source=$(copy_bodies "$name")
    edit "$source/$file" "$expression"
    build_fixture "$source" "$tmp/$name"
    expect_reject "$name" "$tmp/$name" "$expected"
}

# --- well-formed candidates stay blocked with exit 2 --------------------------
readonly good="$tmp/good"
build_fixture "$bodies" "$good"
set +e
"$good/scripts/verify-m4-gpu-source-candidate.sh" >/dev/null 2>&1
usage_result=$?
set -e
[[ $usage_result -eq 64 ]] || { printf 'verifier accepted a call without --static\n' >&2; exit 1; }
expect_blocked good "$good" \
    'M4-gpu-source-candidate=checked-static-only' \
    'gpu_silicon_profile=consistent' \
    'gpu_chip_id=0x6030' \
    'gpu_gen=15' \
    'gpu_variant=S' \
    'gpu_usc_gen=3' \
    'gpu_num_mgpus=2' \
    'gpu_cores_physical=20' \
    'gpu_cores_active=18' \
    'gpu_core_mask_list=0x1ff,0x1ff' \
    're_gated_profile_items=9' \
    're_gated_profile_items_unknown=9' \
    'gpu_patch_series=1' \
    'gpu_dt_patches=1' \
    'gpu_driver_patches=1' \
    'gpu_node_source=arch/arm64/boot/dts/apple/t6030-gpu.dtsi' \
    'gpu_node_overrides=2' \
    'gpu_patch_scope=checked' \
    'gpu_node_status=disabled' \
    'dt_added_blocks=4' \
    'dt_overlay_dtc_syntax=checked' \
    'dt_overlay_dtc_warnings=0' \
    're_gated_placeholders_checked=33' \
    'forbidden_success_tokens=absent' \
    'patch_replay=not-run' \
    'patch_replay_reason=pinned-linux-tree-absent' \
    'board_dtc_new_warnings=not-run' \
    'native_runtime_evidence=false' \
    'tooling_valid=true' \
    'evidence_valid=not-provided' \
    'hardware_acceptance=false' \
    'gate=blocked-for-native-execution'
if grep -E '(hardware_acceptance|evidence_valid)=true' "$tmp/good.out" >/dev/null; then
    printf 'verifier claimed hardware acceptance or evidence\n' >&2
    exit 1
fi

split=$(copy_project split-series)
mkdir "$split/patches/linux-gpu-development-driver"
mv -- "$split/patches/linux-gpu-development/02-t6030-hwconfig.patch" \
    "$split/patches/linux-gpu-development-driver/01-t6030-hwconfig.patch"
printf '01-t6030-gpu-node.patch\n' > "$split/patches/linux-gpu-development/series"
printf '01-t6030-hwconfig.patch\n' > "$split/patches/linux-gpu-development-driver/series"
cp -p -- "$split/patches/linux-gpu-development/README.md" "$split/patches/linux-gpu-development-driver/README.md"
expect_blocked split-series "$split" 'gpu_patch_series=2' 'tooling_valid=true' 'hardware_acceptance=false'

# --- fabricated RE-gated values are rejected even when labelled TODO(re) ------
body_mutant fake-voltage t6030-gpu.dtsi 's|opp-microvolt = GPU_REPEAT(0);|opp-microvolt = GPU_REPEAT(123456);|' \
    'fabricated RE-gated value (gpu_opp_dvfs_table)'
source=$(copy_bodies injected-voltage)
insert_after "$source/t6030-gpu.dtsi" 'operating-points-v2 = <&gpu_opp>;' $'\t\tapple,min-sram-microvolt = <123456>;'
build_fixture "$source" "$tmp/injected-voltage"
expect_reject injected-voltage "$tmp/injected-voltage" 'fabricated RE-gated value (gpu_opp_dvfs_table)'
body_mutant fake-firmware-compat t6030-gpu.dtsi 's|apple,firmware-compat = <0 0 0>;|apple,firmware-compat = <99 9 9>;|' \
    'fabricated RE-gated value (apple_firmware_version)'
body_mutant fake-firmware-version-macro t6030-gpu.dtsi \
    's|define T6030_AGX_RE_GATED_FIRMWARE_VERSION 0 0 0|define T6030_AGX_RE_GATED_FIRMWARE_VERSION 99 9 9|' \
    'fabricated RE-gated value (RE_GATED sentinel)'
body_mutant fake-adt-window t6030-gpu.dtsi \
    's|define FIXTURE_ADT_GATED_GPU_REG 0x0 0x0 0x0 0x0|define FIXTURE_ADT_GATED_GPU_REG 0x0 0x1000 0x0 0x2000|' \
    'fabricated ADT-gated value (ADT_GATED sentinel)'
body_mutant valued-macro t6030-gpu.dtsi 's|# define GPU_REPEAT(x) <x x>|# define GPU_REPEAT(x) <x 7>|' \
    'references non-sentinel identifier GPU_REPEAT'
body_mutant near-poison t603x.rs 's|RE_GATED_U32: u32 = 0xdead_beef;|RE_GATED_U32: u32 = 0xdead_0540;|' \
    'fabricated RE-gated value (RE_GATED sentinel)'
body_mutant tuned-nan-payload t603x.rs 's|F32::from_bits(0x7fc0_dead)|F32::from_bits(0x3fa0_0000)|' \
    'fabricated RE-gated value (RE_GATED sentinel)'
body_mutant fake-firmware-abi-macro t6030-gpu.dtsi 's|define RE_GATED_FIRMWARE_ABI 0 0 0|define RE_GATED_FIRMWARE_ABI 9 9 9|' \
    'fabricated RE-gated value (RE_GATED sentinel)'
body_mutant fake-coefficient t603x.rs 's|unk_coef_b: &\[\],|unk_coef_b: \&[\&f32!([0.0, 1.5])],|' \
    'fabricated RE-gated value (hwconfig_unk_coef_b)'
body_mutant fake-sentinel t603x.rs 's|RE_GATED_PREEMPT_SIZE: usize = 0;|RE_GATED_PREEMPT_SIZE: usize = 0x123;|' \
    'fabricated RE-gated value (RE_GATED sentinel)'
body_mutant fake-hwconfig-a t603x.rs 's|unk_8cc: 0,|unk_8cc: 12345,|' \
    'fabricated RE-gated value (RE_GATED sentinel)'
body_mutant fake-shared-table t603x.rs 's|shared1_tab: &\[0; 16\],|shared1_tab: \&[0xffff; 16],|' \
    'fabricated RE-gated value (hwdata_shared_tables)'
body_mutant fake-sensor-mask t603x.rs 's|fast_sensor_mask: \[0, 0\],|fast_sensor_mask: [0x1234, 0],|' \
    'fabricated RE-gated value (temp_sensor_mask)'
body_mutant unlabeled-dt-placeholder t6030-gpu.dtsi \
    's|apple,firmware-compat = <0 0 0>; /\* TODO(re): apple_firmware_version UNKNOWN \*/|apple,firmware-compat = <0 0 0>;|' \
    'unlabeled RE-gated placeholder (apple_firmware_version)'
body_mutant unlabeled-rust-placeholder t603x.rs 's|, // TODO(re): temp_sensor_mask UNKNOWN|,|' \
    'unlabeled RE-gated placeholder (temp_sensor_mask)'
body_mutant unlabeled-sentinel t603x.rs 's|// TODO(re): hwconfig_unk_coef_a UNKNOWN; NOT a working value|// hwconfig_unk_coef_a UNKNOWN|' \
    'unlabeled RE-gated sentinel (RE_GATED sentinel)'
body_mutant laundered-identifier t603x.rs 's|unk_coef_a: RE_GATED_UNK_COEF,|unk_coef_a: T6030_COEF_A,|' \
    'references non-sentinel identifier T6030_COEF_A'
body_mutant inherited-hwconfig t603x.rs 's|    preempt1_size: RE_GATED_PREEMPT_SIZE,|    ..HWCONFIG_T6020|' \
    'inherits RE-gated fields from another SoC (HWCONFIG_T6020)'
body_mutant wrong-chip-id t603x.rs 's|chip_id: 0x6030,|chip_id: 0x6022,|' 'HwConfig chip_id 0x6022 differs'
body_mutant wrong-gpu-gen t603x.rs 's|GpuGen::G15,|GpuGen::G14,|' 'HwConfig gpu_gen G14 differs'
body_mutant missing-chip-id t603x.rs 's|    chip_id: 0x6030,|    // chip id omitted|' \
    'driver series adds no HwConfig with chip_id 0x6030'
body_mutant re-gated-readme-value README.md 's|- hwconfig_unk_coef_a: UNKNOWN|- hwconfig_unk_coef_a: 1.25 (extracted)|' \
    'RE-gated item carries a value without UNKNOWN, TODO(re) or RE_GATED: hwconfig_unk_coef_a'
source=$(copy_bodies untracked-item)
edit "$source/README.md" 's|hwdata_shared_tables|shared tables|'
edit "$source/t603x.rs" 's|hwdata_shared_tables|shared tables|'
build_fixture "$source" "$tmp/untracked-item"
expect_reject untracked-item "$tmp/untracked-item" \
    'not tracked as UNKNOWN, TODO(re) or RE_GATED by the candidate series: hwdata_shared_tables'

# --- success claims anywhere in the candidate are rejected --------------------
claim=1
for text in \
    'hardware_acceptance=true' \
    'evidence_valid=true' \
    'Vulkan conformance passes on J514s.' \
    'The driver passed conformance.' \
    'GPU rendering verified on J516s.' \
    'Bring-up is proven.' \
    'Production-ready G15 support.'; do
    mutant=$(copy_project "claim-$claim")
    printf '%s\n' "$text" >> "$mutant/patches/linux-gpu-development/README.md"
    expect_reject "claim-$claim" "$mutant" 'forbidden success token'
    claim=$((claim + 1))
done
body_mutant claim-in-patch t603x.rs 's|//! Identity comes from|//! Production ready; identity comes from|' \
    'forbidden success token in patches/linux-gpu-development/02-t6030-hwconfig.patch'
mutant=$(copy_project claim-in-profile)
printf '# GPU rendering verified\n' >> "$mutant/config/milestone4-gpu-silicon-profile.tsv"
expect_reject claim-in-profile "$mutant" 'forbidden success token in config/milestone4-gpu-silicon-profile.tsv'

# --- the device-derived profile must stay internally consistent ---------------
profile_mutant() {
    local name=$1 key=$2 column=$3 value=$4 expected=$5 mutant
    mutant=$(copy_project "$name")
    set_profile "$mutant/config/milestone4-gpu-silicon-profile.tsv" "$key" "$column" "$value"
    expect_reject "$name" "$mutant" "$expected"
}
profile_mutant mask-popcount core_mask_list 2 0x3ff,0x1ff 'differs from popcount(core_mask_list)=19'
profile_mutant active-count gpu_core_count_active 2 19 'gpu_core_count_active=19 differs from popcount(core_mask_list)=18'
profile_mutant mask-width core_mask_list 2 0x7ff,0x1ff 'core mask exceeds the physical cores of one mGPU'
profile_mutant mgpu-count num_mgpus 2 3 'core_mask_list entry count differs from num_mgpus'
profile_mutant chip-id chip_id 2 0x6031 'silicon profile identity mismatch: chip_id'
profile_mutant gpu-gen gpu_gen 2 14 'ioclass does not match gpu_gen'
profile_mutant physical-cores num_cores_physical 2 22 'num_frags_physical differs from num_cores_physical'
profile_mutant firmware-version-value apple_firmware_version 2 99.9.9 \
    'silicon profile RE-gated row carries a value: apple_firmware_version'
profile_mutant dvfs-status gpu_opp_dvfs_table 4 device-derived \
    'silicon profile RE-gated row changed status: gpu_opp_dvfs_table'
mutant=$(copy_project dropped-row)
grep -v '^temp_sensor_mask' "$profile" > "$mutant/config/milestone4-gpu-silicon-profile.tsv"
expect_reject dropped-row "$mutant" 'silicon profile inventory mismatch'
mutant=$(copy_project missing-profile)
rm -f -- "$mutant/config/milestone4-gpu-silicon-profile.tsv"
expect_reject missing-profile "$mutant" 'missing silicon profile'

# --- patch-series shape --------------------------------------------------------
mutant=$(copy_project no-series-dir)
rm -rf -- "$mutant/patches"
expect_reject no-series-dir "$mutant" 'missing patch series under patches/linux-gpu-development*/'
mutant=$(copy_project no-series-file)
rm -f -- "$mutant/patches/linux-gpu-development/series"
expect_reject no-series-file "$mutant" 'missing series file'
mutant=$(copy_project no-readme)
rm -f -- "$mutant/patches/linux-gpu-development/README.md"
expect_reject no-readme "$mutant" 'missing README.md'
mutant=$(copy_project readme-without-gate)
edit "$mutant/patches/linux-gpu-development/README.md" 's|^hardware_acceptance=false\. ||'
expect_reject readme-without-gate "$mutant" 'README.md does not state hardware_acceptance=false'
mutant=$(copy_project missing-patch)
printf '03-missing.patch\n' >> "$mutant/patches/linux-gpu-development/series"
expect_reject missing-patch "$mutant" 'series lists a missing patch'
mutant=$(copy_project orphan-patch)
cp -p -- "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch" \
    "$mutant/patches/linux-gpu-development/03-orphan.patch"
expect_reject orphan-patch "$mutant" 'patch not listed in series'
mutant=$(copy_project cover-letter-diff)
sed -n '/^diff --git/,$p' "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch" \
    >> "$mutant/patches/linux-gpu-development/00-cover-letter.patch"
expect_reject cover-letter-diff "$mutant" 'cover letter carries a diff'
mutant=$(copy_project gap-in-series)
mv -- "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch" \
    "$mutant/patches/linux-gpu-development/03-t6030-hwconfig.patch"
printf '01-t6030-gpu-node.patch\n03-t6030-hwconfig.patch\n' > "$mutant/patches/linux-gpu-development/series"
expect_reject gap-in-series "$mutant" 'series is not numbered contiguously from 01'
mutant=$(copy_project no-dt-patch)
rm -f -- "$mutant/patches/linux-gpu-development/01-t6030-gpu-node.patch"
mv -- "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch" \
    "$mutant/patches/linux-gpu-development/01-t6030-hwconfig.patch"
printf '01-t6030-hwconfig.patch\n' > "$mutant/patches/linux-gpu-development/series"
expect_reject no-dt-patch "$mutant" 'no DT patch'
mutant=$(copy_project no-driver-patch)
rm -f -- "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch"
printf '01-t6030-gpu-node.patch\n' > "$mutant/patches/linux-gpu-development/series"
expect_reject no-driver-patch "$mutant" 'no driver patch'
mutant=$(copy_project out-of-scope)
edit "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch" 's|drivers/gpu/drm/asahi/driver.rs|drivers/gpu/drm/msm/msm_drv.c|g'
expect_reject out-of-scope "$mutant" 'outside the GPU candidate scope'
mutant=$(copy_project truncated-hunk)
edit "$mutant/patches/linux-gpu-development/01-t6030-gpu-node.patch" 's|^@@ -0,0 +1,[0-9]* @@$|@@ -0,0 +1,999 @@|'
expect_reject truncated-hunk "$mutant" 'malformed patch'
mutant=$(copy_project symlink)
ln -s 01-t6030-gpu-node.patch "$mutant/patches/linux-gpu-development/03-link.patch"
expect_reject symlink "$mutant" 'non-regular file'
mutant=$(copy_project no-device-match)
edit "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch" 's|^+\(.*\)"apple,agx-t6030"|+\1"apple,agx-t603x"|'
expect_reject no-device-match "$mutant" 'driver series does not add the apple,agx-t6030 device match'

# --- GPU node and bounded dtc overlay harness ---------------------------------
body_mutant dtc-syntax t6030-gpu.dtsi 's|"apple,agx-g15s";|"apple,agx-g15s"|' \
    'candidate DT overlay failed the bounded dtc syntax check'
body_mutant float-cells t6030-gpu.dtsi 's|operating-points-v2 = <&gpu_opp>;|apple,perf-integral-gain = <0.5>;|' \
    'added DT node carries a float cell literal'
body_mutant function-macro t6030-gpu.dtsi 's|operating-points-v2 = <&gpu_opp>;|apple,core-leak-coef = GPU_SCALE(0);|' \
    'unresolved preprocessor macro in added DT node: GPU_SCALE'
body_mutant enabled-node t6030-gpu.dtsi 's|status = "disabled";$|status = "okay";|' \
    'DT series sets a status other than "disabled": status = "okay";'
body_mutant enabled-override board-gpu-override.dtsi 's|status = "disabled";|status = "okay";|' \
    'DT series sets a status other than "disabled": status = "okay";'
body_mutant wrong-compatible t6030-gpu.dtsi 's|"apple,agx-t6030"|"apple,agx-t6031"|' \
    'GPU node compatible does not include apple,agx-t6030'
body_mutant no-gpu-node t6030-gpu.dtsi 's|gpu: gpu@0 {|agx: gpu@0 {|' "DT series must add exactly one 'gpu: gpu@' node (found 0)"
source=$(copy_bodies unbalanced-node)
awk '{ print } /status = "disabled";$/ { exit }' "$source/t6030-gpu.dtsi" > "$source/t6030-gpu.dtsi.new"
mv -- "$source/t6030-gpu.dtsi.new" "$source/t6030-gpu.dtsi"
build_fixture "$source" "$tmp/unbalanced-node"
expect_reject unbalanced-node "$tmp/unbalanced-node" 'GPU node or &gpu override is not brace-balanced'
source=$(copy_bodies oversized-node)
filler=$(awk 'BEGIN { for (i = 0; i < 520; i++) printf "\t\tapple,fixture-filler-%d;\n", i }')
insert_after "$source/t6030-gpu.dtsi" 'operating-points-v2 = <&gpu_opp>;' "${filler%$'\n'}"
build_fixture "$source" "$tmp/oversized-node"
expect_reject oversized-node "$tmp/oversized-node" 'GPU node exceeds 512 lines'

# --- radix-prefixed and remaining HwConfig values are values, too -------------
body_mutant binary-sensor-mask t603x.rs 's|fast_sensor_mask: \[0, 0\],|fast_sensor_mask: [0b1111_0000_1111, 0],|' \
    'fabricated RE-gated value (temp_sensor_mask)'
body_mutant octal-preempt t603x.rs 's|    preempt1_size: RE_GATED_PREEMPT_SIZE,|    preempt1_size: 0o7740,|' \
    'fabricated RE-gated value (preempt_buffer_sizes)'
body_mutant binary-sentinel t603x.rs 's|RE_GATED_PREEMPT_SIZE: usize = 0;|RE_GATED_PREEMPT_SIZE: usize = 0b1_0000;|' \
    'fabricated RE-gated value (RE_GATED sentinel)'
body_mutant octal-zero-suffix t603x.rs 's|fast_sensor_mask_alt: \[0b0, 0o0_0\],|fast_sensor_mask_alt: [0b0, 0o0_1u64],|' \
    'fabricated RE-gated value (temp_sensor_mask)'
body_mutant underscored-decimal t603x.rs 's|base_clock_hz: RE_GATED_U32,|base_clock_hz: 24_000_000,|' \
    'fabricated RE-gated value (hwconfig_firmware_fields)'
body_mutant fake-sram-k t603x.rs 's|sram_k: RE_GATED_F32,|sram_k: f32!(0.95),|' \
    'fabricated RE-gated value (hwconfig_firmware_fields)'
body_mutant fake-tiling-control t603x.rs 's|tiling_control: RE_GATED_U32,|tiling_control: 0xa540e,|' \
    'fabricated RE-gated value (hwconfig_firmware_fields)'
body_mutant fake-clustering t603x.rs 's|meta1_blocksize: RE_GATED_PREEMPT_SIZE,|meta1_blocksize: 1,|' \
    'fabricated RE-gated value (hwconfig_firmware_fields)'
body_mutant fake-global-tab t603x.rs 's|global_tab: Some(&\[\]),|global_tab: Some(\&[0, 2, 5, 1]),|' \
    'fabricated RE-gated value (hwconfig_firmware_fields)'
body_mutant fake-io-mapping t603x.rs \
    's|io_mappings: &\[\],|io_mappings: \&[Some(IOMapping::new(0x404d00000, 0x1c000, 0x1c000, true))],|' \
    'fabricated RE-gated value (hwconfig_firmware_fields)'
body_mutant fake-sram-base t603x.rs 's|sram_base: Some(0x0_0),|sram_base: Some(0x0_4060_0000),|' \
    'fabricated RE-gated value (hwconfig_firmware_fields)'
body_mutant undefined-sentinel t603x.rs 's|unk_coef_a: RE_GATED_UNK_COEF,|unk_coef_a: RE_GATED_MISSING_COEF,|' \
    'gated sentinel RE_GATED_MISSING_COEF is not defined by the candidate series'
body_mutant binary-readme-value README.md 's|- hwconfig_unk_coef_a: UNKNOWN|- hwconfig_unk_coef_a: 0b101|' \
    'RE-gated item carries a value without UNKNOWN, TODO(re) or RE_GATED: hwconfig_unk_coef_a'

# --- DT reg/interrupts/unit addresses and power/thermal tuning ----------------
body_mutant fake-dt-reg t6030-gpu.dtsi 's|reg = <FIXTURE_ADT_GATED_GPU_REG>;|reg = <0x4 0x6400000 0x0 0x1000000>; /* TODO(adt) */|' \
    'fabricated ADT-gated value (ADT_GATED resource)'
body_mutant fake-dt-interrupt t6030-gpu.dtsi 's|<AIC_IRQ 0 IRQ_TYPE_LEVEL_HIGH>|<AIC_IRQ 1093 IRQ_TYPE_LEVEL_HIGH>|' \
    'fabricated ADT-gated value (ADT_GATED resource)'
body_mutant unlabeled-dt-interrupt t6030-gpu.dtsi 's|; /\* TODO(adt): NOT a working value \*/|;|' \
    'unlabeled ADT-gated placeholder (ADT_GATED resource)'
body_mutant invented-unit-address t6030-gpu.dtsi 's|gpu: gpu@0 {|gpu: gpu@406400000 {|' \
    'added DT node carries an invented unit address @406400000'
source=$(copy_bodies perf-base-pstate)
insert_after "$source/t6030-gpu.dtsi" 'operating-points-v2 = <&gpu_opp>;' $'\t\tapple,perf-base-pstate = <5>;'
build_fixture "$source" "$tmp/perf-base-pstate"
expect_reject perf-base-pstate "$tmp/perf-base-pstate" 'fabricated RE-gated value (gpu_power_tuning)' \
    't6030-gpu.dtsi: apple,perf-base-pstate'
for property in apple,ppm-kp apple,pwr-filter-a-neg apple,avg-power-ki-only apple,fast-die0-integral-gain; do
    source=$(copy_bodies "tuning-$property")
    insert_after "$source/t6030-gpu.dtsi" 'operating-points-v2 = <&gpu_opp>;' $'\t\t'"$property = <0x1f4>;"
    build_fixture "$source" "$tmp/tuning-$property"
    expect_reject "tuning-$property" "$tmp/tuning-$property" 'fabricated RE-gated value (gpu_power_tuning)' \
        "t6030-gpu.dtsi: $property"
done
body_mutant real-looking-microvolt t6030-gpu.dtsi 's|opp-microvolt = GPU_REPEAT(0);|opp-microvolt = <825000 825000>;|' \
    'fabricated RE-gated value (gpu_opp_dvfs_table)'
body_mutant string-tuning t6030-gpu.dtsi 's|apple,firmware-compat = <0 0 0>;|apple,firmware-compat = "13.5";|' \
    'RE-gated value (apple_firmware_version) is a string literal'

# --- status may never be deleted or set to anything but "disabled" ------------
body_mutant delete-status-override board-gpu-override.dtsi 's|status = "disabled";|/delete-property/ status;|' \
    'DT series deletes a status property (/delete-property/ status)'
body_mutant delete-status-node t6030-gpu.dtsi 's|status = "disabled";$|/delete-property/ status;|' \
    'DT series deletes a status property (/delete-property/ status)'
body_mutant ok-status-override board-gpu-override.dtsi 's|status = "disabled";|status = "ok";|' \
    'DT series sets a status other than "disabled": status = "ok";'
body_mutant macro-status-override board-gpu-override.dtsi 's|status = "disabled";|status = GPU_STATUS;|' \
    'DT series sets a status other than "disabled": status = GPU_STATUS;'
body_mutant enabled-mailbox t6030-gpu.dtsi 's|status = "disabled"; // mailbox|status = "okay"; // mailbox|' \
    'DT series sets a status other than "disabled": status = "okay";'
body_mutant enabled-reserved-memory t6030-gpu.dtsi 's|status = "disabled"; // placeholder|status = "okay";|' \
    'DT series sets a status other than "disabled": status = "okay";'
body_mutant deleted-node board-gpu-override.dtsi 's|status = "disabled";|/delete-node/ subnode;|' \
    'DT series deletes a node or property'
source=$(copy_bodies path-override)
printf '\n&{/soc/gpu@0} {\n\tstatus = "okay";\n};\n' >> "$source/board-gpu-override.dtsi"
build_fixture "$source" "$tmp/path-override"
expect_reject path-override "$tmp/path-override" 'DT series sets a status other than "disabled": status = "okay";'
source=$(copy_bodies conditional-status)
insert_after "$source/t6030-gpu.dtsi" 'operating-points-v2 = <&gpu_opp>;' '#if 0'
edit "$source/t6030-gpu.dtsi" 's|^\(.*\)status = "disabled";$|&\
#endif|'
build_fixture "$source" "$tmp/conditional-status"
expect_reject conditional-status "$tmp/conditional-status" 'preprocessor directive inside an added DT node'

# --- every added DT node goes through the dtc harness, not only gpu@ ---------
source=$(copy_bodies duplicate-unit-address)
edit "$source/t6030-gpu.dtsi" 's|mbox@deadbeef {|mbox@0 {|'
edit "$source/t6030-gpu.dtsi" 's|FIXTURE_ADT_GATED_MBOX_REG 0x0 0xdeadbeef 0x0 0x0|FIXTURE_ADT_GATED_MBOX_REG 0x0 0x0 0x0 0x0|'
build_fixture "$source" "$tmp/duplicate-unit-address"
expect_reject duplicate-unit-address "$tmp/duplicate-unit-address" 'candidate DT overlay harness has 1 dtc warning(s)'
grep -Fq 'unique_unit_address' "$tmp/duplicate-unit-address.err" || {
    printf 'duplicate unit address was not reported by dtc\n' >&2
    exit 1
}
body_mutant mailbox-syntax t6030-gpu.dtsi 's|compatible = "apple,asc-mailbox-v4";|compatible = "apple,asc-mailbox-v4"|' \
    'candidate DT overlay failed the bounded dtc syntax check'
body_mutant opp-float t6030-gpu.dtsi 's|opp-hz = /bits/ 64 <0>;|opp-hz = /bits/ 64 <0.5>;|' \
    'added DT node carries a float cell literal'
body_mutant mailbox-unresolved t6030-gpu.dtsi 's|reg = <FIXTURE_ADT_GATED_MBOX_REG>;|reg = <FIXTURE_UNDEFINED_REG>;|' \
    'unresolved preprocessor macro in added DT node: FIXTURE_UNDEFINED_REG'

# --- patch scope covers every path-bearing header -----------------------------
scope_mutant() {
    local name=$1 section=$2 expected=$3 mutant
    mutant=$(copy_project "$name")
    printf '%s\n' "$section" >> "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch"
    expect_reject "$name" "$mutant" "$expected"
}
mutant=$(copy_project diff-git-out-of-scope)
edit "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch" \
    's|^diff --git a/drivers/gpu/drm/asahi/driver.rs b/drivers/gpu/drm/asahi/driver.rs$|diff --git a/kernel/sched.c b/kernel/sched.c|'
expect_reject diff-git-out-of-scope "$mutant" \
    'patch touches a path outside the GPU candidate scope in diff --git header: kernel/sched.c'
readonly in_scope=drivers/gpu/drm/asahi/hw
scope_mutant rename-out-of-scope \
    "diff --git a/$in_scope/t603x.rs b/$in_scope/t603y.rs"$'\nsimilarity index 100%\n'"rename from $in_scope/t603x.rs"$'\nrename to kernel/t603y.rs' \
    'patch touches a path outside the GPU candidate scope in rename to: kernel/t603y.rs'
scope_mutant copy-out-of-scope \
    "diff --git a/$in_scope/t603x.rs b/$in_scope/t603y.rs"$'\nsimilarity index 100%\n'"copy from $in_scope/t603x.rs"$'\ncopy to kernel/sched.c' \
    'patch touches a path outside the GPU candidate scope in copy to: kernel/sched.c'
scope_mutant rename-mismatch \
    "diff --git a/$in_scope/t603x.rs b/$in_scope/t603y.rs"$'\nsimilarity index 100%\n'"rename from $in_scope/t603x.rs"$'\n'"rename to $in_scope/t603z.rs" \
    'rename to differs from the diff --git header'
scope_mutant symlink-file "diff --git a/$in_scope/link.rs b/$in_scope/link.rs"$'\nnew file mode 120000\n--- /dev/null\n'"+++ b/$in_scope/link.rs"$'\n@@ -0,0 +1 @@\n+../../../../../kernel/sched.c' \
    'non-regular file mode 120000'
scope_mutant mode-change "diff --git a/$in_scope/t603x.rs b/$in_scope/t603x.rs"$'\nold mode 100644\nnew mode 100755' \
    'file mode change'
scope_mutant git-binary "diff --git a/$in_scope/blob.bin b/$in_scope/blob.bin"$'\nnew file mode 100644\nGIT binary patch\nliteral 0\nHcmV?d00001\n' \
    'binary patch section'
scope_mutant binary-out-of-scope \
    "diff --git a/$in_scope/blob.bin b/$in_scope/blob.bin"$'\nnew file mode 100644\nBinary files /dev/null and b/firmware/agx.bin differ' \
    'patch touches a path outside the GPU candidate scope in binary section: firmware/agx.bin'
scope_mutant header-mismatch "diff --git a/$in_scope/t603x.rs b/$in_scope/t603x.rs"$'\n'"--- a/$in_scope/t603x.rs"$'\n'"+++ b/$in_scope/t602x.rs"$'\n@@ -1 +1,2 @@\n // SPDX-License-Identifier: GPL-2.0-only OR MIT\n+' \
    '+++ path differs from the diff --git header'
mutant=$(copy_project bare-file-header)
edit "$mutant/patches/linux-gpu-development/02-t6030-hwconfig.patch" '/^diff --git a\/drivers\/gpu\/drm\/asahi\/driver.rs/d'
expect_reject bare-file-header "$mutant" 'file header without diff --git'

# --- the repository's real candidate, and mutants of it -----------------------
real_series=("$project_root"/patches/linux-gpu-development*)
if [[ -f ${real_series[0]}/series ]]; then
    readonly real="$tmp/real"
    mkdir -p "$real/config" "$real/scripts" "$real/patches"
    cp -p -- "$verifier" "$real/scripts/verify-m4-gpu-source-candidate.sh"
    cp -p -- "$profile" "$real/config/milestone4-gpu-silicon-profile.tsv"
    cp -pR -- "${real_series[@]}" "$real/patches/"
    readonly real_dt="patches/linux-gpu-development/01-t6030-gpu-base-node.patch"
    readonly real_override="patches/linux-gpu-development/03-t6030-gpu-compatible.patch"
    readonly real_hw="patches/linux-gpu-development-driver/01-g15-t6030-hw-scaffold.patch"
    real_mutant() { cp -pR -- "$real" "$tmp/$1"; printf '%s\n' "$tmp/$1"; }
    real_lines=('tooling_valid=true' 'evidence_valid=not-provided' 'hardware_acceptance=false'
        'forbidden_success_tokens=absent' 'gpu_node_status=disabled' 'dt_overlay_dtc_warnings=0')
    expect_blocked real-static "$real" "${real_lines[@]}" 'patch_replay=not-run'
    if [[ -n $linux_pin && -d $linux_pin ]]; then
        pin_for_run=$linux_pin
        expect_blocked real-replayed "$real" "${real_lines[@]}" 'patch_replay=git-am-clean' 'patch_replay_patches=6' \
            'board_dtb_t6030-j514s=built,baseline_warnings=7,patched_warnings=7,new_warnings=0,gpu_status=disabled' \
            'board_dtb_t6030-j516s=built,baseline_warnings=7,patched_warnings=7,new_warnings=0,gpu_status=disabled' \
            'board_dtc_new_warnings=0'
    fi
    mutant=$(real_mutant real-binary-mask)
    edit "$mutant/$real_hw" 's|fast_sensor_mask: \[RE_GATED_U64; 2\],|fast_sensor_mask: [0b1111_0000_1111, 0],|'
    expect_reject real-binary-mask "$mutant" 'fabricated RE-gated value (temp_sensor_mask)'
    mutant=$(real_mutant real-octal-preempt)
    edit "$mutant/$real_hw" 's|preempt1_size: RE_GATED_USIZE,|preempt1_size: 0o7740,|'
    expect_reject real-octal-preempt "$mutant" 'fabricated RE-gated value (preempt_buffer_sizes)'
    mutant=$(real_mutant real-delete-status)
    patch_insert_after "$mutant/$real_override" \
        $'+\tcompatible = "apple,agx-t6030", "apple,agx-g15x", "apple,agx-g15s";' $'+\t/delete-property/ status;'
    expect_reject real-delete-status "$mutant" 'DT series deletes a status property (/delete-property/ status)'
    mutant=$(real_mutant real-out-of-scope)
    edit "$mutant/patches/linux-gpu-development/02-t6030-gpu-board-wiring.patch" \
        's|^diff --git a/arch/arm64/boot/dts/apple/t6030.dtsi b/arch/arm64/boot/dts/apple/t6030.dtsi$|diff --git a/kernel/sched.c b/kernel/sched.c|'
    expect_reject real-out-of-scope "$mutant" \
        'patch touches a path outside the GPU candidate scope in diff --git header: kernel/sched.c'
    mutant=$(real_mutant real-perf-base-pstate)
    patch_insert_after "$mutant/$real_dt" $'+\t\toperating-points-v2 = <&gpu_opp>;' $'+\t\tapple,perf-base-pstate = <5>;'
    expect_reject real-perf-base-pstate "$mutant" 'fabricated RE-gated value (gpu_power_tuning)' \
        't6030-gpu.dtsi: apple,perf-base-pstate'
    mutant=$(real_mutant real-microvolt)
    edit "$mutant/$real_dt" $'s|^+\t\t\topp-microvolt = <RE_GATED_T6030_AGX_OPP_MICROVOLT$|+\t\t\topp-microvolt = <825000 825000>;|'
    edit "$mutant/$real_dt" $'s|^+\t\t\t\t\t RE_GATED_T6030_AGX_OPP_MICROVOLT>;$|+|'
    expect_reject real-microvolt "$mutant" 'fabricated RE-gated value (gpu_opp_dvfs_table)' 't6030-gpu.dtsi: opp-microvolt'
    mutant=$(real_mutant real-duplicate-unit-address)
    edit "$mutant/$real_dt" 's|0x0 0xdeadbeef 0x0 0x0|0x0 0x0 0x0 0x0|'
    edit "$mutant/$real_dt" 's|mbox@deadbeef {|mbox@0 {|'
    expect_reject real-duplicate-unit-address "$mutant" 'dtc warning'
    if [[ -n ${pin_for_run-} ]]; then
        # Defects only a replay onto the pinned tree and a full-board build see.
        mutant=$(real_mutant real-merges-existing-node)
        edit "$mutant/$real_dt" 's|gpu_globals: globals {|gpu_globals: isp-heap {|'
        expect_reject real-merges-existing-node "$mutant" \
            'board t6030-j514s changes the status of existing node /reserved-memory/isp-heap'
        mutant=$(real_mutant real-label-collision)
        edit "$mutant/$real_dt" 's|gpu_hw_cal_a: hw-cal-a {|isp: hw-cal-a {|'
        expect_reject real-label-collision "$mutant" 'patched board does not build: t6030-j514s'
        mutant=$(real_mutant real-stale-context)
        edit "$mutant/patches/linux-gpu-development/02-t6030-gpu-board-wiring.patch" \
            's|^ #include "t6030-pmgr.dtsi"$| #include "t6030-pmgr-stale.dtsi"|'
        expect_reject real-stale-context "$mutant" 'patch series does not git-am cleanly onto pinned commit'
        unset pin_for_run
        printf 'real_candidate_patch_replay=checked\n'
    else
        printf 'real_candidate_patch_replay=skipped_no_pinned_linux_tree\n'
    fi
else
    printf 'real_candidate=skipped_no_series\n'
fi

printf 'rejected_fixtures=%s\n' "$rejected"
printf 'M4-gpu-candidate-tests=passed\n'
