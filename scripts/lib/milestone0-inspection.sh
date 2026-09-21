#!/usr/bin/env bash

# Inspection tools are independent of the historical compiler/builder identity.
# Versions include the tools' shared-library closure in the immutable Arch base.
m0_inspection_packages_match() {
    local expected="$1" actual="$2"
    [[ -s $expected && -f $expected && ! -L $expected &&
        -s $actual && -f $actual && ! -L $actual ]] || return 1
    [[ $(wc -l < "$expected" | tr -d '[:space:]') == 48 ]] || return 1
    LC_ALL=C sort -u "$expected" | cmp - "$expected" || return 1
    LC_ALL=C awk '
        $0 !~ /^[a-zA-Z0-9@._+:-]+ [^[:space:]]+$/ { bad=1; next }
        NR == FNR { if ($1 in wanted) bad=1; wanted[$1]=$2; next }
        { if (++seen[$1] != 1) bad=1 }
        $1 in wanted { if ($2 != wanted[$1]) bad=1 }
        END { for (name in wanted) if (seen[name] != 1) bad=1; exit bad ? 1 : 0 }
    ' "$expected" "$actual"
}

m0_inspection_inventory_check() {
    local root="$1" name="$2" contract="$3" expected actual
    [[ -f $root/$name && ! -L $root/$name &&
        -f $root/SHA256SUMS && ! -L $root/SHA256SUMS ]] || return 1
    expected=$(awk -v name="$name" '
        $2 == name || $2 == "./" name { count++; hash=$1; if (NF != 2) bad=1 }
        END { if (count != 1 || bad) exit 1; print hash }
    ' "$root/SHA256SUMS") || return 1
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum -- "$root/$name") || return 1
    [[ ${actual%% *} == "$expected" ]] || return 1
    m0_inspection_packages_match "$contract" "$root/$name"
}

# Fixed mounts/options only. The body is repository-owned verifier code, never
# supplied by a manifest or artifact. No image override or original-image fallback.
m0_inspection_run() (
    [[ $# == 4 ]] || return 1
    local full="$1" packages="$2" builder_id="$3" body="$4" lib_dir contract image_info image_id path
    local image_ref='menci/archlinuxarm@sha256:55b83fc04a09f1e2e08644b4548b95c974ed1108fa8f0a34647af36a4b1c7f60'
    local -a artifact_mounts=(--mount "type=bind,src=$full,dst=/evidence,readonly")
    [[ $builder_id =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    contract="$lib_dir/../../config/milestone0-inspection-packages.txt"
    for path in "$full" "$lib_dir" "${packages:-$full}"; do
        [[ $path == /* && $path != *','* && $path != *[[:cntrl:]]* &&
            -d $path && ! -L $path ]] || return 1
    done
    m0_inspection_inventory_check "$full" packages.txt "$contract" || {
        printf 'M0 inspection package provenance mismatch.\n' >&2; return 1;
    }
    if [[ -n $packages ]]; then
        m0_inspection_inventory_check "$packages" pacman-Q.txt "$contract" || {
            printf 'M0 package inspection provenance mismatch.\n' >&2; return 1;
        }
        artifact_mounts+=(--mount "type=bind,src=$packages,dst=/packages,readonly")
    fi
    image_info=$(docker image inspect --format '{{.Id}} {{.Os}} {{.Architecture}}' "$image_ref") || return 1
    [[ $image_info =~ ^sha256:[0-9a-f]{64}\ linux\ arm64$ ]] || {
        printf 'M0 inspection requires the pinned Linux arm64 image.\n' >&2; return 1;
    }
    image_id=${image_info%% *}
    printf 'm0_inspection.recorded_builder_image_id=%s\nm0_inspection.executor_ref=%s\nm0_inspection.executor_image_id=%s\n' \
        "$builder_id" "$image_ref" "$image_id"
    docker run --rm --pull=never --platform linux/arm64 --network none --read-only \
        --cap-drop ALL --security-opt no-new-privileges --pids-limit 64 \
        --user "$(id -u):$(id -g)" --tmpfs /tmp:rw,nosuid,nodev,noexec,size=2g \
        --workdir /tmp --entrypoint /bin/bash \
        --env PATH=/usr/bin:/bin --env LC_ALL=C --env LANG=C --env BASH_ENV=/dev/null --env ENV=/dev/null \
        --env "LINUX_PKGBASE=${LINUX_PKGBASE:-}" --env "LINUX_PKGVER=${LINUX_PKGVER:-}" --env "LINUX_PKGREL=${LINUX_PKGREL:-}" \
        --mount "type=bind,src=$lib_dir,dst=/verify,readonly" \
        --mount "type=bind,src=$contract,dst=/inspection-packages.txt,readonly" \
        "${artifact_mounts[@]}" "$image_id" --noprofile --norc -Eeuo pipefail -c '
            source /verify/milestone0-inspection.sh
            [[ $(uname -m) == aarch64 ]]
            m0_inspection_inventory_check /evidence packages.txt /inspection-packages.txt
            if [[ -d /packages ]]; then
                m0_inspection_inventory_check /packages pacman-Q.txt /inspection-packages.txt
            fi
            mapfile -t inspection_packages < <(cut -d " " -f1 /inspection-packages.txt)
            pacman -Q -- "${inspection_packages[@]}" > /tmp/inspection-versions.txt
            m0_inspection_packages_match /inspection-packages.txt /tmp/inspection-versions.txt
            printf "m0_inspection.package_versions=matched\n"
            printf "m0_inspection.contract_sha256=%s\n" "$(sha256sum /inspection-packages.txt | cut -d " " -f1)"
            exec /bin/bash --noprofile --norc -Eeuo pipefail -c "$1"
        ' m0-inspection "$body"
)
