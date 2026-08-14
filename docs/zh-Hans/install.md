# 安装与更新

[English](../en/install.md) · **简体中文**

## 安装（DMG）

1. 从 [Releases](https://github.com/Paradox07127/macos-wallpaperengine/releases/latest)
   下载最新的 `Loomscreen-x.y.z.dmg`。
2. 打开 DMG，把 **Loomscreen.app** 拖进 `/Applications`。
3. 在终端里**执行一次**，清掉 Gatekeeper 隔离标记：
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. 启动 Loomscreen —— 图标会出现在菜单栏。

### 为什么要 `xattr` 这一步？

Loomscreen 目前没有付费的 Apple Developer ID，所以构建是 **ad-hoc 签名**的。
macOS Gatekeeper 会隔离 ad-hoc 签名的应用并报告为"已损坏"；执行一次
`xattr -dr com.apple.quarantine` 就能清掉这个标记。之后它和其他应用一样正常启动。
（DMG 里的 `READ ME — first launch.txt` 也写了这件事。）

你可以用随包发布的 `.dmg.sha256` 校验下载文件：

```bash
shasum -a 256 -c Loomscreen-x.y.z.dmg.sha256
```

## 系统权限提示

以下每一项，macOS 都只在你第一次用到对应功能时才询问——没有一项是提前索要的，
而且全都是可选的：

| 提示 | 出现时机 | 用途 |
|---|---|---|
| 桌面 / 文稿 / 下载文件夹访问 | 导入放在这些位置的视频、网页或场景时 | Loomscreen 需要从你存放壁纸文件的地方读取；授权通过 security-scoped bookmark 记住。 |
| 位置（使用期间） | 天气来源设为**系统定位**时 | 驱动天气联动叠加层。在 设置 → 天气 里选**手动位置**或**关闭**即可避免。 |
| 系统音频录制（Pro） | 启用**音频响应**时 | 让音频联动的场景能可视化正在播放的声音。Lite 从不索要。 |

## 首次启动引导

首次启动会打开一个简短的引导：

1. 选来源——**导入文件**（视频 / 网页；Pro 还接受场景文件夹）、**Apple Aerials**，或者直接拖放。
2. 多显示器时，可以只应用到一台，也可以选**所有显示器**。
3. 完成——随即打开该显示器的管理页面供你细调。

你可以跳过它，改从设置窗口手动配置显示器，也可以之后从
**设置 → 关于 → 欢迎导览** 重新走一遍。Steam 创意工坊的配置是独立的，
只有在你打开创意工坊页时才出现（见
[quick-start.md](quick-start.md#8创意工坊配置pro)）。

## 更新

两个版本都会在每次启动时查一次 GitHub Releases API，并以 12 小时节流——没有后台轮询。
有新版本时，**设置 → 关于** 里会出现横幅，你也可以在那里**立即检查**或**跳过此版本**。
Lite 和 Pro 发在同一个 release 里，所以横幅打开的是那个 release 页面，由你挑自己在用的
那个 DMG。

更新方式是手动下载替换：把新的 **Loomscreen.app** 拖进 `/Applications`，
再执行一次 `xattr` 那一步。没有任何构建会自动安装更新。

## 出问题了？

见 [troubleshooting.md](troubleshooting.md) —— 它覆盖了"应用已损坏"提示、
壁纸空白、暂停行为和创意工坊相关的问题。
