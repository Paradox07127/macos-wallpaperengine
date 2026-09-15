from pathlib import Path
import json,statistics,sys
root=Path(__file__).resolve().parents[2];base=root/'.notes/evidence/ui/2026-09-15-appkit-experiment'
rows=[]
for suite in ['scene','grid','installed','interactions','smoke']:
 d=base/suite
 if not d.exists():continue
 groups={}
 for p in d.glob('*.json'):
  if p.name=='manifest.json':continue
  x=json.loads(p.read_text());key=p.stem.rsplit('-r',1)[0];groups.setdefault(key,[]).append(x)
 for key,xs in sorted(groups.items()):
  def metric(f):
   a=[f(x) for x in xs];return {'median':statistics.median(a),'min':min(a),'max':max(a)}
  rows.append({'suite':suite,'case':key,'repeats':len(xs),'samples':sum(x['sampleCount'] for x in xs),'p50':metric(lambda x:x['layoutDisplayMs']['p50']),'p95':metric(lambda x:x['layoutDisplayMs']['p95']),'p99':metric(lambda x:x['layoutDisplayMs']['p99']),'cpuSeconds':metric(lambda x:x['cpuSeconds']),'rssPeakMiB':metric(lambda x:x['rssPeakSampled']/1048576),'rssAfterPurgeMiB':metric(lambda x:x['rssAfterClosePurge']/1048576),'firstLayoutMs':metric(lambda x:x['firstLayoutMs']),'thermalStates':sorted(set((x['thermalStart'],x['thermalEnd']) for x in xs)),'data':xs[0]['data']})
(base/'summary.json').write_text(json.dumps(rows,indent=2))
lines=['# Repeated component measurements','','Median of run-level metrics; brackets show min–max across runs. CPU-side layout/display submission, not GPU frame time or hitch count. No pooling of frames across repetitions.','','| Case | Runs / samples | p50 ms | p95 ms [range] | p99 ms | CPU s | RSS peak MiB |','|---|---:|---:|---:|---:|---:|---:|']
for r in rows:
 lines.append(f"| {r['case']} | {r['repeats']} / {r['samples']} | {r['p50']['median']:.2f} | {r['p95']['median']:.2f} [{r['p95']['min']:.2f}–{r['p95']['max']:.2f}] | {r['p99']['median']:.2f} | {r['cpuSeconds']['median']:.2f} | {r['rssPeakMiB']['median']:.1f} |")
(base/'summary.md').write_text('\n'.join(lines)+'\n');print(f'{len(rows)} cases summarized')
