# Development transfer to the Mac's Linux installation

## Stay-on-Linux kit, 2026-09-10 22:10 UTC

User requested installers and executable cooling/GPU tests to reduce returns to
macOS; then selected Binary Ninja only. Six files now delivered under the Mac
Linux `~/Downloads/mac-dev-transfer-20260910/linux-stay-kit/`. START-HERE has
ordered install, test and resume instructions. Earlier packets remain intact.

Official Binary Ninja Free Linux ARM64 ZIP: 453819990 bytes, 3133 entries,
881884385 unpacked bytes; CRC and path/symlink validation passed. Main executable
is ELF64 little-endian AArch64 and includes ui.mcp.enabled/MCP menu strings.
SHA-256: 1b78125856be461f7324ca00f50c87f178885ec10ad185578070ed991e97d75a.
Source: https://cdn.binary.ninja/installers/binaryninja_free_linux-arm.zip.

Correction to prior assumptions: the current Free edition advertises ARM64
analysis and built-in GUI MCP. General API/plugins and standalone headless MCP
remain unavailable. Sources: https://binary.ninja/free/ and
https://docs.binary.ninja/guide/mcp.html. No patch/key-generation utility ran.
Native launch, actual displayed version, shared libraries and MCP queries still
need Linux validation. Do not call archive delivery an installed working app.
IDA was intentionally omitted after the user's latest choice.

Added Mac source files: scripts/linux-stay-check.py and
tests/linux-stay-check-self-test.py. Standalone copies shipped in the kit, not
overwritten into the newer Linux project. Default reads three idle samples,
SMC RPM, labeled temperatures, CPU caps, services and GPU/backlight inventory.
Optional glxinfo probe requires exact J514s/T6030 identity, known spinning fans,
CPU-labeled temperatures under conservative workflow limits, caps/service gates
and a recognized AGX device. It rechecks hardware/services afterward. No stress,
SMC writes, module operations or boot changes. Missing telemetry blocks probing;
accessory sensors and idle readings do not prove CPU safety or hardware support.
The previous broader collector invokes glxinfo unconditionally; new guide warns
not to use it before clearing cooling. Raw journals can instead be read directly.

Proof: nine unittest methods with multiple rejection/positive subcases pass,
including successful gated probe, post-probe failure, timeout/truncation and
private output. Tests passed again from native-readback copies on macOS using
fixtures, not hardware. Bounded Luna review passed after absolute executable
paths and post-probe regression coverage were added. Four guide shell blocks
pass bash -n and ShellCheck. Gitleaks scan found no text secrets.

Rehearsal and native file checksums/modes passed. All six files UID/GID 1000,
0600; directory 0700. Native e2fsck -fn before/after exit 0, all five passes.
Native inodes 659599 -> 659606; blocks 10014088 -> 10124896. Linux CURRENT SHA
unchanged: 475594db32e91c75ea4f887efb448cf013da1ec46f4ee336539c7357daa5a55b.
Manifest SHA: ae26e2e0b64318791bc3ecbf557bd9ec418bcc675945b24903a33b0464b5ad9f.
Exact partition identity, unmounted state and AC revalidated before writing.
Only a new Downloads folder was added; no reboot, kernel/EFI/fan-control change.
Evidence: out/isolated/linux-stay-kit-20260910/. Private native.e2undo is metadata
undo, not power-loss recovery. No routine step in this kit needs macOS, but
unresolved cooling/firmware faults can still require a separate recovery plan.

## Completion supplement, 2026-09-10 22:00 UTC

Prepared and copied nine additional files to
`/home/moriz/Downloads/mac-dev-transfer-20260910/completion/`.
Read its START-HERE first; it supersedes the parent's context-completeness
overstatement. No existing Linux file was overwritten. Full application
installation is still incomplete for the reasons below.

Contents: START-HERE, POST-BOOT-CHECKLIST, history-context.tar.zst,
EXPORT-COVERAGE.json, macos-gpu-metadata.json, capture/export source, reference
copy of the current Linux collector, and SHA256SUMS. Total 196545 bytes.
History includes 1,413 visible messages (50 user/1,363 assistant), seven selected
notes/excerpts, and exact coverage/omissions. Source cutoff is
2026-09-10 21:53:05.944 UTC. It excludes reasoning, tool data, sensitive-context
messages, control wrappers and unrelated history; not a full native session.

Fresh GPU capture is read-only fixed-target SGX IORegistry data, not kernel/GPU
memory: Mac15,6, build 25G227, 42 exact-allowlisted properties including 14-state
performance tables. Addresses are boot/version-bound and cannot replace the
archived 23J220 evidence. +0x1d64, true GPU page-table context, full calibration,
firmware startup and native rendering remain unresolved.

Validation performed:

- Export: 15 synthetic scope/redaction/preservation checks; exact pinned source
  prefix SHA and one matching session identity; 1,413 visible-only JSON records.
  Scoped reviewer feedback applied to note filtering, control markers and GPU
  bounds. Missing per-message IDs inherit the hash-pinned session container;
  explicit conflicting IDs reject. No native session/auth database exported.
- GPU encoder: scalar preservation plus six bounds/type rejection cases.
  Delivered Python sources compile. Existing Linux collector inspected only;
  not run on macOS and not replaced in Linux.
- Gitleaks on filtered export and delivery text: no leaks. This is a private
  reference, not a blanket publication clearance.
