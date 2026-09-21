#!/usr/bin/env bash
# M9 static safety self-tests; all state lives in a disposable project output.
# shellcheck disable=SC1091,SC2016,SC2100,SC2174
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
test_root=${TEST_OUTPUT_ROOT:-$project_root/out}
mkdir -p -m 700 "$test_root"
tmp=$(mktemp -d "$test_root/m9-tools.XXXXXX")
anchor_tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/m9-anchors.XXXXXX")" && pwd -P)
m1_target=$(printf '%064d' 1)
m1_anchors="$anchor_tmp/independent-m1-anchors.txt"
printf '%064d\n' 2 >"$m1_anchors"
m1_args=(--expected-target-identity-sha256 "$m1_target" --target-readiness-anchors "$m1_anchors")
trap 'rm -rf -- "$tmp" "$anchor_tmp"' EXIT
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
expect_fail_no_output() { local out=$1; shift; expect_fail "$@"; [[ ! -e "$out" && ! -L "$out" ]] || { printf 'failed command emitted output: %s\n' "$out" >&2; exit 1; }; }
atomic_source="$tmp/atomic-source"; atomic_destination="$tmp/atomic-destination"
mkdir -m 700 -- "$atomic_source" "$atomic_destination"
printf 'source\n' > "$atomic_source/source.txt"; printf 'destination\n' > "$atomic_destination/sentinel.txt"
expect_fail evidence_atomic_publish_directory "$atomic_source" "$atomic_destination"
[[ $(cat "$atomic_source/source.txt") == source && $(cat "$atomic_destination/sentinel.txt") == destination ]] || { printf 'atomic no-replace collision changed source or destination\n' >&2; exit 1; }
[[ $(find -P "$atomic_destination" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]') == 1 ]] || { printf 'atomic no-replace collision added destination members\n' >&2; exit 1; }
input="$tmp/input"; cp -R -- "$project_root/tests/fixtures/m9/release-inputs" "$input"
{
    printf 'milestone\tmanifest\tmanifest_sha256\thardware_acceptance\tnative_readiness\tbackup_recovery\tdfu\tdedicated_hardware\n'
    for m in M0 M1 M2 M3 M4 M5 M6 M7 M8; do
        hash=$(evidence_sha256 "$input/$m/manifest.txt")
        printf '%s\t%s/manifest.txt\t%s\tfalse\tfalse\tfalse\tfalse\tfalse\n' "$m" "$m" "$hash"
    done
} > "$input/release-inputs.tsv"
release_anchor="$anchor_tmp/release-anchor.txt"
{
    printf 'format=1\nanchor_type=external-release-inputs\nanchor_trust=untrusted-declarative\ntarget_model=Mac15,6\ntarget_board=J514s\ntarget_soc=T6030\n'
    for m in M0 M1 M2 M3 M4 M5 M6 M7 M8; do
        printf '%s_manifest_sha256=%s\n' "$m" "$(evidence_sha256 "$input/$m/manifest.txt")"
        for key in hardware_acceptance native_readiness backup_recovery dfu dedicated_hardware; do printf '%s_%s=false\n' "$m" "$key"; done
    done
} > "$release_anchor"; chmod a-w "$release_anchor"
legacy_out="$tmp/legacy-release"
expect_fail "$project_root/scripts/validate-m9-release-inputs.sh" "${m1_args[@]}" --inputs "$input" --anchor "$release_anchor" --out "$legacy_out"
[[ ! -e "$legacy_out" ]] || { printf 'removed --inputs path emitted output\n' >&2; exit 1; }
write_trace() {
    local file=$1 branch=$2 final=$3
    {
        printf 'sequence\tfrom_state\taction\tto_state\trequired_evidence\n'
        printf '1\tnew\tpreflight\tpreflighted\tidentity-readiness\n2\tpreflighted\tverify-source\tsource-verified\texternal-source-anchor\n3\tsource-verified\tverify-payload\tpayload-verified\texternal-payload-anchor\n4\tpayload-verified\treview-free-space\tspace-reviewed\treviewed-free-space\n5\tspace-reviewed\tstage-install\tinstall-staged\tdeclarative-install-plan\n'
        printf '6\tinstall-staged\t%s\t%s\trecovery-plan\n7\t%s\trecord-recovery\trecovery-recorded\trecovery-proof\n8\trecovery-recorded\trecord-dfu-evidence\tdfu-evidence-recorded\tdfu-attestation\n' "$branch" "$final" "$final"
    } > "$file"
}
# Missing explicit M1 anchors must fail before any release work, even if the
# same names were supplied through the environment.
for entrypoint in validate-m9-release-inputs create-m9-recovery-plan verify-m9-recovery-plan simulate-m9-installer-state-machine; do
    if M9_EXPECTED_TARGET="$m1_target" M9_TARGET_ANCHORS="$m1_anchors" \
        "$project_root/scripts/$entrypoint.sh" >"$tmp/missing-m1-anchors.log" 2>&1; then exit 1; fi
    grep -Fx 'error: M9 requires explicit M1 target identity and independent readiness anchors' "$tmp/missing-m1-anchors.log" >/dev/null
done
# Build a complete repository-owned canonical M0-M8 fixture. The temporary
# verifier checks the canonical envelope; real handoff verification remains
# exercised by verify-milestone-handoff's dedicated tests.
fixture_project="$tmp/canonical-project"; mkdir -p "$fixture_project/scripts/lib" "$fixture_project/config"
for fixture_file in validate-m9-release-inputs.sh create-m9-recovery-plan.sh verify-m9-recovery-plan.sh simulate-m9-installer-state-machine.sh verify-m9-simulation.sh; do cp -p "$project_root/scripts/$fixture_file" "$fixture_project/scripts/$fixture_file"; done
cp -p "$project_root/scripts/lib/evidence.sh" "$fixture_project/scripts/lib/evidence.sh"
cp -p "$project_root/scripts/lib/m9-canonical.sh" "$fixture_project/scripts/lib/m9-canonical.sh"
for fixture_file in milestone9-action-allowlist.txt milestone9-action-denylist.txt milestone9-state-transitions.tsv; do cp -p "$project_root/config/$fixture_file" "$fixture_project/config/$fixture_file"; done
printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'root=$2' 'project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)' 'source "$project_root/scripts/lib/evidence.sh"' '[[ $1 == --bundle ]]' 'if [[ $(evidence_kv "$root/manifest.txt" milestone) == M1 ]]; then' '  [[ $# -eq 6 && $3 == --expected-target-identity-sha256 && $4 == "$(printf "%064d" 1)" && $5 == --target-readiness-anchors && -f $6 ]]' '  [[ $(cat "$6") == "$(printf "%064d" 2)" ]]' 'else [[ $# -eq 2 ]]; fi' 'evidence_abs_dir "$root"' 'for f in manifest.txt inventory.tsv SHA256SUMS; do evidence_abs_regular "$root/$f"; done' 'evidence_verify_sums "$root" "$root/SHA256SUMS"' 'grep -Fx "target_model=Mac15,6" "$root/manifest.txt" >/dev/null' 'grep -Fx "target_board=J514s" "$root/manifest.txt" >/dev/null' 'grep -Fx "target_soc=T6030" "$root/manifest.txt" >/dev/null' 'grep -Fx "evidence_valid=true" "$root/manifest.txt" >/dev/null' 'grep -Fx "tooling_valid=true" "$root/manifest.txt" >/dev/null' 'grep -Fx "hardware_acceptance=false" "$root/manifest.txt" >/dev/null' 'printf "fixture-handoff=verified\\n"' > "$fixture_project/scripts/verify-milestone-handoff.sh"
chmod +x "$fixture_project/scripts/verify-milestone-handoff.sh"
fixture_handoffs="$tmp/canonical-handoffs"; mkdir -p "$fixture_handoffs"
for m in M0 M1 M2 M3 M4 M5 M6 M7 M8; do
    fixture_bundle="$fixture_handoffs/$m"; mkdir -p "$fixture_bundle/source"
    printf 'fixture=%s\n' "$m" > "$fixture_bundle/source/data.txt"
    printf 'path\tkind\tsha256\tsize_bytes\nsource/data.txt\tregular-file\t%s\t%s\n' "$(evidence_sha256 "$fixture_bundle/source/data.txt")" "$(wc -c < "$fixture_bundle/source/data.txt" | tr -d '[:space:]')" > "$fixture_bundle/inventory.tsv"
    (umask 077; {
        printf 'format=1\nmilestone=%s\ntarget_model=Mac15,6\ntarget_board=J514s\ntarget_soc=T6030\nsource_kind=fixture-canonical\nevidence_valid=true\ntooling_valid=true\nhardware_acceptance=false\nnative_readiness=false\nbackup_recovery=false\ndfu=false\ndedicated_hardware=false\nsource_inventory_sha256=%s\nsource_inventory_records=1\nverifier=fixture-handoff.sh\n' "$m" "$(evidence_sha256 "$fixture_bundle/inventory.tsv")"
    } > "$fixture_bundle/manifest.txt")
    evidence_write_sums "$fixture_bundle" "$fixture_bundle/SHA256SUMS"
done
fixture_anchor="$anchor_tmp/canonical-handoffs-anchor.txt"
{
    printf 'format=1\nanchor_type=external-milestone-handoffs\nanchor_trust=untrusted-declarative\ntarget_model=Mac15,6\ntarget_board=J514s\ntarget_soc=T6030\n'
    for m in M0 M1 M2 M3 M4 M5 M6 M7 M8; do printf '%s_handoff_sha256=%s\n' "$m" "$(evidence_sha256 "$fixture_handoffs/$m/SHA256SUMS")"; done
} > "$fixture_anchor"; chmod a-w "$fixture_anchor"
canonical_release="$tmp/canonical-output/canonical-release"
canonical_before=$(evidence_sha256 "$fixture_handoffs/M0/SHA256SUMS")
canonical_mutated="$tmp/canonical-mutated"
(
    pause_marker=
    for _ in $(seq 1 400); do
        pause_marker=$(find -P "$tmp" -type f -name .m9-copy-test-paused -print -quit)
        [[ -z $pause_marker ]] || break
        /bin/sleep 0.01
    done
    [[ -n $pause_marker ]]
    printf changed >> "$fixture_handoffs/M0/SHA256SUMS"
    : > "$canonical_mutated"
) &
canonical_mutator_pid=$!
SOFTWARE_OUTPUT_ROOT="$tmp/canonical-output" MILESTONE_HANDOFF_ROOT="$tmp/canonical-stage" M9_HANDOFF_TEST_PAUSE_AFTER_FIRST_COPY=1 bash "$fixture_project/scripts/validate-m9-release-inputs.sh" "${m1_args[@]}" --handoffs-root "$fixture_handoffs" --anchor "$fixture_anchor" --out "$canonical_release" >/dev/null
wait "$canonical_mutator_pid"
[[ -f $canonical_mutated && $(evidence_sha256 "$fixture_handoffs/M0/SHA256SUMS") != "$canonical_before" ]] || { printf 'canonical copy-pause mutation did not run\n' >&2; exit 1; }
for required in identity.txt release-inputs.tsv canonical-handoff-map.tsv manifest.txt policy.txt SHA256SUMS; do [[ -s "$canonical_release/$required" ]] || exit 1; done
[[ $(evidence_kv "$canonical_release/manifest.txt" format) == 2 && $(evidence_kv "$canonical_release/manifest.txt" release_input_set) == canonical-milestone-handoffs ]] || { printf 'canonical release envelope is not format 2\n' >&2; exit 1; }
for m in M0 M1 M2 M3 M4 M5 M6 M7 M8; do [[ -s "$canonical_release/manifests/$m/manifest.txt" && -s "$canonical_release/handoffs/$m/SHA256SUMS" ]] || exit 1; done
same_root="$tmp/same-root-handoffs"; cp -R -- "$canonical_release/handoffs" "$same_root"
same_initial_out="$tmp/same-root-output/initial-release"
SOFTWARE_OUTPUT_ROOT="$tmp/same-root-output" MILESTONE_HANDOFF_ROOT="$same_root" bash "$fixture_project/scripts/validate-m9-release-inputs.sh" "${m1_args[@]}" --handoffs-root "$same_root" --anchor "$fixture_anchor" --out "$same_initial_out" >/dev/null
[[ -s "$same_initial_out/manifest.txt" ]] || { printf 'same-root canonical run did not publish\n' >&2; exit 1; }
same_invalid_root="$tmp/same-root-invalid"; cp -R -- "$same_root" "$same_invalid_root"; printf tampered >> "$same_invalid_root/M0/SHA256SUMS"
same_retry_out="$tmp/same-root-output/retry-release"
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/same-root-output" MILESTONE_HANDOFF_ROOT="$same_invalid_root" bash "$fixture_project/scripts/validate-m9-release-inputs.sh" "${m1_args[@]}" --handoffs-root "$same_invalid_root" --anchor "$fixture_anchor" --out "$same_retry_out"
[[ ! -e "$same_retry_out" && ! -L "$same_retry_out" ]] || { printf 'invalid same-root handoffs emitted release output\n' >&2; exit 1; }
SOFTWARE_OUTPUT_ROOT="$tmp/same-root-output" MILESTONE_HANDOFF_ROOT="$same_root" bash "$fixture_project/scripts/validate-m9-release-inputs.sh" "${m1_args[@]}" --handoffs-root "$same_root" --anchor "$fixture_anchor" --out "$same_retry_out" >/dev/null
[[ -s "$same_retry_out/manifest.txt" ]] || { printf 'same-root valid retry did not publish\n' >&2; exit 1; }
retry_handoffs="$tmp/retry-handoffs"; cp -R -- "$canonical_release/handoffs" "$retry_handoffs"
invalid_handoffs="$tmp/invalid-handoffs"; cp -R -- "$retry_handoffs" "$invalid_handoffs"; printf tampered >> "$invalid_handoffs/M0/SHA256SUMS"
retry_release="$tmp/canonical-output/retry-release"
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/canonical-output" MILESTONE_HANDOFF_ROOT="$tmp/retry-stage" bash "$fixture_project/scripts/validate-m9-release-inputs.sh" "${m1_args[@]}" --handoffs-root "$invalid_handoffs" --anchor "$fixture_anchor" --out "$retry_release"
[[ ! -e "$retry_release" && ! -L "$retry_release" ]] || { printf 'invalid canonical handoffs emitted release output\n' >&2; exit 1; }
SOFTWARE_OUTPUT_ROOT="$tmp/canonical-output" MILESTONE_HANDOFF_ROOT="$tmp/retry-stage" bash "$fixture_project/scripts/validate-m9-release-inputs.sh" "${m1_args[@]}" --handoffs-root "$retry_handoffs" --anchor "$fixture_anchor" --out "$retry_release" >/dev/null
[[ -s "$retry_release/manifest.txt" ]] || { printf 'valid canonical retry did not publish\n' >&2; exit 1; }
canonical_plan="$tmp/canonical-output/canonical-plan"
SOFTWARE_OUTPUT_ROOT="$tmp/canonical-output" bash "$fixture_project/scripts/create-m9-recovery-plan.sh" "${m1_args[@]}" --release-inputs "$canonical_release" --release-anchor "$fixture_anchor" --authority authorized-operator-review --operator moriz --out "$canonical_plan" >/dev/null
canonical_plan_anchor="$anchor_tmp/canonical-plan-anchor.txt"
printf 'format=1\nanchor_type=external-recovery-plan\nanchor_trust=untrusted-declarative\nplan_sha256=%s\nrelease_anchor_sha256=%s\n' "$(evidence_sha256 "$canonical_plan/plan.txt")" "$(evidence_sha256 "$fixture_anchor")" > "$canonical_plan_anchor"; chmod a-w "$canonical_plan_anchor"
canonical_trace="$tmp/canonical-trace.tsv"; write_trace "$canonical_trace" recover-interrupted-install interrupted-recovery-planned
SOFTWARE_OUTPUT_ROOT="$tmp/canonical-output" bash "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$canonical_release" --release-anchor "$fixture_anchor" --plan "$canonical_plan" --plan-anchor "$canonical_plan_anchor" --transitions "$canonical_trace" --out "$tmp/canonical-output/canonical-simulation" >/dev/null
release="$canonical_release"; release_anchor="$fixture_anchor"; plan="$canonical_plan"; plan_anchor="$canonical_plan_anchor"
export SOFTWARE_OUTPUT_ROOT="$tmp"
forged_release="$tmp/forged-format1-release"; cp -R -- "$release" "$forged_release"
sed -i.bak 's/^format=2$/format=1/' "$forged_release/manifest.txt"; rm -f -- "$forged_release/manifest.txt.bak"
evidence_write_sums "$forged_release" "$forged_release/SHA256SUMS"
forged_plan_out="$tmp/forged-format1-plan-out"
expect_fail "$fixture_project/scripts/create-m9-recovery-plan.sh" "${m1_args[@]}" --release-inputs "$forged_release" --release-anchor "$release_anchor" --authority authorized-operator-review --operator moriz --out "$forged_plan_out"
[[ ! -e "$forged_plan_out" ]] || { printf 'forged format-1 release emitted recovery plan\n' >&2; exit 1; }
forged_plan="$tmp/forged-format1-plan"; cp -R -- "$plan" "$forged_plan"
forged_release_digest=$(evidence_sha256 "$forged_release/manifest.txt")
sed -i.bak "s/^release_inputs_sha256=.*/release_inputs_sha256=$forged_release_digest/" "$forged_plan/plan.txt"; rm -f -- "$forged_plan/plan.txt.bak"
evidence_write_sums "$forged_plan" "$forged_plan/SHA256SUMS"
forged_plan_anchor="$anchor_tmp/forged-plan-anchor.txt"
printf 'format=1\nanchor_type=external-recovery-plan\nanchor_trust=untrusted-declarative\nplan_sha256=%s\nrelease_anchor_sha256=%s\n' "$(evidence_sha256 "$forged_plan/plan.txt")" "$(evidence_sha256 "$release_anchor")" > "$forged_plan_anchor"; chmod a-w "$forged_plan_anchor"
expect_fail "$fixture_project/scripts/verify-m9-recovery-plan.sh" "${m1_args[@]}" --plan "$forged_plan" --release-inputs "$forged_release" --release-anchor "$release_anchor" --anchor "$forged_plan_anchor"
forged_simulation_out="$tmp/forged-format1-simulation-out"
expect_fail_no_output "$forged_simulation_out" "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$forged_release" --release-anchor "$release_anchor" --plan "$forged_plan" --plan-anchor "$forged_plan_anchor" --transitions "$project_root/config/milestone9-state-transitions.tsv" --out "$forged_simulation_out"
self_bad="$tmp/self-bad"; cp -R -- "$release" "$self_bad"; printf 'anchor-copy\n' > "$self_bad/anchor-copy.txt"; evidence_write_sums "$self_bad" "$self_bad/SHA256SUMS"
expect_fail_no_output "$tmp/self-out" "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$self_bad" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$project_root/config/milestone9-state-transitions.tsv" --out "$tmp/self-out"
for branch in recover-interrupted-install plan-reinstall plan-update plan-rollback plan-removal; do
    case $branch in recover-interrupted-install) final=interrupted-recovery-planned;; plan-reinstall) final=reinstall-planned;; plan-update) final=update-planned;; plan-rollback) final=rollback-planned;; plan-removal) final=removal-planned;; esac
    trace="$tmp/$branch.tsv"; write_trace "$trace" "$branch" "$final"
    "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$trace" --out "$tmp/out-$branch" >/dev/null
