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

## Uniform software gate and handoff

The verifier reports `tooling_valid`, `evidence_valid`, and
`hardware_acceptance` separately. A canonical handoff may be made only after
the milestone verifier passes; the native gate remains blocked.
