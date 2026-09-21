# J514s bootloader configuration and clock-provider contract

Offline development checkpoint. No boot builder selects these changes; no
installed client, bootloader, DTB, module or image changed. Cached IORegistry
metadata was read, but no device command, register/page-table read, reset,
storage, firmware or boot-policy operation occurred.

## Bootloader correction

`patches/m1n1-dcp-development/08-j514s-display-config.patch` applies to m1n1
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. It is independent of patches 01–07
and changes only `src/display.c` and `src/dcp.c` in a disposable export.

- The selector recognizes J514s and uses the exact ADT paths for internal DCP
  and its two DARTs, with PMGR name `DISP_CPU`. It does not extend this to J516s
  or claim other M3 variants. The saved Apple tree has virtual DCP0-V gate 433,
  whose physical parent is DISP_CPU 183. The old `DISP0_CPU0` name is absent.
- `dcp_init` previously copied the configured reset name/die only inside the
  external-DPTX branch. Internal initialization could therefore use the M1
  default or a stale previous external target. It now copies validated reset
  identity for both paths. The external V13.5 firmware gate is unchanged and
  rejects before power calls or reset-identity mutation.
- Null configurations and empty, unterminated or overlong reset names are
  rejected before any hardware-facing dependency. The existing 16-byte reset
  buffer is preserved; valid names must terminate within it.
- Two identical J473 initializers under `USE_DCPEXT=0` were removed because
  those fields are already initialized after `#endif`. Both DPTX/GPIO values
  and firmware gating remain present in both configurations.

This establishes configuration selection and argument routing, not successful
physical reset, compatible iBoot-DCP transport, safe shutdown or native panel
operation. Existing global reset state still assumes serialized, single-DCP
ownership. This patch does not fix ignored PMGR/reset return values, DART/IOVA
initialization failures, mapping publication or teardown/quiescence.

## Verification

`tests/m1n1-dcp-config-self-test.py` extracts the actual configuration types,
all configuration declarations, selector and complete `dcp_init`/`dcp_shutdown`
functions. Its C fixture replaces hardware-facing dependencies with in-process
stubs. Configuration fields remain const; malformed inputs are constructed at
initialization, not written through cast-away const pointers.

- 65 selector/lifecycle cases per `USE_DCPEXT` configuration, 130 total, pass
  ASan/UBSan with `-Wall -Wextra -Werror`. Coverage includes exact J514s values,
  unchanged legacy selectors, missing nodes, poisoned previous reset state,
  internal and external flows, firmware rejection, ten injected failure
  stages and 25 name lengths. J473 has explicit value, success and version-
  rejection checks in both modes.
- Four baseline controls reproduce the original selector and reset-routing
  failures, independently under both external configurations. The baseline
  alternate mode's two duplicate-initializer warnings are retained; only that
  old-source baseline permits those warnings instead of treating them as errors.
- Fresh patch replay is byte-identical to the tested source export. Optimized
  Python and Linux-container runs pass all 130 cases. Linux enables leak
  detection; macOS does not support it. These checks test ownership in this
  fake lifecycle only, not actual device/DMA lifetime.
- Both complete production C translation units compile to AArch64 freestanding
  objects using the pinned Makefile flags plus `-Werror`, without diagnostics.
  No linked bootloader or full Linux/M0 build was made. The first combined
  container run reached the later test command but its non-executable `/tmp`
  prevented test execution; the corrected test-only run passed. Initial fixture
  const/initializer and macOS leak-detector errors were resolved before accepted
  runs; they are not counted as baseline fault reproductions.
- Bounded read-only review found no remaining issue. An initial concern about
  deleted J473 fields was retracted after checking the shared initializers and
  adding the explicit J473 lifecycle regression.

From the repository root:

```bash
AUDIT="$PWD/out/isolated/dcp-source-audit-20260906"
python3 -O -B tests/m1n1-dcp-config-self-test.py \
  "$AUDIT/m1n1-config-replay" "$AUDIT/m1n1-dma-replay/proxyclient" \
  "$AUDIT/inputs/DeviceTree.j514sap.decoded"
```

Evidence: `config-baseline-verified.log`, `config-optimized-replay.log`,
`config-linux-final.log`, `compile-config/{dcp.o,display.o,build-result.json}`
and `config-closure.json`, all under that evidence root. Tests use an existing
read-only construct dependency snapshot; no packages or controller updates.
Container image: `sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
No canonical source volume is mounted or changed by these runs.

## Clock research: lookup resolved, not a fixed constant

IDA analysis uses the exact 23J220 kernelcache SHA-256
`1df6ef30ea65afe3aecbdd4ea2c134690180d8904af459ea52a1fa8e9b15ea07`.
The original Apple input/signature limitations in the bandwidth report remain.

| Function | Exact result |
| --- | --- |
| `AppleH15IO::start`, `0xfffffe0009df7b08` | Calls vtable +2312 with clock-ID base 256. |
| AppleH15IO vtable `0xfffffe0007f458f8` | Method base +16: +2312 is `getIODeviceClocks`; +2192 is `getClockFrequency`. |
| `getIODeviceClocks`, `0xfffffe0008f5c04c` | Reads equal-length uint32 frequency/type arrays, produces 72-byte records and retains the ID base. |
| `getClockFrequency`, `0xfffffe0008f5be58` | Extended clock IDs index records relative to that base; the first uint64 is the frequency. |
| D408 wrapper, `0xfffffe000ab65d34` | Consumes provider and clock-index uint32 arguments; returns one uint64. It does not ignore the requested index. |

The existing `AppleARMIODevice` lookup selects the provider's `clock-ids`
entry before the parent lookup. Saved J514s display IDs are 348 and 412, thus
extended-table indices 92 and 156. Current macOS build **25G227**, not 23J220,
exposes AppleH15IO and 176-entry cached frequency/type arrays. Its selected
entries are 712,000,000 Hz and zero. This is a dated metadata observation, not
a measured clock, a guaranteed operating frequency or future-boot constants.

The saved 23J220 template contains 96 zero frequency entries and no type array;
it cannot supply a valid second clock or a meaningful first one. The actual
firmware consumer also uses `minimum-frequency` and timing-derived values;
zero and fallback paths are meaningful, so blindly substituting a frequency
for every request is incorrect. In particular, the Python client's old
533,333,328-Hz constant and Linux's single-clock, argument-ignoring D408
callback are not a verified T6030 implementation.

Exact exports: `config-clock-provider-analysis.json` and allowlisted
`config-clock-host-metadata.json`. Raw IORegistry trees remain in process
memory, not the repository or shared vault.

## Next safe work

Implement a metadata-driven, argument-aware clock contract using the fresh
boot's ADT, with strict range/type/length checks and no constants copied from
current macOS. Then connect the Linux binding and loader publication path
without enabling DCP early. Runtime reserved-memory/IOVA handoff, panel/eDP
sequencing, DMA lifetime and hardware acceptance remain separate open work.
The development Linux display nodes remain disabled.
