#!/usr/bin/env python3
"""Offline regressions only; never accesses native sysfs or graphics devices."""
import copy
import importlib.util
import json
import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve()
SOURCE = HERE.parent.parent / 'scripts/linux-stay-check.py'
if not SOURCE.is_file():
    SOURCE = HERE.with_name('linux-stay-check.py')
spec = importlib.util.spec_from_file_location('stay', SOURCE)
stay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stay)


def fixture():
    snap = {'boot_id': 'fixture-boot', 'compatible': 'apple,j514s\0apple,t6030\0',
            'fan_control': 'N', 'caps_khz': {'0': 696000, '1': 744000},
            'hwmon': [{'name': 'macsmc_hwmon', 'fans_rpm': [2317, 2502],
                       'temperatures': [{'label': 'CPU', 'millidegrees_c': 45000}]}],
            'render_nodes': {'renderD128': {'driver': 'asahi', 'devnode_present': True}},
            'backlight_devices': []}
    def service(text):
        return {'returncode': 0, 'truncated': False, 'text': text}
    services = {'asahi-cooling-limits.service': service('LoadState=loaded\nActiveState=active\nUnitFileState=enabled'),
                'asahi-fan-boost.service': service('LoadState=masked\nActiveState=inactive\nUnitFileState=masked'),
                'asahi-cooling-boost.service': service('LoadState=not-found\nActiveState=inactive')}
    return [copy.deepcopy(snap) for _ in range(3)], services


