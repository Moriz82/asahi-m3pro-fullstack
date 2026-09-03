# M5 fixtures

`test-m5-ports.sh` builds the complete positive matrix from this contract,
including all seven physical ports, both USB-C orientations, required
operations, advertised DP/HDMI modes, and stress scenarios. Negative cases
remove one orientation, use a bare status, or add an IOMMU fault.
