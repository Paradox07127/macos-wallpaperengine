# 从源码构建

[English](../en/building.md) · **简体中文**

## 环境要求

- Apple Silicon Mac 上的 macOS 14.6+
- **Xcode 27.0**，与出货构建及 `xcode-27` CI runner 一致。UI 会编译 macOS 26 SDK 的 `glassEffect` 等 API，部署目标 14.6 不代表可用 14.x SDK 构建。
- **Metal Toolchain** 组件（Xcode 26 把它作为单独下载项）：
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
  没有它，编译 `.metal` 着色器会失败并报
  `cannot execute tool 'metal' due to missing Metal Toolchain`。

## 克隆并打开

```bash
git clone https://github.com/Paradox07127/macos-wallpaperengine.git
cd macos-wallpaperengine
open LiveWallpaper.xcodeproj
```

## Scheme

| Scheme | 版本 | 说明 |
|---|---|---|
| `LiveWallpaperLite` | Lite | 设置 `LITE_BUILD`；Pro 独有的源码（`#if !LITE_BUILD`）被排除。产物是 `Loomscreen.app`（`com.loomscreen`）。 |
| `LiveWallpaper` | Pro | 完整构建。产物是 `Loomscreen Pro.app`（`com.loomscreen.pro`）。 |

选一个 scheme 然后 `⌘R`。

> **不要并行构建两个 scheme** —— 它们共用同一个 `XCBuildData/build.db`。

## 提 PR 之前

常规 Pro 应用改动使用定向套件或 `make test-app-hosted`；影响 Lite/Pro 行为时用 `make test-app`。
跨模块集成的串行统一入口是：

```bash
make verify
```

顺序为 `fast` → `contracts` → `lint` → `test-packages` → `test-app` → `test-wpe-metal`：
模块/生命周期/本地化、发布工具契约、改动行 lint、Core/ProWPE 包测试、带 Pro/Lite 宿主的无硬件
应用契约分片，最后以签名宿主和 GPU validation 运行 WPE 与转场 Metal 套件。
Metal 层需要本地图形与签名环境；它不是无硬件检查，也**不是完整 Pro 应用套件**。
单层命令见 `make help`。托管 CI 选择性运行 make 层，缺少 Lite 签名身份时使用仅 Pro 的 hosted 分片，
不能代替本地 Metal 门禁。

发版前跑 `scripts/release_candidate_check.sh`，额外覆盖完整签名 Pro 测试、
Pro/Lite Debug/Release 链接矩阵、archive 冒烟和发布/签名检查。
共用构建存储时串行执行 scheme；独立任务必须使用不同 DerivedData。

支持的出货与 CI 工具链为 Xcode 27.0。`make` 默认使用
`/Applications/Xcode.app/Contents/Developer`，安装位置不同时设置 `DEVELOPER_DIR`。
当前 target 与包见[架构说明](architecture.md)；Video/Web 测试位于应用 target。

## 测试工作流

按变更风险跑能回答当前问题的最小门禁；需要跨模块集成验证时跑 `make verify`，发版前跑完整候选门禁。

```bash
# 受影响的 Swift Testing 套件；每个必需用例及参数化运行都必须 passed。
scripts/app_tests.sh suites LocalizationCoverageTests EntitlementAuditTests

# 完整的签名 Pro 应用测试 target，对必需套件逐用例校验。
scripts/app_tests.sh full

# 完整 Pro target 与本地窗口/输入契约的明确入口。
make test-app-full
make test-app-interaction

# 同一份 DerivedData 上构建成功之后，可以不重新构建再跑一次。
scripts/app_tests.sh suites LocalizationCoverageTests --without-building
scripts/app_tests.sh full --without-building

# 日常数据/安全/应用/会话关键分片，用于 PR 反馈。
scripts/fast_app_contract_tests.sh

# 完整的包、Pro、Lite、archive、签名与 entitlement 门禁。
scripts/release_candidate_check.sh
```

应用测试脚本把冗长的 `xcodebuild` 输出留在原始日志里，终端摘要、非零测试数断言、
必需套件是否出现、失败项和最慢测试列表都来自生成的 `.xcresult`。必需套件的每个用例及参数化运行都必须 passed；
环境例外在 `scripts/app_test_skip_policy.json` 中用精确用例标识与理由列出，不能用另一条 passed 掩盖跳过或未知结果。
至少必须实际执行一条测试，不再固定任意总数棘轮。每次运行后都会打印产物路径。设 `DERIVED_DATA` 可以复用构建位置；
外部任务需要确定的产物落点时，设一个新的 `RESULT_BUNDLE` 路径。

逐用例校验只读取一次已有结果树，不追加测试运行，也不逐用例启动 runner；运行耗时由选中的套件决定。

日常应用分片只保留数据持久化/导入、信任与文件系统边界、壁纸应用和会话归属、播放意图、
自动化与下载取消。排版/文案、专用解析/渲染场景和压力测试在相关模块改动时或完整 target 中运行。
有用的回归测试不必永久进入每次 PR；不再为这种划分新增准入框架或计数棘轮，
关键行为确实缺少守卫时再修改现有分片。

包门禁读取 Swift Testing 的 xUnit 用例结果，拒绝缺失、空结果、失败或跳过。
控制台的 passing 总数可能包含跳过项，不能作为执行证据。必跑 CI 任务保留结果包/报告和原始日志。
`make verify` 是选定的集成门禁；本地窗口/输入、完整 Pro target 与发版验证都有单独入口。
即使传入 `-j`，make 各层也串行执行。

保留能约束可观察产品契约的测试：配置持久化与迁移、取消和生命周期归属、信任边界、
真实输入交付，以及具有独立预期的渲染输出。新增前先说明它能抓住哪种回归，以及能否扩充既有测试。
每个行为优先保留一条有效守卫。测试内自造解码器、两份常量清单互相比对、冻结源码精确拼写，
都不能证明 App 行为正确。源码静态检查可以禁止依赖或危险 API，却不能证明控件、回调和渲染器有效。
对已有独立回归而尚无行为替代的窄静态守卫，先核替代是否真实成立，再决定删除；不能机械清空所有字符串、顺序或安全上限断言。
corpus 采集与诊断导出属于证据工具，其运行成功不等于产品回归验证通过。
关键守卫应通过临时破坏对应行为来验证失败，再恢复实现；测试数量和覆盖率不能单独作为验收判据。

Swift Testing 本身就会在进程内并发跑互相独立的测试。请把共享可变状态按测试隔离，
只对确实无法隔离的套件用 `.serialized`；全局调高 Xcode 的 worker 进程数反而会让应用
测试更不稳定，因为有若干套件会触碰进程级状态。快速契约分片刻意关闭了 Xcode 的多
worker 并行——那些套件有文件系统与进程生命周期上的契约，在多个 runner 进程之间没有隔离。

应用测试不要加 `CODE_SIGNING_ALLOWED=NO`，缺少 entitlements 会让相关行为静默跳过。
以 suite 粒度选测试，检查实际 passed/failed/skipped，不能只看退出码。

## 打包发版

维护者专用的 Apple Development 签名 DMG 打包流程、预检清单和更新器现状，见
[`releasing.md`](releasing.md)。
