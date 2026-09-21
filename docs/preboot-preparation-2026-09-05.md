# Native preparation: pause before boot

## Operator handoff: 2026-09-06 03:44 UTC

The user confirms the earlier restart was manual after the lockup. The freeze's
cause is still unproved, but the restart is no longer unexplained. The user now
asks for the restart sequence. This handoff is a go for entering M3 Dev's paired
Recovery setup only, not for the unvalidated Linux/hypervisor execution path.
No power-state or startup-selection command was issued in this handoff.

Fresh checks pass: all 22 saved boot-preparation records, all four live EFI
inventory hashes, unchanged disk layout, SIP enabled, FileVault on. A strict
host-key-checked SSH session to the actual Linux desktop `arch-btw` verified
both staged kits' top-level hash inventories. The read-only receiver listing
returned no secondary console and `device_opened=false`, as expected in macOS.
No new kernel tests/builds, proxy commands or serial opens ran.

### Steps for this restart

1. Save work and keep these instructions available on the Linux desktop or a
   phone. Connect Mac power and leave the USB data cable connected. Have the
   macOS owner password and backup credentials available off this Mac. Tell
   the Linux agent this pass is Recovery setup, not the Linux experiment;
   it should not run `chainload.py`, `run_guest.py`, or any proxy command.
2. In macOS Terminal, resume the existing installer with the command below.
   Enable expert mode, choose `p` (repair incomplete installation), and confirm
   the resumed installation is M3 Dev. With only one incomplete installation,
   it is selected automatically. Do not choose a fresh install or resize.
3. Follow the owner-authentication prompts. Resuming intentionally selects
   M3 Dev as startup default for its paired Recovery. At the installer shutdown
   prompt, press Enter when ready, then wait 25 seconds after shutdown.
4. Press and continuously hold the power button until startup options appear.
   Select **M3 Dev**. If Recovery asks which volume to recover for authentication,
   choose the normal macOS volume, then authenticate. This is not permission to
   erase, restore, or reinstall it.
5. The Asahi second-stage installer must show VGID
   `B1EDE575-17A9-47FC-A7CC-314BB64CDC16`. Follow its prompts and authenticate as
   the macOS owner when requested, normally twice. Its reviewed script scopes
   boot-security changes to this M3 Dev volume group, not Macintosh HD.
6. **Stop at `Installation complete! Press enter to reboot.` Do not press
   Enter.** Photograph the screen for the Linux-side agent. Recovery-side USB
   proxy/backdoor configuration and the controller/guest execution plan still
   need checking before the first experimental boot. No native success claimed.

```sh
cd /Users/moriz/Projects/asahi-m3pro-fullstack/out/isolated/boot-volume-preparation-20260906.5QuD89/installer
sudo /usr/bin/env -u REPORT -u REPORT_TAG \
  EXPERT=1 \
  INSTALLER_BASE=https://cdn.asahilinux.org/installer \
  INSTALLER_DATA=https://raw.githubusercontent.com/AsahiLinux/asahi-installer-data/f5c51844e53b1c5f2eb2ce06fcd03aeeac11378f/data/installer_data.json \
  REPO_BASE=https://cdn.asahilinux.org \
  /usr/bin/caffeinate -i ./install.sh
```

