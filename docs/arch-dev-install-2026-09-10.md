# Arch development installation — 2026-09-10

Experimental M3 Pro/J514s preparation, not hardware acceptance. No reboot is
authorized by this document. **Update: the Arch payload is now active, and
M3 Dev was already the default startup volume.** See the current
[untethered boot and fallback steps](arch-untethered-boot.md). Earlier wording
that macOS was the default was not supported by the actual startup selection.

## Image

- Arch Linux ARM with signed `linux-asahi 7.1.13.asahi1-1`; runtime release
  `7.1.13-1-1-ARCH`. Stock J514s DTB, existing Mac vendor firmware, ext4 root.
- Hyprland `0.56.2-3` rebuilt from the pinned upstream Arch recipe because the
  available ARM `0.56.1-3` package requires an older Aquamarine SONAME. The
  rebuilt executable passes version/library checks against Aquamarine 0.15.0.
  Development signing public key and package signatures accompany the image.
- NetworkManager, SSH, Tailscale, Python, Git, base-devel, kernel headers,
  foot, fuzzel, waybar and portals included. Console/SSH target by default;
  Hyprland is manual. No greeter, autologin or speaker activation.
- Private Wi-Fi keyfile enrolled with root ownership and mode 0600. No network
  password belongs in this repository or shared notes. These are private,
  machine-specific image files, not redistributable release artifacts.
- `moriz` receives arch-btw's public key and passwordless sudo. Root and user
  password authentication are locked. Set a console password after SSH login
  with `sudo passwd moriz`. No private SSH key or Tailscale identity is copied.
- Project working-tree snapshot is under
  `/home/moriz/Projects/asahi-m3pro-fullstack`; large outputs, vendor source trees
  and `.git` are excluded. Host-side final packaging/docs may be newer.

Root filesystem UUID: `72d1456d-516d-41e1-a29d-398001cc4cef`.
Root image size: 107,239,964,672 bytes (99.875 GiB), sparse on the Mac.
macOS reserves a separate 128 MiB Apple_Boot helper from the requested 100 GiB.
The target EFI is `ro,noauto,nofail` in fstab. The upstream `first-boot.service`
is masked because it would rewrite root and EFI filesystem UUIDs.

## Evidence and source

- Final machine root: `out/isolated/arch-dev-20260910-04/`.
  `SHA256SUMS` covers exported package/boot/rootfs inputs. The large raw image
  has its own `root.img.sha256`; the boot packager hashes it in full, and native
  partition readback independently verifies the installed bytes.
- Superseded pre-Wi-Fi metadata: `out/isolated/arch-dev-20260910-pre-wifi/`.
  Its obsolete image/archive moved to the Mac Trash and remain recoverable.
- Hyprland build: `out/isolated/hyprland-upstream-build-20260910/`.
- Final direct-m1n1 candidate: `out/isolated/arch-boot-20260910-02/`.
  The older `arch-boot-20260910` candidate is superseded and must not be installed.
- Native preparation/partition evidence:
  `out/isolated/arch-native-preparation-20260910/`.
- Build recipes: `scripts/build-arch-dev-rootfs.sh`,
  `scripts/build-hyprland-arch-package.sh` and `config/arch-dev-*`.
- Private enrollment: `scripts/enroll-arch-wifi.py`.
- Payload: `scripts/package-arch-boot.py`; focused tests:
  `python3 tests/arch-boot-self-test.py`.

Native root write and full readback passed. The separate EFI candidate was
copied, checked after remount, and initially left inactive. The later untethered
activation selected that same payload; its current status is linked above.
Exact status is in CURRENT.md and the native evidence directory. No boot or
hardware acceptance follows from these installation checks.

The payload uses known-working loader `60e53e7` (SHA-256
`097f1ae47b51e5580f401611977ce6d29c85cc9a15e6f6e28344af82a2e6b99e`),
then boot arguments, stock J514s DTB, explicit m1n1 initramfs wrapper and gzip
kernel. It bypasses U-Boot's generic NVMe compatibility filter. Root selection
uses the fixed ext4 UUID, not a mutable macOS disk identifier.

## Checks and limits

Completed image checks: package dependency database, actual ARM Hyprland
version and library ABI, sudoers, SSH configuration with a disposable test
host key, Python SSL/sqlite imports, initramfs inventory, built-in NVMe/DART/ext4
drivers, all five read-only e2fsck passes, NetworkManager offline parsing and
inspection of the actual ext4 image's Wi-Fi permissions, public key, fresh
machine/SSH identities, protected EFI fstab and first-boot service mask.

These are offline/container checks. No native root mount, Wi-Fi association,
DHCP, SSH, usable display or Hyprland session has been observed for this image.
The [upstream M3 support matrix](https://asahilinux.org/docs/platform/feature-support/m3/)
still marks M3 Pro GPU support TBA; display and USB have separate WIP limitations.
The old successful capture was a Linux guest under m1n1, not this installation.

## Before first boot

The staging/approval sequence below records the original preparation. Candidate
activation is now complete; use the current untethered guide linked above.

1. Keep AC connected. Confirm the observer PC and an actual first-login route.
   The new Linux installation is not enrolled into Tailscale. Same-Wi-Fi SSH
   additionally requires that the access point permits client-to-client traffic.
   A hotel network may not. Do not assume the Mac's Tailscale address will carry
   over to Linux, and do not copy its private Tailscale state.
2. Verify final partition/image readback and staged payload hashes. The active
   EFI `m1n1/boot.bin` must remain the known loader until operator boot approval.
   `m1n1/boot-arch-dev.bin` is only a staged candidate, not automatically selected.
3. Once capture and first-login access are ready, explicitly approve activating
   the candidate. Preserve the loader-only and original UEFI files. Do not alter
   startup policy, overwrite the full EFI partition or touch macOS partitions.
4. Only after that approval, shut down, hold Power for startup options, select
   M3 Dev, and observe the boot. If it fails, power off and select Macintosh HD.
   No automatic retry, partition repair or firmware change is authorized here.
5. After a working network is observed, use arch-btw's key to SSH to the Linux
   address as `moriz`; inspect `uname -a`, `findmnt /`, `journalctl -b -k` and
   `nmcli device status`. Set a console password and perform a fresh interactive
   `sudo tailscale up`. Save hardware evidence before declaring support.
6. Try Hyprland only after a usable DRM output is confirmed. Installed packages
   and compiled simpledrm do not prove visible pixels or GPU acceleration.

Stop condition for this preparation: verified root installation and separately
staged payload, with no reboot. Full-hardware milestones remain open.

Cleanup: removed five stopped, disposable build containers. Their reusable
outputs remain; the final configured root container, checkpoints, original
builder and canonical M0/source caches were retained. Old image/archive are in
Trash, not securely erased. macOS free space measured 22 GiB after cleanup.
