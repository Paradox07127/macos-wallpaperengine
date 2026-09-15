from pathlib import Path
import subprocess,json,hashlib,statistics,argparse
root=Path(__file__).resolve().parents[2]; out=root/'.notes/evidence/ui/2026-09-15-hover-isolation'
p=argparse.ArgumentParser();p.add_argument('--repeats',type=int,default=3);args=p.parse_args();manifest=[]
for rep in range(args.repeats):
 cases=[(mode,variant,playback) for mode in ['online','installed'] for variant,playback in [('baseline','true'),('baseline','false'),('title-fixed','true'),('chrome-fixed','true')]]
 if rep%2:cases.reverse()
 for mode,variant,playback in cases:
  name=f'{mode}-{variant}-{playback}-r{rep+1}';binary=out/variant/'HoverProbe.app/Contents/MacOS/HoverProbe'
  cmd=[str(binary),'--mode',mode,'--playback',playback,'--output',str(out/(name+'.json'))]
  with (out/(name+'.log')).open('w') as log:r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=60)
  manifest.append({'command':cmd,'exitCode':r.returncode,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest()})
  (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
  if r.returncode:raise SystemExit(r.returncode)
  data=json.loads((out/(name+'.json')).read_text())
  if data['hoverTransitions']!=18 or (playback=='true' and not data['frames']) or (playback=='false' and data['frames']):raise SystemExit('Invalid control: '+name)
  samples=sorted(data['samples']);print(name,'p95',round(samples[int(len(samples)*.95)],3),'CPU',round(data['cpuSeconds'],3),'frames',data['frames'],'thermal',data['thermalStart'],data['thermalEnd'],flush=True)