done
positive="$tmp/recover-interrupted-install.tsv"; simulation="$tmp/out-recover-interrupted-install"
release_digest=$(evidence_sha256 "$release/manifest.txt"); plan_digest=$(evidence_sha256 "$plan/plan.txt")
"$fixture_project/scripts/verify-m9-simulation.sh" --simulation "$simulation" --release-sha256 "$release_digest" --plan-sha256 "$plan_digest" >/dev/null
sim_bad="$tmp/sim-bad"; cp -R -- "$simulation" "$sim_bad"; sed -i.bak 's/^release_inputs_sha256=.*/release_inputs_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$sim_bad/simulation.txt"; rm -f -- "$sim_bad/simulation.txt.bak"; evidence_write_sums "$sim_bad" "$sim_bad/SHA256SUMS"
expect_fail "$fixture_project/scripts/verify-m9-simulation.sh" --simulation "$sim_bad" --release-sha256 "$release_digest" --plan-sha256 "$plan_digest"
trace_bad="$tmp/trace-bad"; cp -R -- "$simulation" "$trace_bad"; sed -i.bak 's/verify-source/unknown/' "$trace_bad/transitions.tsv"; rm -f -- "$trace_bad/transitions.tsv.bak"; evidence_write_sums "$trace_bad" "$trace_bad/SHA256SUMS"
expect_fail "$fixture_project/scripts/verify-m9-simulation.sh" --simulation "$trace_bad" --release-sha256 "$release_digest" --plan-sha256 "$plan_digest"
extra_bad="$tmp/extra-bad"; cp -R -- "$simulation" "$extra_bad"; printf 'extra\n' > "$extra_bad/extra.txt"; evidence_write_sums "$extra_bad" "$extra_bad/SHA256SUMS"
expect_fail "$fixture_project/scripts/verify-m9-simulation.sh" --simulation "$extra_bad" --release-sha256 "$release_digest" --plan-sha256 "$plan_digest"
symlink_bad="$tmp/symlink-bad"; cp -R -- "$simulation" "$symlink_bad"; ln -s "$simulation/simulation.txt" "$symlink_bad/link.txt"; evidence_write_sums "$symlink_bad" "$symlink_bad/SHA256SUMS"
expect_fail "$fixture_project/scripts/verify-m9-simulation.sh" --simulation "$symlink_bad" --release-sha256 "$release_digest" --plan-sha256 "$plan_digest"
unsafe="$tmp/unsafe.tsv"; cp -p -- "$positive" "$unsafe"; sed -i.bak 's/1\tnew\tpreflight/1\tnew\texecute-install/' "$unsafe"; rm -f -- "$unsafe.bak"
expect_fail_no_output "$tmp/unsafe-out" "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$unsafe" --out "$tmp/unsafe-out"
unknown="$tmp/unknown.tsv"; cp -p -- "$positive" "$unknown"; sed -i.bak 's/2\tpreflighted\tverify-source/2\tpreflighted\tunknown/' "$unknown"; rm -f -- "$unknown.bak"
expect_fail_no_output "$tmp/unknown-out" "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$unknown" --out "$tmp/unknown-out"
duplicate="$tmp/duplicate.tsv"; cp -p -- "$positive" "$duplicate"; sed -i.bak 's/^2\t/1\t/' "$duplicate"; rm -f -- "$duplicate.bak"
expect_fail_no_output "$tmp/duplicate-out" "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$duplicate" --out "$tmp/duplicate-out"
outorder="$tmp/outorder.tsv"; cp -p -- "$positive" "$outorder"; sed -i.bak 's/^2\tpreflighted\tverify-source/3\tpreflighted\tverify-source/' "$outorder"; rm -f -- "$outorder.bak"
expect_fail_no_output "$tmp/outorder-out" "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$outorder" --out "$tmp/outorder-out"
apfs="$tmp/apfs.tsv"; cp -p -- "$positive" "$apfs"; sed -i.bak 's/external-source-anchor/apfs/' "$apfs"; rm -f -- "$apfs.bak"
expect_fail_no_output "$tmp/apfs-out" "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$apfs" --out "$tmp/apfs-out"
existing="$tmp/existing.tsv"; cp -p -- "$positive" "$existing"; sed -i.bak 's/external-source-anchor/existing-container/' "$existing"; rm -f -- "$existing.bak"
expect_fail_no_output "$tmp/existing-out" "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$existing" --out "$tmp/existing-out"
removal="$tmp/removal.tsv"; cp -p -- "$positive" "$removal"; sed -i.bak 's/recover-interrupted-install/remove-macos/' "$removal"; rm -f -- "$removal.bak"
expect_fail_no_output "$tmp/removal-out" "$fixture_project/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$removal" --out "$tmp/removal-out"
mutable="$anchor_tmp/mutable-anchor.txt"; cp -p -- "$release_anchor" "$mutable"; chmod u+w "$mutable"
expect_fail "$project_root/scripts/validate-m9-release-inputs.sh" "${m1_args[@]}" --handoffs-root "$fixture_handoffs" --anchor "$mutable" --out "$tmp/mutable-out"
bad_plan="$tmp/bad-plan"; cp -R -- "$plan" "$bad_plan"; sed -i.bak 's/^dfu_required=true$/dfu_required=false/' "$bad_plan/plan.txt"; rm -f -- "$bad_plan/plan.txt.bak"; evidence_write_sums "$bad_plan" "$bad_plan/SHA256SUMS"
bad_anchor="$anchor_tmp/bad-anchor.txt"; printf 'format=1\nanchor_type=external-recovery-plan\nanchor_trust=untrusted-declarative\nplan_sha256=%s\nrelease_anchor_sha256=%s\n' "$(evidence_sha256 "$bad_plan/plan.txt")" "$(evidence_sha256 "$release_anchor")" > "$bad_anchor"; chmod a-w "$bad_anchor"
expect_fail "$fixture_project/scripts/verify-m9-recovery-plan.sh" "${m1_args[@]}" --plan "$bad_plan" --release-inputs "$release" --release-anchor "$release_anchor" --anchor "$bad_anchor"
unsafe_authority_out="$tmp/unsafe-authority-out"; expect_fail "$fixture_project/scripts/create-m9-recovery-plan.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --authority 'diskutil apfs erase' --operator moriz --out "$unsafe_authority_out"; [[ ! -e "$unsafe_authority_out" ]]
unsafe_operator_out="$tmp/unsafe-operator-out"; expect_fail "$fixture_project/scripts/create-m9-recovery-plan.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --authority authorized-operator-review --operator 'bad operator' --out "$unsafe_operator_out"; [[ ! -e "$unsafe_operator_out" ]]
mixed_case_out="$tmp/mixed-case-out"; expect_fail "$fixture_project/scripts/create-m9-recovery-plan.sh" "${m1_args[@]}" --release-inputs "$release" --release-anchor "$release_anchor" --authority DiSkUtIl --operator moriz --out "$mixed_case_out"; [[ ! -e "$mixed_case_out" ]]
self_bad="$tmp/self-bad"; cp -R -- "$release" "$self_bad"; printf 'anchor-copy\n' > "$self_bad/anchor-copy.txt"; evidence_write_sums "$self_bad" "$self_bad/SHA256SUMS"
expect_fail "$project_root/scripts/simulate-m9-installer-state-machine.sh" "${m1_args[@]}" --release-inputs "$self_bad" --release-anchor "$release_anchor" --plan "$plan" --plan-anchor "$plan_anchor" --transitions "$project_root/config/milestone9-state-transitions.tsv" --out "$tmp/self-out"
[[ ! -e "$tmp/self-out" ]] || { printf 'tampered release emitted simulation output\n' >&2; exit 1; }
canonical_tampered="$tmp/canonical-output/canonical-tampered"; cp -R "$canonical_release" "$canonical_tampered"
printf tampered >> "$canonical_tampered/handoffs/M0/SHA256SUMS"; evidence_write_sums "$canonical_tampered" "$canonical_tampered/SHA256SUMS"
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/canonical-output" bash "$fixture_project/scripts/create-m9-recovery-plan.sh" "${m1_args[@]}" --release-inputs "$canonical_tampered" --release-anchor "$fixture_anchor" --authority authorized-operator-review --operator moriz --out "$tmp/canonical-output/tampered-plan"
standalone_tampered="$tmp/canonical-output/standalone-tampered"; cp -R "$canonical_release" "$standalone_tampered"
sed -i.bak 's/^target_model=Mac15,6$/target_model=Mac15,7/' "$standalone_tampered/manifests/M0/manifest.txt"; rm -f "$standalone_tampered/manifests/M0/manifest.txt.bak"
standalone_hash=$(evidence_sha256 "$standalone_tampered/manifests/M0/manifest.txt")
awk -F '\t' -v OFS='\t' -v h="$standalone_hash" '$1 == "M0" {$3=h} {print}' "$standalone_tampered/release-inputs.tsv" > "$standalone_tampered/release-inputs.new"; mv "$standalone_tampered/release-inputs.new" "$standalone_tampered/release-inputs.tsv"
awk -F '\t' -v OFS='\t' -v h="$standalone_hash" '$1 == "M0" {$3=h} {print}' "$standalone_tampered/canonical-handoff-map.tsv" > "$standalone_tampered/canonical-handoff-map.new"; mv "$standalone_tampered/canonical-handoff-map.new" "$standalone_tampered/canonical-handoff-map.tsv"
map_hash=$(evidence_sha256 "$standalone_tampered/canonical-handoff-map.tsv"); sed -i.bak "s/^canonical_handoff_map_sha256=.*/canonical_handoff_map_sha256=$map_hash/" "$standalone_tampered/manifest.txt"; rm -f "$standalone_tampered/manifest.txt.bak"
evidence_write_sums "$standalone_tampered" "$standalone_tampered/SHA256SUMS"
expect_fail env SOFTWARE_OUTPUT_ROOT="$tmp/canonical-output" bash "$fixture_project/scripts/create-m9-recovery-plan.sh" "${m1_args[@]}" --release-inputs "$standalone_tampered" --release-anchor "$fixture_anchor" --authority authorized-operator-review --operator moriz --out "$tmp/canonical-output/standalone-tampered-plan"
readiness_tampered="$tmp/canonical-output/readiness-tampered"; cp -R -- "$canonical_release" "$readiness_tampered"
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "M0" {$5="true"} {print}' "$readiness_tampered/release-inputs.tsv" > "$readiness_tampered/release-inputs.new"; mv -- "$readiness_tampered/release-inputs.new" "$readiness_tampered/release-inputs.tsv"
readiness_hash=$(evidence_sha256 "$readiness_tampered/release-inputs.tsv"); sed -i.bak "s/^release_input_set_sha256=.*/release_input_set_sha256=$readiness_hash/" "$readiness_tampered/manifest.txt"; rm -f -- "$readiness_tampered/manifest.txt.bak"
evidence_write_sums "$readiness_tampered" "$readiness_tampered/SHA256SUMS"
expect_fail_no_output "$tmp/canonical-output/readiness-tampered-plan" env SOFTWARE_OUTPUT_ROOT="$tmp/canonical-output" bash "$fixture_project/scripts/create-m9-recovery-plan.sh" "${m1_args[@]}" --release-inputs "$readiness_tampered" --release-anchor "$fixture_anchor" --authority authorized-operator-review --operator moriz --out "$tmp/canonical-output/readiness-tampered-plan"
identity_tampered="$tmp/canonical-output/identity-tampered"; cp -R -- "$canonical_release" "$identity_tampered"
sed -i.bak 's/^model=Mac15,6$/model=Mac15,7/' "$identity_tampered/identity.txt"; rm -f -- "$identity_tampered/identity.txt.bak"
evidence_write_sums "$identity_tampered" "$identity_tampered/SHA256SUMS"
expect_fail_no_output "$tmp/canonical-output/identity-tampered-plan" env SOFTWARE_OUTPUT_ROOT="$tmp/canonical-output" bash "$fixture_project/scripts/create-m9-recovery-plan.sh" "${m1_args[@]}" --release-inputs "$identity_tampered" --release-anchor "$fixture_anchor" --authority authorized-operator-review --operator moriz --out "$tmp/canonical-output/identity-tampered-plan"
printf 'M9 tools self-tests passed\n'
