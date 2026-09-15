import argparse,os,json,subprocess,hashlib,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('variant');p.add_argument('--repeats',type=int,default=3);p.add_argument('--steps',type=int,default=60);p.add_argument('--fixtures',default='/private/tmp/lw-gallery-fixtures');p.add_argument('--tag',default='');args=p.parse_args()
base=Path('.notes/evidence/ui/2026-09-15-gallery-completion');binary=(base/args.variant/'GalleryProbe.app/Contents/MacOS/GalleryProbe').resolve();out=base/(args.variant+args.tag+'-runs');out.mkdir(exist_ok=True)
env=dict(os.environ,GALLERY_FIXTURES=args.fixtures);runs=[]
for repeat in range(1,args.repeats+1):
 modes=['bookmarks','schemes','aerials','candidates','system','mixed']
 if repeat%2==0:modes.reverse()
 for mode in modes:
  dest=out/f'{mode}-r{repeat}.json';cmd=['/usr/bin/time','-l',str(binary),'--mode',mode,'--steps',str(args.steps),'--output',str(dest)]
  with dest.with_suffix('.log').open('w') as f:r=subprocess.run(cmd,env=env,stdout=f,stderr=f,timeout=180)
  runs.append({'mode':mode,'repeat':repeat,'exit':r.returncode,'output':str(dest),'command':cmd,'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()})
  (out/'manifest.json').write_text(json.dumps(runs,indent=2));print(mode,repeat,r.returncode,flush=True)
  if r.returncode:raise SystemExit(r.returncode)