Stop on a wrong volume group, missing files, pairing error, or erase/reinstall
request. Do not improvise repairs or accept destructive prompts. If needed,
return through startup options to Macintosh HD; do not keep retrying Linux.
Power-hold/selection and the final stop text were checked against the actual
v0.9.1 installer and staged `step2.sh`. USB proxy requirements were checked
against [Asahi's tethered-boot guide](https://asahilinux.org/docs/sw/tethered-boot/).
Keep that distinction: an ordinary UEFI boot is not a Linux-HV console test.

## Current checkpoint: 2026-09-06 03:36 UTC

The APFS compressed-file warning is resolved. The affected file was generated
Spotlight cache, not an original document. Recreating the Data index and removing
the one local snapshot retaining the damaged metadata cleared the warning.
Indexing is enabled and rebuilding; automatic backup settings and the completed
encrypted server backup were retained. The newer-APFS-version notice remains;
no forced filesystem repair was used.

Official installer v0.9.1 completed its macOS-side UEFI-only staging. macOS stays
at 384,000,000,000 bytes. M3 Dev now has a 2,499,805,184-byte APFS stub and a
500,170,752-byte EFI partition; 107,384,819,712 bytes remain unallocated.
Original partition/volume identities and the sealed macOS snapshot are preserved.

The EFI partition holds the unchanged official `m1n1/boot.bin` plus inactive
`boot-diagnostics.bin` and `boot-proxy.bin`. All hashes passed after unmount and
remount. Data, new APFS volumes, EFI filesystem and partition-map checks passed.
The stage-1 object exactly matches the official binary with this EFI UUID bound.
This proves file staging, not an activated boot chain or hardware support.

The installer temporarily selected M3 Dev as startup default. macOS was restored
as default and confirmed through NVRAM readback and a fresh installer enumeration.
SIP remains enabled; FileVault remains on. The installer was interrupted at its
shutdown prompt. A second run recognized M3 Dev as an incomplete installation
and offered `p` to resume; that run chose `q` without changing the installation.
No shutdown/reboot command, Recovery activation, or experimental Linux boot ran.

Correction to the preceding lockup account: uptime and reboot history establish
a macOS restart at 2026-09-05 21:54:53 America/Chicago (02:54:53 UTC). We did not
issue it. The user subsequently confirmed restarting manually after the lockup;
the freeze cause is still unproved. Accessible crash-report filenames did not
establish a cause. Sealed earlier evidence retains the then-unconfirmed account.

### Next transition is not yet authorized

1. Confirm recovery access, backup-password access,
   and the Linux observer before scheduling the physical transition. The backup
   has a verified sample restore, not a demonstrated full-disk recovery.
2. With fresh user instruction, resume the pinned installer with `p`, selecting
   M3 Dev volume group `B1EDE575-17A9-47FC-A7CC-314BB64CDC16`. Do not reinstall or
   resize again. This resume intentionally changes startup selection again.
3. Follow the displayed paired-Recovery instructions. Stop before Recovery's
   final reboot: per-OS USB proxy/backdoor setup and the pinned controller/guest
   execution path still need validation. The current official UEFI payload is
   not the intended hypervisor-debug session.
4. Obtain the user's explicit experimental-boot instruction with the Linux
   observer ready. No promise of one-boot success or brick-free recovery.

Exact evidence and resume command:
`out/isolated/boot-volume-preparation-20260906.5QuD89/README.md`.
Cache diagnosis/remediation:
`out/isolated/apfs-cache-remediation-20260906.WQ22bQ/README.md`.
The following sections are historical checkpoints, not current readiness.

## Earlier storage update: 2026-09-06 UTC

The authorized resize is now complete. macOS container `disk0s2`/`disk3` is
384,000,000,000 bytes, with approximately 110.4 GB adjacent unallocated space.
Original partition and APFS volume identities match, the sealed system snapshot
is retained, and partition-map verification passes. The new local Time Machine
snapshot was removed; a completed encrypted 21:01:29 backup and matching sample
restore were checked first. Automatic backup settings were not changed.

The post-resize Data check returned exit 0 but still reported a compressed-file
metadata warning, alongside mixed repair/OK messages. Do not claim warning-free
storage or continue installation writes until this is diagnosed or confirmed
cleared. Mac administrator authentication is still needed. The diagnostic
candidate verifies and installer v0.9.1 is downloaded, but no stub/ESP, image
installation, startup-selection change, shutdown, Recovery entry or boot ran.

Full evidence and current next-step boundaries:
`out/isolated/native-preparation-20260906.7mG0wI/README.md`.
This smaller layout does not silently pass the original full-install space
profile. The following sections describe the preceding historical checkpoint.

## Previous preparation checkpoint

This is the later 2026-09-05 checkpoint, superseding the earlier authority and
backup status in [preboot readiness](preboot-readiness-2026-09-05.md).
The user now authorizes relevant native preparation, including resizing, but
requires a pause before boot. Permission is not the outstanding blocker.

## Verified on the current Mac

- Time Machine is idle and reports the completed 2026-09-05 01:29:47 backup.
  Its mounted sparsebundle reports encryption enabled. A `tmutil restore` of
  the project's 2,580-byte `config/milestone0.env` from the mounted latest
  backup view matches the current file byte-for-byte. This is a sample restore,
  not proof of full-disk recovery or independent availability of the password.
  The nominal `tmutil latestbackup` hidden path is absent; the successful restore
  used the readable `.previous/Data` view on the actual mounted backup volume.
- Internal macOS APFS container `disk3` is 494,384,795,648 bytes. Both reported
  minimum sizes equal the current size: **zero shrink room**, despite about
  181.76 GB decimal (169 GiB) free. Disk identifiers must be rediscovered before
  any later operation. No Asahi stage-1/EFI boot environment exists.
- APFS names both the active, nonpurgeable macOS system snapshot and a purgeable
  local Time Machine snapshot as limits. Neither was deleted. Do not remove
  the active sealed system snapshot or force an unsupported resize. The
  original full-install profile needs 192 GiB free, also not currently met.
- Canonical M0 and the current RAM-only diagnostic candidate verify again.
  No kernel build or canonical promotion was performed. Existing software
  test evidence is retained; this does not establish native driver support.

## Controller preparation

`tests/m1n1-controller-offline-test.py` checks a pinned proxyclient export without
target execution. The transfer kit includes exact hash-locked dependency wheels,
complete verified outer m1n1 evidence, and the complete diagnostic guest. It
does not install the Mac or bypass existing M1 preflight/execution gates.

The kit is now deployed to the actual Linux desktop at
`/home/moriz/Downloads/asahi-m3pro-hv-preboot-20260905`. All 152 shipped files
and both nested evidence closures verify. Python 3.14.7 with Clang/LLVM 22.1.8
passes 121 source parses, both exact dependency checks, selected module imports,
four target-access rejection controls, both parser-only help calls, and local
ARM assembly/disassembly. No serial device was opened. USB listing still has
no m1n1 secondary endpoint. Receiver and controller roles remain separate.

The pinned T6030 HV path is explicit in `chickens.c`, `hv.c`, `smp.c`, and
`proxyclient/m1n1/hv/__init__.py`. Static source support is not hardware success.
The upstream `run_guest.py` also resets the PMU panic counter, enters an
interactive shell after HV returns, and then stops secondaries/sleeps. Its
optional 9P IRQ allocator lacks AIC3. A deliberately gated Linux-HV launcher
and controller evidence remain needed; copying the native tools is not that
implementation. The existing M1 launcher is macOS/direct-Linux only.

## Ordered next steps

1. Identify the available recovery Mac, macOS version, usable cable, and access
   to the encrypted backup's password independently of this laptop. Apple
   requires another Mac running macOS Sonoma 14 or later for firmware recovery.
2. Separately authorize and observe recovery/DFU rehearsal. This changes power
   state and was not performed under the current stop-before-boot instruction.
3. Resolve the APFS shrink limit through the supported macOS/update/recovery
   path, recheck exact partition identities and limits, then select a concrete
   compatible provisioning layout. Preserve ISC, macOS, and System Recovery.
4. Complete and validate the Linux-HV execution/evidence path. Provision and
   verify the compatible boot environment only when storage/recovery evidence
   permits. The Asahi installer calls `bless` before its shutdown prompt;
   running it until that prompt is not a non-mutating preview.
5. Refresh readiness, verify exact outer/inner artifacts and USB port mapping,
   then pause again with the exact operator and observer commands. The user
   instructs the Linux agent to watch before explicitly authorizing the boot.

Evidence, commands, hashes, and desktop results:
`out/isolated/preboot-preparation-20260905/README.md`.
No partition, boot policy, FileVault, SIP, firmware, DFU or native boot change
was made at this checkpoint. No one-boot or brick-free guarantee is possible.

Primary references: [Apple recovery requirements](https://support.apple.com/en-us/108900),
[Asahi tethered boot](https://asahilinux.org/docs/sw/tethered-boot/),
[Asahi M3 status](https://asahilinux.org/docs/platform/feature-support/m3/).