class Tests(unittest.TestCase):
    def test_positive_is_not_hardware_acceptance(self):
        report = stay.assess(*fixture())
        self.assertTrue(report['renderer_probe_eligible'])
        self.assertFalse(report['hardware_acceptance'])

    def test_missing_hot_zero_and_ambiguous_cooling(self):
        mutations = [lambda s: s.update(fan_control='Y'),
                     lambda s: s.update(caps_khz={'0': 4056000, '1': 744000}),
                     lambda s: s.update(compatible='apple,j516s\0apple,t6030'),
                     lambda s: s.update(boot_id=None),
                     lambda s: s['hwmon'][0].update(fans_rpm=[0, 2500]),
                     lambda s: s['hwmon'][0].update(fans_rpm=[None, 2500]),
                     lambda s: s['hwmon'].append(copy.deepcopy(s['hwmon'][0])),
                     lambda s: s['hwmon'][0]['temperatures'][0].update(label='NAND'),
                     lambda s: s['hwmon'][0]['temperatures'][0].update(millidegrees_c=70000),
                     lambda s: s['hwmon'][0]['temperatures'][0].update(millidegrees_c=None),
                     lambda s: s['hwmon'][0]['temperatures'][0].update(millidegrees_c=52000)]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                samples, services = fixture(); mutate(samples[-1])
                self.assertFalse(stay.assess(samples, services)['renderer_probe_eligible'])

    def test_services_fail_closed(self):
        for name in fixture()[1]:
            for change in [{'returncode': 1}, {'truncated': True}, {'text': 'LoadState=loaded\nActiveState=active\nUnitFileState=enabled'}]:
                if name == 'asahi-cooling-limits.service' and 'text' in change:
                    change = {'text': 'ActiveState=inactive\nUnitFileState=disabled'}
                with self.subTest(name=name, change=change):
                    samples, services = fixture(); services[name].update(change)
                    self.assertFalse(stay.assess(samples, services)['renderer_probe_eligible'])

    def test_gpu_and_sample_gates(self):
        for nodes in [{}, {'renderD128': {'driver': 'simpledrm', 'devnode_present': True}},
                      {'renderD128': {'driver': 'asahi', 'devnode_present': False}}]:
            samples, services = fixture(); samples[-1]['render_nodes'] = nodes
            self.assertFalse(stay.assess(samples, services)['renderer_probe_eligible'])
        samples, services = fixture()
        self.assertFalse(stay.assess(samples[:1], services)['renderer_probe_eligible'])
        self.assertFalse(stay.assess([], services)['renderer_probe_eligible'])

    def test_renderer_no_false_success(self):
        cases = [('OpenGL renderer string: Apple M3 Pro (AGX)', 'AGX_renderer_reported'),
                 ('OpenGL renderer string: llvmpipe', 'software_renderer'),
                 ('OpenGL renderer string: Unknown\nAGX supported', 'renderer_unknown'),
                 ('Apple M3 Pro', 'renderer_unknown')]
        for text, expected in cases:
            self.assertEqual(stay.renderer_result({'text': text, 'returncode': 0, 'truncated': False}), expected)
        self.assertEqual(stay.renderer_result({'text': cases[0][0], 'returncode': 1, 'truncated': False}), 'query_failed')

    def test_reader_and_private_output_no_control_writes(self):
        samples, services = fixture()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertIsNone(stay.read(root/'absent'))
            (root/'large').write_bytes(b'x'*4097)
            self.assertIsNone(stay.read(root/'large'))
            samples[0]['hwmon'][0]['fans_rpm'] = [0, 0]
            calls = []
            def query(argv):
                calls.append(argv)
                self.assertEqual(argv[:2], ['/usr/bin/systemctl', 'show'])
                return services[argv[2]]
            with patch.object(stay.platform, 'system', return_value='Linux'), patch.object(stay.platform, 'machine', return_value='aarch64'), patch.object(stay, 'sample', side_effect=samples), patch.object(stay, 'query', side_effect=query), patch.object(stay.time, 'sleep'):
                self.assertEqual(stay.main([str(root/'out'), '--probe-renderer']), 2)
            self.assertEqual(len(calls), 3)
            self.assertEqual((root/'out').stat().st_mode & 0o777, 0o700)
            self.assertEqual((root/'out/report.json').stat().st_mode & 0o777, 0o600)
            self.assertFalse(json.loads((root/'out/report.json').read_text())['assessment']['hardware_acceptance'])
            with patch.object(stay.platform, 'system', return_value='Linux'), patch.object(stay.platform, 'machine', return_value='aarch64'):
                with self.assertRaises(FileExistsError): stay.main([str(root/'out')])

    def test_wrong_host_rejected(self):
        with patch.object(stay.platform, 'system', return_value='Darwin'):
            with self.assertRaises(SystemExit): stay.main(['/unused'])

    def test_successful_probe_and_post_probe_failure(self):
        for fail_after in (False, True):
            with self.subTest(fail_after=fail_after), tempfile.TemporaryDirectory() as temp:
                samples, services = fixture()
                after = copy.deepcopy(samples[0])
                if fail_after: after['hwmon'][0]['fans_rpm'] = [0, 0]
                calls = []
                def query(argv):
                    calls.append(argv)
                    if argv[0] == '/usr/bin/glxinfo':
                        return {'argv': argv, 'text': 'OpenGL renderer string: Apple M3 Pro (AGX)', 'returncode': 0, 'truncated': False}
                    self.assertEqual(argv[0], '/usr/bin/systemctl')
                    return services[argv[2]]
                with patch.object(stay.platform, 'system', return_value='Linux'), patch.object(stay.platform, 'machine', return_value='aarch64'), patch.object(stay, 'sample', side_effect=samples+[after]), patch.object(stay, 'query', side_effect=query), patch.object(stay.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(stay.main([str(Path(temp)/'out'), '--probe-renderer']), 2 if fail_after else 0)
                self.assertEqual(calls.count(['/usr/bin/glxinfo', '-B']), 1)
                self.assertEqual(len(calls), 7)
                report = json.loads((Path(temp)/'out/report.json').read_text())
                self.assertEqual(report['assessment']['renderer'], 'post_probe_gate_failed' if fail_after else 'AGX_renderer_reported')
                self.assertFalse(report['assessment']['hardware_acceptance'])

    def test_query_failure_and_output_bound(self):
        argv = ['/usr/bin/glxinfo', '-B']
        for error, expected in [(FileNotFoundError('missing'), 127), (subprocess.TimeoutExpired(argv, 10), 124)]:
            with patch.object(stay.subprocess, 'run', side_effect=error):
                self.assertEqual(stay.query(argv)['returncode'], expected)
        result = subprocess.CompletedProcess(argv, 0, stdout=b'x'*65537, stderr=b'')
        with patch.object(stay.subprocess, 'run', return_value=result):
            report = stay.query(argv)
            self.assertTrue(report['truncated'])
            self.assertEqual(len(report['text']), 65536)


if __name__ == '__main__':
    unittest.main()
