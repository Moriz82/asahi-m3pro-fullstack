# Milestone 1 initramfs

This is a RAM-only controlled-tether test initramfs for `Mac15,6/J514s`.
It mounts only `proc`, `sysfs`, `devtmpfs`, and a `tmpfs` runtime directory.
It does not accept `root=`, mount NVMe or APFS, write persistent storage, or
change firmware, boot policy, startup-disk selection, or FileVault/SIP state.

The init script records a serial-visible session log and a RAM-local dmesg
snapshot. `M1_TEST_ACTION=prepare-watchdog`, `prepare-panic`, or
`prepare-reboot` records operator preparation only. It never triggers a fault,
watchdog, panic, or reboot automatically.
