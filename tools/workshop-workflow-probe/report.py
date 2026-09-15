"""Write the measured component comparison; keep display validation separate."""
from pathlib import Path
import argparse, json

p = argparse.ArgumentParser()
p.add_argument('base', type=Path)
a = p.parse_args()
base = a.base.resolve()
normal = json.loads((base/'matrix-stable/summary.json').read_text())
off = json.loads((base/'preheat-off/summary.json').read_text())
names = {'lazy': 'LazyVGrid', 'windowed': 'SwiftUI 预布局＋可见范围控制', 'collection': 'NSCollectionView＋NSHostingView'}
wheel_path = base / 'wheel-summary.json'
wheel = json.loads(wheel_path.read_text()) if wheel_path.exists() else None
wheel_complete = wheel and len(wheel['summary']) == 6 and all(row['runs'] == 3 for row in wheel['summary'])
if wheel_complete:
    wheel_lines = ['| 页面与实现 | 三轮滚动停顿次数 | 停顿总时长中位数 ms | 重叠的潜在挂起标记数 |',
                   '|---|---|---:|---|']
    for row in wheel['summary']:
        wheel_lines.append(f"| {row['label']} | {row['hitchCounts']} | {row['hitchDurationMedianMs']:.2f} | {row['potentialHangCounts']} |")
    wheel_section = '''真实滚轮版本完成三次独立 Animation Hitches 录制（轮换 0／1／2），每次覆盖两页、三种容器、完整的 18 个阶段。百张、关闭预热；Online 字节已预先准备，解码缓存每组清理。这与无录制的 CPU／RSS 矩阵条件不同，统计分开。

后台生产者以 60 Hz 发送连续像素滚轮事件，鼠标停在卡片上。每组实际发送 121 次，约 2 秒完成 1000 点向下与返回；再保留约 0.4 秒观察尾部。所有行为检查通过、录制热状态为 Nominal。以下按停顿的开始时间归入滚动阶段；它不是整个录制的总数，也不是每张卡片的 FPS。

''' + '\n'.join(wheel_lines) + '''

潜在挂起标记作为独立 UI 诊断保留；不能把它们自动当作录制损坏，也不能用稀疏 CPU 采样否认它们。显示停顿和主线程响应诊断反映不同现象，不能合并为一个评分。完整逐轮输入节拍、位置与计数见 `wheel-summary.json`，协议与局限见 `wheel-validation.md`。

单次滚动很短，每条件只有三次；细小的计数差异不支持稳定优胜或统计显著性的结论。可以明确排除“同步提交快约六成，实际停顿就一定同比减少”的推断。真实 App 的完整详情、下载、触控板惯性与壁纸运行竞争尚未纳入，当前结果不代表整应用验收。'''
else:
    wheel_section = '真实滚轮显示对照尚未完成三个独立重复，不能据此排名。状态见 `wheel-validation.md`。'

def table(rows):
    lines = ['| 页面 | 数量 | 实现 | 首屏预览就绪 ms | 热返回 ms | 滚动提交 p95 ms | CPU 核秒 | RSS MiB | 图片缓存 MiB |',
             '|---|---:|---|---:|---:|---:|---:|---:|---:|']
    for r in rows:
        values = [r['metrics'][k]['median'] for k in ['coldReadyMs', 'warmReadyMs', 'scrollP95Ms', 'cpuSeconds', 'rssMiB', 'cacheMiB']]
        lines.append(f'| {r["mode"]} | {r["count"]} | {names[r["variant"]]} | ' + ' | '.join(f'{v:.2f}' for v in values) + ' |')
    return '\n'.join(lines)

