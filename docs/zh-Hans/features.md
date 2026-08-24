# 功能指南

[English](../en/features.md) · **简体中文**

从用户可见功能到其实现的权威对照。想要按任务走的教程，请看
[quick-start.md](quick-start.md)。

能力开关的真值源：[`ProductCapabilities.swift`](../../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift)。

## 0）应用界面

- **菜单栏**（`LiveWallpaper/Views/MenuBarContent.swift`）
  - 快速添加壁纸、总开关。
  - 总开关左边的 **Update** 按钮，只在有新版本时出现。
  - 每台显示器一行：状态、播放/暂停、上一张/下一张（播放列表模式）、音量。
  - 实时占用条（CPU / GPU / 内存 / 温度压力）。
  - 管理、通用设置、全部重新加载、退出。
- **设置窗口**（`LiveWallpaper/Views/ContentView.swift`、`LiveWallpaper/Views/Settings/Navigation.swift`）
  - 侧栏：每台显示器的页面、书签、Apple Aerials、Steam 创意工坊（Pro）。
  - 设置页——是否可用取决于 SKU：

| 页 | 版本 | 内容 |
|---|---|---|
| 通用 | 两者 | 语言、开机启动、锁屏帧捕获、Dock 显示 |
| 显示器默认值 | 两者 | 默认静音/音量、帧率上限、适配模式、色彩空间、网页交互 |
| 性能 | 两者 | 暂停规则、App 例外、内存预载预算；**Pro 另有**自适应帧率与每显示器渲染线程 |
| 音频响应 | Pro | 为音频联动场景采集系统音频 |
| 天气 | 两者 | 关闭 / 系统定位 / 手动位置，用于天气联动叠加层 |
| 快捷键 | 两者 | 总开关 + 七个可绑定的全局快捷键 |
| 存储 | Pro | 已下载工程、引擎资源、缓存 |
| 备份与恢复 | 两者 | `.lwconfig` 导出 / 导入 |
| 创意工坊 | Pro | API key、SteamCMD 诊断、引擎资源更新、内容过滤 |
| 高级 | 两者 | 诊断导出、问题报告、日志文件夹 |
| 关于 | 两者 | 版本、链接、欢迎导览、更新横幅 |

## 1）壁纸类型

`WallpaperType`（`Packages/LiveWallpaperCore/.../Schema/WallpaperType.swift`）只有
三种：视频、HTML、场景。Apple Aerials 是以视频源的形式应用的。

### 视频（两个版本）

- 格式：`mp4`、`m4v`、`mov`、`avi`（`Schema/../Persistence/ResourceUtilities.swift`）。
- 适配模式 填充 / 适应 / 拉伸；帧率上限 15/24/30/60/不限。
- 色彩空间：自动、sRGB、Display P3、Rec. 2020 HDR、强制 SDR（`Schema/VideoColorSpace.swift`）。
- 每台显示器独立播放，或一段视频跨所有显示器铺满（`Schema/VideoDisplayMode.swift`）。
- 每屏的内存预载预算，用于平滑循环。

### 网页（两个版本）

`Schema/HTMLConfig.swift` —— 每台显示器可配：JavaScript 开关、鼠标交互、
跟踪器拦截、自定义 CSS、静音/音量、自动刷新间隔、缩放/平移/旋转变换、
Retina 物理像素布局、临时存储（创意工坊导入强制开启）、CSP 强制、激进挂起。

### Apple Aerials（两个版本）

`LiveWallpaper/Infrastructure/Platform/AppleAerialsLibrary.swift` 扫描 macOS 已经
下载好的航拍视频；可在侧栏的库里浏览、搜索并应用。

### Wallpaper Engine 场景（Pro）

