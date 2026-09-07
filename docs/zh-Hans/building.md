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

使用仓库的串行统一入口：

```bash
make verify
```

顺序为 `fast` → `contracts` → `lint` → `test-packages` → `test-app`：模块/生命周期/
本地化、发布工具契约、改动行 lint、Core/ProWPE 包测试，再跑带 Pro/Lite 宿主的无硬件
应用契约分片。它**不是完整 Pro 应用套件**。单层命令见 `make help`。
托管 CI 复用这些 make 层，缺少 Lite 签名身份时使用仅 Pro 的 hosted 分片。

发版前跑 `scripts/release_candidate_check.sh`，额外覆盖完整签名 Pro 测试、
Pro/Lite Debug/Release 链接矩阵、archive 冒烟和发布/签名检查。
共用构建存储时串行执行 scheme；独立任务必须使用不同 DerivedData。

支持的出货与 CI 工具链为 Xcode 27.0。`make` 默认使用
`/Applications/Xcode-beta.app/Contents/Developer`，安装位置不同时设置 `DEVELOPER_DIR`。
当前 target 与包见[架构说明](architecture.md)；Video/Web 测试位于应用 target。

## 测试工作流

先跑能回答当前问题的最小门禁，集成时跑 `make verify`，发版前跑完整候选门禁。

```bash
# 受影响的 Swift Testing 套件；每个必需套件至少要有一个 passed 用例。
scripts/app_tests.sh suites LocalizationCoverageTests EntitlementAuditTests

# 完整的签名 Pro 应用测试 target。条数下限能抓住整体跑零或跑一半的情况，
# 但不能替代逐套件的 passed/skipped 校验。
scripts/app_tests.sh full

# 同一份 DerivedData 上构建成功之后，可以不重新构建再跑一次。
scripts/app_tests.sh suites LocalizationCoverageTests --without-building
scripts/app_tests.sh full --without-building

# 不依赖硬件的架构与安全分片，用于快速的 PR 反馈。
scripts/fast_app_contract_tests.sh

# 完整的包、Pro、Lite、archive、签名与 entitlement 门禁。
scripts/release_candidate_check.sh
```

应用测试脚本把冗长的 `xcodebuild` 输出留在原始日志里，终端摘要、非零测试数断言、
必需套件是否出现、失败项和最慢测试列表都来自生成的 `.xcresult`。必需套件必须至少有一个 passed 用例；允许全跳过的套件须以 `--allow-skipped-suite`
显式列出。跳过项不计入 passed 条数下限。每次运行后都会打印产物路径。设 `DERIVED_DATA` 可以复用构建位置；
外部任务需要确定的产物落点时，设一个新的 `RESULT_BUNDLE` 路径。

Swift Testing 本身就会在进程内并发跑互相独立的测试。请把共享可变状态按测试隔离，
只对确实无法隔离的套件用 `.serialized`；全局调高 Xcode 的 worker 进程数反而会让应用
测试更不稳定，因为有若干套件会触碰进程级状态。快速契约分片刻意关闭了 Xcode 的多
worker 并行——那些套件有文件系统与进程生命周期上的契约，在多个 runner 进程之间没有隔离。

应用测试不要加 `CODE_SIGNING_ALLOWED=NO`，缺少 entitlements 会让相关行为静默跳过。
以 suite 粒度选测试，检查实际 passed/failed/skipped，不能只看退出码。

## 打包发版

维护者专用的 Apple Development 签名 DMG 打包流程、预检清单和更新器现状，见
[`releasing.md`](releasing.md)。
