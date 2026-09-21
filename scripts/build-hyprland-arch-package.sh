#!/usr/bin/env bash
# Disposable ARM64 container only; upstream recipe, local development signature.
set -Eeuo pipefail
[[ $EUID == 0 && $(uname -m) == aarch64 && -f /.dockerenv ]] || exit 1
echo '45a68071b48a06e69b86dc6722e7b3017d02d20156c84a33feaabfce6a7eee8b  /output/PKGBUILD' | sha256sum -c -
exec > >(tee -a /output/build.log) 2>&1
if [[ ! -e /hypr-build ]]; then
# The recipe was reviewed and pinned before executing its declarations/functions.
declare -a depends=() makedepends=()
# shellcheck disable=SC1091
source /output/PKGBUILD
pacman -Syu --noconfirm --needed base-devel "${depends[@]}" "${makedepends[@]}"
useradd -m builder
install -d -o builder -g builder /hypr-build
install -o builder -g builder -m644 /output/PKGBUILD /hypr-build/PKGBUILD
cd /hypr-build
# No debug subpackage needed for this runtime bootstrap. Upstream source is unchanged.
printf '\nOPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug !lto)\n' >> /etc/makepkg.conf
runuser -u builder -- makepkg --noconfirm
gpg --batch --passphrase '' --quick-generate-key 'M3 local packaging (development only)' ed25519 sign 1y
else
    # Finalization may be resumed after compilation; do not repeat the build.
    test -s /hypr-build/hyprland-0.56.2-3-aarch64.pkg.tar.xz
    test -s /hypr-build/hyprpm-0.56.2-3-aarch64.pkg.tar.xz
fi
fingerprint=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')
[[ $fingerprint =~ ^[A-F0-9]{40}$ ]] || exit 1
gpg --armor --export "$fingerprint" > /output/local-build-key.asc
printf '%s\n' "$fingerprint" > /output/local-build-fingerprint.txt
for package in /hypr-build/*.pkg.tar.xz; do
    cp "$package" /output/
    gpg --batch --yes --local-user "$fingerprint" --detach-sign "/output/${package##*/}"
    gpg --verify "/output/${package##*/}.sig" "/output/${package##*/}"
done
pacman -Q > /output/build-packages.txt
cp /recipe/build-hyprland-arch-package.sh /output/build-recipe.sh
sha256sum /hypr-build/Hyprland-0.56.2.tar.gz > /output/source.sha256
(cd /output; sha256sum PKGBUILD ./*.pkg.tar.xz ./*.pkg.tar.xz.sig local-build-key.asc local-build-fingerprint.txt build-packages.txt build-recipe.sh source.sha256 > SHA256SUMS)
echo 'Locally rebuilt upstream Hyprland packages complete; not hardware validation.'
