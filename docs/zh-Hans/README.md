# Loomscreen 文档

[English](../README.md) · **简体中文**

Loomscreen 是一个以菜单栏为核心的 macOS 动态壁纸平台：用 Metal 原生渲染
Wallpaper Engine 场景（Pro），另支持视频、网页与 Apple Aerials 壁纸，可按显示器
分别配置，保存整屏方案，并带播放列表与自动化。天气、小组件和音乐可独立叠加；
macOS 26+ 还提供经兼容性检查的系统视频壁纸 provider。

## 面向用户

- [quick-start.md](quick-start.md) —— 从第一张壁纸到日常使用，含创意工坊配置与场景预设。
- [install.md](install.md) —— 安装、系统权限提示与更新。
- [troubleshooting.md](troubleshooting.md) —— 常见故障与处理办法。
- [lite-vs-pro.md](lite-vs-pro.md) —— 两个版本的能力对照表。

## 面向贡献者

- [features.md](features.md) —— 当前功能与版本边界。
- [architecture.md](architecture.md) —— 应用/会话所有权、包、渲染、XPC 与系统 provider。
- [building.md](building.md) —— 构建要求、scheme 与测试门禁。
- [releasing.md](releasing.md) —— 维护者发版清单。
- [CONTRIBUTING.md](CONTRIBUTING.md) —— 如何提交改动。
- [SECURITY.md](SECURITY.md) —— 如何报告安全问题。
- [LiveWallpaperCore DESIGN.md](../../Packages/LiveWallpaperCore/DESIGN.md) —— 共享 UI token、组件与无障碍契约。
- [../../CHANGELOG.md](../../CHANGELOG.md) —— Lite 与 Pro 的版本记录。

## 翻译

`en/` 下的每一页在 `zh-Hans/` 下都有同名对应文件。改动其中一份，同一个 PR 里要一并改另一份。

## 支持

- [GitHub Issues](https://github.com/Paradox07127/macos-wallpaperengine/issues) —— 请附上 macOS 版本、Mac 机型与复现步骤，或直接用应用内的 **设置 → 关于 → 报告问题…**。
- [GitHub Discussions](https://github.com/Paradox07127/macos-wallpaperengine/discussions) —— 提问与想法。
