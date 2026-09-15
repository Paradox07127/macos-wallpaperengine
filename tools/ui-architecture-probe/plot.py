from pathlib import Path
import json
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
r=Path(__file__).resolve().parents[2];o=r/'.notes/evidence/ui/2026-09-15-appkit-experiment'
rows={x['case']:x for x in json.loads((o/'summary.json').read_text())}
fig,axes=plt.subplots(3,3,figsize=(15,11),constrained_layout=True)
colors={'current':'#2765aa','continuous':'#21856a','native':'#ca733b','collection':'#ca733b'}
for ax,scene in zip(axes[0],['3351072238','3369989878','3509243656']):
 budgets=[100,200,500,1000];ys=[rows[f'scene-{scene}-{b}']['p95']['median'] for b in budgets]
 ax.plot(budgets,ys,'o-',label='Stepped SwiftUI',color=colors['current'])
 for v in ['continuous','native']:
  ax.axhline(rows[f'scene-{scene}-{v}']['p95']['median'],label=v.capitalize(),color=colors[v],linestyle='--')
 ax.set_xscale('log');ax.set_xticks(budgets,[str(x) for x in budgets]);ax.set_title(f'Scene {scene}');ax.set_xlabel('Display stop budget');ax.set_ylabel('Layout/display p95 (ms)');ax.legend(fontsize=8)
for line,suite in enumerate(['grid','installed'],start=1):
 for ax,metric,title in zip(axes[line],['p95','rssPeakMiB','cpuSeconds'],['Layout/display p95 (ms)','Sampled peak RSS (MiB)','Process CPU time (s)']):
  for v in ['current','collection']:
   counts=[30,50,0,500,2000];ks=[f'{suite}-{n}-{v}' for n in counts]
   if not all(k in rows for k in ks):continue
   xx=[30,50,67,500,2000];yy=[rows[k][metric]['median'] for k in ks]
   low=[rows[k][metric]['min'] for k in ks];high=[rows[k][metric]['max'] for k in ks]
   ax.errorbar(xx,yy,yerr=[[y-l for y,l in zip(yy,low)],[h-y for y,h in zip(yy,high)]],marker='o',capsize=3,label='LazyVGrid' if v=='current' else 'NSCollectionView',color=colors[v])
  ax.set_xscale('log');ax.set_xticks([30,50,67,500,2000],['30','50','67','500','2000']);ax.tick_params(axis='x',labelsize=8)
  ax.set_title(('BrowseCard' if suite=='grid' else 'HistoryRow')+' — '+title);ax.set_xlabel('Items (500/2000 cycle real records)');ax.set_ylabel(title);ax.legend(fontsize=8)
for ax in axes.flat:ax.grid(alpha=.22);ax.spines[['top','right']].set_visible(False)
fig.suptitle('Loomscreen UI component experiments | median and observed range, 3 runs\nCPU-side submission only; normalized full-list traversal; no GPU-frame claim',fontsize=14)
fig.savefig(o/'comparison.png',dpi=150)
print(o/'comparison.png')
