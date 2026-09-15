from pathlib import Path
import subprocess,json,statistics,hashlib
root=Path.cwd();base=root/'.notes/evidence/ui/2026-09-15-remaining-interactions';runs=base/'runs';runs.mkdir(exist_ok=True)
exe=base/'probe/InteractionProbe.app/Contents/MacOS/InteractionProbe'
for scene in ['3351072238','3509243656']:
 for repeat in range(3):
  for variant in (['swiftui','native'] if repeat%2==0 else ['native','swiftui']):
   name=f'{scene}-{repeat}-{variant}';out=runs/(name+'.json')
   cmd=[str(exe),'--variant',variant,'--steps','40','--project',f'/Users/taijial/Library/Application Support/Steam/steamapps/workshop/content/431960/{scene}/project.json','--output',str(out)]
   with (runs/(name+'.log')).open('w') as log:r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT)
   if r.returncode:raise RuntimeError((name,r.returncode))
   d=json.loads(out.read_text());failed=[c for c in d['checks'] if not c['passed']]
   if failed:raise RuntimeError((name,failed))
   print(name,'all checks passed','thermal',d['thermalBefore'],d['thermalAfter'],flush=True)
rows=[]
def p95(v):return sorted(v)[int((len(v)-1)*.95)]
for scene in ['3351072238','3509243656']:
 for phase in ['initial','changed-option','collapsed-groups','reopened','drag-close']:
  row={'scene':scene,'phase':phase}
  for v in ['swiftui','native']:
   selected=[json.loads(p.read_text()) for p in runs.glob(f'{scene}-*-{v}.json')]
   records=[next(x for x in d['phases'] if x['phase']==phase) for d in selected]
   row[v]={k:{'median':statistics.median(vals),'min':min(vals),'max':max(vals)} for k in ['submissionMs','mainActorGapMs'] for vals in [[p95(r[k]) for r in records]]}
  rows.append(row)
(base/'comparison.json').write_text(json.dumps({'binarySha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'rows':rows,'boundary':'Posted mouse events plus 16 ms sleep; synchronous submission and main actor gap, not display frame time or physical input latency.'},indent=2)+'\n')
print('Matrix complete',flush=True)
