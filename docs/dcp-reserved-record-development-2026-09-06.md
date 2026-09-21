# Reserved-memory publication and target handoff research

## Result

Development patch `22-reserved-memory-records.patch` follows loader patch 21.
It changes only `src/kboot.c`: one complete IOMMU-address tuple replaces three
separate appends, and two reserved-node failure paths now return an error
instead of stale success. No builder selects these development patches.
No installed image, storage, firmware, boot policy or hardware changed.

This is software evidence, not native support or approval to boot.

## Proven defects and scope

- `dt_device_set_reserved_mem`: the original phandle/address/size appends can
  leave a truncated `iommu-addresses` record when space runs out. The replacement
  uses one 20-byte, five-big-endian-cell append with identical successful bytes.
  This protects the property record, not the entire FDT or its strings block.
- `dt_add_reserved_regions`: a failed reserved node left `ret == 0` before
  cleanup. It now propagates the node error and still attempts every acquired
  DART cleanup, including when one cleanup fails.
- `dt_reserve_asc_firmware`: a failed reserved node returned the previous zero
  result. It now returns the node error. This helper also serves SIO and ISP;
  their existing checked callers now receive that failure. The optional external
  display caller's broader error policy is unchanged.

The patch does not make multi-node publication transactional. Partial earlier
properties or enabled nodes may remain after a later failure. The existing
missing-DART-mapping policy, target carveout classification, segment parser,
activation ordering and hardware initialization/cleanup behavior are unchanged.

## Exact validation

`tests/m1n1-reserved-record-self-test.{c,py}` extracts the actual production
helpers and compiles them with the source tree's real libfdt. DART and ADT are
owned fakes; no target address is dereferenced and no device initializes.

- All three named predecessor controls fail their intended assertions.
- 137 checks pass on macOS and AArch64 Linux with ASan/UBSan and `-Werror`.
  Linux also enables leak detection. Cases cover constrained FDT capacity with
  absent/existing records, full-width big-endian readback, two reservation
  errors, acquired-DART cleanup and every cleanup-failure mask, linked display
  regions, ASC remap/base handling and existing size rounding.
- 4,559 adjacent actual-code checks pass: caller paths 43, retained mappings
  4,059, DART levels/lifecycle 457. The real-libfdt clock handoff passes 46 cases
  plus 275 Linux callback cases and confirms all seven hardware nodes disabled.
  Counts describe parameterized checks, not independent hardware scenarios.
- Sixteen loader patches apply with strict whitespace checks to a fresh private
  Git export from `60e53e7078c5cb7efce32d64bf50829e9401e44f`.
- The full production `kboot.c` compiles with the existing Makefile and
  `EXTRA_CFLAGS=-Werror`. ELF inspection confirms an AArch64 relocatable object.
  No full loader link, Linux build, M0 promotion or reproducibility rebuild was
  needed for this local-helper change. The initial cross-prefixed inspection
  command was unavailable; native `readelf` inspected the same completed object.
- Bounded independent review found no material issue. Fixture portability and
  invocation errors were corrected before the selected final runs.

Executor image:
`sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`.
Network disabled, root filesystem read-only, sources/tests mounted read-only,
temporary compilation in disposable tmpfs. No Linux source volume mounted.

From the repository root, with `/source` and `/before` naming current and
patch-21 exports in that container:

```sh
python3 -B /tests/m1n1-reserved-record-self-test.py /before --baseline
python3 -B /tests/m1n1-reserved-record-self-test.py /source
python3 -B /tests/m1n1-dart-callers-self-test.py /source
python3 -B /tests/m1n1-dcp-mapping-self-test.py /source
python3 -B /tests/m1n1-dart-levels-self-test.py /source
```

Evidence: `out/isolated/dcp-source-audit-20260906/compile-reserved-record/`,
`reserved-record-loader-{source,replay}`, `reserved-record-research.json`, and
`reserved-record-closure.json`. The closure records exact commands, file hashes,
source/link manifests and before-edit bindings for historical evidence.

## Target research: lock is not preservation

The complete pinned Linux Git object was available without extracting or
modifying its worktree. At `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`:

- `drivers/iommu/of_iommu.c:206-274` reads each master's `memory-region` nodes
  and selects `iommu-addresses` tuples by that exact master's phandle.
- `drivers/iommu/iommu.c:1202-1272,3217-3244` installs firmware mappings before
  attaching a device. Address/size widths follow the master's parent cells.
- `drivers/iommu/apple-dart.c:552-573,1410-1423` resets unlocked DARTs during
  probe, disabling streams and clearing TTBRs. Locked DARTs skip this reset.
- Its locked-domain synchronization at lines 428-465 still overwrites existing
  root entries with Linux's new table. Locking alone therefore does not preserve
  mappings missing from the firmware handoff. Device release also clears the
  locked L1 page; source explicitly leaves boot-state restoration as TODO.

The existing disabled development topology assigns DCP SID 5, display SID 0 and
PIODMA SID 4. All necessary mappings must survive the relevant attachment path.
The pin selects T8110 behavior through the compatible fallback; this is not
verified T6030 hardware behavior and does not retire the schema diagnostics.

IDA reopened the existing 23J220 kernelcache and DCP databases after confirming
the old workers were gone. Static DCP `sub_11AB38` associates resource kind 5
with PIODMA mapping, but this is not a carveout ID or proof of DART membership.
Host start-function decompilation was incomplete; disassembly remained available.
Binary Ninja's MCP returned no response, so no Binary Ninja result is claimed.
The recorded excerpts are bound to original binary hashes, not a live device.

No T6030 region table or activation branch was added from these incomplete
observations. Next: establish fresh-boot retained-region/SID membership and
required-versus-optional mapping policy, then implement coherent FDT publication
and ordered activation with negative tests. Cached 25G227 physical addresses
must never become constants for a future 23J220 boot. Display/panel, USB/SSH,
direct-native boot and recovery acceptance remain separate physical gates.
