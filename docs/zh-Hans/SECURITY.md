# 安全策略

[English](../SECURITY.md) · **简体中文**

## 报告漏洞

请通过
[GitHub Security Advisories](https://github.com/Paradox07127/macos-wallpaperengine/security/advisories/new)
私下报告。请不要为漏洞开公开 issue。

有用的信息包括：受影响的版本（**设置 → 关于**）、是 Lite 还是 Pro 构建、复现步骤，
以及攻击者能借此拿到什么。

## 受支持的版本

Loomscreen 还在 `0.x` 线上，只有最新发布版会收到修复。不会向更早的 `0.y` 版本回移。

## 应用如何处理你的数据

- **无账号，无遥测。** 关于你使用情况的任何信息都不会离开这台机器。
- **Steam Web API key** —— 存在 Loomscreen 沙盒的 Application Support 目录里，权限
  仅属主可读，只用于创意工坊查询。Loomscreen 不会主动同步它；Mac 常规的备份与迁移
  行为对该目录仍然适用。
- **Steam 凭据** —— Loomscreen 从不经手。下载走 Valve 的 SteamCMD，用它自己缓存的登录。
- **文件访问** —— 只对你挑选的壁纸文件使用 security-scoped bookmark，仅此而已。
- **网页壁纸** —— 在沙盒上下文中渲染，可选跟踪器拦截与 CSP 强制，创意工坊导入强制
  使用临时存储。

## 值得知道的信任边界

- **构建是 ad-hoc 签名的。** 目前没有付费的 Apple Developer ID，所以 Gatekeeper 会隔离
  这个应用，需要你用 `xattr` 清除一次。这一步意味着你在信任下载本身——运行前请用随包
  发布的 `.dmg.sha256` 校验。
- **SteamCMD 是被验证的，不是被信任的。** 无论它是 Loomscreen 装的、自动探测到的，
  还是你自己指定的，它的代码签名与团队标识在**每次运行**时都会被检查；托管下载还会
  额外与 Valve 清单里的 SHA-256 对校。
- **创意工坊内容是第三方代码。** 场景带有 GLSL，会被转译并在你的 GPU 上执行；创意工坊
  的 HTML 导入会在 web view 里运行。它们跑在应用沙盒内、使用临时存储，但没有经过审计。
