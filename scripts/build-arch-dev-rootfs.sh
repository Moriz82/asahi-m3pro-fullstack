#!/usr/bin/env bash
# Run only inside the isolated, disposable ARM64 packaging container.
# Never mounts a Mac partition or creates a native boot entry.
set -Eeuo pipefail
umask 022

if [[ ${1:-} == --help ]]; then
    echo 'usage: build-arch-dev-rootfs.sh (container: /recipe RO, /output empty RW)'
    exit 0
fi
[[ $(uname -m) == aarch64 && $EUID == 0 && -f /.dockerenv ]] || {
    echo 'Requires a disposable root ARM64 Docker container.' >&2; exit 1;
}
if [[ $# == 0 ]]; then
[[ -d /recipe/config && -d /output && ! -e /work ]] || exit 1
[[ -z $(find /output -mindepth 1 -maxdepth 1 -print -quit) ]] || {
    echo 'Output must be empty; refusing overwrite.' >&2; exit 1;
}
[[ $(df -Pk / | awk 'END {print $4}') -ge 12582912 ]] || {
    echo 'At least 12 GiB free required in builder.' >&2; exit 1;
}
mkdir -p /work/root /work/bootstrap-hooks
exec > >(tee /output/build.log) 2>&1
trap 'echo "Build failed at line $LINENO; output is incomplete." >&2' ERR

# Pin trust to the previously verified upstream public certificate, not a keyserver.
keypkg=/recipe/out/isolated/m8-upstream-signed-20260903T103406Z/packages/asahi-alarm-keyring-20241216-1-any.pkg.tar.xz
echo "798f4b283ad2819aee950d042f26566ae1a68f87c12247301ce449bea3b2d81e  $keypkg" | sha256sum -c -
bsdtar -xOf "$keypkg" usr/share/pacman/keyrings/asahi-alarm.gpg > /work/asahi.asc
gpg --show-keys --with-colons /work/asahi.asc | grep -Fx 'fpr:::::::::12CE6799A94A3F1B5DDFFE88F576553597FB8FEB:'
pacman-key --init
pacman-key --add /work/asahi.asc
pacman-key --lsign-key 12CE6799A94A3F1B5DDFFE88F576553597FB8FEB
install -m644 /recipe/config/arch-dev-pacman.conf /etc/pacman.conf
pacman -Syu --noconfirm --needed arch-install-scripts openssh
# ALARM's old Hyprland package is incompatible with its newer helper libraries.
# The separate, pinned upstream rebuild supplies a matching development package.
[[ ${M3_LOCAL_SIGNER:-} =~ ^[A-F0-9]{40}$ ]] || exit 1
(cd /hypr-input; sha256sum -c SHA256SUMS)
[[ $(cat /hypr-input/local-build-fingerprint.txt) == "$M3_LOCAL_SIGNER" ]] || exit 1
gpg --show-keys --with-colons /hypr-input/local-build-key.asc | grep -Fx "fpr:::::::::$M3_LOCAL_SIGNER:"
pacman-key --add /hypr-input/local-build-key.asc
pacman-key --lsign-key "$M3_LOCAL_SIGNER"
mkdir /work/compat
cp /hypr-input/hyprland-0.56.2-3-aarch64.pkg.tar.xz{,.sig} /work/compat/
pacman-key --verify /work/compat/hyprland-0.56.2-3-aarch64.pkg.tar.xz.sig
repo-add /work/compat/m3-compat.db.tar.gz /work/compat/hyprland-0.56.2-3-aarch64.pkg.tar.xz
sed '/^\[asahi-alarm\]/i [m3-compat]\nSigLevel = Required DatabaseOptional\nServer = file:///work/compat\n' /etc/pacman.conf > /work/pacman.conf
mapfile -t packages < <(sed '/^#/d; /^$/d' /recipe/config/arch-dev-packages.txt)
pacstrap -C /work/pacman.conf -G -M /work/root "${packages[@]}"
elif [[ $# == 1 && $1 == --resume-configure && -x /work/root/usr/bin/pacman && ! -e /output/rootfs.tar.zst ]]; then
    # Explicit checkpoint after the complete package transaction; never recompile.
    exec > >(tee -a /output/build.log) 2>&1
    trap 'echo "Configuration failed at line $LINENO; output is incomplete." >&2' ERR
    pacman --root /work/root --config /work/pacman.conf --gpgdir /etc/pacman.d/gnupg -S --needed --noconfirm archlinuxarm-keyring
else
    echo 'Invalid arguments or incomplete configure checkpoint.' >&2; exit 1
fi
root=/work/root
install -m644 /recipe/config/arch-dev-pacman.conf "$root/etc/pacman.conf"

# Never ship the container's signing secret, machine identity or host keys.
arch-chroot "$root" pacman-key --init
arch-chroot "$root" pacman-key --populate archlinuxarm asahi-alarm
install -Dm644 /hypr-input/local-build-key.asc "$root/usr/local/share/m3-dev/local-build-key.asc"
arch-chroot "$root" pacman-key --add /usr/local/share/m3-dev/local-build-key.asc
arch-chroot "$root" pacman-key --lsign-key "$M3_LOCAL_SIGNER"
if ! arch-chroot "$root" id moriz >/dev/null 2>&1; then
    arch-chroot "$root" useradd -m -G wheel -s /bin/bash moriz
fi
[[ $(arch-chroot "$root" id -u moriz) == 1000 ]] || exit 1
arch-chroot "$root" passwd -l root
arch-chroot "$root" passwd -l moriz
ssh-keygen -lf /machine-input/authorized_keys
install -d -m700 -o1000 -g1000 "$root/home/moriz/.ssh"
install -m600 -o1000 -g1000 /machine-input/authorized_keys "$root/home/moriz/.ssh/authorized_keys"
echo '9a6ee0e53444c30943ca91aec8dbe9b4754e7dc93fdb9463ee2c46083d09547f  /machine-input/firmware.tar' | sha256sum -c -
install -d "$root/usr/lib/firmware/vendor"
bsdtar -xf /machine-input/firmware.tar -C "$root/usr/lib/firmware/vendor"
test -s "$root/usr/lib/firmware/vendor/brcm/brcmfmac4388c0-pcie.apple,texa.bin"
test -s "$root/usr/lib/firmware/vendor/apple/tpmtfw-j514s.bin"
install -d "$root/etc/modprobe.d"
printf 'options firmware_class path=/usr/lib/firmware/vendor\n' > "$root/etc/modprobe.d/10-vendor-firmware.conf"
install -d -m700 "$root/etc/NetworkManager/system-connections"
install -m600 /machine-input/wifi.nmconnection "$root/etc/NetworkManager/system-connections/m3-dev.nmconnection"
printf 'm3-arch-dev\n' > "$root/etc/hostname"
printf 'en_US.UTF-8 UTF-8\n' > "$root/etc/locale.gen"
printf 'LANG=en_US.UTF-8\n' > "$root/etc/locale.conf"
arch-chroot "$root" locale-gen
ln -sfn /usr/share/zoneinfo/America/Chicago "$root/etc/localtime"
install -d -m755 "$root/etc/ssh/sshd_config.d" "$root/etc/sudoers.d" "$root/etc/mkinitcpio.conf.d"
printf '%s\n' 'PermitRootLogin no' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PubkeyAuthentication yes' 'AllowUsers moriz' > "$root/etc/ssh/sshd_config.d/10-m3-dev.conf"
printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$root/etc/sudoers.d/10-wheel"
chmod 440 "$root/etc/sudoers.d/10-wheel"
printf '%s\n' 'MODULES=(apple_dart nvme_apple ext4)' 'HOOKS=(base udev modconf keyboard block filesystems fsck)' 'COMPRESSION="gzip"' > "$root/etc/mkinitcpio.conf.d/10-m3-dev.conf"

# No greeter/autologin or speaker/audio service. Hyprland is a manual session.
systemctl --root="$root" set-default multi-user.target
# Upstream image first-boot randomizes root AND EFI UUIDs; this existing ESP must
# retain its identity. We bind the new root ourselves before installing it.
systemctl --root="$root" mask first-boot.service
systemctl --root="$root" enable NetworkManager.service sshd.service tailscaled.service serial-getty@ttySAC0.service
install -d -m755 "$root/home/moriz/.config/hypr" "$root/usr/local/share/m3-dev"
# shellcheck disable=SC2016 # Hyprland expands these variables, not Bash.
printf '%s\n' 'monitor = , preferred, auto, 1' '$mod = SUPER' 'bind = $mod, RETURN, exec, foot' 'bind = $mod, D, exec, fuzzel' 'bind = $mod, Q, killactive,' 'bind = $mod SHIFT, E, exit,' 'exec-once = waybar' > "$root/home/moriz/.config/hypr/hyprland.conf"
chown -R 1000:1000 "$root/home/moriz/.config"
install -d "$root/home/moriz/Projects/asahi-m3pro-fullstack"
tar -xzf /machine-input/project-working-tree.tar.gz -C "$root/home/moriz/Projects/asahi-m3pro-fullstack"
chown -R 1000:1000 "$root/home/moriz/Projects"
sha256sum /machine-input/authorized_keys /machine-input/firmware.tar /machine-input/project-working-tree.tar.gz /machine-input/wifi.nmconnection > /output/machine-inputs.sha256
printf '%s\n' 'STAGED ONLY: not authorized for native boot.' 'Wi-Fi is enrolled; DHCP and Tailscale login require a running target.' 'PC SSH public key and existing Mac vendor firmware are included.' 'SSH is key-only. The moriz user has passwordless sudo; set a console password with sudo passwd moriz after SSH login.' 'No proven M3 Pro display/GPU; run Hyprland only after a usable DRM output exists.' 'The builder kernel is not evidence of target hardware support.' > "$root/usr/local/share/m3-dev/READINESS.txt"
printf '%s\n' 'UUID=72d1456d-516d-41e1-a29d-398001cc4cef / ext4 defaults,noatime 0 1' 'PARTUUID=2F1EEFA5-5B41-4775-A857-6085E480DCA6 /boot/efi vfat ro,noauto,nofail,umask=0077 0 0' > "$root/etc/fstab"
mkdir -p "$root/boot/efi"

# Build the target initramfs, never one for the container host kernel.
mapfile -t releases < <(find "$root/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
[[ ${#releases[@]} == 1 && ${releases[0]} == 7.1.13-1-1-ARCH ]] || {
    printf 'Unexpected upstream kernel releases: %s\n' "${releases[*]}" >&2; exit 1;
}
release=${releases[0]}
[[ $(arch-chroot "$root" pacman -Qoq "/usr/lib/modules/$release/vmlinuz") == linux-asahi ]] || exit 1
arch-chroot "$root" depmod "$release"
arch-chroot "$root" mkinitcpio -k "$release" -g /boot/initramfs-linux-asahi.img
install -m644 "$root/usr/lib/modules/$release/vmlinuz" "$root/boot/Image"
install -m644 "$root/usr/lib/modules/$release/dtbs/t6030-j514s.dtb" "$root/boot/t6030-j514s.dtb"
arch-chroot "$root" visudo -cf /etc/sudoers
arch-chroot "$root" pacman -Q > /output/packages.txt
arch-chroot "$root" pacman -Dk
install -d -m700 /run/m3-check
arch-chroot "$root" env XDG_RUNTIME_DIR=/run/m3-check Hyprland --version
arch-chroot "$root" ssh -V
mkdir -p /run/sshd
ssh-keygen -q -t ed25519 -N '' -f "$root/usr/local/share/m3-dev/test-host-key"
arch-chroot "$root" /usr/bin/sshd -t -h /usr/local/share/m3-dev/test-host-key
rm "$root/usr/local/share/m3-dev/test-host-key" "$root/usr/local/share/m3-dev/test-host-key.pub"
arch-chroot "$root" python -c 'import ssl, sqlite3; print("python-runtime-ok")'
arch-chroot "$root" /usr/bin/lsinitcpio /boot/initramfs-linux-asahi.img > /output/initramfs-files.txt
# Upstream 7.1.13 builds these drivers in; older local profiles use modules.
for module in nvme_apple apple_dart ext4; do
    filename=$(arch-chroot "$root" modinfo -k "$release" -F filename "$module")
    if [[ $filename != '(builtin)' ]]; then
        grep -F "${filename##*/}" /output/initramfs-files.txt
    fi
    printf '%s %s\n' "$module" "$filename" >> /output/root-drivers.txt
done
test -s "$root/boot/Image"
test -s "$root/boot/t6030-j514s.dtb"
test ! -e "$root/etc/ssh/ssh_host_ed25519_key"
truncate -s0 "$root/etc/machine-id"
arch-chroot "$root" gpgconf --homedir /etc/pacman.d/gnupg --kill all
printf 'kernel_release=%s\nhardware_acceptance=false\nboot_ready=false\nroot_partition_written=false\n' "$release" > /output/status.env
cp /work/pacman.conf /output/transaction-pacman.conf
cp "$root/etc/pacman.conf" /output/pacman.conf
cp /recipe/config/arch-dev-packages.txt /output/requested-packages.txt
cp "$root/boot/Image" "$root/boot/t6030-j514s.dtb" "$root/boot/initramfs-linux-asahi.img" /output/
cp /recipe/scripts/build-arch-dev-rootfs.sh /output/build-recipe.sh
cp /work/compat/hyprland-0.56.2-3-aarch64.pkg.tar.xz{,.sig} /output/
cp /hypr-input/local-build-key.asc /hypr-input/local-build-fingerprint.txt /output/

# Keep complete signed package downloads for reinstallation and provenance.
# They remain in this stopped container; output inventory pins every input.
find /var/cache/pacman/pkg "$root/var/cache/pacman/pkg" -type f -name '*.pkg.tar.*' -exec sha256sum {} + | sort > /output/package-inputs.sha256
tar --numeric-owner --xattrs --acls --exclude='./var/cache/pacman/pkg/*' --exclude='./run/*' -C "$root" -cpf - . | zstd -T2 -3 -o /output/rootfs.tar.zst
chmod 600 /output/rootfs.tar.zst
# A sparse regular-file image only. Never point these tools at a block device.
test ! -e /output/root.img
# diskutil reserves a 128 MiB Apple_Boot helper within the requested 100 GiB.
# This is the verified Linux partition extent, excluding that separate helper.
truncate -s 107239964672 /output/root.img.partial
chmod 600 /output/root.img.partial
mkfs.ext4 -q -F -b4096 -L M3ArchDev -U 72d1456d-516d-41e1-a29d-398001cc4cef -d "$root" /output/root.img.partial
e2fsck -fn /output/root.img.partial
mv /output/root.img.partial /output/root.img
(cd /output; sha256sum Image t6030-j514s.dtb initramfs-linux-asahi.img rootfs.tar.zst packages.txt pacman.conf transaction-pacman.conf requested-packages.txt status.env package-inputs.sha256 machine-inputs.sha256 build-recipe.sh root-drivers.txt hyprland-0.56.2-3-aarch64.pkg.tar.xz{,.sig} local-build-key.asc local-build-fingerprint.txt > SHA256SUMS)
echo 'STAGED rootfs complete; boot_ready=false. No native disks touched.'