- Zstandard test and archive inventory passed. Rehearsal on the prior private
  image passed file hashes and UID/GID 1000, directory 0700/files 0600 checks.
  The image is only a transfer rehearsal, not current native rollback data.
- Revalidated exact partition UUID/size/offset, unmounted status and AC power.
  Native e2fsck -fn before/after both exit 0, all five passes. Inodes changed
  659589 to 659599; blocks 10014034 to 10014088, matching an additive supplement.
- All eight payloads and the manifest read back byte-identically. All nine
  files and their directory have private permissions and correct Linux owner.
  Native operation logs contain no errors. Linux CURRENT hash remains
  475594db32e91c75ea4f887efb448cf013da1ec46f4ee336539c7357daa5a55b.
- Manifest SHA-256:
  73f41cb2bc3a9f58145186694d13c06dd95be40a8f2097f69e1d17e494cecde2.

Evidence: `out/isolated/linux-dev-completion-20260910/`; see delivery,
readback-native/completion, native-fsck-before.log, native-fsck-after.log,
native-readback.log and private native-completion.e2undo. Undo metadata does
not provide power-loss recovery. No reboot or boot/kernel/fan-control write.
Next: existing Linux agent verifies both manifests, reads CURRENT and the
post-boot checklist, preserves cooling protections and collects live evidence.

## Original ten-file transfer

Completed file transfer 2026-09-10 21:40 UTC; application installation incomplete.

Reviewed Linux session `01a08a10-32b9-7593-ba47-cb12b6fd6667`, "Review Asahi logs
and issues", and its current GPU/fan handoff through 21:26 UTC. The newer Linux
tree is now the development authority. Do not overwrite it with this Mac tree.
The Linux checkpoint documents native desktop operation, but not accelerated
GPU rendering or working display brightness. Cooling remains a hardware gate.

Delivered a private 10-file packet to:
`/home/moriz/Downloads/mac-dev-transfer-20260910/`.
Start with `START-HERE.md`; run `sha256sum -c SHA256SUMS` there. It includes the
older Mac source/test/patch reference, two existing IDA databases and matching
Mach-O inputs, the requested private tool ZIPs, and new macOS cooling evidence.
No raw session history, agent login databases, SSH identities, or full vault
was installed. The active Linux project/session and boot configuration were
not replaced. No boot or fan-control write was performed.

Fresh macOS read-only evidence on build 25G227: fan modes 0/0, approximately
2290/2492 RPM, Ftst=0, nominal sampled thermal pressure. This contrasts with
the Linux checkpoint's modes 3/3, zero RPM and mode-write response 0x82. It
does not establish the cause or prove subsequent Linux cooling is repaired.
Do not mix this boot's runtime data with the archived 23J220 binary provenance.

The source-only SMC reader compiled with Wall/Wextra/Werror, asserts the 80-byte
ABI and exposes only fixed-key metadata/value reads. The two lowercase mode
keys were rejected with 0x84 and are not interpreted as successful values.
Upstream reference: https://github.com/exelban/stats/blob/master/SMC/smc.swift

## Exact transfer checks

- Destination resolved by partition UUID EFFA6799-DD71-4D19-B3D2-12F0C411EBA2,
  size 107239964672 and offset 387524288512. It is now disk0s5, not the earlier
  disk0s8. Device identifiers are not permanent. It remained unmounted.
- Private COW image rehearsal, readback checks and five-stage read-only ext4
  check passed. AC power/full battery checked before native writing.
- Native ext4 checks before and after both returned 0. Every delivered file
  read back identically, including the manifest. Directory 0700, files 0600,
  all owned by Linux UID/GID 1000. Destination did not previously exist.
- Linux docs/CURRENT.md before/after SHA-256 unchanged:
  `475594db32e91c75ea4f887efb448cf013da1ec46f4ee336539c7357daa5a55b`.
- Both Zstandard streams and both ZIP CRC tests passed. Gitleaks found no
  exposed text secrets in the delivery scan; private ZIP contents remain
  private and are not a publication-approved credential bundle.
- Evidence/local packet: `out/isolated/linux-dev-migration-20260910/`.
  Native metadata undo is retained there; it is not power-loss recovery.
  Never restore the original pre-development root image over newer Linux work.

## Unfinished application installation

The user asked to download full Linux binaries and apply the supplied kits.
No full Linux installers were present. IDA's official full downloads are in
My Hex-Rays; Binary Ninja supplies customer download links. Native Linux ARM64
builds exist. The supplied Binary Ninja kit only documents synthetic x64 Linux
validation; neither ZIP contains a shell installer or downloads an application.
The IDA script's in-place short-pattern patch and swallowed errors are not
reliable installation proof. Neither patcher was executed.

Matching full Linux ARM64 installer links/files are needed before isolated
inspection and native testing. Binary Ninja Free lacks API/plugins, so it was
not silently substituted for the requested agent integration. References:
https://docs.hex-rays.com/release-notes/9_3
https://docs.binary.ninja/getting-started.html
https://binary.ninja/free/

Resume prompt for the existing Linux agent:

> Read ~/Downloads/mac-dev-transfer-20260910/START-HERE.md and verify its
> SHA256SUMS. Preserve your newer Linux tree and session. Use the macOS fan
> comparison and imported IDA databases; keep cooling protections until fresh
> Linux evidence supports changing them. Continue from your GPU mapping
> checkpoint. Full application installers are still pending.
