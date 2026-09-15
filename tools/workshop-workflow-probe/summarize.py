from pathlib import Path
import argparse, json, statistics

p = argparse.ArgumentParser()
p.add_argument('directory', type=Path)
a = p.parse_args()
groups = {}
excluded = []
for path in a.directory.glob('*.json'):
    if path.name in ['manifest.json', 'summary.json']: continue
    data = json.loads(path.read_text())
    if 'phases' not in data: continue
    if data['errors'] or not data['thermalStart'] == data['thermalEnd'] == 0:
        excluded.append(dict(path=str(path), errors=data['errors'], thermal=[data['thermalStart'],data['thermalEnd']]))
        continue
    for cache in data['cachesAfterPurge']:
        assert cache['bytes'] == 0 and cache['count'] == 0, (path, cache)
    phases = {v['name']: v for v in data['phases']}
    m = dict(coldReadyMs=phases['cold-open']['viewportReadyMs'],
             warmReadyMs=phases['warm-return']['viewportReadyMs'],
             scrollP95Ms=phases['short-scroll']['submissionP95Ms'],
             cpuSeconds=data['cpuSeconds'], rssMiB=data['rssPeakSampled']/2**20,
             cacheMiB=data['cachePeakSampledBytes']/2**20, diskMiB=data['diskCacheBytes']/2**20,
             hoverMs=statistics.median(phases['hover-click']['hoverCallbackMs']),
             clickMs=statistics.median(phases['hover-click']['clickCallbackMs']),
             bodies=data['cardBodies'], frames=data['frames'])
    key = (data['mode'], data['corpus']['items'], data['variant'])
    groups.setdefault(key, []).append(m)
summary = []
for (mode, count, variant), rows in sorted(groups.items()):
    summary.append(dict(mode=mode, count=count, variant=variant, repeats=len(rows),
                        metrics={k: dict(median=statistics.median(r[k] for r in rows),
                                         min=min(r[k] for r in rows), max=max(r[k] for r in rows)) for k in rows[0]}))
(a.directory/'summary.json').write_text(json.dumps(summary, indent=2))
(a.directory/'excluded.json').write_text(json.dumps(excluded, indent=2))
lines = ['# Optimized Workshop workflow comparison', '',
         'Run-level medians. Scroll p95 is CPU submission time, not presented-frame time. Hover includes the product debounce. CPU is core-seconds for the whole workflow. Cache is accounted image cost, separate from process RSS. Cold means fresh process and harness byte cache; OS filesystem cache is uncontrolled.', '',
         '| Page | N | Variant | Repeats | Cold ready ms | Warm ready ms | Scroll p95 ms | CPU s | RSS MiB | Image cache MiB | Disk MiB | Hover ms | Click ms |',
         '|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
for row in summary:
    keys = ['coldReadyMs', 'warmReadyMs', 'scrollP95Ms', 'cpuSeconds', 'rssMiB', 'cacheMiB', 'diskMiB', 'hoverMs', 'clickMs']
    lines.append(f'| {row["mode"]} | {row["count"]} | {row["variant"]} | {row["repeats"]} | ' + ' | '.join(f'{row["metrics"][k]["median"]:.2f}' for k in keys) + ' |')
(a.directory/'summary.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines))
