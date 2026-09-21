# T6030 DCP bandwidth contract, 2026-09-06

## Outcome and boundary

The exact J514sap 23J220 host driver and Apple device tree resolve the internal
display's bandwidth scratch resource: display register **5**, offset **0x988**,
eight bytes, without a separate doorbell. The host RPC wrapper also proves that
D003 returns a 56-byte configuration followed by four-byte status. The existing
Python client incorrectly described all 60 bytes as configuration/padding.

`patches/m1n1-dcp-development/04-t6030-bandwidth.patch` adds a development-only
T6030 callback and corrects that V14.7 wire contract. It targets m1n1
`60e53e7078c5cb7efce32d64bf50829e9401e44f`, touches only Python `ipc.py` and
`manager.py`, and is compatible with patch 01. Apply only to a disposable export.
The callback reads the caller's ADT metadata; it performs no MMIO, DART mapping,
PMP initialization or remote call. Unknown target/firmware/table/resource
contracts raise before publishing the output. This is not an implementation
of protocol error recovery or a ready-to-run T6030 DCP controller.

No builder selects this patch. No kernel rebuild, boot, serial command, live
register/page-table access, installed image, ESP, partition, firmware or boot
policy changed. Existing framebuffer candidates remain unchanged. This closes
a specific **static protocol/resource gap**, not native display acceptance.

## Provenance

Artifacts below are relative to `out/isolated/dcp-source-audit-20260906/` (`AUDIT`).
The host kernelcache is from the same public Apple 23J220 OTA and J514sap
BuildManifest identity as the [earlier DCP firmware work](dcp-abi-development-2026-09-06.md).
Only `AssetData/boot/kernelcache.release.mac15s` was fetched this time, with
30,065,633 network bytes. No installer or firmware was executed.

| Input | SHA-256 |
| --- | --- |
| `target-kernelcache/kernelcache.im4p` | `edc75b1a42ac2b646ad7749de017c29259eaeefcc2ca6cd99dc44a40325d1509` |
| decoded `kernelcache.macho` | `1df6ef30ea65afe3aecbdd4ea2c134690180d8904af459ea52a1fa8e9b15ea07` |
| decoded `inputs/DeviceTree.j514sap.decoded` | `4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478` |

ZIP CRC and the selected manifest's KernelCache SHA-384 match. **Apple signature
verification was not performed**; nothing was promoted through the RE trust
ledger. Original Apple inputs remain immutable local artifacts, outside Git
and the shared vault. Acquisition details: `target-kernelcache/acquisition.json`.

IDA loaded the decoded fileset and analyzed only relevant function ranges.
Host addresses below belong to this exact image, not the current running Mac.
The callback is inside `AppleMobileDispT603S-DCP`; PMGR functions belong to
`ApplePMGR` and `AppleT6030PMGR`. Decompiler cold-path/prototype mistakes were
cross-checked against instructions. The truncated `pmgr-init-driver.json` is
not complete-function evidence and was not used to establish the contract.

## Evidence chain

| Step | Exact evidence |
| --- | --- |
| D003 lookup and reply | `0xfffffe0009acb1f4` selects table entry 3, wrapper `0xfffffe0009acb2b0`; the wrapper stores converted status at reply +56. |
| Host bandwidth callback | `0xfffffe0009aba5cc`: requests `function-bw_req_interrupt0`, writes physical scratch at +8 and descriptor length at +44; length 8 clears doorbell +16 and bit +28. |
| Function provider | Saved `/arm-io/disp0`: PMGR phandle 167, `BIRQ`, device ID 39 (`DISP_SYS`, PMP ID 8). |
| PMP/PMC route | `ApplePMGR` constructor `0xfffffe0009b60ad4` copies zero-initialized feature records. Feature 40 is `pmp`, 83 is `pmc`; `start` populates only present DT properties. Saved target has `pmp=2`, no `pmc`. |
| BIRQ v2 dispatch | `0xfffffe0009b9a9f4` passes device ID and descriptor output to `_getBWRReqMemory` at `0xfffffe0009b8d8d4`; absent/zero PMC selects PMP, not PMC. |
| PMP lookup | `_initPMPv2` at `0xfffffe0009b62620` selects `ptd-ranges[3]` and assigns sequential bandwidth ranks only to `soc-device` records with word 12 nonzero. |
| Target table values | Range handle 13 has base index 304. The bandwidth list begins PMP IDs 7, 8; display PMP ID 8 has rank 1. |
| Physical formula | `_getBWRReqMemoryPMP`, `0xfffffe0009b8d7d4`: map base + `0x10000 + 8*(PTD base index + bandwidth rank)`, descriptor length 8. |
| Target register map | `AppleT6030PMGR::initRegMaps` calls `initRegMap(this,8,40,0,0)` at `0xfffffe0009e6266c`. Enum 8 is the map used above; target PMGR ADT register 40 is `0x3503c0000/0x24000`. |
| DCP consumer | T6030 firmware `0x1e3c20` requests 60 reply bytes, reads status +56 and width +44, chooses provider index 5 for dashboard mode; width 4 uses legacy indices 6/7. |

