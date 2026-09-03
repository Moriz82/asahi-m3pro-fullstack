#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$project_root/config/milestone0.env"
source "$project_root/config/milestones.env"
source "$project_root/scripts/lib/evidence.sh"
source "$project_root/scripts/lib/milestone0-components.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/asahi-m0-integrity.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }

# When a real M0 baseline is available, exercise the complete handoff path,
# including the mapped physical run directories and a rehashed altered map.
canonical_root="${MILESTONE0_OUTPUT_ROOT:-$project_root/out}/milestone0"
if [[ "${M0_INTEGRITY_REAL:-0}" == 1 && -d "$canonical_root" && -L "$canonical_root/m1n1/latest" &&
    -L "$canonical_root/u-boot/latest" && -L "$canonical_root/linux-dtb/latest" &&
    -L "$canonical_root/linux-full/latest" && -L "$canonical_root/linux-packages/latest" &&
    -L "$canonical_root/boot-payload/latest" &&
    -f "$canonical_root/boot-payload/latest/manifest.txt" ]] &&
    grep -Eq '^m1n1_source_run_id=.+$' "$canonical_root/boot-payload/latest/manifest.txt"; then
    prior_payload_pointer=$(readlink "$canonical_root/boot-payload/latest")
    expect_fail env M0_PAYLOAD_VERIFY_FORCE_FAILURE=1 \
        "$project_root/scripts/assemble-boot-payload.sh" \
        "$canonical_root/m1n1/latest" "$canonical_root/linux-dtb/latest" "$canonical_root/u-boot/latest"
    test "$(readlink "$canonical_root/boot-payload/latest")" = "$prior_payload_pointer"
    handoff="$MILESTONE_HANDOFF_ROOT/M0-integrity-test.$$"
    "$project_root/scripts/create-milestone-handoff.sh" --milestone M0 \
        --source "$canonical_root" --out "$handoff" >/dev/null
    "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$handoff" >/dev/null
    test -d "$handoff/source/m0/m1n1/$(basename "$(cd -P "$canonical_root/m1n1/latest" && pwd -P)")"
    bad_handoff="$MILESTONE_HANDOFF_ROOT/M0-integrity-bad.$$"
    cp -R -- "$handoff" "$bad_handoff"
    map="$bad_handoff/source/m0/component-map.tsv"
    sed -i.bak $'s/^m1n1\t[^\t]*/m1n1\taltered-run-id/' "$map"; rm -f "$map.bak"
    map_hash=$(evidence_sha256 "$map"); map_size=$(wc -c < "$map" | tr -d '[:space:]')
    awk -F '\t' -v OFS='\t' -v h="$map_hash" -v s="$map_size" \
        '$1 == "source/m0/component-map.tsv" {$3=h; $4=s} {print}' \
        "$bad_handoff/inventory.tsv" > "$bad_handoff/inventory.new"
    mv "$bad_handoff/inventory.new" "$bad_handoff/inventory.tsv"
    inventory_hash=$(evidence_sha256 "$bad_handoff/inventory.tsv")
    sed -i.bak "s/^source_inventory_sha256=.*/source_inventory_sha256=$inventory_hash/" \
        "$bad_handoff/manifest.txt"; rm -f "$bad_handoff/manifest.txt.bak"
    evidence_write_sums "$bad_handoff" "$bad_handoff/SHA256SUMS"
    expect_fail "$project_root/scripts/verify-milestone-handoff.sh" --bundle "$bad_handoff"
    rm -rf -- "$handoff" "$bad_handoff"
else
    printf 'M0 handoff end-to-end fixture skipped: enable M0_INTEGRITY_REAL=1 with a fresh canonical baseline\n'
fi

# The component freezer must reject a deterministic latest-pointer flip.
canonical="$tmp/canonical"; mkdir -p "$canonical"
for component in "${m0_component_names[@]}"; do
    mkdir -p "$canonical/$component/run-a" "$canonical/$component/run-b"
    ln -s run-a "$canonical/$component/latest"
done
(
    readonly root="$canonical"
    evidence_path_under "$canonical/m1n1" "$canonical"
    IFS=$'\t' read -r readonly_pointer readonly_resolved < <(m0_component_snapshot "$canonical" m1n1)
    m0_component_assert_unchanged "$canonical" m1n1 "$readonly_pointer" "$readonly_resolved"
)
IFS=$'\t' read -r pointer resolved < <(m0_component_snapshot "$canonical" m1n1)
rm "$canonical/m1n1/latest"; ln -s run-b "$canonical/m1n1/latest"
expect_fail m0_component_assert_unchanged "$canonical" m1n1 "$pointer" "$resolved"