- WPE `scene.pkg` 工程的原生 Metal 渲染器：分层场景、粒子系统、puppet-warp 动画、SceneScript、文字图层、音频联动与光标特效。场景内部的 GLSL 特效在载入时转译为 Metal（`LiveWallpaper/Runtime/Metal/WPEShaderTranspiler*.swift`）——着色器属于场景渲染的一部分，不是单独一种壁纸类型。
- 来源：本地工程文件夹（就地读取）或 Steam 创意工坊下载。
- 场景专有控制项：适配模式（含居中）、光标视差、点击交互。
- 需要 Windows 可执行文件的工程在导入时会被跳过。

#### 场景预设（Pro）

一个预设就是一组具名的 `project.json` 属性值，绑定在某一张基础壁纸上
（`Schema/ScenePreset.swift`）。从创意工坊下载的预设条目和"保存我当前的参数"是
*同一个*对象，正因如此，下载来的预设也能像本地预设一样被重命名、重新保存和导出。

- **以图层方式应用，从不烘进去**：场景默认值 → 预设 → 你按显示器的增量改动。所以"重置为预设"就是把增量丢掉而已。
- 预设里还带着 Wallpaper Engine 自己的按壁纸应用级设置，这些**不是** `project.json` 属性，因此不在壁纸的 schema 里：
  - **色彩校正**（`wec_e` 启用开关，加上亮度 / 对比度 / 饱和度 / 色相，量程 0–100，50 为中性）会变成一个全帧后处理 pass；值为中性时整个 pass 被跳过 —— `Schema/WPEEngineColorCorrection.swift`、`Runtime/Metal/WPEMetalRenderExecutor+Present.swift`。中性点和启用开关是从真实发布的预设里定出来的；传递曲线则对齐了本应用自己的视频色彩控制，而不是与 Wallpaper Engine 逐位一致。
  - **音量**（0–100）会变成一个增益，与你的主音量**相乘**而不是替换它 —— `Schema/WPEEngineAudioSettings.swift`。

  两者读的都是预设快照而非合并后的映射表，所以一张声明了自己名为 `volume` 属性的壁纸没法驱动引擎设置。
- 界面：场景设置卡片里的**预设**那一行（`LiveWallpaper/Views/ScreenDetail/ScenePresetBar.swift`）——选择器分为*你保存的*与*来自创意工坊*两组，另有保存 / 重命名 / 删除。创意工坊的壁纸页会列出为该壁纸发布的预设（`LiveWallpaper/Views/Workshop/DetailPresetsSection.swift`）；列出它们需要 Steam Web API key，下载则需要 SteamCMD。

## 2）播放与自动化

- **播放列表**（`LiveWallpaper/Views/Playlist/PlaylistSection.swift`、`LiveWallpaper/Policies/PlaylistPolicy.swift`）—— 拖拽排序、随机、1–1440 分钟轮换、应用到一台或所有显示器。
- **计划**（`LiveWallpaper/Views/ScheduleSection/`、`LiveWallpaper/Policies/SchedulePolicy.swift`）—— 带预设时段、冲突检测、回落到主壁纸。
- **协调器**（`LiveWallpaper/Policies/WallpaperAutomationCoordinator.swift`）—— 单个 60 秒 tick，只在确实有显示器启用了自动化时才运行；锁屏/休眠期间完全停止，唤醒后只对齐一次。
- **书签**（`Schema/WallpaperBookmark.swift`、`LiveWallpaper/App/ScreenManager+Bookmarks.swift`）—— 快照内容加播放/叠加层状态。监控面板的布局刻意保持按显示器独立，不进书签。
- **导入路由**（`LiveWallpaper/Infrastructure/Assets/WallpaperImportRouter.swift`）—— 工具栏选择器、拖放和引导流程背后共用一个分类器：视频 / 场景工程 / 场景库 / html / 不支持。

## 3）叠加层

所有叠加层都与渲染器无关——它们同样能叠在视频、网页和场景壁纸上。

