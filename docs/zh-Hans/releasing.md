# 发布 Loomscreen

[English](../en/releasing.md) · **简体中文**

这是手动发 `0.x` 版本的维护者清单。公开构建用 Apple Development 证书签名（带
Team ID，Sparkle 才能加载），以 DMG 形式从 GitHub Releases 分发。不是
Developer ID，也没有公证。

## 当前的更新器边界

已安装的副本去拉 `main` 上按 SKU 分开的 Sparkle appcast（`appcast-lite.xml` /
`appcast-pro.xml`）。Sparkle 下载对应 DMG、校验 EdDSA 签名并替换应用。新下载的
构建首次启动仍要跑清除隔离标记的命令——没有公证。

## 版本号清单

1. 把两个应用 target（`LiveWallpaper` 和 `LiveWallpaperLite`）的 `MARKETING_VERSION`
   设为 `X.Y.Z`。`CFBundleVersion` 跟这个值走（Sparkle 比的是 `CFBundleVersion`，
   构建号冻在 `1` 会让每一版看起来都一样）。
2. Xcode 工程里的 `CURRENT_PROJECT_VERSION` 不用动；应用 plist 已经不读它。
3. 更新 `CHANGELOG.md`，加上 `## [X.Y.Z] — YYYY-MM-DD`。这个文件没有页脚 compare
   链接，只给某一个版本补一条会让其余版本显得缺失。
4. Swift 包的 pin 有变动时，确保带上
   `LiveWallpaper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。
5. 打包前先提交版本号与文档改动。本地打包脚本拒绝脏工作树，但允许
   `appcast-lite.xml` 和 `appcast-pro.xml`，因为脚本会重新生成它们。

## 预检

生成产物之前，先跑完整的串行门禁：

```sh
scripts/release_candidate_check.sh
```

脚本会跑 Core 与 ProWPE 包测试、签名的 Pro 测试、四面链接矩阵
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
它们只做 ad-hoc 签名，目的是走一遍真实的 archive/签名路径。Pro 必须只含 arm64；
Lite 必须含 arm64，并允许额外带 x86_64——因为 Lite 以 universal 形式发布以支持
Intel Mac。两者的嵌套签名都必须有效。Pro 必须且只能内嵌一个 XPC 服务 `SteamConnector.xpc`，
并且它**不能**带 App Sandbox entitlement —— 辅助进程不进沙盒正是关键所在，
因为一个进了沙盒的辅助进程会把它的 STEAMROOT 放回应用容器里，从而悄悄撤销 Steam
库迁移。（本段原先描述的 SceneScript XPC 辅助进程已于 2026-07-23 退役。）
Lite 必须完全不含内嵌 XPC 服务，也不能含 Pro 的渲染器/SceneScript 符号、
JavaScriptCore，或手动链接的 libc++ 动态库。Sparkle 是故意链接的。每次运行都用新的
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

先 Lite 后 Pro，让打包顺序与上传顺序一致：

```sh
scripts/release-app.sh --sku lite --version X.Y.Z --skip-checks
scripts/release-app.sh --sku pro  --version X.Y.Z --skip-checks
```

`release-app.sh` 默认会为**每个** SKU 重跑一整轮候选门禁，所以不带参数的两条命令
会在同一个 commit 上把门禁跑三遍。`--skip-checks` 跳过的正是这次重复——只有在上面
那轮门禁已经在这个 commit 上通过时才用它，并在发布报告里写明。它**不会**跳过每个
SKU 真正要紧的核验：Sparkle 辅助程序重签与 Team ID 对齐、签名验证、对已签 app 的
有效 entitlements 检查、bundle ID / 显示名 / 版本号字段、DMG 挂载与验签、sha256、
以及 appcast 再生成。这些是无条件执行的。

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

顺序要紧：Sparkle 读的是 `main` 上的 feed，appcast 先落地而 DMG 还不存在，指向的就是 404。

```sh
# 1. 提交两次打包再生出的 appcast，然后打 tag
git add appcast-lite.xml appcast-pro.xml
git commit -m "Publish Sparkle appcast for X.Y.Z"
git tag -a loomscreen-vX.Y.Z -m "Loomscreen X.Y.Z"
git push origin loomscreen-vX.Y.Z

# 2. 上传 DMG，让 enclosure URL 真正可解析
gh release create loomscreen-vX.Y.Z \
  build/release/Loomscreen-X.Y.Z.dmg \
  build/release/Loomscreen-X.Y.Z.dmg.sha256 \
  build/release/Loomscreen-Pro-X.Y.Z.dmg \
  build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256 \
  --verify-tag \
  --title "Loomscreen X.Y.Z" \
  --notes-file <notes.md>

