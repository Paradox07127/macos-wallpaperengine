"""Summarize independent real-wheel captures using raw trace timestamps."""
from pathlib import Path
import argparse
import json
import statistics

p = argparse.ArgumentParser()
p.add_argument('base', type=Path)
a = p.parse_args()
rows = []
excluded = []
for directory in sorted((a.base / 'traces').glob('wheel-r*')):
    if not (directory / 'trace.json').exists():
        continue
    metadata = json.loads((directory / 'trace.json').read_text())
    if not metadata.get('complete'):
        excluded.append({'run': directory.name, 'reason': metadata.get('reason')})
        continue
    probe = json.loads((directory / 'probe.json').read_text())
    raw = json.loads((directory / 'raw-rows.json').read_text())
    phases = raw['OSSignpostIntervals']
    assert len(phases) == 18
    for case in probe['cases']:
        assert not case['errors'] and case['thermalEnd'] == 0
        events = case['wheelInputEvents']
        assert len(events) == 121
        starts = [event[0] for event in events]
        gaps = sorted((right - left) * 1000 for left, right in zip(starts, starts[1:]))
        phase = next(row for row in phases if row['start-message']['fmt'] == case['label'] + ':short-scroll')
        start = int(phase['start']['raw'])
        end = start + int(phase['duration']['raw'])
        hitches = [row for row in raw['hitches'] if start <= int(row['start']['raw']) < end]
        hangs = [row for row in raw['potential-hangs']
                 if int(row['start']['raw']) < end
                 and int(row['start']['raw']) + int(row['duration']['raw']) > start]
        rows.append(dict(run=directory.name, label=case['label'],
                         inputSpanMs=(starts[-1] - starts[0]) * 1000,
                         inputGapP95Ms=gaps[int(0.95 * (len(gaps) - 1))],
                         inputGapMaxMs=max(gaps),
                         travel=max(point[1] for point in case['wheelPositions']),
                         finalY=case['wheelPositions'][-1][1],
                         hitches=len(hitches),
                         hitchDurationMs=sum(int(row['duration']['raw']) for row in hitches) / 1e6,
                         potentialHangsOverlapping=len(hangs)))
summary = []
for label in sorted({row['label'] for row in rows}):
    group = [row for row in rows if row['label'] == label]
    summary.append(dict(label=label, runs=len(group),
                        hitchCounts=[row['hitches'] for row in group],
                        hitchMedian=statistics.median(row['hitches'] for row in group),
                        hitchDurationMedianMs=statistics.median(row['hitchDurationMs'] for row in group),
                        potentialHangCounts=[row['potentialHangsOverlapping'] for row in group]))
result = dict(runs=rows, summary=summary, excluded=excluded,
              scope='100 cards, preheat off, encoded bytes primed, real synthetic continuous wheel; scroll interval attribution by hitch start, hang attribution by overlap')
(a.base / 'wheel-summary.json').write_text(json.dumps(result, indent=2))
print(json.dumps(summary, indent=2))
