#!/usr/bin/env python3
"""Compile the captured WPE stages and compare DXC layouts with FXC RDEF."""

import argparse
from collections import Counter
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time


CAPTURES = Path('/Users/example/Developer/wpe-fixtures/hlsl-capture-2026-10-12')
DXCOMPILER = Path('/Users/example/Developer/DirectXShaderCompiler/build-14.6/lib/libdxcompiler.dylib')
METALIRCONVERTER = Path('/usr/local/lib/libmetalirconverter.dylib')
STAGES = {
    'vs_5_0': ('vertex', (65534,), 70),
    'ps_5_0': ('fragment', (65535,), 68),
    # These FXC captures use the ASCII GS tag; their SHEX stage type is 2.
    'gs_5_0': ('geometry', (65533, 0x4753), 7),
}


def schema_errors(reflection, stage):
    errors = []
    if reflection.get('schema') != 1 or reflection.get('stage') != stage or reflection.get('entry') != 'main':
        errors.append('incorrect schema, stage or entry')
    for key in ('cbuffers', 'resources', 'topLevelArgumentBuffer', 'vertexInputs', 'stageOutputs'):
        if not isinstance(reflection.get(key), list):
            errors.append(f'{key} must be an array')
    if not isinstance(reflection.get('mscReflection'), dict):
        errors.append('mscReflection must be an object')
    for key in ('vertexInputs', 'stageOutputs'):
        for item in reflection.get(key, []):
            missing = {'name', 'index', 'elementType', 'columns'} - item.keys()
            if missing:
                errors.append(f'{key} {item!r} lacks {sorted(missing)}')
    return errors


def verify(compiler):
    manifest = json.loads((CAPTURES / 'manifest.json').read_text())
    pairs = json.loads((CAPTURES / 'dxs-pairs.json').read_text())
    by_number = {item['n']: item for item in pairs}
    failures, mismatches = [], []
    expected = {target: values[2] for target, values in STAGES.items()}
    if Counter(item['target'] for item in manifest) != Counter(expected):
        failures.append('manifest stage counts differ from 70 vs / 68 ps / 7 gs')
    if len(by_number) != len(pairs) or len({item['n'] for item in manifest}) != len(manifest):
        failures.append('duplicate capture numbers')
    compiled = Counter()
    matched = compared = 0
    times, sizes = [], []
    geometry_message = None
    build = Path(__file__).resolve().parent / 'build'
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='captures-', dir=build) as temporary:
        output = Path(temporary)
        for item in manifest:
            target = item['target']
            stage, programs, _ = STAGES[target]
            label = f"capture {item['n']} {item['name']} ({target})"
            metallib = output / f"{item['n']}.metallib"
            reflection_path = output / f"{item['n']}.json"
            command = [
                str(compiler), '--stage', stage, '--input', str(CAPTURES / item['hlsl']),
                '--output-metallib', str(metallib), '--output-reflection', str(reflection_path),
                '--dxcompiler', str(DXCOMPILER), '--metalirconverter', str(METALIRCONVERTER),
                '--bounds-check',
            ]
            started = time.perf_counter()
            result = subprocess.run(command, capture_output=True, text=True)
            elapsed = time.perf_counter() - started
            if result.returncode:
                failures.append(f'{label}: exit {result.returncode}: {result.stderr.strip()}')
            else:
                times.append(elapsed * 1000)
                if stage == 'geometry' and result.stderr:
                    geometry_message = result.stderr.strip()
            if metallib.is_file() and metallib.stat().st_size:
                sizes.append(metallib.stat().st_size)
                if metallib.read_bytes()[:4] != b'MTLB':
                    failures.append(f'{label}: invalid metallib magic')
            elif stage != 'geometry':
                failures.append(f'{label}: missing or empty metallib')
            if not reflection_path.is_file():
                failures.append(f'{label}: missing reflection')
                continue
            try:
                reflection = json.loads(reflection_path.read_text())
                errors = schema_errors(reflection, stage)
                failures.extend(f'{label}: {error}' for error in errors)
                if not result.returncode and not errors and (stage == 'geometry' or metallib.is_file()):
                    compiled[target] += 1
                pair = by_number[item['n']]
                if (pair['target'], pair['hlsl']) != (target, item['hlsl']):
                    raise ValueError('manifest and dxs-pairs entry differ')
                rdefs = [entry['rdef'] for entry in pair['rdef'] if entry['rdef']['program'] in programs]
                if len(rdefs) != 1:
                    raise ValueError(f'expected exactly one matching RDEF stage, got {len(rdefs)}')
                fxc_buffers = {buffer['name']: buffer for buffer in rdefs[0]['cbuffers']}
                for buffer in reflection['cbuffers']:
                    fxc = fxc_buffers.get(buffer['name'])
                    if fxc is None:
                        continue
                    if buffer['size'] != fxc['size']:
                        mismatches.append(f"{label}: {buffer['name']} size DXC={buffer['size']} FXC={fxc['size']}")
                    fxc_variables = {variable['name']: variable for variable in fxc['vars']}
                    for variable in buffer['variables']:
                        reference = fxc_variables.get(variable['name'])
                        if reference is None:
                            continue
                        compared += 1
                        if (variable['offset'], variable['size']) == (reference['offset'], reference['size']):
                            matched += 1
                        else:
                            mismatches.append(
                                f"{label}: {buffer['name']}.{variable['name']} "
                                f"DXC offset/size={variable['offset']}/{variable['size']} "
                                f"FXC={reference['offset']}/{reference['size']}"
                            )
            except (KeyError, TypeError, ValueError) as error:
                failures.append(f'{label}: invalid reflection or ground truth: {error}')
    if geometry_message:
        print(geometry_message, file=sys.stderr)
    if times:
        print(f'compile time per shader median {statistics.median(times):.3f} ms '
              '(short-lived process, library loading, DXC, MSC and output I/O; bounds check enabled)', file=sys.stderr)
    if sizes:
        print(f'metallib sizes: total {sum(sizes)} bytes; median {statistics.median(sizes):g} bytes; '
              f'min {min(sizes)} bytes; max {max(sizes)} bytes', file=sys.stderr)
    print(f"compiled {compiled['vs_5_0']}/70 vs, {compiled['ps_5_0']}/68 ps, "
          f"{compiled['gs_5_0']}/7 gs; metallib {len(sizes)}; "
          f'cbuffer vars matched {matched}/{compared}; mismatches {len(mismatches)}')
    for mismatch in mismatches:
        print(mismatch)
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures or mismatches else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', required=True, type=Path)
    args = parser.parse_args()
    try:
        return verify(args.compiler.resolve())
    except (OSError, ValueError, KeyError) as error:
        print(f'verify_captures: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
