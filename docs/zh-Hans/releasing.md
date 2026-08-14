# 发布 Loomscreen

[English](../en/releasing.md) · **简体中文**

这是手动发 `0.x` 版本的维护者清单。公开构建是 ad-hoc 签名的，以 DMG 形式从
GitHub Releases 分发。

## 当前的更新器边界

发版投递走 GitHub Releases，并且仍是手动的：用户下载新的 DMG 并替换已安装的应用。
两个 SKU 都会跑启动时和"关于"面板里的 GitHub 更新检查；两者都不会自动安装更新。

## 版本号清单

1. 把两个应用 target（`LiveWallpaper` 和 `LiveWallpaperLite`）的 `MARKETING_VERSION`
   设为 `X.Y.Z`。
2. 除非构建号策略有变，否则 `CURRENT_PROJECT_VERSION` 保持不动。
3. 更新 `CHANGELOG.md`，加上 `## [X.Y.Z] — YYYY-MM-DD` 与页脚的 compare 链接。
4. Swift 包的 pin 有变动时，确保带上
   `LiveWallpaper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。
5. 打包前先提交版本号与文档改动。本地打包脚本拒绝在脏工作树上运行。

## 预检

生成产物之前，先跑完整的串行门禁：

```sh
scripts/release_candidate_check.sh
```

脚本会跑 Core 与 ProWPE 包测试、签名的 Pro 测试、四面 arm64 链接矩阵
（Pro Debug/Release 与 Lite Debug/Release）、Pro 与 Lite 的 Release archive 冒烟、
发布版构建设置/隐私检查，以及 `git diff --check`。每个 Xcode 动作都带
`SWIFT_EMIT_LOC_STRINGS=NO`。包、Pro、Lite 三段检查刻意串行并使用隔离的构建数据库，
以避开编译器/构建数据库争用。

想要可复现的验证运行，把所有临时产物放在仓库之外：

```sh
DERIVED_DATA=/tmp/LoomscreenReleaseCandidate-arm64 \
  scripts/release_candidate_check.sh
```

Pro 与 Lite 的冒烟 archive 默认落在
`/tmp/LoomscreenReleaseCandidate-arm64ProRelease/LiveWallpaper-LinkMatrix.xcarchive`
和
`/tmp/LoomscreenReleaseCandidate-arm64LiteRelease/Loomscreen-LinkMatrix.xcarchive`。
它们只做 ad-hoc 签名，目的是走一遍真实的 archive/签名路径。两者都必须只含 arm64
可执行文件且嵌套签名有效。Pro 必须且只能内嵌一个 XPC 服务 `SteamConnector.xpc`，
并且它**不能**带 App Sandbox entitlement —— 辅助进程不进沙盒正是关键所在，
因为一个进了沙盒的辅助进程会把它的 STEAMROOT 放回应用容器里，从而悄悄撤销 Steam
库迁移。（本段原先描述的 SceneScript XPC 辅助进程已于 2026-07-23 退役。）
Lite 必须完全不含内嵌 XPC 服务，也不能含 Pro 的渲染器/SceneScript 符号、
JavaScriptCore、Sparkle，或手动链接的 libc++ 动态库。每次运行都用新的
`DERIVED_DATA`/archive 路径；门禁拒绝删除或覆盖已存在的 archive。

这些 ad-hoc archive 是**验证证据，不是出货用的 entitlement 产物**。Xcode 的
"Sign to Run Locally"路径可能注入 `get-task-allow=true`，而
`scripts/check_entitlements.sh --app` 必须拒绝这种形态。真正出货的 Pro/Lite
entitlement 批准、Developer ID 信任与公证，必须在签名 Mac 上针对最终的
Developer ID archive 执行；不要豁免那里的失败，也不要拿链接矩阵的 archive 顶替。

## 手动打包

被跟踪的、不含密钥的打包辅助脚本会产出：

- `build/release/Loomscreen-X.Y.Z.dmg`
- `build/release/Loomscreen-X.Y.Z.dmg.sha256`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256`

打包需要打包机上装有 `create-dmg`：

```sh
brew install create-dmg
```

它会布置挂载后的 DMG 窗口（背景、图标位置、`/Applications` 拖放链接）。窗口背景由
`scripts/dmg_background.swift` 按 SKU 渲染，会把该 SKU 的应用名烘进图上显示的
Gatekeeper 命令里——这也是它在打包时生成、而不是作为静态 PNG 提交的原因。

预期命令：

```sh
scripts/release-app.sh --sku lite --version X.Y.Z
scripts/release-app.sh --sku pro  --version X.Y.Z
```

不构建、不签名地验证干净克隆下的工具链契约：

```sh
scripts/release_contract_check.sh
scripts/release-app.sh --sku lite --version X.Y.Z --plan
scripts/release-app.sh --sku pro  --version X.Y.Z --plan
```

`--plan` 不做构建也不写任何产物。签名身份以及将来可能的公证凭据始终是
环境/机器层面的输入，不存放在本仓库里。

公开的 Lite 产物必须命名为 `Loomscreen-X.Y.Z.dmg`，Pro 产物必须命名为
`Loomscreen-Pro-X.Y.Z.dmg`。asset 顺序不影响应用内的检查——它读的是 release tag，
从不看 asset 列表——但仍把 Lite 的 DMG 放在前面，好让 release 页面以公开下载开头。

## GitHub release

创建一个统一的 release：

```sh
gh release create loomscreen-vX.Y.Z \
  build/release/Loomscreen-X.Y.Z.dmg \
  build/release/Loomscreen-X.Y.Z.dmg.sha256 \
  build/release/Loomscreen-Pro-X.Y.Z.dmg \
  build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256 \
  --title "Loomscreen X.Y.Z" \
  --notes-file <notes.md>
```

发布说明应以 Lite 下载开头，并说明更新是手动的：下载新 DMG、替换
`/Applications` 里的应用，然后再执行一次清除隔离标记的命令。

## 发布后冒烟

1. 在一台干净的 Mac 上安装 Lite DMG。
2. 执行：
   ```sh
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
3. 启动 Loomscreen，确认菜单栏应用能打开。
4. 在 **设置 → 关于** 里确认版本为 `X.Y.Z`。
5. 确认**立即检查**能通过 GitHub Releases 解析到当前版本。
