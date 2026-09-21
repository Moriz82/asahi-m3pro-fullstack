# J514s Linux and loader clock handoff

Development-only source checkpoint. No boot builder consumes these patches;
no installed client/image/module/DTB, storage, firmware or boot policy changed.
No target command, clock programming, live register/page-table access or
native boot occurred. The full hardware-support goal remains incomplete.

## Implemented path

Linux `12-t6030-clock-handoff.patch` applies after development patches 01–11
to `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`. m1n1
`10-j514s-clock-handoff.patch` targets
`60e53e7078c5cb7efce32d64bf50829e9401e44f`, changing only `src/kboot.c`.
The tested C export also includes the prior DART/configuration patches 02/03/08.

- J514s receives two named, **disabled** fixed-clock providers, `pixel` and
  `video`, with rate placeholders. DCP, both DARTs, mailbox and display remain
  disabled. No unrelated board fragment or runtime address is added.
- Before existing display handoff, m1n1 validates J514s/T6030/V14.7 identity,
  `/arm-io/disp0` clock IDs 348/412, equal nonempty uint32 frequency/type arrays,
  type values 0–3, ordered FDT references/names and both disabled providers.
  The DCP node itself has no `clock-ids`; it is not the ADT frequency source.
- It computes table indices relative to base 256. In-table zero and declared
  out-of-table zero are preserved. Only after every check succeeds are the two
  existing four-byte FDT properties updated in place. No allocation or FDT
  resizing occurs during publication; failures leave all FDT bytes unchanged.
  Older trees without a DCP alias and other boards are left unchanged.
- Linux acquires both mandatory T6030 clocks during platform probe, before
  its PHY/GPIO/component setup. Device-managed ownership lasts until platform
  removal; component bind/unbind reuses those handles.
  Legacy chips keep their existing unnamed component-lifetime clock path.
  A real zero-rate handle remains valid; a missing provider is a probe failure.
- V14.7 D408 consumes its provider/index and returns the selected rate. Invalid
  providers/indices return zero with a warning. The dispatcher rejects short
  headers and malformed D408 input/output sizes before clearing output or
  changing callback depth. Other callback schemas are not fully validated.
- A 12-byte packet header plus eight-byte input puts the uint64 response at
  offset 20. Existing output macros performed an unaligned typed store.
  Shared OUT/INOUT trampolines now copy returned bytes with `memcpy`, preserving
  their signatures and one handler invocation. No wire layout changed.

## Verification

- 275 actual Linux C cases pass ASan/UBSan across 12.3, 13.3 and 14.7: both
  target indices, unchanged legacy replies, valid zeros, invalid requests,
  eight alignment offsets, structured 65-byte replies, short/malformed
  packets, ownership failures and repeated component clock bind/unbind.
  The old code independently reproduces wrong-index and unaligned-store faults.
- 46 loader cases use the actual helper and bundled libfdt. They cover table
  boundaries, repeated changing rates, 34 malformed metadata/FDT variants,
  exact old-template rejection, current recorded-table values and old-tree/
  other-board no-ops. Every rejection checks the complete FDT is unchanged.
- Both suites pass on macOS and network-disabled AArch64 Linux. The integration
  runner feeds actual FDT rate readback into the real Linux callback fixture.
  ADT C calls and kernel clock/device-management services are explicit stubs;
  this is not a live Rust ADT parser, Linux OF/CCF registration or native
  device-lifetime test. Python parses the exact Apple input before fixture
  generation. Recorded 25G227 tables are test data, not 23J220 runtime proof,
  operating-rate measurements or constants for later boots.
- Eight existing topology tests and the bandwidth, register-map and null-flag
  suites pass. J516 DTBs are byte-identical. J514 retains ten prior compiler
  warnings, with no new clock warning; the prior three added topology warnings
  remain debt. This is not a full dt-schema pass.
- The complete Apple DRM module builds with W=1 without warnings/errors against
  the retained framebuffer kernel. The authoritative source-volume lock was
  held, with its kernel tree/output mounted read-only and a separate module
  output. No full kernel/M0 build or promotion ran. The complete m1n1 `kboot.c`
  freestanding object also builds with the pinned Makefile flags and `-Werror`.
- Full 12-patch replay matches all regular files and symlink targets: 1,417 Linux-export
  entries and 510 m1n1-export entries. Some inherited asset/header links do not
  resolve in these partial exports; the explicit link-aware comparison, not
  plain `diff` warnings about those links, establishes replay. Git administrative
  files are excluded from the source comparison. No linked
  bootloader was built. Bounded source review has no material finding.

Initial test-harness newline/unused-stub compilation errors were corrected
before accepted tests. Diagnostic comparison initially treated source-location
continuation lines as changes; normalization of locations confirms unchanged
warnings. Neither is counted as a reproduced production defect.
The full series check also exposed an older patch-11 packaging defect:
its new DTS fragment lacked `new file mode 100644`, causing `git apply` to
look for `dev/null`. The missing header was added, with the original patch
archived. All twelve patches now apply and reproduce the exact tested source;
the packaging correction changes no resulting DTS bytes or compiled artifact.

From the repository root:

```bash
AUDIT="$PWD/out/isolated/dcp-source-audit-20260906"
DRIVER="$AUDIT/clock-linux-replay/drivers/gpu/drm/apple"
python3 -O -B tests/m1n1-dcp-clock-handoff-self-test.py \
  "$AUDIT/clock-loader-replay" "$AUDIT/m1n1-clock-replay/proxyclient" \
  "$AUDIT/inputs/DeviceTree.j514sap.decoded" \
  "$AUDIT/config-clock-host-metadata.json" "$AUDIT/clock-j514s.dtb" "$DRIVER"
python3 -B tests/dcp-clock-self-test.py \
  "$AUDIT/display-linux-replay/drivers/gpu/drm/apple" --baseline
```

Evidence: `clock-handoff-closure.json`, `clock-handoff-final.log`,
`clock-c-baseline-final.log`, `clock-regression-*.log`, `clock-dt-regression.log`,
`clock-*-before/after.dtb`, and `compile-clock/` under that root. The latter
contains compiler logs, `appledrm.ko`, `kboot.o` and Linux integration results.
Image: `sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Kernel vermagic: `7.1.9.asahi1-m3devfb1+ SMP preempt mod_unload aarch64`.

The earlier display closure remains unmodified. Its live README/series and
patch-11 paths have advanced; their exact prior bytes are retained as
`clock-linux-readme-before.md`, `clock-linux-series-before.txt` and
`clock-topology-patch-before.patch`. The new
closure records these historical bindings instead of pretending the old
paths still contain the old revision.

## Remaining work

Providers are deliberately still disabled. Activation must be ordered with
fresh runtime reservations/IOVA handoff and compatible DCP firmware metadata;
otherwise Linux cannot obtain these clocks. Current loader display setup still
contains physical DART locking and lacks T6030 retained-mapping setup. Only
the new pure metadata helper was executed by the offline tests.

Live metadata provenance, operating-rate adequacy or dynamic rate changes,
reset/transport, panel/eDP sequencing and DMA coherency/quiescence remain open.
The dispatcher still lacks general shared-memory/context bounds and complete
per-callback size validation. Rejected packets have no recovery/resynchronization
policy beyond dropping the callback. No native milestone is promoted.
