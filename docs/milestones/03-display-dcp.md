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

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
