# M3 Pro upstream support checkpoint — 2026-09-03

Target: `Mac15,6` / `J514s` / `T6030`.

## Verdict

The statement “Linux 7.3 supports this chip” is true only for initial upstream
bring-up. Linux 7.3 is currently `7.3-rc1`; the latest stable release is 7.2.3.
The upstream T6030 change describes its device trees as minimal and enumerates
CPU cores, timer, interrupt controller, power states, watchdog, serial,
pin-controller, I2C, PWM keyboard illumination, and the boot framebuffer.
It does not provide full internal-display/DCP or AGX GPU support.

Primary evidence:

- [kernel.org release data](https://www.kernel.org/releases.json)
- [upstream initial T6030/J514s commit](https://github.com/torvalds/linux/commit/e81af013dbdd84c4e13f92c304eee555b1f9447a)
- [Linux v7.3-rc1 J514s device tree](https://github.com/torvalds/linux/blob/v7.3-rc1/arch/arm64/boot/dts/apple/t6030-j514s.dts)
- [Linux v7.3-rc1 T6030 SoC description](https://github.com/torvalds/linux/blob/v7.3-rc1/arch/arm64/boot/dts/apple/t6030.dtsi)
- [Linux v7.3-rc1 shared J514/J516 description](https://github.com/torvalds/linux/blob/v7.3-rc1/arch/arm64/boot/dts/apple/t603x-j514-j516.dtsi)
- [Asahi M3 feature matrix](https://asahilinux.org/docs/platform/feature-support/m3/)
- [Asahi Linux 7.2 progress report](https://asahilinux.org/2026/08/progress-report-7-2/)

## Exact scope of the 7.3 label

At this checkpoint, `7.3` is mainline `7.3-rc1`; the latest stable kernel is
7.2.3. The accepted upstream commit adds minimal T6030/J514s device trees with
CPU cores, timer, AIC, power states, watchdog, UART, pin control, I2C, keyboard
backlight PWM, and the boot framebuffer. A boot framebuffer is not DCP display
support or GPU acceleration.

The Asahi matrix uses `linux-asahi (7.3)` for the M3 Pro device tree, AICv3,
UART, watchdog, I2C, GPIO, and keyboard backlight. In the matrix's terminology,
that means the support is stable in the downstream `linux-asahi` tree and is
expected upstream by the named release. It is not a statement that every M3 Pro
feature is in mainline 7.3.

Other blocks already marked `linux-asahi`, including NVMe, PCIe, CPU frequency
and idle, suspend, DART, SMC, SPMI, RTC, keyboard, touchpad, battery, radios,
audio, camera, and SD, should be reused from the downstream tree and validated
on J514s rather than reimplemented. The same live matrix still marks DCP,
USB2/3, DP Alt Mode, USB-PD, installer, display, brightness, and HDMI as WIP,
while GPU, PMU, SEP, Touch ID, Neural Engine, video encode, and ProRes are TBA.

The August progress report describes development success for ACE3/SPMI, USB 3,
Thunderbolt, webcam, microphones, and near-feature-parity DCP work. Those
reports identify code to consume, but the feature matrix remains the release
readiness authority: development success does not promote a WIP or TBA item.

The pinned downstream AVD source statically enumerates AV1 on the T8122
fallback selected by the T6030 node. That is a source candidate, not a runtime
support claim, and does not override the feature matrix's current AV1 caveat.

An independent source cross-check found the same boundary. Mainline
`t6030-j514s.dts` supplies the machine compatibility and a loader-populated
simple framebuffer, while the shared J514/J516 description enables only the
serial port and keyboard-backlight PWM. The v7.3-rc1 target description has no
NVMe, PCIe, USB, SPMI, SMC, MTP, ISP, or AVD nodes. By contrast, the pinned
downstream T6030 description is 1,536 lines versus mainline's 524 and includes
those platform blocks plus their J514 wiring. The downstream build is therefore
not made redundant by 7.3.

The only newly redundant work would be a local reimplementation of the minimal
T6030/J514s device tree or its generic bindings; this repository has no such
duplicate. The local schema-lint patch remains a downstream validation fix, not
an M3-support implementation. If the project later rebases to mainline, that
patch must be re-evaluated against mainline's different PCIe binding structure
instead of carried automatically.

## Reuse map

| Milestone | Current official status | Project action |
| --- | --- | --- |
| M0–M1 | Initial J514s DT is in 7.3-rc1; native installer remains WIP | Keep the pinned reproducible downstream baseline and native gate. Do not replace it with an RC or call the DT a hardware boot result. |
| M2 core/power | Core blocks, NVMe, PCIe, CPU frequency/idle, and sleep are available in `linux-asahi`; several core compatibles and the initial DT target 7.3 | Integrate and validate official work. Do not reimplement it. |
| M3 display/DCP | Official matrix: WIP. The progress report says the macOS 14.8.3 DCP ABI is almost at feature parity | Track and consume the reviewed Asahi implementation when it is published for wider testing. Keep native acceptance blocked. |
| M4 GPU | Official matrix: TBA for M3 Pro | Genuine unresolved gap. Do not treat boot framebuffer or existing older-SoC AGX code as T6030 acceleration. |
| M5 ports | New ACE3/SPMI, USB 3, and Thunderbolt work exists in Asahi development; the feature matrix still marks user-ready states WIP/TBA | Reuse the official series, but do not promote volatile topic branches or claim acceptance without pinned review and native evidence. |
| M6 media/audio | Webcam, microphones, speakers, jack, and hardware decode work is reported in `linux-asahi`; video encode and ProRes remain TBA | Consume official drivers/configuration. Keep unsupported paths explicit instead of building duplicates or inventing passing evidence. |
| M7 security/accelerators | PMU, SEP, and Neural Engine are TBA | Leave blocked until public support or a separately justified lawful research task exists. |
| M8–M9 integration/release | Fedora/Arch integration can be prepared, but the M3 Pro installer and key display paths remain WIP | Continue software-only packaging tests; no native install or release claim. |

The Asahi matrix defines `linux-asahi (7.3)` as stable in the downstream Asahi
tree and expected to reach upstream by 7.3. It does not mean every platform
feature is present in mainline 7.3. This checkpoint is time-sensitive and must
be refreshed before selecting a later kernel or beginning subsystem work.

## Source-head audit at 2026-09-03T10:28:45Z

The release-facing source pins remain deliberate:

- `AsahiLinux/linux:asahi` and `Moriz82/linux:asahi` both resolve to the pinned
  `77cb8f24c2381a8abb7272d7bbdec548d6426a8a` baseline.
- `AsahiLinux/m1n1:main` and `Moriz82/m1n1:main` both resolve to the pinned
  `60e53e7078c5cb7efce32d64bf50829e9401e44f` baseline.
- `asahi-alarm/PKGBUILDs:main` and `Moriz82/PKGBUILDs:main` both resolve to the
  pinned `07b5b2d8fc7addf4625a5500365177eb88129b5b` baseline.
- `AsahiLinux/linux:asahi-wip` resolves to
  `ca9a850f237f98949996eefb8980371a5d58c886`. GitHub's comparison reports it
  as 394 commits ahead and 47 behind the stable pin. Its history contains
  explicit `WIP` and `DO NOT MERGE` commits plus merges of DCP, GPU, ISP, and
  SPMI/Type-C topic branches. It is research input, not a release candidate.
- `AsahiLinux/u-boot:asahi-releng` has moved to
  `dbd2154cb0d3a5552505cfcc00a8b5f8da737030`, while the user fork and M0 remain
  pinned at `3b233f59d0b6b57eae5add46a6fa7787ea11388e`. The newer history includes
  Apple M3 Pro/Max and MTP work, but it is also based on a substantially newer
  U-Boot line. It requires a separate isolated candidate build and review
  before promotion; it does not invalidate the byte-reproducible M0 handoff.

These checks prevent duplicate implementation and prevent an attractive but
volatile topic aggregate from silently becoming the canonical source. They do
not establish runtime hardware support.