# 3. 到这一步才把 feed 推出去
git push origin main
```

## 发布说明

四块，顺序固定：下载选择表 → 折叠的首次启动说明 → 三段式 changelog → 系统要求。
英文整套在前，`---` 分隔，中文整套在后。链接定义放在文件最末尾，两种语言共用。

````markdown
## Download

| Edition | Your Mac | Wallpapers |
| --- | --- | --- |
| [**Lite**][lite] | Intel or Apple Silicon | Video · Web |
| [**Pro**][pro] | Apple Silicon | Video · Web · **Wallpaper Engine scenes** |

<details>
<summary><b>First launch</b> — if macOS says the app is damaged</summary>

Nothing here is notarized, so a DMG downloaded by hand is quarantined and macOS
may refuse to open it. If that happens, run this once:

```sh
xattr -dr com.apple.quarantine /Applications/Loomscreen.app
```

For Pro:

```sh
xattr -dr com.apple.quarantine "/Applications/Loomscreen Pro.app"
```

Once is enough — updates Loomscreen installs itself clear the flag, so later
versions open straight away.

</details>

## What's New

- <之前没有的、用户可见的新能力>

## Improvements

- <已有行为变得更好、更快或更清楚>

## Bug Fixes

- <哪里坏了，用用户的说法写；有 issue 就引用>

Requires macOS 14.6+.

<!-- 文件最末尾 -->
[lite]: https://github.com/Paradox07127/macos-wallpaperengine/releases/download/loomscreen-vX.Y.Z/Loomscreen-X.Y.Z.dmg
[pro]: https://github.com/Paradox07127/macos-wallpaperengine/releases/download/loomscreen-vX.Y.Z/Loomscreen-Pro-X.Y.Z.dmg
````

以下几条都是踩过的：

- **Lite 只占一行，写「Intel 或 Apple Silicon」** —— 它出的是 universal（`x86_64 arm64`），
  一个包通吃，不要按架构拆成两行（2026-08-30 试过又撤回：同一个链接出现两次看着像贴错）。
  Pro 是 `arm64` 单架构，所以那行只写 Apple Silicon。架构结论以本次发布的 `lipo -archs` 为准，
  别照抄上一版。
- **首次启动那块是兜底说明，不是必做步骤。** 2026-08-30 实测：Sparkle 2.9.6 会清掉它自己
  安装的那份的 `com.apple.quarantine`，所以用户执行过一次之后，后续更新都不用再执行。
  措辞要写成「如果 macOS 拒绝打开」，并说明应用内更新会自己清掉这个标记。但**不能整段删**
  ——手动下载的 DMG 仍然会被隔离，而且 `release_contract_check.sh` 会断言 appcast 里必须有这条命令。
- **`</summary>` 后面要空一行**，否则 GitHub 不会渲染 `<details>` 里的 markdown。
- **一键复制靠的就是围栏代码块** —— GitHub 会自动加复制按钮。Lite 与 Pro 分成两个块，
  各有各的按钮。
- changelog 条目取自 `git log <上一个 tag>..HEAD` 里实际发出去的东西，挑用户会注意到的写。
  这是 changelog，不是每个 commit 的汇总，也不是把 `CHANGELOG.md` 换个说法。没内容的小节整段省略。
- 等价就是等价：版本号、命令行、路径、SKU 名（Loomscreen / Loomscreen Pro）两边字面一致
  且不翻译，任何一边都不许比另一边少一条。中文标题用 新功能 / 改进 / Bug 修复。
- 仍然**不要写**：营销式标语或开场段落、按子系统划分的小标题。下载与首次启动**是要写的**，
  但只用上面的表格与折叠块形式，不要退回成散文段落。

这份文件是两个界面的**唯一真值源**：`gh release create --notes-file` 用它渲染 release 页，
`scripts/generate-appcast.sh --notes-file` 从中抽出三段 changelog——只取 `---` 之前的英文
半边——注入 Sparkle 的更新弹窗。下载表、折叠块和中文半边都不会进弹窗：正在下载的更新器
不需要下载表，而且面板只有 565x402。**notes 要在打包之前写好**，因为
`release-app.sh --notes-file` 是在打包时把它交给 appcast 生成器的；漏传不报错，只会退回成
弹窗里只有 quarantine 一行。

## 发布后验证

先确认上传没有损坏——这是唯一能证明 GitHub 上放着的就是这里签出来的那份字节的证据：

```sh
gh release view loomscreen-vX.Y.Z --json tagName,assets \
  --jq '.tagName, (.assets[] | "\(.name) \(.size)")'
gh release download loomscreen-vX.Y.Z --pattern 'Loomscreen-X.Y.Z.dmg' --clobber
shasum -a 256 Loomscreen-X.Y.Z.dmg   # 必须等于 build/release/Loomscreen-X.Y.Z.dmg.sha256
```

然后对构建本身做冒烟：

1. 在一台干净的 Mac 上安装 Lite DMG。
2. 执行：
   ```sh
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
3. 启动 Loomscreen，确认菜单栏应用能打开。
4. 在 **设置 → 关于** 里确认版本为 `X.Y.Z`。
5. 确认**立即检查**走的是 Sparkle（不是报错，也不是 appcast 还没上 `main` 时的假“已是最新”）。
