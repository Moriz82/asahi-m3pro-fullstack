# Milestone 3: internal display and DCP

The collector validates supplied display-mode declarations, clean kernel and
DCP logs, at least 100 structured successful brightness records, and at least
50 structured successful suspend/resume records. Bare `pass` strings are not
accepted as records. All bundles remain `software-plan-only` with
`hardware_acceptance=false`.

Human-only future gates include DCP initialization, framebuffer handoff,
modesetting, eDP and panel sequencing, backlight and variable refresh, lid and
hotplug behavior, blank/unblank, compositor restart, low-battery resume,
black-screen recovery, two-person review, and native panel evidence at every
advertised mode.

## Pinned source state

The pinned post-patch Linux source tree contains the Apple DRM/DCP driver, and
the M0 configuration builds `CONFIG_DRM_APPLE=m`. The J514s/T6030 device-tree
closure does not contain a DCP device, DCP mailbox/DART, display subsystem,
panel, or backlight node; it exposes only the loader-populated simple
framebuffer. Older Apple SoCs having DCP nodes does not make that driver usable
on T6030. No target DCP implementation is inferred or duplicated here.

`scripts/check-m3-source-readiness.sh` binds this check to the M2 source
contract and checks the target DCP node, mailbox, DART, and display-subsystem
requirements. With the current pin it exits 2 and reports
`gate=blocked-target-dcp-topology`. Run it in the same read-only pinned Arch
container used by the M2 source-contract check.

The structured-evidence validator requires positive numeric width, height, and
refresh values for unique display-mode tuples, brightness percentages in
`0..100`, and nonnegative numeric resume times. These checks only prevent
malformed supplied records. They do not turn a software-plan bundle into
runtime or hardware evidence. M3 stays blocked until reviewed target source and
native panel evidence exist.

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
