# 贡献指南

[English](../CONTRIBUTING.md) · **简体中文**

欢迎提 issue 和 pull request。这一页是简版；细节在 [building.md](building.md)。

## 提 PR 之前

1. 先看 [building.md](building.md) 里的工具链要求 —— Apple Silicon 上的 macOS 14.6+、
   Xcode 26+，以及需要单独下载的 Metal Toolchain。
2. 跑发版候选门禁：

   ```bash
   scripts/release_candidate_check.sh
   ```

   它按顺序跑 Swift 包测试、签名的 Pro 应用测试、Lite 构建。不要把 Pro 和 Lite 两半
   并行跑——它们共用一个 `XCBuildData/build.db`。
3. 如果你的改动必须偏离某个测试套强制的运行时不变量（本地化覆盖、粒子与渲染行为、
   entitlement），请在 PR 描述里说清楚，而不是悄悄把测试放松。

## 格式化

SwiftFormat 和 SwiftLint 都**没有接进 CI** —— `.swiftformat` 与 `.swiftlint.yml`
描述的是本项目的风格约定，不会卡你的 PR。

**不要对整个仓库跑 SwiftFormat。** 这份代码库不是 formatter-clean 的，跑一遍全量会
重写几千行、毁掉 `git blame`，并与正在进行的重构撞车。只格式化你动过的文件：

```bash
scripts/format-changed.sh          # 相对 HEAD 的改动 + 已暂存 + 未跟踪的文件
scripts/format-changed.sh main     # 相对另一个基准的改动
```

`.swiftformat` 的 `--exclude` 里列出的巨石文件会被自动跳过；那份清单由
`scripts/check_quality_exclusions.py` 与 `.swiftlint.yml` 保持同步。

## 每个 PR 都会被要求的事

- **两个版本都要能构建。** 凡是碰到 `#if !LITE_BUILD` 的改动，`LiveWallpaper` 和
  `LiveWallpaperLite` 两个 scheme 都要编译通过。单个 scheme 绿，对另一个什么都证明不了。
- **字符串要本地化。** 用户可见的文本要走字符串目录，四种发布语言（英语、日语、
  简体中文、繁体中文）都要有。没有"就这一条字符串"的例外通道。
- **文档要同步。** 如果你改的行为在 `docs/` 里有描述，同一个 PR 里要同时更新英文页
  **和**它在 `zh-Hans/` 下的对应文件。
- **渲染类结论必须有证据。** "这修好了渲染器"要配上一次抓帧、一份 dump 或一个测试，
  不能靠读代码推断。像素级 diff 在这里明确不作为验收判据（RNG、字体栅格化和浮点差异
  会让它变成噪音）。

## 边界

- `LiveWallpaper.xcodeproj` 及其 `.pbxproj` 由维护者编辑。新增源文件请放到磁盘上并在
  PR 里说明，不要手改工程文件。
- `.entitlements` 文件和 Info.plist 的权限键，只有在 PR 描述里给出明确理由时才改。
- 新增 Swift Package 依赖需要先讨论。

## 报告 bug

请用应用内的 **设置 → 关于 → 报告问题…** —— 它会自动填好一个 issue 需要的诊断信息。
或者直接提一个
[GitHub issue](https://github.com/Paradox07127/macos-wallpaperengine/issues)，
附上 macOS 版本、Mac 机型和复现步骤。

安全问题走 [SECURITY.md](SECURITY.md)，不要提到公开的 issue 列表里。