report = f'''# Workshop 框架与操作流程对照

## 结论与当前状态

三种候选实现和 72 次有效组件对照已完成：20／50／100 张、Online／Installed、每个条件三次；其中 18 次为百张场景关闭预热的对照。

- **最低占用与首屏准备：多数条件下 LazyVGrid 更合适。** 它通常使用较少 CPU、进程内存和图片缓存，首屏预览赋值与热返回也更早完成。20 张 Installed 是 CPU 的一个例外，原生方案略低。
- **同步提交尾部：优化后的 NSCollectionView 更低。** 在 50／100 张时，两页的程序滚动提交 p95 约减少 57–60%；同时 CPU 约增加 5–19%，进程 RSS 也增加。这一指标不包含最终显示完成，不能直接解释为更高帧率或整体更丝滑。
- **预布局＋窗口化没有形成综合优势。** 它避免了全量创建重卡片的内存代价，但 50／100 张时的提交尾部与占用通常仍高于 LazyVGrid。
- **真实滚轮没有证实原生容器更顺。** 百张 Installed 三轮滚动停顿为 LazyVGrid 6／9／4、原生 7／6／7、窗口化 9／16／12；Online 三者每轮为 0–3 次。原生方案与 LazyVGrid 的先后随轮次变化，不能据此宣称原生更流畅。窗口化 Installed 三轮均更差。
- **悬停主要受现有 150 ms 门槛影响。** 各方案的悬停回调中位数多在 165–176 ms，点击回调没有一致的全面赢家。两者均非输入到最终像素的延迟。

本轮代码位于独立的 `tools/workshop-workflow-probe/`。生产页面仍使用原有容器。当前证据支持保留 LazyVGrid 为生产基线，保留改进后的原生方案作接入候选；不依据提交 p95 单独决定迁移。

## 实现调整

共同部分采用固定条目 ID、按 ID 查询的模型、逐卡观察状态。选中只修改旧／新卡片；卡片尺寸使用当前 Core 的尺寸档位、边距和行距。图片、GIF 帧调度、悬停门槛与播放门控使用当前产品代码。可选预热只准备附近两行，复用已有有界缓存与解码器。

LazyVGrid 使用固定尺寸列与逐卡状态。提前创建方案改用平铺的 SwiftUI Layout，跨列数变化保留条目身份；只挂载可见区域及附近一行的完整卡片。原生方案使用 diffable 数据源，结构变化应用差异；选中不替换 hosting root，复用时清理旧卡片子树。全量 eager 方案作为控制参数保留，未作为最终候选。

轻量数据准备与资源调度是各容器共用的策略。实验没有把每次卡片状态改变都变成重新排序／查询整个库，也没有把原生容器的整页 reload 作为默认更新方式。

## 50 张：共同开启预热

以下均为三轮的逐轮指标中位数。完整范围见原始汇总 JSON。

{table([r for r in normal if r['count']==50])}

已安装 50 张的具体取舍：原生提交 p95 为 6.84 ms，LazyVGrid 为 16.84 ms；完整流程 CPU 为 1.64 对 1.56 核秒，RSS 约 259 对 224 MiB，图片缓存约 52.4 对 45.8 MiB。

## 100 张：关闭预热

这是另一组独立的三轮对照，不能与上表混合计算分位数。

{table(off)}

关闭预热后，LazyVGrid 的图片缓存从约 45.8 降至 36.7 MiB，提交 p95 的中位数约增加 1 ms。原生 Installed 的图片缓存从约 60.4 降至 55.6 MiB，CPU 与提交 p95 没有出现一致的恶化；Online 原生的图片缓存则略高，说明占用还取决于实际访问和回收顺序。预热应保持有界、可调整，并根据真实滚轮结果选择，不能把增加预读当作默认收益。

## 数据、流程与计量口径

- 机器为 Apple M5 Pro、18 核 CPU、64 GiB 内存；macOS 27.0（26A428）。实验屏幕为 1920×1080 逻辑点、2×缩放、60 Hz，减少动态效果与减少透明度均关闭。结论仅适用于该机器、系统和这批素材，不能外推为所有 macOS 版本的固定排名。
- 素材来自本机 Steam Workshop：67 份实际预览，其中 55 份 GIF。100 张通过不同卡片 ID 循环这些资源，不代表 100 份不同媒体。Online 的 100 张是压力条件；产品实际分页为 30／50。
- 三种容器使用相同卡片与素材。Online 网络边界替换为读取同一批本地字节；实际 Steam 网络、下载、应用壁纸、完整详情内容和多屏菜单未纳入。
- 正式矩阵每次新建进程与 Online 字节缓存目录；操作系统文件缓存没有清空。热返回在同一进程重建窗口并保留图片缓存。
- 流程包含首屏、96 步固定距离程序滚动、真实 CGEvent 悬停／点击、筛选恢复、620／900 点宽度切换、热返回和关闭清理。程序滚动每步之后等待 16 ms，因此它不是等速物理滚轮实验。
- 首屏就绪指前 12 个预览成功赋值，不是首个已呈现帧。滚动 p95 是同步更新、布局、显示提交与 flush 的时间。CPU 是整段流程的 user＋system 核秒，1 核秒相当于一个 CPU 核执行 1 秒。
- RSS 为采样的进程驻留内存。图片缓存为插入／回收账本中的估算成本；它不等于 RSS，也不包括所有图层／动画帧或系统缓存。磁盘字节缓存另列在完整汇总中；Installed 的原始预览文件不计作新增缓存。
- 有效样本的起止热状态均为 Nominal，交替调整运行顺序。关闭后缓存账本归零，未观察到继续赋帧。没有新增自定义键盘或辅助功能交互。

## 有效性与额外显示追踪

热状态变化的早期批次单独保留，未进入正式表格。正式矩阵有一次未收到预期悬停回调，保留失败结果并重跑；表中只含 54 个通过行为检查的样本。预热关闭组有 18 个通过样本。

额外追踪没有并入上述 CPU 或内存统计。最早的单任务与计时器驱动出现挂起标记或阶段缺失，不能用来排名。事件状态机的单次六组合流程完成了 36 个阶段，行为检查通过、采集热状态正常，但其滚动仍由主线程程序化推进；它提示提交耗时排名不能自动转换为显示卡顿排名，不构成三轮显示性能结论。

{wheel_section}

## 复现与原始记录

- [实验实现与运行说明]({Path.cwd()/'tools/workshop-workflow-probe/README.md'})
- [54 次正式矩阵]({base/'matrix-stable/summary.md'})、[逐轮范围]({base/'matrix-stable/summary.json'})、[排除样本]({base/'matrix-stable/excluded.json'})
- [18 次预热关闭对照]({base/'preheat-off/summary.md'})
- [真实滚轮协议与有效性]({base/'wheel-validation.md'})、[逐轮显示与输入数据]({base/'wheel-summary.json'})
- [构建与源码指纹]({base/'probe/source-build-manifest.json'})
- `traces/` 保存录制请求、查询、完整性问题与对应程序结果；检查记录协议后再比较。

后续生产接入应先在 Installed 以相同实际功能做小范围对照；共同的数据准备与逐卡更新策略可独立于容器选择推进。当前没有充分证据支持为百张以内场景全面更换容器。
'''
(base/'report.md').write_text(report)
print(base/'report.md')
