from pathlib import Path
import json,statistics,math,sys,re
base=Path('.notes/evidence/ui/2026-09-15-gallery-completion')
def p95(a):return sorted(a)[max(0,math.ceil(len(a)*.95)-1)]
variants = ['baseline-v2', 'final-v2'] if '--v2' in sys.argv else ['baseline', 'candidate']
results={}
for variant in variants:
 rows=[]
 for path in sorted((base/(variant+'-runs')).glob('*-r*.json')):
  j=json.loads(path.read_text())
  for phase in j['phases']:
   rows.append({'file':str(path),'mode':j['mode'],'phase':phase['phase'],'thermalStart':j['thermalStart'],'thermalEnd':j['thermalEnd'],'submissionP95Ms':p95(phase['submissionMs']),'gapP95Ms':p95(phase['mainActorGapMs'][1:]),'gapMaxMs':max(phase['mainActorGapMs'][1:])})
 results[variant]=rows
out=[]
for key in sorted({(r['mode'],r['phase']) for r in results[variants[0]]}):
 row={'mode':key[0],'phase':key[1]}
 for variant,rows in results.items():
  group=[r for r in rows if (r['mode'],r['phase'])==key]
  row[variant]={'runs':len(group),'thermal':sorted(set((r['thermalStart'],r['thermalEnd']) for r in group))}
  for measure in ['submissionP95Ms','gapP95Ms','gapMaxMs']:
   a=[r[measure] for r in group]
   row[variant][measure]={'median':statistics.median(a),'min':min(a),'max':max(a)} if a else None
 out.append(row)
(base/('comparison-v2.json' if '--v2' in sys.argv else 'comparison.json')).write_text(json.dumps({'rows':out,'raw':results},indent=2))
for r in out:
 if r['phase'] in ['scroll','filtered-scroll','warm-scroll']:
  a=r[variants[0]]['gapP95Ms'];b=r[variants[1]]['gapP95Ms'];print(r['mode'],r['phase'],round(a['median'],1),round(b['median'],1) if b else None)
