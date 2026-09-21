# T6030 Linux bandwidth and disabled display topology

Development-only, offline checkpoint. Patches 10/11 are not selected by any
boot builder. No installed DTB, module, image, storage or boot-policy change;
no new boot or native display acceptance.

## Changes and evidence

Base Linux: `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`. Apply the isolated
`patches/linux-dcp-development/series` (01–11) in order, never in a source
volume owned by a build. Evidence root throughout this report:
`out/isolated/dcp-source-audit-20260906/`.

Patch 10 implements the [previously resolved bandwidth contract](dcp-bandwidth-development-2026-09-06.md)
in Linux. Firmware-version-specific 60-byte reply structures preserve the
legacy wire layout; V14.7 names scratch width at byte 44 and status at byte
56. Only V14.7 plus `apple,t6030-dcp` selects the 8-byte scratch contract.
Resource validation checks the entire access width and prevents unsigned
subtraction underflow on undersized resources. The legacy doorbell contract
and zeroed unused reply bytes remain unchanged.

Patch 11 adds `t6030-display.dtsi`, included only by J514s. The DCP, display
subsystem, mailbox and both DART nodes are **disabled**. Its resource-only
scratch node has no driver-compatible string. This is reviewed static wiring,
not a complete probeable configuration or permission to enable it. The J516s
DTB remains byte-identical.

The exact saved 23J220 Apple tree, SHA-256
`4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478`,
supplies translated physical resources and mapper relationships:

| Component | Resource or relationship |
| --- | --- |
| DCP coprocessor / mailbox | `0x28ec00000/0x4000`; mailbox at `0x28ec08000/0x4000` |
| Display resources 0–4 | `0x28c000000/0x690000`, `0x28c800000/0x690000`, `0x28d320000/0x4000`, `0x28d344000/0x4000`, `0x28e800000/0x800000` |
| Scratch resource 5 | `0x3503d0000/0x4000`, offset `0x988`, width 8; appended once through `apple,bw-scratch` |
| DCP DART / mapper | `0x28d30c000/0x4000`, SID 5 |
| Display DART / mappers | `0x28d304000/0x4000`, display SID 0, PIODMA SID 4 |
| DART address windows | Base 1 TiB, size 64 GiB; shared IRQ 609 |
| DCP power | Existing `ps_disp_cpu`, through DISP_FE and DISP_SYS |

The ADT's larger ASC wrapper is split using the existing Linux register
window convention and m1n1's mailbox offset. Named mailbox IRQs 589–592 use
the same ADT-to-Linux ordering as this SoC's existing SMC and MTP nodes; the
test checks both independent comparisons. T8110 DART and ASC mailbox-v4
fallbacks are existing driver layouts, not new hardware implementations.
The DCP uses the generic internal `apple,dcp` match; there is no new
SoC-specific driver match-data or claimed native support.

## Validation

- Actual extracted C structure, callback and resource-parser functions run
  under ASan/UBSan with `-Wall -Wextra -Werror`: three positive firmware
  executables and three rejected mutants. Each positive profile runs 131
  resource cases (393 across profiles), including undersized and boundary
  resources, phandle failures and unchanged publication on failure. Tests
  compare all 60 reply bytes. The old baseline reproduces the faults.
- Eight exact-input DT tests pass, also under Python `-O` on fresh replay.
  Five independently corrupted DTBs are rejected: enabled DCP, wrong SID,
  wrong scratch slot, swapped mailbox IRQs and wrong DMA window. The original
  target tree cannot satisfy the new topology checks.
- Both board DTBs compile in case-sensitive Linux temporary source/output
  directories. J514s fresh replay matches its tested DTB byte-for-byte;
  J516s is unchanged before/after. The tested driver and DT source exports
  likewise match fresh ordered patch replay.
- Existing register-mode and null-flag C regressions pass. The complete
  configured Apple DRM module, including all three firmware objects, compiles
  and links with `W=1`: no warnings or errors. Bounded read-only review found
  no material issue.

There are **three additional DT compiler warnings**, inherited from existing
DCP conventions: a display-subsystem node without `reg/ranges`, unused DCP
address/size cells for its PIODMA child, and the loader's `disp0_piodma` alias
containing an underscore. These are retained debt, not suppressed. No full
dt-schema pass is claimed: DCP/display-subsystem bindings are absent, and
SoC-specific compatible enumeration also needs review.

Focused test commands from the repository root:

```bash
AUDIT="$PWD/out/isolated/dcp-source-audit-20260906"
python3 -B tests/dcp-bandwidth-self-test.py \
  "$AUDIT/display-linux-replay/drivers/gpu/drm/apple"
python3 -O -B tests/t6030-display-dt-self-test.py \
  "$AUDIT/m1n1-dma-replay/proxyclient" \
  "$AUDIT/inputs/DeviceTree.j514sap.decoded" \
  "$AUDIT/display-j514s-replay.dtb" \
  "$AUDIT/display-t6030-j514s-before.dtb"
```

The isolated module build used image
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`,
read-only/network-disabled execution, the retained framebuffer-kernel build
and a separate temporary module output. It acquired the authoritative
source-volume lock before compilation; the job finished and released it.
Inside that container, the build command was:

```bash
exec 9</workspace/.milestone0-build.lock
flock -xn 9 || exit 75
make -C /workspace/src/linux \
  O=/workspace/build/linux-development-framebuffer \
  M=/driver MO=/tmp/dcp-module ARCH=arm64 W=1 -j4 modules
```

No full Linux or M0 rebuild/promotion occurred. Module evidence:
`compile-display/module-build.log`, `appledrm.ko` and `Module.symvers` in that
directory. Module SHA-256:
`d3f813486547992b60d8bb23b5367547679c25258417845d9f22944178001d6d`.
Replay/test logs are `display-*.log`; exact patch/test/source/DTB/module hashes
are recorded in `display-closure.json`. Evidence copies are write-protected.

## Remaining blockers and next safe work

1. The driver requires an unnamed clock. ADT IDs 348/412 do not supply its
   frequency: the saved base frequency table contains zeros. IDA analysis of
   `IOMFB::ServiceRelay::getClockFrequency`, `AppleARMIODevice` and `AppleARMIO`
   resolves lookup indirection, not the actual target value. Do not copy an
   older SoC's fixed frequency. Static pseudocode is retained in
   `target-kernelcache/display-clock-lookup.json`.
2. Panel/eDP metadata, power sequencing, brightness and supported surface
   capabilities remain unproved. No dummy geometry or panel node was added.
3. m1n1 lacks the exact-target display setup and T6030 runtime reservation/
   IOVA handoff. Its fallback PMGR name is wrong for this target. Existing
   reservation code initializes/enables DARTs and is not a read-only metadata
   path; adding a SoC branch or flipping one status property is insufficient.
   Future work must account for every disabled dependency and fresh boot-time
   mappings. Current macOS carveout addresses must never become constants.
4. DMA mapping cache/ownership, attributes and quiesce-before-unmap remain
   unresolved. The Python manager's raw stream mappings and true wide IOVA
   encoding also remain open; see [DMA prerequisites](dcp-dma-prerequisites-2026-09-06.md).

Continue with offline clock/provider and loader-contract analysis. Keep this
fragment disabled until those contracts and activation order are implemented
and reviewed; actual panel and full-laptop acceptance still require separately
approved hardware observation.