# Exercise payload binding with small source snapshots.  Rewriting aggregate
# checksums must not make stale or rehashed payload content acceptable.
payload="$tmp/payload"; mkdir "$payload"
m1="$tmp/m1n1"; dtb="$tmp/linux-dtb"; ub="$tmp/u-boot"
mkdir -p "$m1/run-m1" "$dtb/run-dtb" "$ub/run-ub"
printf 'format=1\nsource_commit=%s\n' "$M1N1_COMMIT" > "$m1/run-m1/manifest.txt"
printf 'm1n1-bytes\n' > "$m1/run-m1/m1n1.macho"
printf 'format=1\nsource_commit=%s\n' "$LINUX_COMMIT" > "$dtb/run-dtb/manifest.txt"
printf 'dtb-bytes\n' > "$dtb/run-dtb/t6030-j514s.dtb"
printf 'format=1\nsource_commit=%s\n' "$UBOOT_COMMIT" > "$ub/run-ub/manifest.txt"
printf 'u-boot-bytes\n' > "$ub/run-ub/u-boot-nodtb.bin"
cp "$m1/run-m1/m1n1.macho" "$payload/m1n1.macho"
cp "$dtb/run-dtb/t6030-j514s.dtb" "$payload/t6030-j514s.dtb"
cp "$ub/run-ub/u-boot-nodtb.bin" "$payload/u-boot-nodtb.bin"
cp "$m1/run-m1/manifest.txt" "$payload/m1n1-manifest.txt"
cp "$dtb/run-dtb/manifest.txt" "$payload/linux-dtb-manifest.txt"
cp "$ub/run-ub/manifest.txt" "$payload/u-boot-manifest.txt"
cat "$payload/m1n1.macho" "$payload/t6030-j514s.dtb" "$payload/u-boot-nodtb.bin" > "$payload/$BOOT_PAYLOAD"
m1_size=$(wc -c < "$payload/m1n1.macho" | tr -d ' ')
dtb_size=$(wc -c < "$payload/t6030-j514s.dtb" | tr -d ' ')
ub_size=$(wc -c < "$payload/u-boot-nodtb.bin" | tr -d ' ')
cat > "$payload/manifest.txt" <<EOF
format=1
target=Mac15,6/J514s/T6030
status=build-verified-not-hardware-booted
payload=$BOOT_PAYLOAD
layout=m1n1.macho+t6030-j514s.dtb+u-boot-nodtb.bin
m1n1_commit=$M1N1_COMMIT
linux_commit=$LINUX_COMMIT
u_boot_commit=$UBOOT_COMMIT
m1n1_source_run_id=run-m1
m1n1_source_manifest_sha256=$(evidence_sha256 "$m1/run-m1/manifest.txt")
linux_dtb_source_run_id=run-dtb
linux_dtb_source_manifest_sha256=$(evidence_sha256 "$dtb/run-dtb/manifest.txt")
u_boot_source_run_id=run-ub
u_boot_source_manifest_sha256=$(evidence_sha256 "$ub/run-ub/manifest.txt")
m1n1_offset=0
m1n1_size=$m1_size
dtb_offset=$m1_size
dtb_size=$dtb_size
u_boot_offset=$((m1_size + dtb_size))
u_boot_size=$ub_size
total_size=$((m1_size + dtb_size + ub_size))
EOF
printf '%s: Mach-O 64-bit arm64\n' "$BOOT_PAYLOAD" > "$payload/file.txt"
(
    cd "$payload"
    shasum -a 256 "$BOOT_PAYLOAD" file.txt linux-dtb-manifest.txt m1n1-manifest.txt \
        m1n1.macho manifest.txt t6030-j514s.dtb u-boot-manifest.txt u-boot-nodtb.bin > SHA256SUMS
)

"$project_root/scripts/verify-boot-payload.sh" "$payload" \
    --m1n1-source "$m1/run-m1" --linux-dtb-source "$dtb/run-dtb" --u-boot-source "$ub/run-ub" >/dev/null
printf 'stale_source: '
printf 'stale\n' >> "$m1/run-m1/manifest.txt"
expect_fail "$project_root/scripts/verify-boot-payload.sh" "$payload" \
    --m1n1-source "$m1/run-m1" --linux-dtb-source "$dtb/run-dtb" --u-boot-source "$ub/run-ub"
printf 'rehashed_payload: '
cp "$payload/m1n1-manifest.txt" "$m1/run-m1/manifest.txt"
printf 'tampered\n' >> "$payload/m1n1.macho"
(
    cd "$payload"
    shasum -a 256 "$BOOT_PAYLOAD" file.txt linux-dtb-manifest.txt m1n1-manifest.txt \
        m1n1.macho manifest.txt t6030-j514s.dtb u-boot-manifest.txt u-boot-nodtb.bin > SHA256SUMS
)
expect_fail "$project_root/scripts/verify-boot-payload.sh" "$payload" \
    --m1n1-source "$m1/run-m1" --linux-dtb-source "$dtb/run-dtb" --u-boot-source "$ub/run-ub"

assembly_script="$project_root/scripts/assemble-boot-payload.sh"
verify_line=$(grep -nF 'verify-boot-payload.sh" "$stage"' "$assembly_script" | cut -d: -f1)
move_line=$(grep -nF 'mv "$stage" "$destination"' "$assembly_script" | cut -d: -f1)
publish_line=$(grep -nF 'atomic_symlink_replace "$run_id" "$latest"' "$assembly_script" | cut -d: -f1)
test -n "$verify_line" && test -n "$move_line" && test -n "$publish_line"
test "$verify_line" -lt "$move_line" && test "$move_line" -lt "$publish_line"
printf 'passed\n'
printf 'milestone0 integrity tests passed\n'
