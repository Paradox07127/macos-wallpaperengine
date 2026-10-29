# 发布 Loomscreen

[English](../en/releasing.md) · **简体中文**

这是手动发 `0.x` 版本的维护者清单。公开构建用团队的 Developer ID Application 证书签名，
经过公证，以 DMG 形式从 GitHub Releases 分发。app 和 DMG 都装订了公证票据，所以 Gatekeeper
直接放行下载的副本，不需要终端命令。0.9.3 及更早的版本用 Apple Development 签名，没有公证。

以下 DMG 流程适用于 Pro 与 Lite。第三个 target `LoomscreenAppStore` 使用独立的 [App Store 发布流程](app-store.md)；每次上传都递增它的 `CURRENT_PROJECT_VERSION`。

## 当前的更新器边界

已安装的副本去拉 `main` 上按 SKU 分开的 Sparkle appcast（`appcast-lite.xml` /
`appcast-pro.xml`）。Sparkle 下载对应 DMG、校验 EdDSA 签名并替换应用。手动下载的
构建经过公证，可以直接打开。

## 版本号清单

1. 把两个应用 target（`LiveWallpaper` 和 `LiveWallpaperLite`）的 `MARKETING_VERSION`
   设为 `X.Y.Z`。`CFBundleVersion` 跟这个值走（Sparkle 比的是 `CFBundleVersion`，
   构建号冻在 `1` 会让每一版看起来都一样）。
2. 这两个 DMG target 的 `CURRENT_PROJECT_VERSION` 不用动；它们的 plist 读取营销版本号。App Store target 仍读取独立构建号。
3. 更新 `CHANGELOG.md`，加上 `## [X.Y.Z] — YYYY-MM-DD`。这个文件没有页脚 compare
   链接，只给某一个版本补一条会让其余版本显得缺失。
4. Swift 包的 pin 有变动时，确保带上
   `LiveWallpaper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。
5. 打包前先提交版本号与文档改动。本地打包脚本拒绝脏工作树，但允许
   `appcast-lite.xml` 和 `appcast-pro.xml`，因为脚本会重新生成它们。

## 预检

日常集成先跑 `make verify`；生成发版产物之前，再跑完整串行门禁：

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
DERIVED_DATA="$(mktemp -d -t LoomscreenReleaseCandidate)" \
  scripts/release_candidate_check.sh
```

