# Milestone 1 initramfs

This is a RAM-only controlled-tether test initramfs for `Mac15,6/J514s`.
It mounts only `proc`, `sysfs`, `devtmpfs`, and a `tmpfs` runtime directory.
It does not accept `root=`, mount NVMe or APFS, write persistent storage, or
change firmware, boot policy, startup-disk selection, or FileVault/SIP state.

The init script records a serial-visible session log and a RAM-local dmesg
snapshot. `M1_TEST_ACTION=prepare-watchdog`, `prepare-panic`, or
`prepare-reboot` records operator preparation only. It never triggers a fault,
watchdog, panic, or reboot automatically.

`/run` is mounted before its log directory is created. Failed virtual-filesystem
mounts, unreadable command lines, forbidden storage parameters, and unknown test
actions stop at the safe-halt loop without reporting tether readiness.

The offline test executes the unchanged init in a disposable Linux chroot with
ordinary files for the console and command line. Test doubles model mounts,
dmesg, and the final sleep; they do not mount a device or boot a kernel. CI runs
this inside a read-only, network-disabled container. Chroot alone is not a
security boundary. An optional `--busybox PATH` test uses the hash-pinned target
BusyBox on AArch64 Linux. These checks do not simulate Apple hardware.

The artifact verifier requires the embedded init to match the current reviewed
source byte-for-byte. Existing images must be rebuilt after init changes.
It accepts exactly one size-bounded gzip member and newc archive with canonical end padding, root
ownership, M0 source timestamps, executable modes, and no hardlinked payloads.
Rehashed fixtures cover concatenated archives and metadata that previously
passed despite an unbootable `/init`.

Packing normalizes the private staging tree (including Darwin symlink modes)
and uses a unique temporary archive. The completed staging evidence must pass
verification before atomic no-replace publication. Byte-equal fixture archives
from different input timestamps prove this packing path, not a full M1 build
or native boot. Measured Mac/Linux equality applies to the tested toolchains,
not arbitrary host cpio/gzip versions. Failure cleanup removes only private
staging paths, preserving previously published evidence. The canonical M0
prerequisite is unchanged.

The RAM-only userspace policy does not prove that boot firmware, the kernel,
or drivers are risk-free; native execution remains separately gated.

The first-session diagnostic pass reads cached kernel metadata and emits it to
the existing RAM log and console. Each file has a two-second timeout and a
65,536-byte output cap; dmesg collection has a three-second timeout. Missing
files, errors and unassessed truncation are reported, never converted into
hardware success. Only `head` and `timeout` are added to the pinned BusyBox
applet set. No storage/device exercise, stress, suspend or reset is triggered.
See [the Linux USB receiver and session checklist](../../docs/usb-debug-linux.md)
for the distinction between direct boot and the hypervisor's USB virtual UART.
