# Lite 与 Pro

[English](../en/lite-vs-pro.md) · **简体中文**

两个版本出自同一份代码。区别在于**哪些渲染器和工具会被打包进去**，而不是给你哪套界面——
Lite 是轻量运行时，不是被阉割的界面。视频 / 网页 / Apple Aerials 的保真度完全一致。

| 能力 | Lite | Pro |
|---|:---:|:---:|
| 视频壁纸（含 HDR 色彩链路、跨屏铺满） | ✅ | ✅ |
| 网页壁纸（JS 开关、跟踪器拦截、自定义 CSS、自动刷新） | ✅ | ✅ |
| Apple Aerials | ✅ | ✅ |
| 每台显示器独立壁纸、一键复制到全部 | ✅ | ✅ |
| 播放列表、随机、轮换 | ✅ | ✅ |
| 时段计划自动化 | ✅ | ✅ |
| 书签 | ✅ | ✅ |
| 粒子与天气联动叠加层 | ✅ | ✅ |
| 系统监控叠加面板 | ✅ | ✅ |
| 全局快捷键 | ✅ | ✅ |
| 锁屏时截取视频帧作为桌面图片 | ✅ | ✅ |
| 全屏 / 遮挡 / 电池 / 低电量模式自动暂停 | ✅ | ✅ |
| 更新检查（仅提示，从不自动安装） | ✅ | ✅ |
| **Wallpaper Engine 场景渲染**（Metal） | — | ✅ |
| **场景工程导入**（链接本地文件夹，就地读取） | — | ✅ |
| **Steam 创意工坊浏览与下载** | — | ✅ |
| **场景预设**（创意工坊预设 + 你自己保存的参数） | — | ✅ |
| **音频联动场景**（系统音频采集） | — | ✅ |
| **遮挡时自适应帧率** | — | ✅ |
| **每显示器独立渲染线程** | — | ✅ |
| **存储管理**（工程、引擎资源、缓存） | — | ✅ |
| **可在 Intel Mac 上运行** | ⚠️ 未测试 | — |

## 这个划分是怎么实现的

Pro 独有的代码用 `#if !LITE_BUILD` 圈起来。Lite 的 scheme（`LiveWallpaperLite`）
设置了 `LITE_BUILD` 编译条件，所以整个 Wallpaper Engine 渲染器、场景运行时和创意工坊栈
根本不会被编译进 Lite 二进制——不是"藏起来"而已。Metal 着色器特效只存在于场景渲染*内部*
（GLSL 在载入时转译为 Metal），所以它属于场景能力的一部分，不是单独一条。

一个版本对外暴露什么，运行时的真值源是
[`ProductCapabilities.swift`](../../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift)。

GitHub Releases 更新检查两个版本都跑。它比对的是 release 的 tag 而不是 asset 名，
所以同时挂着两个 DMG 的那一个 release 能服务两边。两个版本都不会安装任何东西——
横幅只会打开 release 页面。

## 架构

Lite 以 universal 二进制（arm64 + x86_64）分发，因此可以在能升到 macOS 14.6 的
Intel Mac 上运行。**Intel 切片从未在 Intel 硬件上测试过** —— 它能编译链接，硬件采样
那几条路径（SMC 传感器键、`IOAccelerator` 的 GPU 统计、`hw.perflevel*` 核簇）也都带
Intel 兜底，但没有人在真的 Intel Mac 上跑过。真出问题时，最可能的表现是监视器面板上
读数为空，而不是崩溃。欢迎反馈。

Pro 只有 arm64。它的 Metal 场景渲染器从未在 Intel GPU 上跑过；发一个未经测试的渲染器，
和发一个未经测试的小组件是两个量级的风险。

## 许可

- **Lite** 是 MIT，在 GitHub Releases 分发。
- **Pro** 是完整版。MIT [`LICENSE`](../../LICENSE) 覆盖整个仓库，包括 Pro 独有的模块。
