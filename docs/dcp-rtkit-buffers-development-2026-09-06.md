# RTKit buffer addresses and ownership

Development-only m1n1 patch 13 follows C patches 02/03/08/10/11/12 on
`60e53e7078c5cb7efce32d64bf50829e9401e44f`. It changes only `src/rtkit.c`
and `src/rtkit.h` in disposable exports. No builder selects these patches.
No boot, target command, installed artifact, storage or firmware change.

## Evidence and behavior

The [pinned RTKit source](https://raw.githubusercontent.com/AsahiLinux/m1n1/60e53e7078c5cb7efce32d64bf50829e9401e44f/src/rtkit.c)
uses a 42-bit buffer-request address but truncates DART translations and
unmaps to 36 bits. Its optional `asc-dram-mask` is read from the ASC's first
child. The hashed, decoded J514s Apple tree identifies that child as
`iop-dcp-nub`, without the mask property, while DCP's DART `vm-base` is
`1 << 40`. This is evidence of a source-level width mismatch, not permission
to reuse a cached runtime address or proof of live firmware behavior.

The correction preserves real high IOVA bits and strips only explicitly
provided ASC tag bits. Encoding rejects tag collisions, crossing a tag bit,
integer wrap and unaligned mappings before DART publication. Buffer requests
reject addresses/spans that cannot fit the existing 42-bit wire format;
the protocol itself is not widened. Generic RTKit mappings can be wider.

Borrowed buffers now require every covered DART page to translate into one
contiguous CPU span before the descriptor is published. They retain the
firmware address in the descriptor, with a separate explicit ownership bit.
Missing pages, remapped interiors and null DART contexts fail without changing
the descriptor. Borrowed SRAM buffers remain supported; supplied-address SART
buffers remain unsupported rather than dereferencing a null DART.

Owned buffers round and validate size before allocation, refuse replacement
of a live descriptor, publish only after successful mapping, and release the
exact mapped IOVA. Successful release clears the descriptor and returns true;
repeated release is harmless. Borrowed memory is never unmapped/freed, even
when its pointer happens to fall in the heap. SART removal failure preserves
the owned buffer and reports failure instead of freeing still-permitted memory.
Callers must zero-initialize new descriptors, as all current callers already do.

## Verification

- 299 actual-RTKit C cases pass with ASan/UBSan, leak detection, assertions
  and strict warnings on AArch64 Linux. Only the allocator, DART, SART and
  mailbox boundaries are mocked; the RTKit functions are not rewritten.
- The same harness reproduces four original failures: high-IOVA unmap,
  allocation/mapping size disagreement, erroneous release result/dangling
  descriptor, and high-IOVA borrowed-buffer translation.
- Tests cover all 255 nonzero request sizes, high addresses, explicit tag
  round trips/collisions/crossings, reply-width failures, allocation/IOVA/map/
  mailbox failures, missing and discontiguous interior pages, borrowed heap
  memory, repeated/live-descriptor operations, SART failure and SRAM behavior.
- 457 retained-level and 4,059 retained-mapping C cases pass again against
  the final replay. Other preceding DART/configuration/clock results remain
  bound to unchanged sources by the historical closure, not claimed reruns.
- All seven C patches replay from the pin. The two exports match 510 file/
  link entries, including five symlinks. Complete RTKit, AFK and DCP production
  objects compile with `-Werror` and no diagnostics. No linked image was built.
- One bounded read-only review found no material regression. Python syntax,
  patch whitespace, secret scans and historical evidence hashes also pass.

Exact test commands, using the final replay at `/source` and pre-patch-13
export at `/baseline`:

```bash
python3 -B /tests/m1n1-rtkit-buffer-self-test.py /source
python3 -B /tests/m1n1-rtkit-buffer-self-test.py /baseline --baseline
python3 -B /tests/m1n1-dart-levels-self-test.py /source
python3 -B /tests/m1n1-dcp-mapping-self-test.py /source
```

Executor: `sha256:768496550d56042381855034500985860812008876244cfb59a5969ad6e33469`,
network disabled, read-only root/source/test mounts, temporary `/tmp` build.
The harness disables only the existing intentional multi-character-constant
warning. Production builds use existing `build-cfg` and `invoke_cc` targets.
No Linux source volume, M0 build or kernel build is involved.

Evidence: `out/isolated/dcp-source-audit-20260906/rtkit-closure.json`,
`rtkit-research.json`, `compile-rtkit/*final*` and
`rtkit-loader-{source,replay}`. Final tree hash:
`671f1f347efe669be26992c67695834e8d6ab4ee5bab1abc175d5de5c21977b2`.
Before-edit documentation snapshots keep preceding closures verifiable.

## Not yet proved

This retires RTKit's unconditional 36-bit truncation and buffer ownership
defects, not the complete DCP DMA path. The IOVA allocator's domain bounds,
AFK's separate 48-bit address field and error recovery, log/crash parsers,
permissions/cache attributes, live mapping stability, DMA quiescence and
void DART invalidation/unmap failure reporting remain separate work.
`rtkit_free()` still cannot propagate per-buffer cleanup failure. Physical
address zero remains ambiguous in the pointer-returning translation API.

No synthetic test proves a live page-table snapshot, firmware negotiation,
target region/stream policy, reset/panel sequencing or native hardware
support. Next safe work: validate the real IOVA allocator's high-base domain
contract and AFK buffer envelope before integrating or enabling this path.
