from pathlib import Path
import hashlib
import json
import subprocess
import time

root = Path(__file__).resolve().parents[2]
base = root / '.notes/evidence/ui/2026-09-15-settings-implementation'
binary = base / 'probe/UIArchitectureProbe.app/Contents/MacOS/UIArchitectureProbe'
output = base / 'state-runs'
output.mkdir(exist_ok=True)
sha = hashlib.sha256(binary.read_bytes()).hexdigest()
cases = [(scene, variant) for scene in ['3351072238', '3509243656'] for variant in ['current', 'quantized']]
manifest = []
for repeat in range(3):
    for scene, variant in (cases if repeat % 2 == 0 else list(reversed(cases))):
        label = f'{scene}-{variant}-r{repeat + 1}'
        path = output / (label + '.json')
        command = [str(binary), '--mode', 'scene', '--scene', scene, '--variant', variant,
                   '--operation', 'state-sequence', '--steps', '100', '--output', str(path)]
        start = time.time()
        with (output / (label + '.log')).open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=600)
        manifest.append({'command': command, 'binarySHA256': sha, 'exitCode': result.returncode,
                         'seconds': time.time() - start, 'output': str(path)})
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        if result.returncode:
            raise SystemExit(f'Failed {label}')
        data = json.loads(path.read_text())
        phases = data['statePhases']
        assert phases[0]['valuesDescription'] == phases[-1]['valuesDescription']
        assert phases[0]['displayedPropertyKeys'] == phases[-1]['displayedPropertyKeys']
        assert all(p['thermalStart'] == p['thermalEnd'] == 0 for p in phases)
        print(label, 'p95 by phase:', [round(p['layoutDisplayMs']['p95'], 2) for p in phases], flush=True)
