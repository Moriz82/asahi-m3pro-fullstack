# DCP register-address modes, 2026-09-06

## Outcome and boundary

Exact 23J220 host and T6030 firmware analysis resolves D411's formerly unknown
first output. It is a **DCP-side address**, not always an IOVA: the host returns
the physical address in both address fields when request flag bit 31 is clear.
With bit 31 set, the first field instead contains a real DCP DMA address.
The bandwidth initialization path requests the direct mode (`PROV`, `0x100`).

Two development-only fixes are available:

- `patches/m1n1-dcp-development/05-t6030-direct-registers.patch`: implements the
  verified direct-register callback for J514s/T6030/V14.7, with all three
  output pointers, target/resource checks and no hardware access. DMA requests
  and unverified profiles remain rejected. It also restores callback nesting
  depth in `finally`, so handler/decoder exceptions do not corrupt later calls.
- `patches/linux-dcp-development/09-d411-register-mapping.patch`: V14.7 honors
  physical versus DMA mode. Modern DMA mapping failure returns zeroed outputs
  with nonzero status instead of reporting success with `DMA_MAPPING_ERROR`.
  Earlier firmware address-selection behavior is otherwise unchanged.

Both apply only to disposable source exports. Linux patch 09 is appended to
the **development-only** series, which no boot builder consumes. No canonical
source, pin, installed module/client, candidate, ESP, partition, firmware or
boot policy changed. No target command, register/page-table read, DART/device
initialization or new boot occurred. This is not full D411 lifecycle, display
or native hardware acceptance.

## Binary evidence

Inputs, digest verification and signature limits are those of the preceding
[bandwidth analysis](dcp-bandwidth-development-2026-09-06.md). Host kernelcache
SHA-256 is `1df6ef30ea65afe3aecbdd4ea2c134690180d8904af459ea52a1fa8e9b15ea07`;
decoded T6030 firmware SHA-256 is
`fc54724dcdfcaa8c285c5171258dccd85d5c0713bdc111935d8c667d52107883`.
IDA reads were static; firmware was not executed. `AUDIT` below means
`out/isolated/dcp-source-audit-20260906/`.

Host `ServiceRelay_RemoteCalls::D411_callback__` at `0xfffffe000ab661b4` decodes
three u32 inputs and three output-null bytes; outputs occupy offsets 0, 8 and
16, with status at 24. Firmware `0x177fa4` independently requests 16 input and
28 reply bytes. The existing client/header wire schemas already match these
sizes; the Python manager's callable signature did not accept the first output.

| Request/reply field | Offset | Meaning |
| --- | ---: | --- |
| request object/index/flags | 0/4/8 | `PROV` encodes as little-endian `0x50524f56` |
| request output-null flags | 12/13/14 | first address, physical address, length |
| reply first address | 0 | PA when bit 31 clear; DCP DMA address when set |
| reply physical address | 8 | provider resource PA |
| reply length/status | 16/24 | u64 length, u32 link status |

`IOMFB::ServiceRelay::mapDeviceMemoryWithIndex`, `0xfffffe000ab35f60`, checks
all output pointers and caches a descriptor per service/register index. A
signed flag test selects the mode. For direct mode it assigns descriptor
`getPhysicalAddress()` to both outputs. For DMA mode it calls
`DCPLink::map_physical`, then uses `DCPMemoryDescriptor::get_dcp_dva()` for the
first output and `getPhysicalAddress()` for the second. The relevant vtable
slots are 88 and 96 after the address-point prefix. A failed prepare clears
the cached-valid byte and all outputs; the wrapper converts its error status.

This is the actual bandwidth caller, not an assumed mode:

1. T6030 firmware `0x1e3c20` asks its provider for scratch register index 5
   with flags `0x100` for the eight-byte dashboard configuration.
2. Provider accessor `0x19bc2c` constructs service `PROV` via `0x178cd8`.
3. That constructor sets vtable `0x625858`; slot `0xa0` points to `0x177fa4`.
4. `0x177fa4` forwards the flags unchanged through D411. It passes reply
   address 0 to RTK memory-map creation (`0x176c30`), then records reply PA 8.
5. Consequently this request needs the physical address in both fields, not
   a newly allocated IOVA and not a dummy zero DMA output.

Evidence: `target-kernelcache/{d411-callback,service-map-device-memory,
dcp-map-physical,memdesc-map-physical,dcp-memory-vtable,dcp-get-dva,dcp-get-pa,
service-release-mappings}.json` and `workspace/ida/{d411-call,
d411-call-disassembly,provider-service,service-constructor,register-memory-map,
pmp-register-init}.json` under AUDIT. Raw instructions resolve decompiler
prototype omissions in the firmware memory-map constructor call.

## Validation and replay

Sources: Linux `77cb8f24c2381a8abb7272d7bbdec548d6426a8a` with development patches
01–09; m1n1 `60e53e7078c5cb7efce32d64bf50829e9401e44f` with Python patches
01, 04 and 05. Fresh private-Git exports replay every listed patch and match
the tested changed files byte-for-byte. Canonical source files stay untouched.

