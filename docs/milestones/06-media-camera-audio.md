# Milestone 6: media, camera, microphone, and audio safety

M6 collectors only package explicitly supplied evidence. They never open a
camera, capture or play audio, load a codec, change a mixer, or mutate a
device. Static bundles always carry `hardware_acceptance=false`.

The contract requires structured camera capture records, microphone capture
and headphone playback records, and codec-by-codec 4K decode and encode rows.
Camera rows must be positive numeric capture dimensions/rate with Apple ISP
telemetry on T6030; virtual and software camera sources are rejected.
Every codec row names the selected hardware codec and includes concurrent
device/utilization telemetry. H.264, HEVC, and VP9 require observed hardware
decode and encode. AV1 and ProRes must be either observed with hardware
selection or explicitly unsupported with a hardware-specific reason. Hardware
codec identifiers must match the strict `T6030-{codec}-{decoder|encoder|unsupported}`
allowlist. Any
software fallback, CPU/software/FFmpeg codec, placeholder, bare pass, or
missing path fails.

Internal speakers are never tested by the collector. They remain
`unsupported` unless `speaker-safety.tsv` proves the exact J514 calibration
hash anchored to the repository-reviewed `config/milestone6-speaker-calibrations.tsv`,
active `speakersafetyd`, approved DSP graph ID/hash, amplifier thermal
telemetry and limit, and a blocked negative safety result. The production
allowlist is intentionally empty until a reviewed calibration is added. A
supported speaker row without every proof is rejected.

## Pinned source readiness

`scripts/check-m6-source-readiness.sh` binds its result to the exact clean
Linux tree used by M0, the M2 source contract, a focused M6 file-hash contract,
and the checksummed M0 kernel config/module inventory. It reuses the existing
downstream Apple drivers; it does not reimplement media or audio support.

The pinned tree contains an explicit T6030 ISP match and J514 IMX558 camera
wiring. Its T6030 AVD node uses a driver-matched T8122-compatible decoder path,
whose static formats include H.264, HEVC, VP9, and AV1. J514 also has AOP
microphone, CS42L84 headphone-jack, and six-amplifier speaker topology, with
the expected ADMAC, MCA, macaudio, and codec modules built. These are static
source candidates only, not proof that any path works on this Mac.

The same exact tree has no Apple video-encoder or ProRes driver path. The
reviewed J514 speaker-calibration allowlist is empty, and no static check can
provide speakersafetyd, DSP, amplifier-thermal, or native runtime evidence.
The source gate therefore exits 2 with granular positive and negative fields;
internal speakers remain unactuated and M6 hardware acceptance remains false.

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