Pro 与 Lite 的冒烟 archive 每次使用新的系统临时目录，脚本验证后清理。
必选门禁不需要个人 Workshop 库；真实 producer/oracle 语料通过[构建指南](building.md#真实-producer-与-workshop-语料验收)中的独立入口验收。
它们只做 ad-hoc 签名，目的是走一遍真实的 archive/签名路径。Pro 必须只含 arm64；
Lite 必须含 arm64，并允许额外带 x86_64——因为 Lite 以 universal 形式发布以支持
Intel Mac。两者的嵌套签名都必须有效。两个 SKU 都内嵌 `WallpaperMaintenance.xpc`，它替系统壁纸扩展
运行 `lsregister` 并重启 WallpaperAgent；Pro 额外内嵌 `SteamConnector.xpc`。两个服务都
**不能**带 App Sandbox entitlement —— 辅助进程不进沙盒正是关键所在：进了沙盒的
SteamConnector 会把它的 STEAMROOT 放回应用容器里，从而悄悄撤销 Steam 库迁移；进了沙盒的
维护辅助进程则碰不到 `lsregister`。（本段原先描述的 SceneScript XPC 辅助进程已于
2026-07-23 退役。）Lite 不能含其他内嵌 XPC 服务，也不能含 Pro 的渲染器/SceneScript 符号、
JavaScriptCore，或手动链接的 libc++ 动态库。Sparkle 是故意链接的。每次运行都用新的
`DERIVED_DATA`/archive 路径；门禁拒绝删除或覆盖已存在的 archive。

这些 ad-hoc archive 是**验证证据，不是出货用的 entitlement 产物**。Xcode 的
"Sign to Run Locally"路径可能注入 `get-task-allow=true`，而
`scripts/check_entitlements.sh --app` 必须拒绝这种形态。真正出货的 Pro/Lite
有效 entitlement 与嵌套签名，在签名 Mac 上针对最终 Developer ID 签名应用验证；
`release-app.sh` 会做这项验证，并完成公证和装订。不要以 ad-hoc 冒烟 archive
代替出货产物，也不要豁免 `get-task-allow` 检查失败。

## 文档与 UI 素材

包含 UI 改动的版本在打包前：

- 同步根目录中英文 README 与成对指南；在构建后的应用里核对导航名称，包含 Lite 可用页面。
- 截取真实发版候选：显示器全景与壁纸架、统一壁纸库、显示器播放编辑器、统一叠加层画布、
  Pro 创意工坊。记录构建和外观，检查最小窗口与长文案。
- 使用允许再分发的壁纸素材；检查画面中是否包含本地路径、账号、API key 等私人信息。
- 替换或撤下 README/文档中的过期截图，不用演示 HTML 或设计稿冒充产品截图。
  抓图成功不证明播放、无障碍或性能正确。
- 宣传公告可用[宣传文案](press-kit.md)，版本说明仍遵守下方只写版本变化的格式。

## 手动打包

被跟踪的、不含密钥的打包辅助脚本会产出：

- `build/release/Loomscreen-X.Y.Z.dmg`
- `build/release/Loomscreen-X.Y.Z.dmg.sha256`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256`

打包机需要 Python 3.10+ 和固定版本的 `dmgbuild` 工具。在仓库根目录创建本地虚拟环境，
安装依赖，并在预检与打包期间将其可执行文件保留在 `PATH` 中：

```sh
python3 -m venv build/release-tools
build/release-tools/bin/python -m pip install -r scripts/release-requirements.txt
export PATH="$PWD/build/release-tools/bin:$PATH"
```

`dmgbuild` 直接写入 DMG 窗口布局，无需自动控制 Finder。
`scripts/dmg_settings.py` 从打包输入读取背景、图标位置和 `/Applications` 拖放链接。
窗口几何数据和背景由 `scripts/dmg_background.swift` 提供。DMG 里只有 app 和
`/Applications` 链接。

签名和公证需要打包机上有两样东西：

- login 钥匙串里有且只有一个属于本项目 Team 的 **Developer ID Application** 身份。
  脚本按 SHA-1 签名，因为同一 Team 的两张证书同名。
- 一个 `notarytool` 钥匙串配置，默认名 `loomscreen-notary`（可用 `NOTARY_PROFILE` 覆盖）。
  用 account.apple.com 生成的 App 专用密码建一次：

  ```sh
  xcrun notarytool store-credentials loomscreen-notary --apple-id <Apple ID> --team-id <Team ID>
  ```

脚本在归档之前检查这两项。每个 SKU 提交两次公证：先提交压缩后的 app（票据装订到 app 上，
从 DMG 拖出的副本离线也能过 Gatekeeper），再提交签名后的 DMG。装订会改动 DMG，所以它在
校验和与 Sparkle EdDSA 签名之前执行。

预期命令：

先 Lite 后 Pro，让打包顺序与上传顺序一致：

```sh
scripts/release-app.sh --sku lite --version X.Y.Z --skip-checks \
  --notes-file build/release-notes/X.Y.Z.md
scripts/release-app.sh --sku pro  --version X.Y.Z --skip-checks \
  --notes-file build/release-notes/X.Y.Z.md
```

`--notes-file` 实际上不是可选项。不加的话 appcast 会退回到只有发布说明链接，
于是 Sparkle 的更新弹窗对本次发布只字不提，而 GitHub 页面列得好好的。漏掉某一个 SKU
很容易且没有提示——打包依然报成功。

`release-app.sh` 默认会为**每个** SKU 重跑一整轮候选门禁，所以不带参数的两条命令
会在同一个 commit 上把门禁跑三遍。`--skip-checks` 跳过的正是这次重复——只有在上面
那轮门禁已经在这个 commit 上通过时才用它，并在发布报告里写明。它**不会**跳过每个
SKU 真正要紧的核验：Sparkle 辅助程序重签与 Team ID 对齐、签名验证、对已签 app 的
有效 entitlements 检查、bundle ID / 显示名 / 版本号字段、app 与 DMG 的公证和装订、
DMG 挂载后的验签与 Gatekeeper 检查、sha256、
以及 appcast 再生成。这些是无条件执行的。

不构建、不签名地验证干净克隆下的工具链契约：

```sh
scripts/release_contract_check.sh
scripts/release-app.sh --sku lite --version X.Y.Z --plan
scripts/release-app.sh --sku pro  --version X.Y.Z --plan
```

`--plan` 不做构建也不写任何产物。签名身份和公证凭据始终是
环境/机器层面的输入，不存放在本仓库里。

公开的 Lite 产物必须命名为 `Loomscreen-X.Y.Z.dmg`，Pro 产物必须命名为
`Loomscreen-Pro-X.Y.Z.dmg`。asset 顺序不影响应用内检查：Sparkle 读取对应版本 appcast 的 enclosure，
并比较 `CFBundleVersion`。仍把 Lite 放在前面，保持下载顺序稳定。

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

第一行必须是只含本次版本号的 H1，例如 `# 0.9.0b2`，之后空一行。
整份双语发布说明只保留这一个版本标题。

三块，顺序固定：下载选择表 → 三段式 changelog → 系统要求。
英文整套在前，`---` 分隔，中文整套在后。链接定义放在文件最末尾，两种语言共用。

````markdown
# X.Y.Z

## Download

| Edition | Your Mac | Wallpapers |
| --- | --- | --- |
| [**Lite**][lite] | Intel or Apple Silicon | Video · Web |
| [**Pro**][pro] | Apple Silicon | Video · Web · **Wallpaper Engine scenes** |

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
- changelog 条目取自 `git log <上一个 tag>..HEAD` 里实际发出去的东西，挑用户会注意到的写。
  这是 changelog，不是每个 commit 的汇总，也不是把 `CHANGELOG.md` 换个说法。没内容的小节整段省略。
- 等价就是等价：版本号、命令行、路径、SKU 名（Loomscreen / Loomscreen Pro）两边字面一致
  且不翻译，任何一边都不许比另一边少一条。中文标题用 新功能 / 改进 / Bug 修复。
- 仍然**不要写**：营销式标语或开场段落、按子系统划分的小标题。下载块**是要写的**，
  但只用上面的表格形式，不要退回成散文段落。

这份文件是两个界面的**唯一真值源**：`gh release create --notes-file` 用它渲染 release 页，
`scripts/generate-appcast.sh --notes-file` 从中抽出三段 changelog——只取 `---` 之前的英文
半边——注入 Sparkle 的更新弹窗。下载表和中文半边都不会进弹窗：正在下载的更新器
不需要下载表，而且面板只有 565x402。**notes 要在打包之前写好**，因为
`release-app.sh --notes-file` 是在打包时把它交给 appcast 生成器的；漏传不报错，只会退回成
弹窗里只有发布说明链接。

## 发布后验证

先确认上传没有损坏——这是唯一能证明 GitHub 上放着的就是这里签出来的那份字节的证据：

```sh
gh release view loomscreen-vX.Y.Z --json tagName,assets \
  --jq '.tagName, (.assets[] | "\(.name) \(.size)")'
gh release download loomscreen-vX.Y.Z --pattern 'Loomscreen-X.Y.Z.dmg' --clobber
shasum -a 256 Loomscreen-X.Y.Z.dmg   # 必须等于 build/release/Loomscreen-X.Y.Z.dmg.sha256
```

然后对构建本身做冒烟：

1. 在一台干净的 Mac 上从 release 页下载 Lite DMG（这样它带隔离标记），把 app 拖进 `/Applications`。
2. 不运行任何终端命令，直接启动 Loomscreen。Gatekeeper 可以弹出「从互联网下载」的确认框，但不能拦截。
3. 确认菜单栏应用能打开。
4. 在 **设置 → 关于** 里确认版本为 `X.Y.Z`。
5. 确认**立即检查**走的是 Sparkle（不是报错，也不是 appcast 还没上 `main` 时的假“已是最新”）。

## 本地产物保留

当前 stable 和 beta 的 DMG、校验文件、xcarchive 及匹配 dSYM 保留在
`build/release/`。旧版本按整组移入 `build/release/archive/YYYY-MM/`；精确匹配的
dSYM 用于历史崩溃符号化，继续保留。记录移动前后路径，不改写发布收据里的历史测量或签名。

核对保留的 DMG 且确认暂存路径没有运行中的应用后，可删除 `staging-Loomscreen*`
暂存副本。编译和模块缓存可以重建；唯一 xcresult、trace、源码快照和许可来源应明确保留或归档，
不整批删除。当前 shader 工具链输入继续按 `WPEShaderCompiler/toolchain-inputs.sha256` 固定。
