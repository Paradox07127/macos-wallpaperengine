from pathlib import Path
import subprocess,json,time,hashlib,argparse
root=Path(__file__).resolve().parents[2]; base=root/'.notes/evidence/ui/2026-09-15-appkit-experiment';binary=base/'UIArchitectureProbe.app/Contents/MacOS/UIArchitectureProbe'
p=argparse.ArgumentParser();p.add_argument('--suite',choices=['scene','grid','installed','interactions','state-sequence','smoke'],default='scene');p.add_argument('--steps',default='300');p.add_argument('--repeats',type=int,default=3);args=p.parse_args()
out=base/args.suite;out.mkdir(exist_ok=True)
sha=hashlib.sha256(binary.read_bytes()).hexdigest()
cases=[]
if args.suite=='scene':
 for scene in ['3351072238','3369989878','3509243656']:
  for v in ['current','100','200','500','1000','continuous','native']:cases.append(['--mode','scene','--scene',scene,'--variant',v])
elif args.suite in ['grid','installed']:
 for n in ['30','50','0','500','2000']:
  for v in ['current','collection']:cases.append(['--mode',args.suite,'--count',n,'--variant',v])
elif args.suite=='state-sequence':
 for scene in ['3351072238','3509243656']:
  for v in ['current','continuous','native']:cases.append(['--mode','scene','--scene',scene,'--variant',v,'--operation','state-sequence'])
elif args.suite=='interactions':
 for mode,vs,ops in [('grid',['current','collection'],['select','filter','resize']),('scene',['current','continuous','native'],['edit','collapse','resize'])]:
  for v in vs:
   for op in ops:cases.append(['--mode',mode,'--variant',v,'--operation',op])
else:
 for lang in ['en','zh-Hans','zh-Hant','ja','es']:
  for v in ['current','continuous','native']:cases.append(['--mode','scene','--variant',v,'--language',lang,'--reduce-motion','true','--reduce-transparency','true'])
manifest=[]
if args.suite == 'grid':
 prime=out/'prewarm';prime.mkdir(exist_ok=True)
 with (prime/'warm.log').open('w') as f:
  subprocess.run([str(binary),'--mode','grid','--variant','current','--count','0','--steps','300','--cache',str(out/'cache'),'--output',str(prime/'warm.json')],stdout=f,stderr=subprocess.STDOUT,timeout=180,check=True)

for rep in range(args.repeats):
 for index,c in enumerate(cases if rep%2==0 else list(reversed(cases))):
  label='-'.join(c[1::2])+f'-r{rep+1}';path=out/(label+'.json')
  cmd=[str(binary),*c,'--steps',args.steps,'--cache',str(out/'cache'),'--output',str(path)]
  log=out/(label+'.log');start=time.time()
  with log.open('w') as f:
   proc=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=600)
  entry={'command':cmd,'binarySHA256':sha,'exitCode':proc.returncode,'seconds':time.time()-start,'output':str(path)};manifest.append(entry)
  (out/'manifest.json').write_text(json.dumps(manifest,indent=2))
  if proc.returncode:raise SystemExit(f'FAILED {label}; {log}')
  d=json.loads(path.read_text());print(label,d['layoutDisplayMs'],'thermal',d['thermalStart'],d['thermalEnd'],flush=True)