Thus `0x3503c0000 + 0x10000 + 8*(304+1) = 0x3503d0988`.
Saved display register 5 is `0x3503d0000/0x4000`, giving offset `0x988`.
These are static resource descriptors, **not reusable runtime IOVAs/carveouts**.

The implementation derives the address from supplied ADT register mappings and
PMP tables, then checks the verified offset, provider identity, unique records,
target geometry, alignment, bounds and overflow. It deliberately rejects
other board/firmware/layout variants rather than claiming a general PMP parser.
It retains V12/V13 layouts and old-chip reply bytes. V14.7 alone gets explicit
`scratch_size` at +44 and status at +56; no future-version ABI is inferred.

Saved IDA exports: `target-kernelcache/{d003-lookup,d003-callback,
rt-bandwidth-setup-ap,pmgr-feature-initializers,pmgr-start,pmgr-constructor,
pmp-interrupt-v2,pmgr-pmpv2-init,bandwidth-memory-b,t6030-register-maps,
pmgr-init-reg-map}.json`; raw route/formula/constructor disassembly is alongside
them. Firmware consumer: `workspace/ida/pmp-register-init.json`.

## Validation

Run from the repository root against a disposable patched client:

```bash
AUDIT="$PWD/out/isolated/dcp-source-audit-20260906"
CLIENT="$AUDIT/m1n1-bandwidth-final-replay/proxyclient"
for version in V12_3 V13_5 V14_7 V14_8; do
    AGX_FWVER="$version" PYTHONDONTWRITEBYTECODE=1 python3 -B \
        tests/m1n1-dcp-bandwidth-self-test.py "$CLIENT" \
        "$AUDIT/inputs/DeviceTree.j514sap.decoded" || break
done
PYTHONDONTWRITEBYTECODE=1 python3 -B tests/m1n1-dcp-abi-self-test.py "$CLIENT"
```

- V14.7: all eight tests pass, including exact Apple ADT, real D003 callback
  encoding, nonzero status, three resource relocations and **47 malformed
  contracts** rejected before output. No fake object exposes transport/MMIO.
- V12.3/V13.5: four relevant tests each pass; four target-only tests each skip.
- Simulated V14.8: four tests pass/four skip. This test alone adds an artificial
  version label to catch broad future-version guards; production does not add
  or support that label. It verifies old layout selection and T6030 rejection.
- Original source fails the V14.7 suite (one failure/five errors), including
  the original 60-byte-configuration mismatch and unsupported T6030 callback.
- All eight target tests also pass under Python `-O`; contract rejection does
  not depend on removable Python `assert` statements.
- Fresh private-Git export replays patch 04, matches both tested files exactly,
  then accepts patch 01. All five A407 tests still pass.
- All 168 V12.3 and 174 V13.5 top-level RPC layouts remain identical. Of 174
  V14.7 entries, only D003 and the earlier A407 correction change; the latter
  also appears under its verified alias `swap_submit_dcp`.
- Bounded independent review found an overly broad version guard; exact-version
  gating plus the future-profile negative test resolved it. Re-review found
  no remaining material issue in scope.

Evidence: `bandwidth-baseline.log`, `bandwidth-final-{V12_3,V13_5,V14_7,V14_8}.log`,
`bandwidth-final-a407.log`, `bandwidth-closure.json`.
Optimized-mode evidence: `bandwidth-final-optimized.log`.
Patch SHA-256: `55e8a0798684da70790cd793344faaf2b3a9dbba7286d23638b9c876ad325fa5`.
Test SHA-256: `d7d0cc9cd70af71f674d0ddcde7b8e631cc5f54f32ae408aaddaaff45945269f`.

## Remaining work

The next useful offline path is D411 register mapping: reconcile its Python
manager signature and real DMA ownership/stream semantics with the target host
driver. Do not substitute a zero DVA or initialize hardware to satisfy a test.
The [subsequent register-mode work](dcp-register-development-2026-09-06.md)
resolves and implements the direct-register path; DMA-mode ownership and
stream prerequisites remain open.
T6030 DCP DT topology, boot-time DART/reserved mappings, PMP runtime readiness,
panel/power sequencing, framebuffer handoff and native display operation remain
unproven. Linux's `apple,bw-scratch` probe gate stays intact. This patch does not
retire canonical milestone gates or establish full hardware support.

The [subsequent Linux/topology work](dcp-display-topology-2026-09-06.md)
implements this contract in the Linux V14.7 reply, fixes full-width resource
bounds and adds disabled exact-ADT J514s display wiring. Sanitizer, DT,
negative-control, replay and module-build checks pass. It supersedes only the
development topology absence above; clock, runtime loader mappings, panel,
PMP readiness and DMA lifecycle remain unproved.
