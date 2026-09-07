# Security Policy

**English** · [简体中文](zh-Hans/SECURITY.md)

## Reporting a vulnerability

Report privately through [GitHub Security Advisories](https://github.com/Paradox07127/macos-wallpaperengine/security/advisories/new).
Include the version, edition, reproduction steps and impact. Do not put secrets
or private media in a public issue. Only the latest `0.x` release receives fixes;
there are no backports to earlier minor versions.

## Data and network access

- **No Loomscreen account or usage telemetry.** Optional features still make
  network requests: Steam queries/downloads, weather, artwork/lyrics and updates.
  Remote web wallpapers can communicate with their own sites.
- **Steam Web API keys** are newly saved to the login Keychain. Older
  owner-only Application Support files migrate after a verified Keychain write;
  the legacy file can remain usable if migration is refused. Keys are not
  included in configuration exports.
- **Steam sign-in** can happen in the app, including Steam Guard. Credentials
  pass through the connector to SteamCMD's terminal input; Loomscreen does not
  save the password/Guard code or put them in command arguments or logs.
  SteamCMD maintains cached login state in its per-account profile.
- **File access** uses selected folders and security-scoped bookmarks for media,
  project/dependency roots and the Steam library. The app also has platform
  permissions for enabled features; it is not limited to reading one wallpaper.
- **Music** uses Spotify/Apple Music notifications and Apple Events for control
  and playhead reads. Artwork and optional lyrics have HTTPS host allowlists,
  size limits and caches. Lyrics are off by default.
- **Agent Session** reads local session records for status. Diagnostic exports
  are generated locally and redacted; review them before sharing.

## Process and content boundaries

The main app is sandboxed. Pro's **SteamConnector XPC service is unsandboxed**
so it can run SteamCMD against the authorized Steam library. The tool is
verified at execution; managed installation also checks package hashes against
Valve's manifest. Before importing a reported download, the app revalidates the
requested item inside the authorized library.

Workshop content is third-party input: scenes contain shaders and SceneScript,
and web projects run in WKWebView. Parser/runtime limits, file-root checks and
web policies reduce risk, but do not constitute an audit of every project.
Workshop web imports force ephemeral storage and network isolation; that
storage statement applies to web content, not all scene execution.

System audio capture is Pro-only and subject to TCC. Now Playing Automation
access is limited to Spotify and Music. System Wallpaper uses a separate,
version-sensitive provider with private integration bridges and compatibility
guards; it is not a general public wallpaper API.

## Distribution and updates

Public DMGs use **Apple Development signing**, not Developer ID signing, and
are **not notarized**. A trusted manually downloaded app may need quarantine
cleared; verify its published `.dmg.sha256` first. See [Install](en/install.md).
A checksum verifies the downloaded bytes against the published value; it does
not replace trust in the publisher.

Sparkle reads separate HTTPS appcasts for Lite and Pro and verifies update
payloads against each app's pinned Ed25519 public key. Its installer services
handle replacing the sandboxed app. Do not bypass a signature failure.