```bash
AUDIT="$PWD/out/isolated/dcp-source-audit-20260906"
CLIENT="$AUDIT/m1n1-register-final-replay/proxyclient"
DRIVER="$AUDIT/register-linux-replay/drivers/gpu/drm/apple"
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m1n1-dcp-register-self-test.py \
    "$CLIENT" "$AUDIT/inputs/DeviceTree.j514sap.decoded"
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/dcp-map-registers-self-test.py "$DRIVER"
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m1n1-dcp-abi-self-test.py "$CLIENT"
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m1n1-dcp-bandwidth-self-test.py \
    "$CLIENT" "$AUDIT/inputs/DeviceTree.j514sap.decoded"
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/dcp-null-flags-self-test.py "$DRIVER"
```

- Python: all seven target tests pass. Coverage includes all six exact Apple
  resources, 18 repeated fake callbacks, 11 malformed requests and 11 malformed
  ADT cases, legacy signature, and four dispatcher-failure/depth combinations.
  The fake client has no transport or MMIO methods. Python `-O` also passes.
  V12.3/V13.5 each pass three applicable tests and skip four target-only tests.
- The exact Apple ADT caught an initially overstrict built-in-integer type
  check; the parser returns integer subclasses. That was corrected and the
  saved-input test now passes. Synthetic metadata alone was not accepted.
- The pre-depth-fix export fails all four depth-restoration assertions. The
  original extended callback fails with unexpected-keyword errors. Evidence:
  `register-python-before.log`, `register-callback-depth-before.log` and
  `register-python-final-{V12_3,V13_5,V14_7}.log`.
- C: six ASan/UBSan executables compile with `-Wall -Wextra -Werror`: three
  firmware profiles plus three independently rejected mutants. Tests execute
  the complete real callback and real header structs against owned fake DMA
  state. They cover invalid indices, zero/nonzero successful DMA addresses,
  failure status/zeroed outputs, direct mode, repetition, and mode selection.
  This is callback coverage, not execution of the full kernel driver.
- The unpatched C callback fails the injected mapping-error check. Mutants
  separately reject success-on-failure, always-DMA and always-physical behavior.
  Evidence: `register-c-before.log`, `register-c-replay.log`.
- Existing A407 five-test, D003 eight-test and C null-initialization five-case
  regressions pass. Bounded independent review found no remaining material
  issue in scope; the final depth-restoration delta was separately reviewed.

The complete configured AArch64 Apple DRM module also builds with `W=1`, no
warnings/errors, including all three IOMFB version objects and MODPOST/link.
It used the pinned Docker image and retained framebuffer-kernel output from
the earlier ABI report, source volume read-only with its authoritative lock
held exclusively. Build output was case-sensitive Linux `/tmp`; no full kernel
rebuild or canonical M0 evidence promotion occurred. Inner build command:

```bash
make -C /workspace/src/linux O=/workspace/build/linux-development-framebuffer \
    M=/driver MO=/tmp/dcp-module ARCH=arm64 W=1 -j4 modules
```

Module evidence: `compile-registers/{module-build.log,appledrm.ko,Module.symvers}`.
Module SHA-256: `74539aa909b17bab7ec131e8067e091089a344b1f24d623f833da096b303c256`.
Patch and tested-source digests: `register-closure.json`.

## Remaining mapping and boot requirements

The host caches mappings and has an explicit release routine. The Linux WIP
callback still allocates each **DMA-mode** mapping separately and does not
retain/unmap those resources. Its component unbind issues asynchronous IOMFB
shutdown; no explicit RTKit quiesce-before-unmap path was found. Do not insert
unmapping into unbind without establishing that lifetime and concurrency order.
Direct-register mode now allocates no DMA resource, including on repeat calls.

Python DMA-mode D411 stays rejected. Before implementing it, resolve the DCP
stream choice/invalidation mask, T8110 mapping/cache attributes, retained page
tables and failure ownership. The current `DCPClient` defaults to stream zero;
`StandardASC.iomap` invalidates mask 1 even when its stream differs. Neither is
proof of correct target SID 5 behavior. The T8110 four-level mapping branch also
needs source-backed testing before reuse. No arbitrary IOVA or zero-address
fallback was added to hide these gaps.

Next offline work: those mapping prerequisites and a reviewed DMA lifetime,
then complete target DCP topology/reservations, panel and power sequencing.
Linux's probe gates and native/recovery approval boundaries remain unchanged.

Subsequent [DMA prerequisite work](dcp-dma-prerequisites-2026-09-06.md) fixes the
explicit stream/invalidation mismatch and retained Python T8110 traversal, with
validation-before-enable and focused actual-code regressions. It does not yet
resolve raw manager mappings, wide DVA semantics or DMA ownership/coherency.
