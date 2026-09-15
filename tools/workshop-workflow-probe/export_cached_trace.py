"""Read exact timestamps from the Instruments MCP's already-ingested SQLite cache.

Run native describe/query first. This does not ingest or modify a trace. Every
exported row is cross-checked against its native query row/table index; a changed
cache schema fails loudly rather than silently assigning an empty measurement.
"""
from pathlib import Path
import argparse
import json
import sqlite3

p = argparse.ArgumentParser()
p.add_argument('directory', type=Path)
a = p.parse_args()
metadata = json.loads((a.directory / 'trace.json').read_text())
stop = json.loads((a.directory / 'stop.json').read_text())
queries = json.loads((a.directory / 'queries.json').read_text())
db = Path(stop['tracePath']).with_suffix('.db')
connection = sqlite3.connect(db.as_uri() + '?mode=ro', uri=True)
connection.row_factory = sqlite3.Row
result = {}
for schema, query in queries.items():
    data = query['data']
    assert not data['hasMore'], schema
    suffix = f"[{metadata['signpostPosition']}]" if schema == 'OSSignpostIntervals' else ''
    table = f"1:{schema}{suffix}"
    exported = []
    for expected in data['rows']:
        if schema != 'device-thermal-state-intervals' and expected['cells'].get('process') != f"WorkflowProbe ({metadata['pid']})":
            continue
        row = connection.execute(f'SELECT * FROM "{table}" WHERE _row_idx=?',
                                 (expected['tableIndex'],)).fetchone()
        assert row is not None
        cells = {}
        for key in ['start', 'duration', 'start-message', 'thermal-state', 'hang-type']:
            if key not in expected['cells']:
                continue
            assert row[key + '__fmt'] == expected['cells'][key], (schema, key)
            cells[key] = {'raw': row[key], 'fmt': row[key + '__fmt']}
        exported.append(cells)
    result[schema] = exported
connection.close()
(a.directory / 'raw-rows.json').write_text(json.dumps(result, indent=2))
print({schema: len(rows) for schema, rows in result.items()})
