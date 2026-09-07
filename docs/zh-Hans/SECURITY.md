# 安全策略

[English](../SECURITY.md) · **简体中文**

## 报告漏洞

请通过 [GitHub Security Advisories](https://github.com/Paradox07127/macos-wallpaperengine/security/advisories/new)
私下报告，附版本、Lite/Pro、复现步骤与影响。不要把密钥或私人媒体发到公开 issue。
只有最新 `0.x` 发布版收到修复，不向更早的小版本回移。

## 数据与网络访问

- **无需 Loomscreen 账号，不收集使用遥测。** 可选功能仍产生网络请求：Steam 查询/下载、天气、封面/歌词与更新。远程网页壁纸也可访问自己的站点。
- **Steam Web API key** 新保存到登录钥匙串。旧版仅属主可读的 Application Support 文件在钥匙串写入并确认后迁移；迁移被拒时，旧文件可能继续可用。配置导出不含 key。
- **Steam 登录**可在应用内完成，支持 Steam Guard。凭据经连接器交给 SteamCMD 的终端输入；Loomscreen 不保存密码/Guard code，不把它们放进命令参数或日志。SteamCMD 在逐账号 profile 中维护缓存登录。
- **文件访问**通过用户选定目录和 security-scoped bookmark 授权媒体、项目/依赖与 Steam 库。应用还为启用的功能持有相应平台权限，访问范围不只是一个壁纸文件。
- **音乐**使用 Spotify/Apple Music 通知，并以 Apple Events 控制和读取播放位置；封面与可选歌词有 HTTPS 域名白名单、大小限制和缓存，歌词默认关闭。
- **Agent 会话**读取本地会话记录呈现状态。诊断在本地生成并脱敏，分享前请检查内容。

## 进程与内容边界

主应用处于沙盒中。Pro 的 **SteamConnector XPC 服务不在沙盒中**，用于在授权 Steam 库上
运行 SteamCMD。工具在执行时验证；托管安装还按 Valve manifest 校验下载包 hash。
导入下载结果前，应用按请求项目重新验证授权库内的目录。

创意工坊内容是第三方输入：场景含 shader 与 SceneScript，网页项目运行于 WKWebView。
解析/运行时预算、文件根检查和网页策略降低风险，但不等于每个项目都已审计。
创意工坊网页导入强制临时存储与网络隔离；临时存储指网页，不是所有场景运行时。

系统音频捕获仅 Pro 提供并受 TCC 授权约束。正在播放的自动化访问限于 Spotify 与 Music。
系统壁纸是独立且随系统版本变化的 provider，使用私有集成桥接和兼容性检查，
不是通用的公开壁纸 API。

## 分发与更新

公开 DMG 使用 **Apple Development 签名**，不是 Developer ID 签名，且**尚未公证**。
可信的手动下载可能需要清除隔离标记，请先验证发布的 `.dmg.sha256`，见[安装](install.md)。
校验和证明下载内容与发布值相符，不能替代对发布者的信任。

Sparkle 分别读取 Lite/Pro 的 HTTPS appcast，按应用内固定的 Ed25519 公钥验证更新包，
由安装服务替换沙盒应用。不要绕过签名验证失败。
