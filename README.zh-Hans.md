# Loomscreen

<div align="center">

<img src="docs/images/loomscreen-logo.png" width="144" alt="Loomscreen" />

### 在 macOS 上运行 Wallpaper Engine 场景 —— 原生 Metal 渲染器，另支持视频与网页壁纸，多显示器统一管理。

![macOS](https://img.shields.io/badge/macOS-14.6%2B-blue.svg)
![Architecture](https://img.shields.io/badge/Apple_Silicon-required_for_Pro-purple.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Release](https://img.shields.io/github/v/release/Paradox07127/macos-wallpaperengine?include_prereleases&sort=semver)

[⬇ 下载](https://github.com/Paradox07127/macos-wallpaperengine/releases/latest) ·
[🚀 快速上手](docs/zh-Hans/quick-start.md) ·
[✨ 功能](docs/zh-Hans/features.md) ·
[⚖ Lite vs Pro](docs/zh-Hans/lite-vs-pro.md) ·
[🛠 构建](docs/zh-Hans/building.md) ·
[🇬🇧 English](README.md)

</div>

> 独立的 Metal 实现，与 Wallpaper Engine 无关联；Workshop 内容通过你自己的 Steam 账号与授权下载。

![Loomscreen 主界面](docs/images/main.png)

## 壁纸类型

| 类型 | 版本 | 能力 |
|---|---|---|
| **Wallpaper Engine 场景** | Pro | 原生 Metal 渲染 `scene.pkg` 项目 —— 粒子、着色器特效、木偶变形动画、音频反应图层、光标特效。支持导入本地项目文件夹，或通过 Steam Workshop 下载场景及社区预设；兼容程度随项目而异。 |
| **视频** | Lite + Pro | `mp4` / `m4v` / `mov` / `avi`，平滑循环，HDR 感知色彩管线，可逐屏播放或跨所有屏幕铺展。 |
| **网页** | Lite + Pro | 沙盒化 `WKWebView`，支持 JavaScript 开关、跟踪器拦截、自定义 CSS、定时自动刷新。 |
| **Apple Aerials** | Lite + Pro | 浏览并应用 Mac 上已有的 Apple TV 航拍视频。 |

## 实际效果

| | |
|:---:|:---:|
| ![视频壁纸](docs/images/video.png) **视频** | ![网页壁纸](docs/images/web.png) **网页** |
| ![Wallpaper Engine 场景](docs/images/scene.png) **场景（Pro）** | ![Steam Workshop](docs/images/workshop.png) **Workshop（Pro）** |

## 不只是播放器

- **每屏独立控制** —— 每台显示器运行各自的壁纸；可一键复制到所有屏幕，或让一个视频跨屏铺展。
- **播放列表与计划** —— 随机播放、轮换间隔、按时段自动切换，书签库一键换壁纸。
- **菜单栏优先** —— 全局开关、每屏播放/暂停与上下切换，实时 CPU / GPU / 内存 / 热压力状态条。
- **桌面叠加层** —— 12 种粒子特效、实时天气联动和可配置监控面板；共十一种组件，包含组合式系统总览、天气与本地 AI agent 会话，可逐屏调整排列与尺寸。
- **音乐层** —— 支持 Spotify 与 Apple Music，提供 Poster/Vinyl/Aurora 布局、封面、播放控制和可选同步歌词；Pro 另有系统音频驱动的视觉效果。
- **系统壁纸（macOS 26+）** —— 把视频交给 macOS 壁纸 provider，Loomscreen 关闭后仍可播放，受 provider 兼容性限制。
- **节能播放策略** —— 可配置全屏、遮挡、电池与低电量模式规则；锁屏/休眠和资源压力处理保留你的播放/暂停意图。
- **全局快捷键** —— 八个可绑定动作，从全部播放/暂停到重载。
- **保存壁纸与方案** —— 书签只切换内容，方案恢复整屏配置；`.lwconfig` 备份设置和引用，不携带媒体文件或可跨机器使用的文件授权。
- **五种界面语言** —— English、简体中文、繁體中文、日本語、Español。
- **默认隐私** —— 无需 Loomscreen 账号，不收集使用遥测；可选在线功能会访问各自的服务。

## 版本划分

| | **Lite** | **Pro** |
|---|:---:|:---:|
| 视频 / 网页 / Apple Aerials、播放列表、计划、叠加层、快捷键 | ✅ | ✅ |
| Wallpaper Engine 场景渲染与导入 | — | ✅ |
| Steam 创意工坊在线浏览与下载 | — | ✅ |
| 场景预设（创意工坊预设 + 自己保存的参数） | — | ✅ |
| 系统音频捕获（场景与音乐视觉效果） | — | ✅ |
| 自适应帧率与逐屏独立渲染线程 | — | ✅ |
| Sparkle 更新检查、下载与安装 | ✅ | ✅ |
| 音乐层、天气组件和整屏方案 | ✅ | ✅ |
| 系统壁纸视频 provider（macOS 26+，有兼容性检查） | ✅ | ✅ |

Lite 是更轻的运行时，不是阉割版 UI —— 视频、网页、Aerials 的保真度与 Pro 完全一致。完整对照：[docs/zh-Hans/lite-vs-pro.md](docs/zh-Hans/lite-vs-pro.md)。

## 安装

1. 从 [Releases](https://github.com/Paradox07127/macos-wallpaperengine/releases/latest) 下载最新 `Loomscreen-x.y.z.dmg`。
2. 拖拽 **Loomscreen.app** 到 `/Applications`。
3. 启动应用。发布版使用 Apple Development 签名，尚未公证；如果 macOS 拒绝打开手动下载的副本，先核对发布的校验和，再清除隔离标记：
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. Loomscreen 常驻菜单栏，首次引导会帮你设好第一张壁纸。

Pro 请下载 `Loomscreen-Pro-x.y.z.dmg`，安装 **Loomscreen Pro.app**，并将上述命令路径改为 `"/Applications/Loomscreen Pro.app"`。应用内更新由 Sparkle 完成，也可手动替换。

安装细节、权限弹窗与更新方式：[docs/zh-Hans/install.md](docs/zh-Hans/install.md) · 首次配置全流程：[docs/zh-Hans/quick-start.md](docs/zh-Hans/quick-start.md)

## 运行要求

- macOS 14.6 及以上
- **Loomscreen（Lite）**：Apple Silicon 或 Intel。Intel 切片已构建并随包发布，但
  **尚未在 Intel Mac 上测试过** —— 最可能出问题的是监视器面板里的硬件读数（可能为空）。
  欢迎反馈。
- **Loomscreen Pro**：仅 Apple Silicon。它的 Metal 场景渲染器从未在 Intel 硬件上运行过。

## 从源码构建

```bash
git clone https://github.com/Paradox07127/macos-wallpaperengine.git
cd macos-wallpaperengine
open LiveWallpaper.xcodeproj
```

Scheme：`LiveWallpaperLite`（Lite）· `LiveWallpaper`（Pro）。出货与 CI 使用 Xcode 27.0，日常验证从 `make verify` 开始，完整发版候选门禁单独运行。[架构说明](docs/zh-Hans/architecture.md) · 环境要求与测试门禁：[docs/zh-Hans/building.md](docs/zh-Hans/building.md)。

## 贡献与许可

欢迎 Issue 和 PR —— 每个 PR 需要过哪些门禁见 [docs/zh-Hans/CONTRIBUTING.md](docs/zh-Hans/CONTRIBUTING.md)。安全问题请走 [docs/zh-Hans/SECURITY.md](docs/zh-Hans/SECURITY.md)，不要提到公开的 issue 列表里。报 Bug 建议直接用应用内 **设置 → 关于 → 报告问题…**，它会自动附带诊断信息。

MIT（[LICENSE](LICENSE)）—— 覆盖整个仓库，含 Pro-only 模块。
