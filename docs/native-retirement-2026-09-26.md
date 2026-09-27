# Native installation retirement

The owner requested removal of Linux and expansion of macOS APFS, conditional
on preserving the development work in Git. The operation completed on
2026-09-26 (America/Chicago), without rebooting.

## Preserved work

- Public source baseline: this repository, publication commit `5a8b53c`.
- Original native checkpoint: `07bbb42db7904062313bd22e225a4803a6d72d1e`,
  containing 111 commits and 550 tracked files.
- Maintainer-only archive: [Moriz82/linux, native-retirement branch](https://github.com/Moriz82/linux/tree/m3pro/native-retirement-20260926).
  Archive commit: `38be04977dae07aaa4d976bb6f102755ff3b9842`.
- The archive adds 625 previously untracked project files and 37,505 textual
  source/research files. Its manifest records included hashes and exclusions.
  Private reverse-engineering exports and machine captures are not published
  in this public repository.

Verification covered Git integrity, original tracked-file contents, every
archived file hash, the latest promoted GPU source, and the unfinished
first-descriptor candidate. GitHub archive download SHA-256 matched
`277c4b0d744b8b0f7fd3ecf690703558a332b9f7a5deb3626d6897cfb11f6c7e`.
Secret scans and review found no actual credential; 27 generic-key matches
were provenance hashes or source symbols. The private archive retains the
redacted findings and their review.

Recovered native records report an R16 boot, GPU firmware initialization and
control-queue retirement. They do not establish GPU rendering or complete
hardware support. Source-only compute work after R16 was not installed.

## Storage result

The Linux root, Linux EFI, M3 Dev APFS stub and associated Apple_Boot helper
were removed only after preservation verification. macOS APFS expanded from
384,000,000,000 to 494,384,795,648 bytes. Its live filesystem check returned
zero, and final partition-map verification passed. The macOS store identity,
default startup volume, and protected ISC/System Recovery identities, sizes
and offsets were unchanged.

This is source/research preservation, not a complete Linux disk image.
Reinstall and rebuild to restore Linux; old device identifiers, credentials,
boot commands and runtime assumptions must not be reused blindly.
