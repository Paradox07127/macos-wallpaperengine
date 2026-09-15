from pathlib import Path
from collections import defaultdict
from statistics import median
import json

base = Path(__file__).resolve().parents[2] / '.notes/evidence/ui/2026-09-15-appkit-experiment'
folder = base / 'state-sequence'
groups = defaultdict(list)
runs = []
for path in sorted(folder.glob('scene-*.json')):
    data = json.loads(path.read_text())
    phases = data['statePhases']
    initial, restored = phases[0], phases[-1]
    assert initial['displayedPropertyKeys'] == restored['displayedPropertyKeys'], path
    assert initial['valuesDescription'] == restored['valuesDescription'], path
    assert initial['expandedSections'] == restored['expandedSections'], path
    assert all(len(p['samples']) == 100 for p in phases), path
    assert all(all(key in p['previousDisplayedPropertyKeys'] for key in p['changedKeys']) for p in phases), path
    assert all(p['thermalStart'] == p['thermalEnd'] == 0 for p in phases), path
    runs.append({'file': path.name, 'scene': data['data']['scene'], 'variant': data['variant'],
                 'phases': len(phases), 'samples': sum(len(p['samples']) for p in phases),
                 'restorationExact': True})
    for phase in phases:
        groups[(data['data']['scene'], phase['phase'], data['variant'])].append(phase)

summary = []
for (scene, phase, variant), values in groups.items():
    counts = {len(v['displayedPropertyKeys']) for v in values}
    assert len(counts) == 1
    p95 = [v['layoutDisplayMs']['p95'] for v in values]
    summary.append({'scene': scene, 'phase': phase, 'variant': variant, 'repeats': len(values),
                    'properties': counts.pop(), 'sliders': values[0]['controlTypes'].get('slider', 0),
                    'changedKeys': values[0]['changedKeys'], 'p95MedianMs': median(p95),
                    'p95MinMs': min(p95), 'p95MaxMs': max(p95),
                    'p99MedianMs': median(v['layoutDisplayMs']['p99'] for v in values),
                    'rssPeakMedianMiB': median(v['rssPeakSampled'] for v in values) / 1048576})
(base / 'state-summary.json').write_text(json.dumps({'runs': runs, 'groups': summary}, indent=2))
lines = ['# 同一窗口内的交互状态补测', '',
         f'{len(runs)} runs; {sum(r["samples"] for r in runs)} synchronous layout/display samples.', '',
         '每一格为三轮各自 p95 的中位数；括号为三轮范围，单位 ms。不是实际帧时间或 hitch。', '',
         '两份真实壁纸 × current / continuous / native × 三轮。每轮固定 8 阶段，每阶段 100 次从顶到底的位置驱动滚动；阶段间等待 250 ms。', '',
         '开关/下拉项按默认值下条件显示变化最多的可见候选选择，具体 key 和值保存在 JSON；滑杆取首个可见滑杆修改到范围端点。此顺序是有意的压力序列，并非全部使用路径。', '',
         '变更经 ProbeModel 绑定、真实 schema/presentation 执行；不含生产 Editor、持久化、patch 或 session 重建。transitionSubmissionMs 不含后续 run-loop 更新，不可当完整交互延迟。', '',
         'displayedPropertyKeys 表示展开后列表包含的属性，不是屏幕视口同时可见的控件。positions/documentHeights 保留位置；没有逐帧控件与屏幕坐标的对应表。', '',
         '每阶段遍历完整文档。条件/折叠改变文档高度时，步幅与遇到的控件也变，不能把阶段差异单独归因于控件数。每个候选之间的相同阶段更可比。', '']
for scene in sorted({row['scene'] for row in summary}):
    lines += [f'## {scene}', '', '| 阶段 | 属性/滑杆 | current | continuous | native |', '|---|---:|---:|---:|---:|']
    names = list(dict.fromkeys(row['phase'] for row in summary if row['scene'] == scene))
    for phase in names:
        variants = {row['variant']: row for row in summary if row['scene'] == scene and row['phase'] == phase}
        first = next(iter(variants.values()))
        values = [f'{first["properties"]}/{first["sliders"]}']
        for variant in ['current', 'continuous', 'native']:
            row = variants.get(variant)
            values.append('pending' if row is None else f'{row["p95MedianMs"]:.2f} ({row["p95MinMs"]:.2f}–{row["p95MaxMs"]:.2f})')
        lines.append('| ' + phase + ' | ' + ' | '.join(values) + ' |')
    lines.append('')
lines += ['## 校验与边界', '',
          '- 每轮恢复后的属性 key、值、展开分组与初始完全一致；逐阶段实际热状态为 nominal。',
          '- 3351072238 是单个未分组列表；生产 rows 规则忽略折叠集合，因此 collapsed 阶段是无效变更对照，不能声称完成了折叠。',
          '- 3509243656 有分组，collapsed 阶段只有分组标题；这是不同内容和不同文档长度，不是等负载性能胜利。',
          '- 原始 samples、位置、文档高度、控件类型、条件可见 key、值、展开分组、温度和命令/二进制哈希均在 state-sequence/。',
          '- 固定阶段顺序与每阶段一次遍历不能覆盖焦点、鼠标悬停、快速交错输入、滚动惯性、键盘、VoiceOver 或真实渲染提交。', '']
(base / 'state-summary.md').write_text('\n'.join(lines))
print(f'{len(runs)} runs / {sum(r["samples"] for r in runs)} samples / {len(summary)} groups')
