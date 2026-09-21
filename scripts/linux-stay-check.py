#!/usr/bin/env python3
"""Read-only J514s cooling/GPU checks. No fan writes, stress, modules or reboot.

Default: short idle samples and device/service metadata only. --probe-renderer
may create graphics contexts; it requires complete conservative cooling gates.
Passing these checks is not full cooling, GPU or hardware acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time
from datetime import datetime, timezone


def read(path):
    try:
        with path.open('rb') as stream:
            value = stream.read(4097)
        return value.decode(errors='replace').strip() if len(value) <= 4096 else None
    except OSError:
        return None


def number(value):
    try:
        return int(value)
    except (ValueError, TypeError):
        return None


def query(argv):
    try:
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                                timeout=10, check=False)
        data = result.stdout + result.stderr
        return {'argv': argv, 'returncode': result.returncode,
                'text': data[:65536].decode(errors='replace'),
                'truncated': len(data) > 65536}
    except subprocess.TimeoutExpired:
        return {'argv': argv, 'returncode': 124, 'text': 'timeout', 'truncated': False}
    except OSError as exc:
        return {'argv': argv, 'returncode': 127, 'text': str(exc), 'truncated': False}


def service_snapshot():
    return {name: query(['/usr/bin/systemctl', 'show', name, '--no-pager',
                         '--property=LoadState,ActiveState,UnitFileState']) for name in
            ('asahi-cooling-limits.service', 'asahi-fan-boost.service', 'asahi-cooling-boost.service')}


def properties(result):
    if result['returncode'] or result['truncated']:
        return {}
    return dict(line.split('=', 1) for line in result['text'].splitlines() if '=' in line)


def sample(root=Path('/')):
    hwmon = root / 'sys/class/hwmon'
    monitors = []
    for node in sorted(hwmon.glob('hwmon*')):
        name = read(node / 'name')
        temps = []
        for path in sorted(node.glob('temp*_input'))[:128]:
            label = read(path.with_name(path.name.replace('_input', '_label')))
            temps.append({'path': str(path), 'label': label,
                          'millidegrees_c': number(read(path))})
        monitors.append({'name': name, 'path': str(node), 'temperatures': temps,
                         'fans_rpm': [number(read(node / f'fan{i}_input')) for i in (1, 2)]})
    drivers = {}
    for node in sorted((root / 'sys/class/drm').glob('renderD*')):
        driver = node / 'device/driver'
        drivers[node.name] = {'driver': driver.resolve().name if driver.is_symlink() else None,
                             'devnode_present': (root / 'dev/dri' / node.name).exists()}
    return {'boot_id': read(root / 'proc/sys/kernel/random/boot_id'),
            'compatible': read(root / 'sys/firmware/devicetree/base/compatible'),
            'fan_control': read(root / 'sys/module/macsmc_hwmon/parameters/fan_control'),
            'caps_khz': {str(i): number(read(root / f'sys/devices/system/cpu/cpufreq/policy{i}/scaling_max_freq'))
                         for i in (0, 1)},
            'hwmon': monitors, 'render_nodes': drivers,
            'backlight_devices': sorted(p.name for p in (root / 'sys/class/backlight').glob('*'))}


def assess(samples, services):
    blockers = []
    cpu_ranges = []
    if not samples or not samples[0].get('boot_id'):
        blockers.append('missing boot identity')
    for snap in samples:
        compatible = (snap.get('compatible') or '').split('\0')
        if 'apple,j514s' not in compatible or 'apple,t6030' not in compatible:
            blockers.append('wrong or unknown board')
        if snap.get('boot_id') != samples[0].get('boot_id'):
            blockers.append('boot identity changed')
        if snap.get('fan_control') != 'N':
            blockers.append('fan_control is not confirmed N')
        if snap.get('caps_khz') != {'0': 696000, '1': 744000}:
            blockers.append('expected temporary CPU caps not confirmed')
        smc = [n for n in snap['hwmon'] if n['name'] == 'macsmc_hwmon']
        if len(smc) != 1 or not all(isinstance(v, int) and 0 < v <= 10000
                                   for v in smc[0]['fans_rpm']):
            blockers.append('both SMC fans not confirmed spinning; not itself a fault diagnosis')
        cpu = [t['millidegrees_c'] for n in snap['hwmon'] for t in n['temperatures']
               if re.search(r'\bcpu\b|[pe]-?cluster', t['label'] or '', re.I)]
        if not cpu or any(v is None or not 0 < v < 70000 for v in cpu):
            blockers.append('CPU-labeled temperatures unavailable or outside conservative probe bound')
        else:
            cpu_ranges.append(max(cpu))
    if cpu_ranges and max(cpu_ranges) - min(cpu_ranges) > 5000:
        blockers.append('CPU temperature changed more than 5 C during idle samples')
    caps = properties(services['asahi-cooling-limits.service'])
    if caps.get('ActiveState') != 'active' or caps.get('UnitFileState') != 'enabled':
        blockers.append('persistent cooling-limit service not active and enabled')
    boost = [properties(services[name]) for name in
             ('asahi-fan-boost.service', 'asahi-cooling-boost.service')]
    if not any(p.get('LoadState') == 'masked' for p in boost) or any(
            p.get('LoadState') not in ('masked', 'not-found') or
            p.get('ActiveState') not in ('inactive', 'failed') for p in boost):
        blockers.append('boost services not confirmed masked/absent and inactive')
    nodes = samples[-1]['render_nodes'] if samples else {}
    gpu_ready = any(n['devnode_present'] and n['driver'] in ('asahi', 'apple-agx')
                    for n in nodes.values())
    return {'cooling_blockers': sorted(set(blockers)),
            'gpu_device_state': 'recognized render device present' if gpu_ready else 'no recognized AGX render device',
            'renderer_probe_eligible': len(samples) >= 3 and not blockers and gpu_ready,
            'hardware_acceptance': False,
            'warning': 'Idle/probe eligibility only. Caps and accessory sensors do not prove CPU safety. No stress authorization.'}


def renderer_result(result):
    if result['returncode'] or result['truncated']:
        return 'query_failed'
    text = result['text']
    match = re.search(r'^\s*OpenGL renderer string:\s*(.+)$', text, re.M | re.I)
    if not match:
        return 'renderer_unknown'
    if re.search(r'llvmpipe|softpipe|swrast|lavapipe|software', text, re.I):
        return 'software_renderer'
    return 'AGX_renderer_reported' if re.search(r'\bAGX\b|Apple M3', match[1], re.I) else 'renderer_unknown'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='new private evidence directory')
    parser.add_argument('--probe-renderer', action='store_true', help='opt-in glxinfo context query after cooling gates; no benchmark')
    args = parser.parse_args(argv)
    if platform.system() != 'Linux' or platform.machine() not in ('aarch64', 'arm64'):
        parser.error('Run on the native ARM64 Linux installation, not macOS or emulation')
    os.umask(0o077)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    samples = []
    for i in range(3):
        if i:
            time.sleep(2)
        samples.append(sample())
    services = service_snapshot()
    result = assess(samples, services)
    renderer = None
    post_services = None
    if args.probe_renderer and result['renderer_probe_eligible']:
        renderer = query(['/usr/bin/glxinfo', '-B'])
        result['renderer'] = renderer_result(renderer)
        after = sample()
        samples.append(after)
        post_services = service_snapshot()
        post = assess(samples, post_services)
        result['post_probe'] = post
        if not post['renderer_probe_eligible']:
            result['renderer'] = 'post_probe_gate_failed'
            result['renderer_probe_eligible'] = False
    else:
        result['renderer'] = 'blocked_by_gate' if args.probe_renderer else 'not_requested'
    report = {'schema': 1, 'captured_utc': datetime.now(timezone.utc).isoformat(),
              'kernel': platform.release(), 'samples': samples, 'services': services,
              'assessment': result, 'renderer_query': renderer, 'post_probe_services': post_services,
              'scope': 'idle read-only checks; optional explicitly gated graphics-context query; no stress or controls'}
    report_path = args.output / 'report.json'
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    digest = hashlib.sha256(report_path.read_bytes()).hexdigest()
    (args.output / 'SHA256SUMS').write_text(f'{digest}  report.json\n')
    print(json.dumps({'output': str(args.output), **result}, indent=2))
    return 0 if result['renderer_probe_eligible'] and result['renderer'] in ('not_requested', 'AGX_renderer_reported') else 2


if __name__ == '__main__':
    raise SystemExit(main())
