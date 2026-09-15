from pathlib import Path
import json
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

base = Path(__file__).resolve().parents[2] / '.notes/evidence/ui/2026-09-15-appkit-experiment'
data = json.loads((base / 'state-summary.json').read_text())
phases = ['initial-scroll', 'repeat-scroll', 'collapsed-scroll', 'reexpanded-scroll',
          'after-bool-scroll', 'after-combo-scroll', 'after-slider-scroll', 'restored-scroll']
labels = ['Initial', 'Repeat', 'Collapse', 'Expand', 'Bool', 'Combo', 'Slider', 'Restore']
fig, axes = plt.subplots(1, 2, figsize=(13, 5.4), sharey=True)
colors = {'current': '#bd4435', 'continuous': '#2676a8', 'native': '#218769'}
for ax, scene in zip(axes, ['3351072238', '3509243656']):
    for variant in colors:
        rows = {r['phase']: r for r in data['groups'] if r['scene'] == scene and r['variant'] == variant}
        assert all(rows[p]['repeats'] == 3 for p in phases)
        y = [rows[p]['p95MedianMs'] for p in phases]
        low = [rows[p]['p95MinMs'] for p in phases]
        high = [rows[p]['p95MaxMs'] for p in phases]
        ax.plot(range(8), y, marker='o', label=variant, color=colors[variant], linewidth=2)
        ax.fill_between(range(8), low, high, color=colors[variant], alpha=0.13)
    ax.set_xticks(range(8), labels, rotation=35)
    ax.set_yscale('log')
    ax.grid(axis='y', alpha=0.25, which='both')
    ax.set_title(scene + (' | ungrouped, collapse is a no-op' if scene == '3351072238' else ' | 19 groups, collapse hides controls'), fontsize=11)
    ax.set_xlabel('Sequential phases in the SAME window')
axes[0].set_ylabel('p95 synchronous layout/display submission (ms, log scale)')
axes[0].legend(frameon=False)
fig.suptitle('Interaction state matters; compare candidates within the same phase', fontsize=14, fontweight='bold')
fig.text(0.5, 0.025, 'Median of 3 run-level p95 values; shading = range. 100 scroll positions per phase.\nDifferent content/height changes scroll stride. No real input events or render-session commits; these are not frame times.', ha='center', fontsize=9)
fig.tight_layout(rect=(0, 0.09, 1, 0.93))
fig.savefig(base / 'state-comparison.png', dpi=160)
print(base / 'state-comparison.png')
