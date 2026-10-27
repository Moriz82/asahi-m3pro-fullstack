# Testing the T6030 / G15 GPU candidate on an M3 Pro Mac

A practical, honest guide to taking the M4 GPU candidate from this repo and
exercising it on real M3 Pro hardware (Mac15,6 / J514s 14" and Mac15,7 / J516s
16"). It is written for the machine's **owner-operator** — the native steps are
yours to run and confirm; nothing here is done remotely or automatically.

---

## 0. Read this first — what this does and does NOT do

- The candidate's G15 code is **non-functional scaffolding** behind
  `CONFIG_DRM_ASAHI_G15_CANDIDATE`. Its `probe()` **deliberately refuses** every
  `apple,agx-t6030` device, and its reverse-engineering-gated values are
  sentinels. **You will not get GPU acceleration from installing it.**
- What hardware testing *is* good for:
  1. **Validate the software-proven layers on real silicon** — that the T6030
     GPU device-tree node + driver match are correct and the driver binds-then-
     refuses cleanly (no crash), on both display sizes.
  2. **Harvest the real values** this repo's offline RE could not produce — the
     ADT-provided GPU properties and a firmware trace of the macOS driver's
     init-data — which are the actual inputs the driver needs to become
     functional.
- Installing Asahi Linux repartitions your disk. **It is reversible with care,
  but it carries real risk. Back up first and know the DFU recovery path.**
- `hardware_acceptance=false` stays true until a real bring-up validates the
  recovered values; a passing build/boot is **not** a working GPU driver.

**Prerequisites**
- An M3 Pro Mac (Mac15,6 or Mac15,7), macOS up to date, an admin account.
- A **full backup** (Time Machine or clone). Non-negotiable.
- ~60–100 GB free for a comfortable Linux install.
- A second Mac + USB-C cable **or** an Apple Configurator setup, in case you
  need a DFU restore. Know how to enter DFU for your model before you start.
- A stable internet connection.

---

## 1. Install the supported Asahi base (gives you Linux, not GPU accel)

Use the **official Asahi installer** — it is the supported, recovery-gated path
and sets up `m1n1` + U-Boot + the bootloader and partitioning for you. Do **not**
hand-partition.

In macOS Terminal:

```bash
curl https://alx.sh | sh
```

- Choose your M3 Pro machine when prompted. M3 / M3 Pro support is in the
  installer behind **Expert mode** (added 2026-09), so select that track if the
  default track does not list your model.
- Pick the desktop environment you want; let the installer resize macOS and
  create the Linux + EFI partitions.
- Finish in 1TR (the "pick your OS" step it walks you through), then boot Linux.

This base uses `linux-asahi` and **software rendering (LLVMpipe)** for graphics —
there is no GPU acceleration on M3 Pro from anyone yet. That is expected. If you
only wanted a working Linux, stop here; the GPU candidate below changes nothing
about day-to-day use.

> This repo's own gated bring-up procedure (m1n1 tethered boot with recovery and
> evidence gates) is in [`docs/milestones/01-controlled-tethered-boot.md`](milestones/01-controlled-tethered-boot.md)
> and [`docs/dualboot-candidate.md`](dualboot-candidate.md). The official
> installer above is the simpler supported route for testing.

---

## 2. Build the candidate kernel with the GPU patches

You can build **on the Mac under Linux** (simplest) or cross-compile. On-device:

```bash
# 2.1 Get the exact pinned Asahi source this repo targets
git clone https://github.com/AsahiLinux/linux.git
cd linux
git checkout 77cb8f24c2381a8abb7272d7bbdec548d6426a8a

# 2.2 Apply this repo's candidate patch series (adjust REPO to your checkout)
REPO=/path/to/asahi-m3pro-fullstack
git config user.email you@example.com; git config user.name you
for p in $(cat "$REPO"/patches/linux-gpu-development/series); do
    git am "$REPO/patches/linux-gpu-development/$p"
done
for p in $(cat "$REPO"/patches/linux-gpu-development-driver/series); do
    git am "$REPO/patches/linux-gpu-development-driver/$p"
done

# 2.3 Configure: asahi defconfig + the G15 candidate (EXPERT-gated, off by default)
make ARCH=arm64 LLVM=1 defconfig
./scripts/kconfig/merge_config.sh -m .config arch/arm64/configs/asahi.config
./scripts/config --enable  CONFIG_EXPERT
./scripts/config --module  CONFIG_DRM_ASAHI
./scripts/config --enable  CONFIG_DRM_ASAHI_G15_CANDIDATE
make ARCH=arm64 LLVM=1 olddefconfig
grep -E 'CONFIG_RUST=|CONFIG_DRM_ASAHI=|CONFIG_DRM_ASAHI_G15_CANDIDATE=' .config

# 2.4 Build kernel + modules + both board DTBs
make ARCH=arm64 LLVM=1 -j"$(nproc)"
make ARCH=arm64 LLVM=1 apple/t6030-j514s.dtb apple/t6030-j516s.dtb
```

Requirements on the Linux side: the kernel's Rust toolchain (rustc **1.93.1**,
`rust-src`, `rustfmt`, `bindgen` 0.72.1) and clang/LLVM; `make rustavailable`
must pass. (This repo already proved this source + the patches compile — see
[`docs/evidence/m4-gpu-compile-proof-2026-10-23.md`](evidence/m4-gpu-compile-proof-2026-10-23.md).)

Install the kernel/modules the way your distro expects (e.g. copy `Image`,
`make modules_install`, install the DTB for your board, update the bootloader),
then reboot into it.

