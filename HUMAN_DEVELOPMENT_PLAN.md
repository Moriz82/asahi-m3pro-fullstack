# M3 Pro full-stack Linux human development plan

- Status: planning only
- Primary target: `Mac15,6`, `J514s`, Apple `T6030` M3 Pro
- Distribution target: Arch Linux ARM with Hyprland
- Safety target: dual boot with macOS retained until all acceptance gates pass

## 1. Objective

Create a downstream Apple M3 Pro Linux platform that is suitable for daily use
on the target Mac. Human developers perform the reverse engineering, write the
drivers, review the patches, and operate the hardware bring-up tools.

The completed system must support every accessible M3 Pro Mac feature, not only
boot to a shell. A feature is complete only after it has a maintained driver,
power-management support, recovery behavior, documentation, and repeatable
real-hardware evidence.

The first hardware target is this `J514s/T6030` Mac. Support claims for other
M3 Pro products require separate tests on those products.

## 2. Required platform stack

```text
Apple boot policy and vendor firmware
  -> m1n1 stage 1 and stage 2
  -> U-Boot UEFI
  -> Linux kernel, device trees, and firmware interfaces
  -> Mesa and hardware-media userspace
  -> Arch packages, firmware extraction, and update tooling
  -> PipeWire/WirePlumber, speaker safety, and desktop services
  -> Hyprland daily-driver session
```

The human team owns integration across the complete stack. Passing one layer
does not prove the layers above or below it.

## 3. Current upstream baseline

