# Milestone 8 package availability audit

Snapshot time: `2026-09-03T11:37:10Z`

This was a read-only HTTPS and local-artifact audit. It did not download a new
package, build a package, install anything, publish a repository, or execute an
update or rollback.

## What is already proven locally

- `out/isolated/m8-upstream-signed-20260903T103406Z` contains all 17 package
  families in `config/milestone8-upstream-required-packages.txt`; their package
  and repository signatures already passed the pinned offline verifier. Its
  `SHA256SUMS` file hashes to
  `9d6598154323eff8571bc7f85a937ea784063e2e7b67d3a75548e4204b59d9d5`.
- `out/isolated/m8-archlinuxarm-signed-20260903T105112Z` contains the five
  Hyprland-side packages and signatures already checked against the pinned
  Arch Linux ARM build-system fingerprint. Its `SHA256SUMS` file hashes to
  `70fa94e8d61e0d5d3f9d075ee68766f2179773e217d340e037c9ccda0deabbdb`.
- The local eight-package closure combines the downstream kernel and headers
  with the selected desktop packages. Its signed development repository is a
  separate noncanonical artifact, not a replacement for either upstream trust
  check.
- `out/isolated/m8-full-platform-candidate-20260903T120409Z` composes the two
  byte-identical M0 kernel packages, five signed Arch Linux ARM desktop
  packages, and 16 signed Asahi ALARM platform packages under the checked-in
  23-package contract. It preserves 21 upstream detached signatures and hashes
  the four lifecycle files without executing them. Its `SHA256SUMS` file
  hashes to
  `a46cc2bad33e261832ac8558f2439315ed9a5b5d9b575bf2ce7265bfeb962e56`.

These artifacts establish current package availability and provenance only.
The full-platform candidate is not a generated or signed repository and is
explicitly unauthorized for installation. These artifacts do not prove
installation, runtime behavior, J514s support, or rollback.

## Live authoritative-source result

The [Asahi ALARM GitHub releases API](https://api.github.com/repos/asahi-alarm/asahi-alarm/releases?per_page=100)
reported only the fixed `aarch64`, `archport`, and `rootfs` release tags. The
[`aarch64` asset inventory](https://api.github.com/repos/asahi-alarm/asahi-alarm/releases/tags/aarch64)
contained exactly one binary package asset for each of the 17 required Asahi
package families. It did not contain a second version for any required family.
The response SHA-256 values at the snapshot time were:

```text
234e284b2915f369c1893f3819f32b5c32b1c6473459574315067286319438ec  releases?per_page=100
817556260629b5625230381f5456903807645fa97d75946c104c0ab1f1f7acaf  releases/tags/aarch64
```

The live [Arch Linux ARM `extra` mirror index](https://fl.us.mirror.archlinuxarm.org/aarch64/extra/)
likewise exposed one exact base-package binary for each selected desktop
package: `aquamarine 0.14.0-2`, `hyprland 0.56.1-3`, `libinput 1.31.3-1`,
`wayland 1.26.0-1`, and `xdg-desktop-portal-hyprland 1.4.1-1`. The index
response SHA-256 was
`0b5e87d7ed4941d5e67e1d48c65ea58dbe0d1a54fb5430f90b08b319c22ed04d`.

The official [Asahi ALARM PKGBUILD history](https://github.com/asahi-alarm/PKGBUILDs/commits/main/linux-asahi)
does retain older recipes and pins. That is enough to design a controlled
rebuild, but it is not an authoritative retained binary and cannot prove byte
identity with a package that was previously installed.

## Decision

No real prior-version package set was found in the authoritative endpoints or
local retained artifacts inspected here. Do not fill the gap with an
unverified third-party archive or relabel fixture packages as real evidence.

For a future real rollback gate, retain the verified current package set before
promoting an update, then test a separately verified newer candidate against
that retained set. If an older package must instead be rebuilt, pin the
historical recipe and all sources, record the rebuild provenance, sign it with
the development key, and label it as a local rebuild rather than an upstream
binary. A real update and rollback transaction remains a native, separately
authorized Milestone 8 action.

This audit is a point-in-time snapshot. Repeat it before relying on current
package availability because both release assets and rolling mirrors can
change.
