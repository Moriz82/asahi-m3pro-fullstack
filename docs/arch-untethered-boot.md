# Untethered Arch boot attempt

Prepared 2026-09-10 05:59 UTC; local login enrolled 06:22 UTC. No boot performed.

The verified Arch payload is now active at EFI `m1n1/boot.bin`. It contains
the loader, kernel, initramfs and J514s DTB, and selects the installed internal
root by UUID. No USB data cable, proxy controller, external disk or network
download is required to launch it. If a console appears, log in as `moriz`
with the user-supplied password (the final character is a literal asterisk,
not a backslash). Wi-Fi is needed for SSH, not local login.

**M3 Dev was already the default startup volume. That setting was not changed.
The next normal restart will attempt Arch.** This corrects the earlier guide's
unverified statement that macOS was the default. Macintosh HD remains available
through startup options.

## When ready to try

1. Save work and connect a charger. Disconnect the Mac-to-PC USB data cable.
   Keep the enrolled Wi-Fi available; arch-btw should remain on that same LAN.
   Do not run the old m1n1 proxy/capture/boot scripts for this untethered attempt.
2. Shut down. Hold Power until startup options appear, then select **M3 Dev**.
   A normal restart also uses M3 Dev, but explicit selection avoids ambiguity.
3. Check for a useful display and/or a DHCP lease named `m3-arch-dev`. The Linux
   IP may differ from macOS's old IP. Use the router's lease information; do not
   assume the old Mac Tailscale address belongs to this Linux installation.
4. From arch-btw, use its existing key:

   ```sh
   ssh -o HostKeyAlias=m3-arch-dev -i ~/.ssh/id_ed25519 moriz@<LINUX_IP>
   ```

   This installation generates a new SSH host identity on first boot. Confirm
   the destination is your new Linux host before accepting it. Do not disable
   host-key checking or delete an unrelated machine's saved key.
5. Check `hostname`, `uname -r` and `findmnt -no UUID /`. Expected:
   `m3-arch-dev`, `7.1.13-1-1-ARCH`, and
   `72d1456d-516d-41e1-a29d-398001cc4cef`. Then collect
   `journalctl -b -k --no-pager`, `systemctl --failed` and `nmcli device status`.
   Enroll this new Linux identity separately with `sudo tailscale up` if wanted.

Local console access is configured for `moriz`; root remains locked and SSH
accepts keys only. There is no automatic graphical login.
Hyprland is installed but must not be treated as a proven usable desktop.
Native Wi-Fi, NVMe boot, display and GPU behavior remain untested. A persistent
journal directory exists, but failures before userspace may leave no disk log.

## If it does not come up

If neither a usable display nor SSH appears after roughly three minutes, do
not keep repeating the attempt. Hold Power until the Mac turns off. Hold Power
again for startup options and select **Macintosh HD**. This time window is an
operator observation limit, not proof of the failing hardware component.

For a loader-only rollback after returning to macOS, revalidate the exact EFI
partition UUID `2F1EEFA5-5B41-4775-A857-6085E480DCA6`, then restore the preserved
`m1n1/boot-before-arch-20260910.bin` over `m1n1/boot.bin` with hash checks and an
atomic rename. Its SHA-256 is
`097f1ae47b51e5580f401611977ce6d29c85cc9a15e6f6e28344af82a2e6b99e`.
Do not restore an entire partition image or change the partition map routinely.
This fallback does not guarantee recovery from every experimental hardware fault.

## Verification

Evidence: `out/isolated/arch-untethered-activation-20260910/`.
Active payload SHA-256:
`2c06c09bd0cf174fa2ca83147b69d1318b6306675fa7d0809d8163a78f4e1b4c`.
Embedded component hashes, internal-root selection, prior full native readback
evidence, direct LAN SSH and matching PC public key checked. FAT check and
post-remount active/rollback hashes pass. Startup selection unchanged; EFI left
unmounted. No root-image rewrite, rebuild, partition, firmware or boot-policy
change in this activation step.

Local login was subsequently enrolled by changing only `moriz`'s hash and
last-change date in the installed root's `/etc/shadow`. The update was rehearsed
on a private image clone, checked with the Linux authentication library, then
read back from the exact unmounted Linux partition. Ownership/mode remain
root:root/0600; all other account records are unchanged. Native read-only ext4
checks pass all five stages. Private evidence and rollback data are under
`out/isolated/arch-console-enrollment-20260910/`; never publish that directory.
The original full-image hash is a pre-enrollment baseline, not the current
native filesystem hash. This is offline credential verification, not proof of
a working native keyboard, console, or login session.