- **粒子**（`Schema/ParticleEffect.swift`）—— 雪、雨、散景、萤火虫、尘埃、星星、落叶、樱花。
- **天气联动**（`LiveWallpaper/Runtime/WeatherReactiveService.swift`）—— 每小时的 Open-Meteo 天气状况映射到粒子特效与视频调整（饱和度、亮度、色温……）。位置来源：关闭 / 系统 / 手动。
- **监控面板**（`LiveWallpaper/Monitor/`）—— 按显示器独立，可置于桌面层（点击穿透）或始终置顶。组件：CPU、内存、GPU、网络、磁盘、电源、进程、Agent 会话（跟踪本机的 Claude Code / Codex CLI 会话）、ANE 内存。完全被遮挡或用户离开时自动挂起。
- **音乐播放**（`LiveWallpaper/Monitor/NowPlaying/`、`LiveWallpaper/Monitor/Widgets/NowPlaying*`）—— 显示 Spotify 或 Apple Music 正在播放的曲目，提供海报、黑胶、极光三种样式，强调色取自封面；开启音频响应后还有五种随音乐起伏的特效。它是独立的叠加层，开关与位置都与监控面板分开（九宫格锚点，或在预览里直接拖动），没有音乐播放时整层消失。
  - **曲目信息来源：**播放器自己广播的 `DistributedNotificationCenter` 通知。不轮询、不装辅助进程、不用 Media Remote 私有 API。
  - **播放控件**在悬停时出现，通过 Apple Events 控制播放器；macOS 会在首次使用时弹出「自动化」授权，拒绝授权只会让按钮失效，不影响其他功能。
  - **歌词**（可选）来自公开的 LRCLIB 服务，按艺人／标题／专辑匹配。Spotify 会广播播放位置，所以歌词逐行跟随；Apple Music 不广播位置，歌词固定停在开头。
  - **网络约束：**封面与歌词只走固定白名单主机（`open.spotify.com`、`itunes.apple.com`、`lrclib.net` 以及 Spotify／Apple 的封面 CDN）的 HTTPS，边下边计字节上限，跳转到白名单之外一律拒绝；命中与未命中分别有 LRU 缓存和带 TTL 的负缓存（`NowPlayingNetwork.swift`）。

## 4）性能模型

`LiveWallpaper/Policies/WallpaperPolicyEngine.swift` 把**安全挂起**（用户不在、内存压力
达到 critical、过热达到 critical——不可覆盖）与**可选挂起**（全屏、窗口遮挡 ≥85%、电池、
低电量模式、按 App 规则）分开。中度发热（serious）对场景与网页壁纸只会**降低帧率**
而不是停掉,内存 warning 则只降场景的帧率——繁忙场景在正常使用时本来就常年停在这些
档位附近。视频没有可降的帧率旋钮,降档等于空操作,所以中度发热仍会挂起视频。

- **App 例外**（`Schema/ApplicationPerformanceRule.swift`）—— 每个 App 三种触发方式：位于最前时暂停、运行期间暂停，或**从不暂停**（只否决可选挂起）。游戏也走这条路：全屏检测能抓住大多数，剩下的用一条显式规则覆盖。
- **任何挂起都不会改写你的播放意图**——意图由每屏一台的状态机统一持有
  （`LiveWallpaperCore … WallpaperPlaybackStateMachine.swift`），只有播放/暂停操作能写入。
  条件解除后壁纸一定自行恢复，播放键也不可能把壁纸卡死。
- 系统规则压住壁纸时，菜单栏和该屏详情页会写明**是哪条规则**（电池、全屏、过热……）。
- 手动暂停会保留最后一帧画面，5 分钟后释放解码器与缓存——视频、网页、场景三类壁纸
  的时刻一致。
- Pro 另有遮挡时的自适应帧率与每显示器渲染线程。

## 5）多显示器

- 每台显示器独立配置（`LiveWallpaper/App/ScreenManager+Screens.swift`）。
- 把一台显示器的配置复制到全部；把一段视频跨所有显示器铺满。
- 侧栏的显示器顺序会持久化（`LiveWallpaper/Models/SidebarDisplayOrder.swift`）。

## 6）创意工坊（Pro）

