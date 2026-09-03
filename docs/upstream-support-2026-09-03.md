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
