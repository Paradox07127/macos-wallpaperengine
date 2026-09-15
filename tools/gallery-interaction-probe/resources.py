from pathlib import Path
import re,json,statistics
base=Path('.notes/evidence/ui/2026-09-15-gallery-completion')
rows=[]
for variant in ['baseline-v2','final-v2']:
 for p in (base/(variant+'-runs')).glob('*-r*.log'):
  s=p.read_text();rss=re.search(r'(\d+)\s+maximum resident set size',s);foot=re.search(r'(\d+)\s+peak memory footprint',s)
  if rss:rows.append({'variant':variant,'mode':p.stem.rsplit('-r',1)[0],'file':str(p),'rssBytes':int(rss[1]),'footprintBytes':int(foot[1]) if foot else None})
summary=[]
for mode in sorted({r['mode'] for r in rows}):
 row={'mode':mode}
 for variant in ['baseline-v2','final-v2']:
  a=[r['rssBytes']/1048576 for r in rows if r['mode']==mode and r['variant']==variant]
  row[variant]={'runs':len(a),'medianRSSMiB':statistics.median(a),'min':min(a),'max':max(a)} if a else None
 summary.append(row)
(base/'resources-v2.json').write_text(json.dumps({'rows':rows,'summary':summary},indent=2))
for r in summary:print(r)
