# 从源码构建

[English](../en/building.md) · **简体中文**

## 环境要求

- Apple Silicon Mac 上的 macOS 14.6+
- Xcode 26 或更高。出货构建与 CI 都用 **Xcode 27.0**（CI 走 `xcode-27` runner 镜像）；UI 层用了 macOS 26 SDK 的 API，例如 `glassEffect`，更老的工具链编译不过
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

```bash
scripts/release_candidate_check.sh
```

发版候选门禁先跑 Core 与 ProWPE 两个 Swift 包的测试，然后是签名的 Pro 应用测试，
最后是 Lite 构建。视频/网页行为由应用 target 的测试套覆盖；当前仓库里没有独立的
VideoWeb Swift 包。这些检查是**刻意串行**的；不要把 Pro 和 Lite 拆开并行跑。
测试套强制的是运行时不变量（本地化覆盖、粒子/渲染行为等）；如果你的改动必须偏离
其中某一条，请在 PR 描述里说明。

## 测试工作流

用能回答当前问题的最小门禁，集成前再跑完整的发版候选门禁。

```bash
# 一个或多个受影响的 Swift Testing 套件；会校验每个请求的套件确实出现在 xcresult 里。
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
必需套件是否出现、失败项和最慢测试列表都来自生成的 `.xcresult`。目前"出现过"
并不能证明某个套件里有一个没被跳过且通过的用例；逐套件结果清单是一项还没关闭的
发版门禁待办。每次运行后都会打印产物路径。设 `DERIVED_DATA` 可以复用构建位置；
外部任务需要确定的产物落点时，设一个新的 `RESULT_BUNDLE` 路径。

Swift Testing 本身就会在进程内并发跑互相独立的测试。请把共享可变状态按测试隔离，
只对确实无法隔离的套件用 `.serialized`；全局调高 Xcode 的 worker 进程数反而会让应用
测试更不稳定，因为有若干套件会触碰进程级状态。快速契约分片刻意关闭了 Xcode 的多
worker 并行——那些套件有文件系统与进程生命周期上的契约，在多个 runner 进程之间没有隔离。

## 打包发版

维护者专用的 ad-hoc DMG 打包流程、预检清单和更新器现状，见
[`releasing.md`](releasing.md)。
