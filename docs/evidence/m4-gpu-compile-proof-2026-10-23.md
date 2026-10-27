# T6030/G15 GPU driver compile proof — 2026-10-23

Standalone compile of the Asahi DRM driver candidate against the pinned
Asahi tree. Proof-only toolchain (current Arch Linux ARM clang/LLVM; rustc
pinned to the kernel-compatible 1.93.1 via rustup; bindgen 0.72.1). This
proves the candidate COMPILES; it is not a runtime/hardware result.
hardware_acceptance=false.

```
base HEAD=77cb8f24c
patched HEAD=7e0387e83
CONFIG_EXPERT=y
CONFIG_RUST=y
CONFIG_DRM_ASAHI=m
CONFIG_DRM_ASAHI_G15_CANDIDATE=y
Rust is available!
--- build output ---
  RUSTC [M] drivers/gpu/drm/asahi/asahi.o
  DTC     arch/arm64/boot/dts/apple/t6030-j514s.dtb
  DTC     arch/arm64/boot/dts/apple/t6030-j516s.dtb
-rw-r--r-- 1 root root 14788488 Oct 23 16:28 drivers/gpu/drm/asahi/asahi.o
-rw-r--r-- 1 root root 68683 Oct 23 16:28 arch/arm64/boot/dts/apple/t6030-j514s.dtb
-rw-r--r-- 1 root root 68683 Oct 23 16:28 arch/arm64/boot/dts/apple/t6030-j516s.dtb
COMPILE_PROOF_OK
```

Toolchain note: the canonical hash-pinned Arch builder (Containerfile.arch)
could not be rebuilt — its pinned archlinuxarm packages have rolled off the
mirror. This proof used a current-toolchain image; canonical M0 evidence
still requires the repo's pinned pipeline. asahi.o is the linked module
object; a full .ko (modpost) was not produced. No GPU execution occurred.