> **Safety:** keep your known-good Asahi kernel as the default boot entry and add
> the test kernel as a *separate* entry, so a bad boot falls back. The candidate
> is gated off unless you set the three CONFIG options above, so a normal build
> is unaffected.

---

## 3. What to observe — the real test

Because the driver refuses to probe by design, "success" here is **clean,
expected behaviour**, not acceleration:

```bash
# The driver should match the T6030 GPU and REFUSE it cleanly (no crash/taint)
sudo dmesg | grep -iE 'asahi|agx|t6030|drm'
# Expect: driver recognizes apple,agx-t6030 and declines (G15 candidate).

# Confirm the GPU device-tree node is present on YOUR board (14" or 16")
ls /proc/device-tree/soc/gpu* 2>/dev/null
for p in compatible firmware-abi; do
  echo -n "$p: "; tr -d '\0' < /proc/device-tree/soc/gpu*/apple,$p 2>/dev/null | xxd | head -1
done
cat /proc/device-tree/soc/gpu*/compatible | tr '\0' '\n'   # apple,agx-t6030/g15x/g15s
```

Checklist (this is what hardware confirms that the offline work could not):
- [ ] The patched kernel boots on your M3 Pro.
- [ ] The GPU node exists on the DT for **your** panel (J514s 14" or J516s 16").
- [ ] The asahi driver binds the match and refuses without panicking or tainting.
- [ ] System is otherwise stable (CPU/display/USB unaffected).

Report these back and they close the "boot/attach on real silicon" gap. They do
**not** make `hardware_acceptance` true — that needs a *functional* driver.

---

## 4. Harvest the real values (the actual payoff)

This is where hardware earns its keep: it produces the values the macOS-only RE
in this repo could only partially recover.

**4.1 ADT-provided GPU properties** (fill the DT's ADT-gated fields):

```bash
# The real per-machine GPU config lives in the Apple Device Tree, exposed by Linux
for k in gpu-core-count gpu-num-perf-states perf-states perf-states-sram; do
  echo "== $k =="; find /proc/device-tree -name "*$k*" -exec sh -c 'tr -d "\0" <"$1"|xxd|head' _ {} \;
done
# Also the firmware version triple the driver reads as apple,firmware-version
find /proc/device-tree -path '*gpu*firmware*' -print
```

Record `gpu-core-count` (expect 18 on M3 Pro), the DVFS operating points
(frequency / voltage / power), and the firmware-version triple. These go into
the device tree's GPU node (replacing the RE-gated OPP/firmware sentinels),
**validated because they came off your actual machine.**

**4.2 Firmware trace for the HwConfig constants** (the hard part, the Asahi way):

The numeric `HwConfig` tuning constants (`da`/`db`, `HwDataShared`, `unk_coef`,
`sram_k`, temp masks) are built by the macOS AGX kernel driver. The correct,
validatable way to get them is to **trace macOS under the m1n1 hypervisor** and
capture the init-data the driver sends — which must match the firmware
interface word this repo already recovered.

```bash
# On a SECOND machine (the "host"), with the Asahi m1n1 proxyclient checked out,
# tethered to the M3 Pro over USB, boot macOS under the hypervisor and trace AGX:
git clone https://github.com/AsahiLinux/m1n1.git && cd m1n1
#   put the Mac in the m1n1 proxy state per the Asahi tethered-boot docs, then:
python3 -m m1n1.proxyclient.tools.chainload -r macos   # boot macOS under the HV
#   and use the AGX tracer (m1n1/proxyclient/m1n1/trace/agx.py) to capture the
#   GPU init-data / HwConfig the macOS driver programs.
```

See this repo's [`docs/usb-debug-linux.md`](usb-debug-linux.md) and
[`docs/milestones/01-controlled-tethered-boot.md`](milestones/01-controlled-tethered-boot.md)
for the tethered-boot and USB-console setup, and the private RE notes staged at
`/Volumes/yuh/apple-firmware/RE-STAGING-NOTES.md` for the firmware ABI anchor
(the init-data interface word) your trace should line up with.

**4.3 Feed values back — through the honesty gate only:**

Put recovered values into the candidate and re-run the gate; never hand-wave a
value in:

```bash
cd "$REPO"
./scripts/verify-m4-gpu-source-candidate.sh --static   # must stay honest
```

Only once values are (a) recovered from hardware/trace and (b) exercised on the
GPU does `hardware_acceptance` get to change — and that step (command
submission, rendering, OpenGL/Vulkan conformance, suspend, 24-hour stress, the
two-person review in [`docs/milestones/04-gpu.md`](milestones/04-gpu.md)) is the
real finish line.

---

## 5. Reverting

- To remove just the test kernel: delete its boot entry and files; your stock
  Asahi kernel keeps booting.
- To remove Asahi entirely: use the Asahi uninstaller / `diskutil` to delete the
  Linux + EFI partitions and expand macOS back (or DFU-restore with Apple
  Configurator for a clean slate). Keep your backup until you have verified
  macOS boots normally again.

---

## 6. Honest summary

- Installing the candidate validates the **software** layers on real silicon and
  lets you **harvest the real ADT + firmware-trace values** — the inputs this
  offline work was missing.
- It does **not** deliver GPU acceleration; the driver refuses to probe until the
  recovered values are filled in *and* validated on the GPU.
- Keep backups and a recovery path at every step. The native install and trace
  are operator actions on your own machine; run them deliberately.
