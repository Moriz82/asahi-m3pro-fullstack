# M9 fixtures

The self-test uses these nine static M0-M8 handoff manifest inputs to build a
temporary canonical handoff root and external hash anchor. It then exercises
the format-2 `canonical-milestone-handoffs` release envelope, including the
copy race and tamper regressions. No fixture is an authorization or a
hardware-support claim; every attestation remains blocked.
