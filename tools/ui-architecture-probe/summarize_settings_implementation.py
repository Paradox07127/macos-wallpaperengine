from collections import defaultdict
from pathlib import Path
from statistics import median
import json

base = Path(__file__).resolve().parents[2] / '.notes/evidence/ui/2026-09-15-settings-implementation'
groups = defaultdict(list)
runs = []
for path in sorted((base / 'state-runs').glob('*.json')):
    if path.name == 'manifest.json':
        continue
    run = json.loads(path.read_text())
    runs.append(run)
    for phase in run['statePhases']:
        groups[(run['data']['scene'], phase['phase'], run['variant'])].append(phase)
assert len(runs) == 12
rows = []
lines = ['# 最终生产控件复测', '', '12 次运行，96 个阶段，9600 次同步 layout/display 采样。', '',
         '每格为三轮各自 p95 的中位数（ms）；不是实际帧耗时。两种候选使用同一个二进制，逐轮反转运行顺序。', '',
         '| 场景 | 阶段 | 属性/滑杆 | 旧离散轨道 | 生产连续轨道 |', '|---|---|---:|---:|---:|']
phases = [p['phase'] for p in runs[0]['statePhases']]
for scene in ['3351072238', '3509243656']:
    for phase in phases:
        entry = {'scene': scene, 'phase': phase}
        for variant in ['current', 'quantized']:
            items = groups[(scene, phase, variant)]
            assert len(items) == 3
            assert all(p['thermalStart'] == p['thermalEnd'] == 0 for p in items)
            p95 = [p['layoutDisplayMs']['p95'] for p in items]
            entry[variant] = {'p95MedianMs': median(p95), 'p95RangeMs': [min(p95), max(p95)],
                              'p99MedianMs': median(p['layoutDisplayMs']['p99'] for p in items),
                              'rssPeakMedianMiB': median(p['rssPeakSampled'] for p in items) / 1048576}
        assert groups[(scene, phase, 'current')][0]['displayedPropertyKeys'] == groups[(scene, phase, 'quantized')][0]['displayedPropertyKeys']
        p = groups[(scene, phase, 'current')][0]
        lines.append(f'| {scene} | {phase} | {len(p["displayedPropertyKeys"])}/{p["controlTypes"].get("slider", 0)} | {entry["current"]["p95MedianMs"]:.2f} | {entry["quantized"]["p95MedianMs"]:.2f} |')
        rows.append(entry)
lines += ['', '同一阶段中两方案的属性 key 一致。每轮恢复后的值和显示属性与初始一致；全部阶段热状态为 nominal。', '',
          '3351072238 未分组，collapse 是无效变更对照；3509243656 折叠后只剩标题。不同阶段的文档高度/滚动步幅不一样，不能把所有状态混为同等负载。', '',
          '比较使用生产 QuantizedSlider，但列表仍是隔离 harness；不包括真实输入到屏幕的延迟、完整 Editor、网页执行和渲染 patch/session。原始值、分组、位置、样本、命令及二进制哈希保存在 state-runs/。', '']
(base / 'performance.json').write_text(json.dumps(rows, indent=2))
(base / 'performance.md').write_text('\n'.join(lines))
print('Validated 12 runs / 48 groups / 9600 samples')
