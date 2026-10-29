# Mac App Store 发布

[English](../en/app-store.md) · **简体中文**

`LoomscreenAppStore` target 是独立的 Lite 子集，身份为
`com.loomscreen.appstore`；不复用或更改 DMG 两版的标识。三个版本由共享源码和
`Config/*.xcconfig` 维护，见[版本对照](lite-vs-pro.md#mac-app-store-版)。

## 维护版本边界

- App 源码用 `MAS_BUILD` 排除商店版功能，用 `LITE_BUILD` 排除 Pro 功能。
  Swift 包收不到 App 的编译标志；共享代码通过注入能力区分版本。
- 商店 target 只链接 Core，有独立的 Info.plist、entitlements 和 InfoPlist catalog。
  Sparkle、外部助手和系统壁纸扩展必须留在它的 target membership 与依赖图之外。
- 共享 Localizable catalog 只由 Pro 自动抽取。保留手工管理的版本专用 key，以及
  de、en、es、fr、ja、ko、pt-BR、zh-Hans、zh-Hant 九语。Xcode 构建后检查 catalog 差异；MAS 不生成字符串符号。
- Pro/Lite 的构建版本跟随 `MARKETING_VERSION`，供 Sparkle 比较；MAS 读取
  `CURRENT_PROJECT_VERSION`，每次上传（包括重传）都要递增。
- Lite 与 MAS 都生成 `Loomscreen.app`。使用独立 DerivedData/archive 路径，
  测试或打包前先核对 bundle ID。

## 本地预检

改动后运行相关 App 测试及共享集成门禁。商店产物检查不运行 Pro 着色器流水线：

```sh
make verify
DERIVED_DATA="$(mktemp -d -t LoomscreenMAS)" \
  bash scripts/release_candidate_check.sh --appstore
```

归档保留在该目录。可用 `ARCHIVE_PATH` 指定仓库外尚不存在的绝对 `.xcarchive`
路径；`--appstore` 后的额外参数传给 `xcodebuild archive`，供签名机器配置。
脚本先检查源码权限和本地化，再归档 universal Release，并用
`scripts/check_appstore_bundle.py` 检查真实签名包：架构、签名有效性、权限基线、
已知禁用 API/端点/组件、九语编译资源和隐私清单。
这是有限范围的本地审计，不能替代完整私有 API 检测或苹果审核。

## 分发与苹果校验

1. 在 App Store Connect 创建 `com.loomscreen.appstore` 的 macOS 记录，
   配置团队的 Mac App Store 分发签名和描述文件。
2. 在 Xcode Organizer 使用 App Store Connect 分发流程导出，或用
   `xcodebuild -exportArchive`（`method=app-store-connect`、`destination=export`）。
   使用团队实际的证书与描述文件。
3. 对导出 App 再运行
   `python3 scripts/check_appstore_bundle.py /path/to/Loomscreen.app --require-distribution`。
   Development 或 ad-hoc 签名归档只能作为本地验证证据。
4. 运行 Organizer 的 **Validate App** 或经认证的 `xcrun altool --validate-app`，
   保存校验收据。本地构建不能证明苹果服务端检查通过。
5. 核对版本/构建号、元数据、隐私答案和截图都对应商店版后再上传，
   并通过 TestFlight 验证处理后的构建。

## 本地化提交文案

商店文案的版本源是 [release/app-store/metadata.json](../../release/app-store/metadata.json)，
包含九种语言。App 资源使用 `de`、`fr`，Connect 使用 `de-DE`、`fr-FR`；
巴西葡语两边均为 `pt-BR`。三个版本共用 App 与 provider 的翻译目录，
各 Target 保留自己的权限目录和产品名称。系统权限提示遵循 macOS 为 App 选择的语言；
App 内语言选择器影响 App 文案，不会改写已显示的系统提示。

复制到 Connect 前运行 `python3 scripts/check_appstore_metadata.py`，检查语言集合、
必填文本、字符上限和关键词 UTF-8 字节数。
[审核备注](../../release/app-store/review-notes.txt)在设备、TestFlight 和联系信息补齐前仍为草稿。
截图、公开 URL 和账号字段须另行做最终提交检查。此目录不会自动上传内容。

## 提交清单

- 验证首次启动、菜单栏重开/退出、视频与本地/远程网页导入、应用/暂停/清除、
  重启后文件授权、配置导入导出、计划/播放列表、显示器重连，以及定位拒绝和手动城市下的天气。
  最低支持的 macOS 与真实 Intel Mac 需要单独验收。
- 截图使用商店构建及有权分发的媒体。苹果目前接受无透明通道的 Mac 截图尺寸：
  1280×800、1440×900、2560×1600、2880×1800。不要宣传此版本已删除的功能。
- App 内和 Connect 填写可访问的隐私政策 URL，说明可选天气请求、外部网页和用户提交的支持报告。
  Open-Meteo 政策允许保留含坐标的请求日志最多 90 天；不能宣称天气坐标不离开设备或绝不保留。
- App Privacy 按实际数据流填写；manifest 的定位声明不会自动填写 Connect。
  不使用跟踪或账户标识。商业化方案变化时重新核对天气服务许可。
- 年龄分级问卷须如实反映 URL 输入能力。用户可选择任意网站作为网页壁纸，应按真实能力评估 Unrestricted Web Access，不能默认填 4+；实际分级由苹果根据答案计算。
- 审核备注说明菜单栏形态、公开桌面层窗口、用户自己的文件/URL、WebKit、可选天气和 GitHub 支持。
  无需登录。支持仓库名称是历史命名，并不在此构建启用场景渲染或下载。

苹果当前资料：[审核指南](https://developer.apple.com/app-store/review/guidelines/)、
[App Privacy](https://developer.apple.com/app-store/app-privacy-details/)、
[截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)。
天气服务：[Open-Meteo 条款](https://open-meteo.com/en/terms)。
