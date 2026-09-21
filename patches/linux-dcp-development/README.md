# Development-only DCP 14.7 backport

Apply `series` in order to Linux `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`
or its existing schema-only patched tree `d8082213fc5a3a64c8b9464a7d5c82d13b1ea115`.
Do not apply in the canonical checkout or a source volume owned by a build.
This series is **not selected by any canonical or development boot builder**.

The first seven files retain their upstream authors and commit IDs. They come
from AsahiLinux's `bits/200-dcp` history, inspected at
`52f0b76aaae7b9a1cc2100f4a9b33257b450d5c0`. Do not replace the whole branch: it
also includes unrelated kernel/API changes. Patch 08 adapts the flush argument
to our pinned API and replaces the remaining guessed A407 layout with the
six-secondary-surface layout observed in two 23J220 firmware binaries.

The complete Apple DRM module compiles with W=1 against the retained AArch64
framebuffer-kernel build. This is not a complete kernel build, M0 promotion,
native run, or evidence of correct display power, DMA or framebuffer lifetime.
The installed/canonical J514s boot DT remains unchanged. Patch 11 adds only
disabled development nodes, not a ready-to-enable display configuration.
Upstream WIP callback, EDID, audio and runtime behavior still need review and
hardware evidence.

Exact evidence, limitations and reproduction: `docs/dcp-abi-development-2026-09-06.md`.

Patch 09 now distinguishes V14.7 direct physical registers from bit-31 DMA
requests and returns an error on DMA mapping failure. Six sanitizer-backed C
executables cover all three firmware profiles and three negative controls;
the full configured module recompiles with W=1 and no warnings/errors. DMA
mapping cache/teardown lifetime remains unresolved, and no new device tree,
probe enablement, installed module or boot candidate is implied. See
`docs/dcp-register-development-2026-09-06.md` for exact binary evidence and limits.

Patch 10 implements the exact T6030 8-byte bandwidth scratch contract in the
V14.7 reply and validates the entire resource extent without unsigned
underflow. Patch 11 adds exact-ADT J514s DCP/mailbox/DART/display wiring, all
disabled, with the scratch resource appended exactly once at slot 5. Six
sanitizer executables, eight DT tests, five rejected DT mutants, clean replay
and another full W=1 module build pass. J516s remains byte-identical. Three
additional DT compiler warnings remain documented; no dt-schema pass is
claimed. Clock, loader/runtime mappings, panel sequencing and DMA lifetime
remain blockers. See `docs/dcp-display-topology-2026-09-06.md`.

Patch 12 adds two disabled fixed-clock providers and an index-aware V14.7
T6030 D408 consumer, retaining target clock handles for platform-device
lifetime while preserving legacy component behavior. It checks D408 packet
sizes and fixes unaligned reply stores in the shared output trampolines.
Paired m1n1 patch 10 publishes fresh ADT-derived rates only after validating
both providers; all display hardware and clock providers remain disabled.
275 clock/RPC cases plus 46 real-libfdt cases pass on macOS and Linux, with
FDT readback fed into the real callback fixture. Full W=1 DRM-module and m1n1
kboot object compilation pass; no full kernel/M0 build or boot. Clock-provider
activation, runtime mappings and physical display/DMA acceptance remain open.
See `docs/dcp-clock-handoff-development-2026-09-06.md` for commands and limits.
Patch 11's missing new-file mode header is also corrected for `git apply`;
its resulting DTS bytes are unchanged and the original patch is archived.

Patch 13 bounds IOMFB callback envelopes and stack depth before mutation,
separates RX/TX frame ownership, reserves shared CMD/CB transmit windows, and
uses saved output pointers for ACKs without trusting returned packet headers.
3,743 actual-C sanitizer cases pass on macOS and AArch64 Linux; five faults
reproduce in the original code. Existing clock and adjacent regressions,
clean replay and a full W=1 DRM module build pass. This is transport hardening,
not full callback-schema validation, recovery, concurrency or hardware proof.
No builder selects the series. See `docs/dcp-transport-development-2026-09-06.md`.

Patch 14 renames only the J514s PIODMA alias property to `disp0-piodma`;
the `disp0_piodma` node label and target path are unchanged. Paired upstream
m1n1 patch 23 supports old and new aliases without contracting compatibility.
Eight DT tests and 321 clock-handoff/callback checks pass. Decoded J514s DTB
changes only that property; J516s is byte-identical. The alias warning is
retired, leaving nine J514s warnings (seven baseline, two development) and
seven unchanged J516s warnings. This is not dt-schema or hardware acceptance.
All nodes remain disabled and no builder selects this series. See
`docs/upstream-loader-integration-2026-09-06.md`.

Patch 15 corrects startup calls using the exact T6030 23J220 firmware: A406
uses a by-value client handle, a 16-byte request and an 8-byte reply; A472 has
three boolean inputs and its output-pointer null flag at byte 11. Versioned
declarations preserve older layouts and all internal callers use them. The
power-saving method uses A448, not A443's two-output getter.

99 actual-C wire cases across three profiles, three predecessor controls,
adjacent regressions, fifteen-patch replay and a full W=1/-Werror Apple DRM
module build pass. Python patch 25 pairs the two schema corrections. No
builder selects either patch; no display node is enabled. Runtime status/error
policy and the remaining startup/callback contracts still need review. See
`docs/dcp-startup-abi-development-2026-09-06.md`.

Patch 16 corrects the exact-target D589 swap-completion structure: 34-byte
completion data, eight 216-byte records, count, two booleans and null flag.
V14.7 dispatch requires input/output 1776/0 and outer length 1788 before any
callback state or ACK. Older layouts and acceptance remain unchanged.
135 startup/completion C cases and 3807 transport cases pass on macOS/Linux;
predecessor defects, strict sixteen-patch replay and full DRM module linkage
are checked. Python patch 26 pairs the schema and real manager fix.
No builder selects this series or display node becomes enabled. See
`docs/dcp-completion-abi-development-2026-09-06.md`.

Patch 17 fixes D006 frame-sync and D576 hotplug in/out metadata layouts,
preservation and target length checks. 5,640 metadata C cases, 3,903 transport
cases, strict replay and full W=1/-Werror DRM-module link pass. No brightness
policy, tiling support or hardware acceptance is implied. Paired Python patch
27 and exact evidence: `docs/dcp-metadata-development-2026-09-06.md`.
