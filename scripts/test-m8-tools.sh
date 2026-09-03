#!/usr/bin/env bash
# shellcheck disable=SC1091
set -Eeuo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$project_root/scripts/lib/evidence.sh"
test_root=${TEST_OUTPUT_ROOT:-$project_root/out}
mkdir -p "$test_root"
chmod 700 "$test_root"
tmp=$(mktemp -d "$test_root/m8-tools.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }
assert_absent() { [[ ! -e $1 && ! -L $1 ]] || { printf 'unexpected output remains: %s\n' "$1" >&2; exit 1; }; }
assert_empty_dir() {
    [[ -d $1 && ! -L $1 ]] || { printf 'expected directory: %s\n' "$1" >&2; exit 1; }
    if find -P "$1" -mindepth 1 -print -quit | grep -q .; then
        printf 'unexpected nested output: %s\n' "$1" >&2
        exit 1
    fi
}
race_publish() {
    local race_name=$1 race_out race_marker race_log race_pid race_rc watcher_rc race_stage
    shift
    race_out="$tmp/$race_name"
    race_marker="$tmp/$race_name-marker"
    race_log="$tmp/$race_name.log"
    (
        local attempt=0
        while ((attempt < 12000)); do
            for race_stage in "$tmp/.${race_name}.stage."*; do
                [[ -d $race_stage && ! -L $race_stage ]] || continue
                [[ ! -e $race_out && ! -L $race_out ]] || exit 2
                mkdir -m 700 "$race_out" || exit 2
                : > "$race_marker"
                exit 0
            done
            attempt=$((attempt + 1))
            sleep 0.01
        done
        exit 1
    ) &
    race_pid=$!
    set +e
    "$@" --out "$race_out" >"$race_log" 2>&1
    race_rc=$?
    wait "$race_pid"
    watcher_rc=$?
    set -e
    [[ $watcher_rc -eq 0 && -f $race_marker ]] || { printf 'race watcher did not claim destination: %s\n' "$race_name" >&2; exit 1; }
    [[ $race_rc -ne 0 ]] || { printf 'race publisher unexpectedly succeeded: %s\n' "$race_name" >&2; exit 1; }
    if grep -Fx "repo=$race_out" "$race_log" || grep -Fx "rollback-evidence=$race_out" "$race_log"; then
        printf 'race publisher printed success: %s\n' "$race_name" >&2
        exit 1
    fi
    assert_empty_dir "$race_out"
    for race_stage in "$tmp/.${race_name}.stage."*; do assert_absent "$race_stage"; done
}
fixture="$project_root/tests/fixtures/m8/package-input"
"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$fixture" >/dev/null
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$project_root/tests/fixtures/m8/package-input-missing"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$project_root/tests/fixtures/m8/package-input-forbidden"
repo="$tmp/repo"; "$project_root/scripts/build-m8-unsigned-repo.sh" --input-dir "$fixture" --out "$repo" >/dev/null
"$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$repo" >/dev/null
race_publish race-repo "$project_root/scripts/build-m8-unsigned-repo.sh" --input-dir "$fixture"
renamed_input="$tmp/renamed-input"; cp -R -- "$fixture" "$renamed_input"
mv -- "$renamed_input/linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst" "$renamed_input/qemu-linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst"
awk -F '\t' -v a=qemu-linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst 'BEGIN {OFS="\t"} NR == 2 {$5=a} {print}' "$renamed_input/packages.tsv" > "$renamed_input/packages.tsv.new"; mv -- "$renamed_input/packages.tsv.new" "$renamed_input/packages.tsv"
evidence_write_sums "$renamed_input" "$renamed_input/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$renamed_input"
renamed_repo="$tmp/renamed-repo"; cp -R -- "$repo" "$renamed_repo"
mv -- "$renamed_repo/packages/linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst" "$renamed_repo/packages/qemu-linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst"
awk -F '\t' -v a=qemu-linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst 'BEGIN {OFS="\t"} NR == 2 {$5=a} {print}' "$renamed_repo/packages.tsv" > "$renamed_repo/packages.tsv.new"; mv -- "$renamed_repo/packages.tsv.new" "$renamed_repo/packages.tsv"
renamed_manifest_hash=$(evidence_sha256 "$renamed_repo/packages.tsv")
awk -F '=' -v h="$renamed_manifest_hash" 'BEGIN {OFS="="} /^package_manifest_sha256=/{ $0="package_manifest_sha256=" h } {print}' "$renamed_repo/manifest.txt" > "$renamed_repo/manifest.txt.new"; mv -- "$renamed_repo/manifest.txt.new" "$renamed_repo/manifest.txt"
{ printf 'format=1\nrepo_name=asahi-m8-local-preview\narchitecture=aarch64\n'; tail -n +2 "$renamed_repo/packages.tsv" | LC_ALL=C sort -t $'\t' -k1,1; } > "$renamed_repo/repo.db"
evidence_write_sums "$renamed_repo" "$renamed_repo/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --repo "$renamed_repo"
expect_fail "$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$renamed_repo"
metadata_repo="$tmp/metadata-repo"; cp -R -- "$repo" "$metadata_repo"
printf 'vm_token=qemu\n' >> "$metadata_repo/manifest.txt"; evidence_write_sums "$metadata_repo" "$metadata_repo/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --repo "$metadata_repo"
expect_fail "$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$metadata_repo"
metadata_repo_db="$tmp/metadata-repo-db"; cp -R -- "$repo" "$metadata_repo_db"
printf 'qemu metadata\n' >> "$metadata_repo_db/repo.db"; evidence_write_sums "$metadata_repo_db" "$metadata_repo_db/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --repo "$metadata_repo_db"
expect_fail "$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$metadata_repo_db"
cp -p -- "$repo/packages/linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst" "$repo/packages/extra-1-aarch64.pkg.tar.zst"
evidence_write_sums "$repo" "$repo/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --repo "$repo"
expect_fail "$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$repo"
rm -f -- "$repo/packages/extra-1-aarch64.pkg.tar.zst"
evidence_write_sums "$repo" "$repo/SHA256SUMS"
cp -p -- "$repo/repo.db" "$tmp/repo.db.orig"
printf 'tampered metadata\n' >> "$repo/repo.db"
expect_fail "$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$repo"
cp -p -- "$tmp/repo.db.orig" "$repo/repo.db"
coverage_tampered="$tmp/coverage-tampered"; cp -R -- "$repo" "$coverage_tampered"
sed -i.bak 's/^boot-chain\tnot-provided/boot-chain\tstatic-snapshot/' "$coverage_tampered/coverage.tsv"; rm -f -- "$coverage_tampered/coverage.tsv.bak"
coverage_hash=$(evidence_sha256 "$coverage_tampered/coverage.tsv"); sed -i.bak "s/^platform_coverage_sha256=.*/platform_coverage_sha256=$coverage_hash/" "$coverage_tampered/manifest.txt"; rm -f -- "$coverage_tampered/manifest.txt.bak"
evidence_write_sums "$coverage_tampered" "$coverage_tampered/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$coverage_tampered"
make_bad_archive() {
    case_name=$1; pkgname=$2; pkgver=$3; arch=$4; dependency=$5; path_token=$6
    case_root="$tmp/$case_name"; cp -R -- "$fixture" "$case_root"
    work_root="$tmp/$case_name-work"; mkdir -p "$work_root/root/usr/share"
    printf 'pkgname = %s\npkgver = %s\npkgbase = linux-asahi\narch = %s\n' "$pkgname" "$pkgver" "$arch" > "$work_root/root/.PKGINFO"
    if [[ $dependency == install-action ]]; then
        printf 'install = /usr/bin/unsafe\n' >> "$work_root/root/.PKGINFO"
    elif [[ $dependency == safe-build-dependency ]]; then
        printf 'makedepend = openssl\n' >> "$work_root/root/.PKGINFO"
    elif [[ -n $dependency ]]; then
        printf 'depend = %s\n' "$dependency" >> "$work_root/root/.PKGINFO"
    fi
    case $path_token in
        .INSTALL) printf 'lifecycle\n' > "$work_root/root/.INSTALL";;
        libalpm-hook) mkdir -p "$work_root/root/usr/share/libalpm/hooks"; printf 'lifecycle\n' > "$work_root/root/usr/share/libalpm/hooks/lifecycle.hook";;
        pacman-hook) mkdir -p "$work_root/root/etc/pacman.d/hooks"; printf 'lifecycle\n' > "$work_root/root/etc/pacman.d/hooks/lifecycle.hook";;
        safe-link) printf 'safe target\n' > "$work_root/root/usr/share/target"; ln -s target "$work_root/root/usr/share/m8";;
        escaping-link) ln -s ../../../../outside "$work_root/root/usr/share/m8";;
        safe-header-token) mkdir -p "$work_root/root/usr/include"; printf 'generic header\n' > "$work_root/root/usr/include/qemu_fw_cfg.h";;
        qemu-executable) mkdir -p "$work_root/root/usr/bin"; printf 'vm executable\n' > "$work_root/root/usr/bin/qemu-system-aarch64";;
        *) mkdir -p "$work_root/root/usr/share/$path_token"; printf 'bad archive\n' > "$work_root/root/usr/share/$path_token/file";;
    esac
    if command -v gtar >/dev/null 2>&1; then
        tar_tool=gtar
    elif command -v tar >/dev/null 2>&1 && tar --version 2>/dev/null | grep -Fq 'GNU tar'; then
        tar_tool=tar
    else
        command -v bsdtar >/dev/null 2>&1 || { printf 'tar or bsdtar is required\n' >&2; return 1; }
        tar_tool=bsdtar
    fi
    if [[ $tar_tool == bsdtar ]]; then
        # libarchive tar variants do not share GNU tar's reproducibility flags;
        # these archives are tamper fixtures whose hashes are recomputed below.
        tar_options=(--format=ustar)
    else
        tar_options=(--format=ustar --sort=name --mtime='1970-01-01 00:00:00Z' --owner=0 --group=0 --numeric-owner)
    fi
    "$tar_tool" "${tar_options[@]}" -C "$work_root/root" -cf - . | zstd -q --no-check -19 -f -o "$case_root/linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst"
    bad_hash=$(evidence_sha256 "$case_root/linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst")
    awk -F '\t' -v h="$bad_hash" 'BEGIN {OFS="\t"} NR == 2 {$4=h} {print}' "$case_root/packages.tsv" > "$case_root/packages.tsv.new"
    mv -- "$case_root/packages.tsv.new" "$case_root/packages.tsv"
    printf '%s\n' "$case_root"
}
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive mismatch-name wrong-name 7.1.9.asahi1-1 aarch64 '' safe)"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive mismatch-version linux-asahi wrong-version aarch64 '' safe)"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive mismatch-arch linux-asahi 7.1.9.asahi1-1 x86_64 '' safe)"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive compressed-forbidden linux-asahi 7.1.9.asahi1-1 aarch64 qemu qemu)"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive path-only-qemu linux-asahi 7.1.9.asahi1-1 aarch64 '' qemu)"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive install-metadata linux-asahi 7.1.9.asahi1-1 aarch64 install-action safe)"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive install-file linux-asahi 7.1.9.asahi1-1 aarch64 '' .INSTALL)"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive libalpm-hook linux-asahi 7.1.9.asahi1-1 aarch64 '' libalpm-hook)"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive pacman-hook linux-asahi 7.1.9.asahi1-1 aarch64 '' pacman-hook)"
"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive safe-link linux-asahi 7.1.9.asahi1-1 aarch64 '' safe-link)" >/dev/null
"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive safe-build-dependency linux-asahi 7.1.9.asahi1-1 aarch64 safe-build-dependency safe)" >/dev/null
"$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive safe-header-token linux-asahi 7.1.9.asahi1-1 aarch64 '' safe-header-token)" >/dev/null
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive escaping-link linux-asahi 7.1.9.asahi1-1 aarch64 '' escaping-link)"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$(make_bad_archive qemu-executable linux-asahi 7.1.9.asahi1-1 aarch64 '' qemu-executable)"
invalid_builder_out="$tmp/libalpm-builder-hook-repo"
expect_fail "$project_root/scripts/build-m8-unsigned-repo.sh" --input-dir "$(make_bad_archive libalpm-builder-hook linux-asahi 7.1.9.asahi1-1 aarch64 '' libalpm-hook)" --out "$invalid_builder_out"
assert_absent "$invalid_builder_out"
"$project_root/scripts/build-m8-unsigned-repo.sh" --input-dir "$fixture" --out "$invalid_builder_out" >/dev/null
"$project_root/scripts/verify-m8-unsigned-repo.sh" --repo "$invalid_builder_out" >/dev/null
plaintext="$tmp/plaintext"; cp -R -- "$fixture" "$plaintext"; printf 'not an archive\n' > "$plaintext/linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst"; plaintext_hash=$(evidence_sha256 "$plaintext/linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst")
awk -F '\t' -v h="$plaintext_hash" 'BEGIN {OFS="\t"} NR == 2 {$4=h} {print}' "$plaintext/packages.tsv" > "$plaintext/packages.tsv.new"; mv -- "$plaintext/packages.tsv.new" "$plaintext/packages.tsv"
expect_fail "$project_root/scripts/verify-m8-package-closure.sh" --input-dir "$plaintext"
anchor="$tmp/source-anchor"; printf 'format=1\nanchor_type=external-source-snapshot\nsource_snapshot_sha256=%s\n' "$(evidence_sha256 "$repo/SHA256SUMS")" > "$anchor"; chmod a-w "$anchor"
candidate="$tmp/candidate"; "$project_root/scripts/build-m8-unsigned-repo.sh" --input-dir "$project_root/tests/fixtures/m8/package-input-candidate" --out "$candidate" >/dev/null
race_publish rollback-race "$project_root/scripts/simulate-m8-update-rollback.sh" --repo "$repo" --candidate "$candidate" --anchor "$anchor"
invalid_rollback_out="$tmp/rollback-invalid"
expect_fail "$project_root/scripts/simulate-m8-update-rollback.sh" --repo "$repo" --candidate "$metadata_repo" --anchor "$anchor" --out "$invalid_rollback_out"
assert_absent "$invalid_rollback_out"
evidence="$invalid_rollback_out"; "$project_root/scripts/simulate-m8-update-rollback.sh" --repo "$repo" --candidate "$candidate" --anchor "$anchor" --out "$evidence" >/dev/null
"$project_root/scripts/verify-m8-update-rollback.sh" --evidence "$evidence" --anchor "$anchor" >/dev/null
cp -p -- "$evidence/candidate/packages/linux-asahi-7.1.9.asahi1-2-aarch64.pkg.tar.zst" "$evidence/before/packages/linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst"
before_package_hash=$(evidence_sha256 "$evidence/before/packages/linux-asahi-7.1.9.asahi1-1-aarch64.pkg.tar.zst")
awk -F '\t' -v h="$before_package_hash" 'BEGIN {OFS="\t"} NR == 2 {$2="7.1.9.asahi1-2"; $4=h} {print}' "$evidence/before/packages.tsv" > "$evidence/before/packages.tsv.new"; mv -- "$evidence/before/packages.tsv.new" "$evidence/before/packages.tsv"
before_manifest_hash=$(evidence_sha256 "$evidence/before/packages.tsv")
awk -F '=' -v h="$before_manifest_hash" 'BEGIN {OFS="="} /^package_manifest_sha256=/{ $0="package_manifest_sha256=" h } {print}' "$evidence/before/manifest.txt" > "$evidence/before/manifest.txt.new"; mv -- "$evidence/before/manifest.txt.new" "$evidence/before/manifest.txt"
{ printf 'format=1\nrepo_name=asahi-m8-local-preview\narchitecture=aarch64\n'; tail -n +2 "$evidence/before/packages.tsv" | LC_ALL=C sort -t $'\t' -k1,1; } > "$evidence/before/repo.db"
evidence_write_sums "$evidence/before" "$evidence/before/SHA256SUMS"
before_hash=$(evidence_sha256 "$evidence/before/SHA256SUMS")
awk -F '=' -v h="$before_hash" 'BEGIN {OFS="="} /^source_before_sha256=/{ $0="source_before_sha256=" h } {print}' "$evidence/transaction.txt" > "$evidence/transaction.txt.new"; mv -- "$evidence/transaction.txt.new" "$evidence/transaction.txt"
evidence_write_sums "$evidence" "$evidence/SHA256SUMS"
expect_fail "$project_root/scripts/verify-m8-update-rollback.sh" --evidence "$evidence" --anchor "$anchor"
printf 'tampered rollback\n' >> "$evidence/rollback/repo.db"
expect_fail "$project_root/scripts/verify-m8-update-rollback.sh" --evidence "$evidence" --anchor "$anchor"
printf 'M8 tools self-tests passed\n'