Recheck the official
[M3 feature matrix](https://asahilinux.org/docs/platform/feature-support/m3/)
before each development cycle. At the 2026-09-01 baseline, the matrix reports:

| Area | M3 Pro status |
|---|---|
| DCP, USB2, USB3, DP Alt Mode, USB-PD | WIP |
| GPU, Thunderbolt, PMU | TBA |
| Video decoder | `linux-asahi`, no AV1 |
| Video encoder, ProRes codec | TBA |
| NVMe, PCIe, CPU frequency/idle, suspend | `linux-asahi` |
| SEP, Touch ID, Neural Engine | TBA |
| J514/J516 installer, main display, brightness, HDMI | WIP |
| Wi-Fi, Bluetooth, keyboard, touchpad, battery, SD, audio | `linux-asahi` |
| Webcam and microphones | `linux-asahi` |

Treat `WIP` and `TBA` as unsupported. Never infer support from a related block.

## 4. Governance and provenance

- Keep this as a clearly named downstream project. Do not claim endorsement by
  Asahi Linux, Arch Linux ARM, Apple, or upstream Linux maintainers.
- Human developers must inspect every imported commit and preserve its author,
  license, source URL, and original commit ID.
- Use only public, lawfully obtained source and hardware observations. Do not
  use leaked Apple documentation, private diagnostic software, confidential
  firmware, or internal vendor material.
- Keep a provenance record for traces, register descriptions, firmware
  interfaces, patches, and test data.
- Do not submit downstream work upstream unless its authors independently meet
  the target project's contribution and provenance rules.
- Require two human reviewers for boot-policy, storage, speaker, display power,
  USB-PD, GPU power, SEP, and firmware-loading changes.

## 5. Safety prerequisites

No native bring-up starts until all items are available:

- A current full backup on an external SSD and a verified sample restore.
- A second Mac, the correct data cable, and a rehearsed Finder DFU detection.
- A separate Linux or macOS host for tethered m1n1 operation and log capture.
- A documented DFU revive procedure; restore is the destructive last resort.
- macOS remains installed and remains the default startup system.
- FileVault and SIP remain enabled for the macOS installation.
- No manual APFS resize, container deletion, snapshot deletion, or partition
  rearrangement.
- A bench test inventory: external display, HDMI display, USB-C DP display,
  dock, USB2/USB3 devices, Thunderbolt device, SD card, Bluetooth devices,
  headphones, microphone, charger, and USB-PD analyzer where available.

Use the existing read-only safety gate before any storage change:

```bash
cd /Users/moriz/Projects/asahi-arch-hyprland-lab
./scripts/check-native-readiness.sh
```

## 6. Development environment

The kernel source must live on a case-sensitive Linux filesystem. The initial
macOS clone produced case-collision changes on case-insensitive APFS and is not
a valid patch or build tree.

Use one of these human-operated environments:

1. The existing Arch ARM VM with a Linux filesystem.
2. A Linux build host.
3. A Docker named volume backed by Docker's Linux filesystem.

Pin and record the compiler, linker, Rust toolchain, build container digest,
kernel configuration, source commits, and artifact hashes. Keep build outputs
outside the source trees.

## 7. Repository layout and branch policy

The human maintainer creates and owns the downstream forks. Each component must
have an `upstream` remote and a downstream `origin` remote.

Suggested components:

- Linux kernel and Apple device trees
- m1n1 bootloader, hypervisor, and human-operated tracing tools
- U-Boot
- Mesa
- Arch Linux ARM package recipes and signed package repository
- Firmware extraction and synchronization tools
- Audio topology, ALSA UCM, speakersafetyd, and Asahi audio DSP
- Installer metadata only after all hardware gates pass

Use one topic branch per subsystem, for example `topic/t6030-dcp` or
`topic/j514s-usb3`. Do not combine unrelated drivers in one patch series. Keep
upstream history intact and rebase only with recorded test results.

## 8. Bring-up order

### Milestone 0: Reproducible baseline

- Build pinned m1n1, U-Boot, kernel, device trees, modules, and Arch packages.
- Produce SHA-256 manifests and compiler/version records.
- Run kernel configuration checks, `dtbs_check`, warnings-as-errors where
  practical, package validation, and clean-tree verification.
- Rebuild from a clean environment and confirm matching source manifests.

Exit: the human team can reproduce identical source state and functionally
equivalent artifacts without changing the Mac.

### Milestone 1: Controlled tethered boot

- Install the minimum human-reviewed boot environment only after the safety
  prerequisites pass.
- Boot a development kernel through tethered m1n1 with serial capture.
- Use an initramfs and external or RAM-backed development root where practical.
- Prove watchdog, panic capture, reboot, macOS return, and DFU detection.

Exit: 20 controlled boots, complete logs, no storage corruption, and reliable
return to macOS.

### Milestone 2: Core platform and power

- Validate AIC, DART/IOMMU, PMGR domains, SMC, SPI, I2C, GPIO, SPMI, RTC,
  watchdog, NVMe, PCIe, CPU frequency, CPU idle, thermals, and suspend.
- Audit every T6030 device-tree address, interrupt, power domain, clock,
  reset, and IOMMU mapping against human-observed traces.
- Add fault handling and timeouts before enabling dependent blocks.

Exit: clean boot, stress, thermal, idle, and 20-cycle suspend/resume tests with
no IOMMU faults, lockups, leaked power domains, or unsafe temperatures.

### Milestone 3: Internal display and DCP

- Reverse engineer and implement T6030 DCP initialization, framebuffer handoff,
  modesetting, eDP link management, panel power sequencing, backlight control,
  variable refresh behavior, hotplug state, sleep, and recovery.
- Test lid events, brightness limits, blank/unblank, compositor restart, panic
  display, suspend, and low-battery resume.

Exit: native panel operation at all advertised modes, 100 brightness cycles,
50 suspend/resume cycles, and no black screen, panel overdrive, or DCP fault.

### Milestone 4: GPU acceleration

- Identify the T6030 GPU generation, firmware ABI, power states, memory model,
  cache behavior, command submission, synchronization, faults, reset, and
  performance counters through human reverse engineering.
- Implement kernel DRM support and matching Mesa OpenGL/Vulkan support.
- Add robust timeout, reset, isolation, and suspend behavior before performance
  tuning.

Exit: Apple GPU renderer with no software fallback; OpenGL and Vulkan conformance
targets; 24-hour compositor/compute stress; suspend under load; successful GPU
fault recovery; no DART fault, corruption, or kernel warning.

### Milestone 5: USB-C, USB-PD, displays, and Thunderbolt

- Complete USB2, USB3, Type-C orientation, role switching, charging, USB-PD,
  ATC PHY, DP Alt Mode, HDMI, dock, and Thunderbolt bring-up.
- Test each physical port independently and in every supported orientation.
- Add hotplug, unplug-under-load, sleep, wake, fault, and over-current tests.

Exit: every port passes USB2/USB3 data and charging; HDMI and USB-C DP pass all
advertised modes; a Thunderbolt storage/network device passes sustained I/O,
hotplug, and suspend without data loss.

### Milestone 6: Media, camera, and audio

- Validate ISP camera operation, microphones, headphone jack, speakers, AVD
  H.264/H.265/VP9/AV1 decode, video encode, and ProRes where hardware permits.
- Do not play through internal speakers until the exact J514 calibration,
  speakersafetyd service, DSP graph, and amplifier thermal feedback are proven.
- Prove explicit hardware codec selection with simultaneous device telemetry.

Exit: stable camera capture; clean microphone and headphone paths; speaker
safety under load and suspend; visible 4K hardware decode and encode with no
software fallback; codec-by-codec evidence including AV1 and ProRes.

### Milestone 7: Security and accelerators

- Human-research SEP interfaces, Touch ID enrollment/authentication boundaries,
  key isolation, PMU access, and Neural Engine operation.
- Preserve biometric privacy and never expose raw biometric templates to Linux
  userspace.
- Threat-model DMA, firmware trust, rollback, reset, suspend, and multi-user
  isolation before exposing interfaces.

Exit: maintained drivers and userspace interfaces with a human-reviewed threat
model, negative tests, recovery behavior, and no reduction of macOS security.
If a block cannot be safely supported, document it as unsupported; do not mark
the platform complete.

### Milestone 8: Arch Linux ARM and Hyprland integration

- Package the exact tested kernel, modules, device trees, m1n1, U-Boot, Mesa,
  firmware tooling, audio stack, speaker safety, and platform services.
- Publish them in a signed test repository with rollback packages.
- Reuse the proven Hyprland/UWSM desktop configuration from the VM lab.
- Remove all QEMU-specific packages, boot files, mounts, and device assumptions.

Exit: a clean Arch installation reaches Hyprland with accelerated graphics,
working portals, power management, networking, Bluetooth, media, safe audio,
camera, and all ports. A full update and rollback both succeed.

### Milestone 9: Installer and release

- Develop installation only after every selected hardware feature passes.
- Use the supported Apple Silicon boot flow and only free space prepared by the
  reviewed installer path.
- Never teach Linux partitioning tools to modify existing APFS containers.
- Test install, interrupted install, reinstall, update, rollback, removal,
  recovery boot, and DFU revive on dedicated hardware.

Exit: repeated installs on dedicated J514s hardware with no APFS damage and a
documented recovery route. macOS removal is not part of initial release.

## 9. Per-patch evidence

Every human-authored patch series includes:

- Exact hardware model, board, SoC, firmware, and macOS pairing version.
- Upstream base commit and complete patch series.
- Register/interface provenance and sanitized trace references.
- Build configuration, tool versions, artifact hashes, and warning output.
- Positive, negative, fault-injection, suspend, resume, and recovery tests.
- Kernel logs with no new warning, panic, DART fault, lockdep fault, or sanitizer
  report.
- Power, thermal, and performance measurements before and after the change.
- Rollback instructions and a named human reviewer.

Compilation, a successful boot, or one working peripheral is not acceptance.

## 10. Daily-driver release gate

Run the existing native checker and hardware-decode proof, extended by human
developers for newly implemented features:

```bash
cd /Users/moriz/Projects/asahi-arch-hyprland-lab
./scripts/check-native-hardware.sh
./scripts/test-hardware-decode.sh /absolute/path/to/4k-sample.mp4
```

The final release requires at minimum:

- 10 cold boots and 10 warm reboots.
- 50 suspend/resume cycles, including overnight and low-battery cases.
- Seven days of normal work followed by a 30-day candidate period.
- 24-hour CPU, GPU, media, network, storage, and display stress runs.
- Every port, display path, radio, input, sensor, camera, microphone, speaker,
  headphone, codec, security block, and accelerator tested separately.
- Full system update, previous-kernel boot, bootloader rollback, package rollback,
  macOS boot, Recovery, Startup Options, DFU revive rehearsal, and documented
  recovery from an interrupted update.
- No data loss, unsafe audio, thermal violation, software-rendering fallback,
  software-codec fallback, unexplained power drain, lockup, or failed resume.

Only then can Linux become the default startup system. Keep macOS installed for
firmware updates and recovery through at least one stable release cycle.

## 11. Definition of complete

“Full M3 Pro support” means all hardware blocks in the official matrix and all
physical features on the J514s pass this plan, including items currently marked
WIP or TBA. Unsupported Touch ID, SEP, Neural Engine, GPU, Thunderbolt, PMU,
AV1, video encode, or ProRes means the project is not complete.

Use these labels accurately:

- **Bring-up:** a human developer can exercise the block with debug tooling.
- **Experimental:** normal users can test it, but failures or missing power
  management remain.
- **Daily-driver ready:** complete functionality, recovery, suspend, safety,
  packaging, and burn-in evidence exist.
- **Full platform:** every selected block is daily-driver ready on each claimed
  hardware model.

## 12. Immediate human next actions

1. Read and accept the licenses, policies, and contribution rules for every
   component before creating downstream forks.
2. Acquire the backup SSD, second Mac, tether host, cables, and test peripherals.
3. Finish the backup, sample restore, and DFU rehearsal.
4. Create the human-owned component forks and provenance register.
5. Recreate the Linux source on a case-sensitive Linux filesystem.
6. Reproduce the pinned baseline artifacts without changing the target Mac.
7. Review and approve a separate tethered-boot runbook before the first native
   operation.
8. Start with Milestone 0. Do not begin GPU, display, or installer work before
   the dependency and safety gates are satisfied.
