# 安装与更新

[English](../en/install.md) · **简体中文**

## 安装（DMG）

1. 从 [Releases](https://github.com/Paradox07127/macos-wallpaperengine/releases/latest) 下载对应版本：Lite 为 `Loomscreen-x.y.z.dmg`，Pro 为 `Loomscreen-Pro-x.y.z.dmg`。
2. 打开 DMG，把 **Loomscreen.app** 或 **Loomscreen Pro.app** 拖进 `/Applications`。
3. 启动应用，它常驻菜单栏。Lite 需要 macOS 14.6+，同时提供 Apple Silicon 和 Intel 切片（Intel 真机尚未验证）；Pro 需要 Apple Silicon。

### 如果 macOS 拒绝打开下载的应用

当前公开安装包使用 **Apple Development 签名**，不是 Developer ID 签名，且**尚未公证**。
手动下载的副本可能被 Gatekeeper 拦截。先在同时放有 DMG 与校验文件的目录中，
核对随发布提供的校验和：

```bash
shasum -a 256 -c Loomscreen-x.y.z.dmg.sha256
```

Pro 使用对应的 Pro 文件名。确认下载正确后，如果仍被拦截，可清除已安装应用的隔离标记：

```bash
xattr -dr com.apple.quarantine /Applications/Loomscreen.app
```

Pro：

```bash
xattr -dr com.apple.quarantine "/Applications/Loomscreen Pro.app"
```

然后重新打开。这只适用于可信的手动下载，不是所有启动失败的通用修复。
应用内 Sparkle 更新通常会在安装时处理隔离标记；重新手动下载的副本可能还需要处理。

## 系统权限提示

权限取决于使用的功能和 macOS 已有授权。拒绝可能让对应功能不可用，不需要为此开启其他功能。

| 权限 | 用途 |
|---|---|
| 文件与文件夹 / 选定目录 | 导入媒体、本地网页、场景，或授权 Steam 库；书签记住所选访问范围 |
| 位置 | 系统定位模式下的天气组件和天气联动；可改用手动位置或关闭 |
| 系统音频录制（Pro） | 为场景与音乐视觉效果提供音频响应；Lite 不捕获系统音频 |
| 自动化：Spotify / Music | 正在播放的控制、跳转与缺失播放位置的读取；首次执行时 macOS 可能询问 |
| 钥匙串访问 | 保存/读取 Steam Web API key；签名变化或已有条目可能需要批准 |

## 首次启动引导

选择**导入文件**、**Apple Aerials**，或拖入支持的文件/项目。多屏时选择一台或所有显示器。
可以跳过引导，之后从设置配置显示器，也可以从**关于 → 欢迎导览**重新打开。
创意工坊配置独立进行，见[快速上手](quick-start.md#8创意工坊配置pro)。

## 更新

两个版本使用 **Sparkle**，各自读取对应的 HTTPS appcast。
Sparkle 检查更新并可显示更新窗口。菜单栏的更新按钮与**设置 → 关于**也提供更新入口；
Sparkle 可以下载、验证更新包签名、安装并重新启动应用。

**设置 → 通用**控制自动检查，关于页仍可手动检查。下载、安装、跳过等选择由 Sparkle
窗口处理；当前更新会话保留时，菜单栏标记可能仍在。
更新不再只是打开 GitHub 发布页；开启检查本身不代表同意安装。

也可以下载对应版本 DMG 手动替换。启动、权限或更新问题见[故障排查](troubleshooting.md)。
