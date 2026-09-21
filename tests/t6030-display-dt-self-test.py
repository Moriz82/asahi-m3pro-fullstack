#!/usr/bin/env python3
"""Validate a development J514s display DTB against the exact saved Apple ADT.

Usage: CLIENT DECODED_ADT DTB [BASELINE_J514S_DTB]
Only reads metadata and calls fdtget. No target access or boot.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

if len(sys.argv) not in (4, 5):
    raise SystemExit(__doc__)
client, adt_file, dtb = [Path(arg).resolve(strict=True) for arg in sys.argv[1:4]]
baseline = Path(sys.argv[4]).resolve(strict=True) if len(sys.argv) == 5 else None
sys.argv[1:] = []
sys.dont_write_bytecode = True
sys.path.insert(0, str(client))
from m1n1.adt import load_adt

fdtget = shutil.which('fdtget')
if fdtget is None:
    raise SystemExit('existing fdtget is required')


def offline_only(event, args):
    if event in {'socket.connect', 'os.system'}:
        raise RuntimeError('offline DT test forbids connections/execution')
    if event == 'subprocess.Popen' and args[0] != fdtget:
        raise RuntimeError('offline DT test permits only fdtget')
    if event == 'open' and isinstance(args[0], (str, bytes, os.PathLike)):
        path = os.fsdecode(args[0])
        if path.startswith('/dev/') and path not in {'/dev/null', '/dev/urandom', '/dev/random'}:
            raise RuntimeError('offline DT test forbids device access')


sys.addaudithook(offline_only)
raw_adt = adt_file.read_bytes()
if hashlib.sha256(raw_adt).hexdigest() != '4964d5c2ca371a0a0e13029aab5f7655fe748c0358f89a71b51285f82e5e3478':
    raise SystemExit('unexpected Apple ADT input')
adt = load_adt(raw_adt)


def prop(node, name, kind='x', tree=dtb):
    result = subprocess.run([fdtget, '-t', kind, str(tree), node, name],
                            capture_output=True, text=True, check=True)
    return result.stdout.strip() if kind == 's' else [int(word, 16) for word in result.stdout.split()]


def cells64(values):
    if len(values) % 2:
        raise ValueError('incomplete 64-bit cells')
    return [(values[i] << 32) | values[i + 1] for i in range(0, len(values), 2)]


class DisplayTree(unittest.TestCase):
    def setUp(self):
        self.dcp = prop('/aliases', 'dcp', 's')
        self.display = prop('/aliases', 'disp0', 's')
        self.piodma = prop('/aliases', 'disp0-piodma', 's')
        self.dart_dcp = '/soc/iommu@28d30c000'
        self.dart_disp = '/soc/iommu@28d304000'
        self.mailbox = '/soc/mbox@28ec08000'

    def test_exact_target_and_register_order(self):
        self.assertEqual(adt.model, 'Mac15,6')
        self.assertEqual(prop('/', 'compatible', 's').split(),
                         ['apple,j514s', 'apple,t6030', 'apple,arm-platform'])
        self.assertEqual(prop(self.dcp, 'compatible', 's').split(), ['apple,t6030-dcp', 'apple,dcp'])
        self.assertEqual(prop(self.dcp, 'reg-names', 's').split(),
                         ['coproc'] + [f'disp-{i}' for i in range(5)])
        expected = [adt['/arm-io/dcp'].get_reg(0)[0], 0x4000]
        for i in range(5):
            expected.extend(adt['/arm-io/disp0'].get_reg(i))
        self.assertEqual(cells64(prop(self.dcp, 'reg')), expected)

    def test_scratch_appends_the_sixth_register_once(self):
        source = '/soc/power-management@3503d0000'
        self.assertEqual(cells64(prop(source, 'reg')), list(adt['/arm-io/disp0'].get_reg(5)))
        self.assertEqual(prop(source, '#apple,bw-scratch-cells'), [3])
        self.assertEqual(prop(self.dcp, 'apple,bw-scratch'), prop(source, 'phandle') + [0, 5, 0x988])
        names = subprocess.check_output([fdtget, '-p', str(dtb), self.dcp], text=True).split()
        self.assertNotIn('apple,bw-doorbell', names)

    def test_dart_resources_and_address_windows(self):
        for node, path in [(self.dart_dcp, '/arm-io/dart-dcp'), (self.dart_disp, '/arm-io/dart-disp0')]:
            with self.subTest(node=node):
                source = adt[path]
                self.assertEqual(list(source.compatible), ['dart,t8110'])
                self.assertEqual(prop(node, 'compatible', 's').split(), ['apple,t6030-dart', 'apple,t8110-dart'])
                self.assertEqual(cells64(prop(node, 'reg')), list(source.get_reg(0)))
                self.assertEqual(prop(node, '#iommu-cells'), [1])
                self.assertEqual(cells64(prop(node, 'apple,dma-range')),
                                 [source.getprop('vm-base'), source.getprop('vm-size')])
                self.assertEqual(prop(node, 'interrupts'), [0, source.interrupts[0], 4])

    def test_iommu_and_mailbox_links(self):
        alias_names = subprocess.check_output([fdtget, '-p', str(dtb), '/aliases'], text=True).split()
        self.assertNotIn('disp0_piodma', alias_names)
        self.assertEqual(alias_names.count('disp0-piodma'), 1)
        for node, dart, path in [(self.dcp, self.dart_dcp, '/arm-io/dart-dcp/mapper-dcp'),
                                 (self.display, self.dart_disp, '/arm-io/dart-disp0/mapper-disp0'),
                                 (self.piodma, self.dart_disp, '/arm-io/dart-disp0/mapper-disp0-piodma')]:
            with self.subTest(node=node):
                self.assertEqual(prop(node, 'iommus'), prop(dart, 'phandle') + [adt[path].reg])
                self.assertEqual(len(prop(node, 'phandle')), 1)
        self.assertEqual(prop(self.dcp, 'mboxes'), prop(self.mailbox, 'phandle'))
        self.assertEqual(prop(self.dcp, 'mbox-names', 's'), 'mbox')
        self.assertEqual(self.piodma, self.dcp + '/piodma')

    def test_mailbox_matches_existing_t6030_convention(self):
        base = adt['/arm-io/dcp'].get_reg(0)[0]
        self.assertEqual(cells64(prop(self.mailbox, 'reg')), [base + 0x8000, 0x4000])
        self.assertEqual(prop(self.mailbox, 'compatible', 's').split(),
                         ['apple,t6030-asc-mailbox', 'apple,asc-mailbox-v4'])
        for node, source in [(self.mailbox, adt['/arm-io/dcp']),
                             ('/soc/mbox@36c408000', adt['/arm-io/smc']),
                             ('/soc/mbox@37a408000', adt['/arm-io/mtp'])]:
            with self.subTest(node=node):
                interrupts = []
                for index in (1, 0, 3, 2):
                    interrupts.extend([0, source.interrupts[index], 4])
                self.assertEqual(prop(node, 'interrupts'), interrupts)
                self.assertEqual(prop(node, 'interrupt-names', 's').split(),
                                 ['send-empty', 'send-not-empty', 'recv-empty', 'recv-not-empty'])

    def test_existing_display_power_chain_is_reused(self):
        cpu = '/soc/power-management@350700000/power-controller@10000'
        front_end = '/soc/power-management@350700000/power-controller@258'
        system = '/soc/power-management@350700000/power-controller@1c0'
        self.assertEqual(prop(cpu, 'power-domains'), prop(front_end, 'phandle'))
        self.assertEqual(prop(front_end, 'power-domains'), prop(system, 'phandle'))
        self.assertEqual(prop('/chosen/framebuffer@0', 'power-domains'), prop(cpu, 'phandle'))
        for node in [self.dcp, self.mailbox, self.dart_dcp, self.dart_disp]:
            self.assertEqual(prop(node, 'power-domains'), prop(cpu, 'phandle'))
        self.assertEqual(prop(self.dcp, 'resets'), prop(cpu, 'phandle'))

    def test_no_automatic_probe_or_static_runtime_addresses(self):
        for node in [self.dcp, self.display, self.mailbox, self.dart_dcp, self.dart_disp]:
            with self.subTest(node=node):
                self.assertEqual(prop(node, 'status', 's'), 'disabled')
        for node in [self.dcp, self.display, self.piodma]:
            names = subprocess.check_output([fdtget, '-p', str(dtb), node], text=True).split()
            self.assertNotIn('memory-region', names)
            self.assertNotIn('apple,firmware-version', names)
            self.assertNotIn('apple,firmware-compat', names)
        self.assertEqual(prop('/chosen/framebuffer@0', 'reg'), [0, 0, 0, 0])

    @unittest.skipUnless(baseline, 'optional baseline tree')
    def test_baseline_cannot_satisfy_new_topology(self):
        for name in ['dcp', 'disp0', 'disp0-piodma', 'disp0_piodma']:
            with self.assertRaises(subprocess.CalledProcessError):
                prop('/aliases', name, 's', baseline)


if __name__ == '__main__':
    unittest.main(verbosity=2)
