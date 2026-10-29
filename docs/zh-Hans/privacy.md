# 隐私政策

[English](../en/privacy.md)

更新日期：2026-10-29

本政策适用于 Loomscreen、Loomscreen Pro 和 Mac App Store 版 Loomscreen。

## 概要

- Loomscreen 没有账号，没有广告，不含第三方统计或追踪 SDK。
- 壁纸库、设置和壁纸文件都留在你的 Mac 上。
- 只有在你使用某项功能时，app 才会访问网络服务，并且只发送该功能需要的数据。

## 留在本机的数据

- 壁纸库、播放列表、日程和显示器设置。
- 你选择的文件夹的访问权限，以 macOS 安全书签保存。
- Pro：Steam Web API key，保存在 macOS 钥匙串里。
- Pro 的音频响应：系统音频在本机分析，不录制、不保存、不上传。

## 会访问网络的功能

| 功能 | 服务 | 发送的内容 |
|---|---|---|
| 天气效果（位置选“系统”或“手动”） | Open-Meteo | 精确到约 1 公里的经纬度；手动模式使用所选城市的坐标 |
| 正在播放的封面 | iTunes Search API、Spotify oEmbed | 曲名、艺人和专辑，或 Spotify 曲目链接 |
| 正在播放的歌词（默认关闭） | LRCLIB | 曲名、艺人、专辑和时长 |
| 网页壁纸 | 你添加的网站 | 网页自身发出的普通请求 |
| 创意工坊（Pro） | Steam | 搜索词、条目 ID 和你的 API key |
| 检查更新（DMG 版） | Loomscreen 更新源 | 版本类型和版本号；打开"共享匿名硬件信息"后，另含 Mac 型号、CPU、内存、macOS 版本、显示器数量和分辨率档位 |

更新源按版本类型和版本号统计检查次数，不保存 IP 地址。Mac App Store 版不使用这个更新源，由 App Store 负责更新。

位置权限只用于天气。你也可以手动选择城市，或者关闭天气。

Open-Meteo 会收到请求的 IP 地址，并可能按其[隐私条款](https://open-meteo.com/en/terms)保留含坐标的请求日志最多 90 天。手动城市搜索会向 Apple 地图发送搜索文字。

## Mac App Store 版

商店版不请求音乐封面或歌词，不访问创意工坊，不采集系统音频，也不通过 Sparkle 检查更新。可选联网功能是天气和你选择的网页。设置与文件权限和 DMG 两版分开保存。

## 报告问题

**报告问题** 先在 App 内提供诊断预览。继续操作会在浏览器打开预填的 GitHub issue，并将预填文字发送给 GitHub；只有在 GitHub 提交后，issue 才会公开。本地日志不会自动上传，是否附加由你决定。

## 数据的保留与删除

- Loomscreen 没有服务器端副本。本机数据一直保留，直到你删除。
- **设置 › 高级 › 重置所有设置** 清除壁纸库、设置和文件夹访问权限，不删除磁盘上的壁纸文件。
- 删除 app 及其容器会移除它保存的全部内容。Pro：在 app 内移除 Steam Web API key，或在"钥匙串访问"里删除。
- 要停止使用位置：关闭天气、改为手动选择城市，或在 系统设置 › 隐私与安全性 › 定位服务 里关闭 Loomscreen。
- 你提交的 GitHub issue 可以在 GitHub 上编辑或删除。需要协助删除时，在 GitHub 提交 issue 或联系维护者。

## 儿童

Loomscreen 不询问年龄，也不创建儿童档案。可选联网功能遵循上面的数据处理方式。

## 变更

本政策的变更会发布在这个文件里，并更新顶部的日期。

## 联系方式

在 [GitHub Issues](https://github.com/Paradox07127/macos-wallpaperengine/issues) 提交 issue。