- **SteamConnector**（`SteamConnector/`）—— XPC 辅助进程，串行运行 SteamCMD，校验其代码签名与 SHA-256，发现已缓存的 Steam 登录，并用你的账号下载创意工坊条目。
- **SteamCMD 托管安装**（`Workshop/SteamCMDManagedInstallCoordinator.swift`）—— 应用只负责发起，实际工作全在 connector 里：拉取 Valve 的包清单、下载每个包、SHA-256 与清单对不上就拒绝、解包到暂存目录，只有当装好的二进制的代码签名与团队标识确实是 Valve 的才保留。任何一步失败都回滚到此前已安装的状态。这是**增量能力**——包管理器探测和手动指定的二进制都不受影响，而且所有运行路径都过同一套信任门。
- **在线浏览**（`LiveWallpaper/Infrastructure/Workshop/WorkshopQueryService.swift`）—— Steam Web API 查询，带分页、缓存、限流、作者解析；设置里有成人内容模糊与内容过滤。
- **引擎资源**（`LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsInstaller.swift`）—— 通过 SteamCMD 一次性下载 Wallpaper Engine 的共享资源，并按 build ID 检查更新。
- **诊断**（`LiveWallpaper/Infrastructure/Workshop/Doctor/`）—— 对整条链路的引导式配置与诊断。

## 7）更新（两个版本）

`LiveWallpaper/Infrastructure/Services/SparkleUpdaterController.swift` —— 检查、
下载与安装都交给 Sparkle。更新包会用固定在各版本 `Info.plist` 里的 ed25519 公钥验签，
没有用发布密钥签过的更新一律拒绝；feed 只走 HTTPS。

后台检查刻意保持安静。Sparkle 默认一发现新版就弹对话框，而这会打断正在全屏播放的壁纸；
gentle-reminder 委托把那个对话框压掉，改成点亮菜单栏的 **Update** 按钮。点它才把控制权
交给 Sparkle 自己的安装界面。自动检查可以在**设置 → 通用**里关掉，**设置 → 关于**的
横幅显示同一份状态并提供手动检查。

因为应用处于沙盒中，它无法替换自己的 bundle：Sparkle 通过一个跑在沙盒外的 XPC 服务
完成安装，这正是 `SUEnableInstallerLauncherService` 和 `-spks`/`-spki` 两条 mach-lookup
授权的用途。两个版本各有自己的 appcast（`appcast-pro.xml`、`appcast-lite.xml`），
发版时由 `scripts/generate-appcast.sh` 重新生成——因为它们是两个独立的 DMG，
一条 enclosure 只能指向其中一个。Sparkle 按 `CFBundleVersion` 排序，两份
plist 都把它设成 `MARKETING_VERSION`。打包时会重签 Sparkle 嵌套的安装
helper，让它们和主程序共用同一个 Team ID。

## 8）安全与隐私

- 无遥测，无账号。
- 创意工坊 API key 存放在 Loomscreen 沙盒的 Application Support 目录里，权限仅属主可读。
  Loomscreen 不会主动同步它；Mac 常规的备份与迁移行为仍属系统策略范畴。
- 网页壁纸在沙盒上下文中渲染；跟踪器拦截与 CSP 强制为可选项。
- 文件访问使用 security-scoped bookmark；权限提示清单见
  [install.md](install.md#系统权限提示)。

## 9）代码入口

- 能力开关：`Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift`
- 屏幕编排：`LiveWallpaper/App/ScreenManager.swift`（扩展在 `LiveWallpaper/App/` 下）
- 策略（暂停/播放列表/计划）：`LiveWallpaper/Policies/`
- 显示器详情界面：`LiveWallpaper/Views/ScreenDetail*`
- 菜单栏：`LiveWallpaper/Views/MenuBarContent.swift`
- 设置：`LiveWallpaper/Views/Settings/`
- WPE 运行时：`LiveWallpaper/Runtime/`（Metal 渲染器、场景运行时）
- 创意工坊栈：`LiveWallpaper/Infrastructure/Workshop/`、`SteamConnector/`
