"""Serial, rotated-order component experiments. Each process includes cold + warm return."""
from pathlib import Path
import argparse, fcntl, hashlib, json, os, subprocess, time

p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--counts', nargs='+', type=int, default=[20, 50, 100])
p.add_argument('--modes', nargs='+', default=['online', 'installed'])
p.add_argument('--variants', nargs='+', default=['lazy', 'windowed', 'collection'])
p.add_argument('--repeats', type=int, default=3)
p.add_argument('--preheat', choices=['on', 'off'], default='on')
p.add_argument('--suite', default='matrix')
p.add_argument('--resume', action='store_true')
a = p.parse_args()
lock = open('/private/tmp/loomscreen-workflow-probe.lock', 'w')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
processes = subprocess.check_output(['ps', '-axo', 'pid=,comm=,args='], text=True)
conflicts = [line for line in processes.splitlines()
             if any(token in line for token in ['/MacOS/WorkflowProbe', '/usr/bin/xcodebuild',
                                                '/usr/bin/xctrace', '/scripts/profile_scenes.py '])]
if conflicts:
    raise SystemExit('Another probe, build, or recording is active: ' + '\n'.join(conflicts))
binary = a.out / 'probe/WorkflowProbe.app/Contents/MacOS/WorkflowProbe'
sha = hashlib.sha256(binary.read_bytes()).hexdigest()
dest = a.out / a.suite
dest.mkdir(parents=True, exist_ok=True)
manifest = json.loads((dest/'manifest.json').read_text()) if a.resume and (dest/'manifest.json').exists() else []
for repetition in range(a.repeats):
    variants = a.variants[repetition % len(a.variants):] + a.variants[:repetition % len(a.variants)]
    for mode in a.modes if repetition % 2 == 0 else list(reversed(a.modes)):
        for count in a.counts:
            for variant in variants:
                base_label = f'{mode}-{count}-{variant}-r{repetition+1}'
                label = base_label
                existing = list(dest.glob(base_label + '*.json'))
                if a.resume and existing:
                    valid = [path for path in existing if not (d := json.loads(path.read_text()))['errors']
                             and d['thermalStart'] == d['thermalEnd'] == 0]
                    if valid:
                        assert len(valid) == 1, valid
                        record = next(row for row in manifest if row['output'] == str(valid[0]))
                        assert record['binarySHA256'] == sha and json.loads(valid[0].read_text())['preheat'] == a.preheat
                        continue
                    label += f'-retry{len(existing)}'
                output = dest / f'{label}.json'
                cache = dest / f'{label}-cache'
                if output.exists() or cache.exists():
                    raise SystemExit(f'Refusing to overwrite an existing run: {label}')
                command = [str(binary), '--variant', variant, '--mode', mode, '--count', str(count),
                           '--preheat', a.preheat, '--output', str(output), '--cache', str(cache)]
                if a.suite == 'smoke':
                    command += ['--screenshot', str(dest / f'{label}.png')]
                start = time.time()
                with (dest / f'{label}.log').open('w') as log:
                    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=720)
                entry = dict(command=command, binarySHA256=sha, exitCode=result.returncode,
                             wallSeconds=time.time()-start, output=str(output), systemLoadAverage=os.getloadavg())
                manifest.append(entry)
                (dest / 'manifest.json').write_text(json.dumps(manifest, indent=2))
                if result.returncode:
                    raise SystemExit(f'FAILED {label}, see its log and result JSON')
                data = json.loads(output.read_text())
                print(label, f'CPU={data["cpuSeconds"]:.3f}s', f'RSS={data["rssPeakSampled"]/2**20:.1f}MiB',
                      'thermal', data['thermalStart'], data['thermalEnd'], flush=True)
                if data['thermalStart'] != 0 or data['thermalEnd'] != 0:
                    raise SystemExit(f'Thermal conditions changed during {label}; retained but not comparable')
                time.sleep(5)
