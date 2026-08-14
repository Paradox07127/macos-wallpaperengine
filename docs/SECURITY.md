# Security Policy

**English** · [简体中文](zh-Hans/SECURITY.md)

## Reporting a vulnerability

Report privately through
[GitHub Security Advisories](https://github.com/Paradox07127/macos-wallpaperengine/security/advisories/new).
Please don't open a public issue for a vulnerability.

Useful things to include: the affected version (**Settings → About**), whether
it's the Lite or Pro build, reproduction steps, and what an attacker gains.

## Supported versions

Loomscreen is on the `0.x` line and only the latest release gets fixes. There
are no backports to earlier `0.y` versions.

## What the app does with your data

- **No accounts, no telemetry.** Nothing about your usage leaves the machine.
- **Steam Web API key** — stored in Loomscreen's sandboxed Application Support
  directory with owner-only permissions, used only for Workshop queries.
  Loomscreen does not intentionally sync it; ordinary Mac backup and migration
  behavior still applies to that directory.
- **Steam credentials** — never handled by Loomscreen. Downloads run through
  Valve's SteamCMD with its own cached login.
- **File access** — security-scoped bookmarks for the wallpaper files you pick,
  and nothing else.
- **Web wallpapers** — rendered in sandboxed contexts, with optional tracker
  blocking and CSP enforcement, and ephemeral storage forced for Workshop
  imports.

## Trust boundaries worth knowing about

- **The builds are ad-hoc signed.** There is no paid Apple Developer ID, so
  Gatekeeper quarantines the app and you clear it once with `xattr`. That step
  means you are trusting the download itself — verify it against the published
  `.dmg.sha256` before running it.
- **SteamCMD is verified, not trusted.** Whether it was installed by Loomscreen,
  found by auto-detection, or picked by you, its code signature and team
  identifier are checked on every run, and managed downloads are additionally
  checked against the SHA-256 in Valve's manifest.
- **Workshop content is third-party code.** Scenes carry GLSL that is transpiled
  and executed on your GPU, and Workshop HTML imports run in a web view. They run
  inside the app sandbox with ephemeral storage, but they are not audited.
