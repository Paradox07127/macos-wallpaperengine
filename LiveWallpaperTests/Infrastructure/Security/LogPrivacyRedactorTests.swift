import Testing
import Foundation
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("LogPrivacyRedactor: regex branches")
struct LogPrivacyRedactorTests {

    @Test("Collapses another user's absolute path to its leaf")
    func redactsHomeDirectorySegment() {
        let scrubbed = LogPrivacyRedactor.scrub("Failed to read /Users/alice/Movies/Sunset.mp4")
        #expect(scrubbed.contains("<path>/Sunset.mp4"))
        #expect(!scrubbed.contains("alice"))
        #expect(!scrubbed.contains("Movies"))
    }

    @Test("Replaces HOME prefix when set")
    func redactsHomeEnvironmentPrefix() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard !home.isEmpty else { return }
        let raw = "\(home)/Documents/secret.json"
        let scrubbed = LogPrivacyRedactor.scrub(raw)
        #expect(scrubbed.hasPrefix("~"))
        #expect(!scrubbed.contains(home))
    }

    @Test("Strips URL query strings")
    func redactsURLQuery() {
        let scrubbed = LogPrivacyRedactor.scrub("Fetch https://cdn.x.com/a.mp4?token=abc&lat=37.78 failed")
        #expect(scrubbed.contains("https://cdn.x.com/a.mp4?<query-redacted>"))
        #expect(!scrubbed.contains("token=abc"))
    }

    @Test("Strips custom-scheme nonce and URL fragments")
    func redactsCustomSchemeSecrets() {
        let nonce = LogPrivacyRedactor.scrub(
            "Failed livewallpaper://wallpaper/index.html?n=session-secret"
        )
        #expect(nonce.contains("livewallpaper://wallpaper/index.html?<query-redacted>"))
        #expect(!nonce.contains("session-secret"))

        let fragment = LogPrivacyRedactor.scrub("Redirect app://trusted/callback#access-token")
        #expect(fragment.contains("app://trusted/callback#<fragment-redacted>"))
        #expect(!fragment.contains("access-token"))
    }

    @Test("Collapses mounted and private absolute paths to their leaf")
    func redactsNonHomeAbsolutePaths() {
        let scrubbed = LogPrivacyRedactor.scrub(
            "Copy /Volumes/Studio/ClientX/secret.mov via /private/var/folders/ab/session.json"
        )
        #expect(scrubbed.contains("<path>/secret.mov"))
        #expect(scrubbed.contains("<path>/session.json"))
        #expect(!scrubbed.contains("Studio"))
        #expect(!scrubbed.contains("folders"))
    }

    @Test("Redacts file:// URLs entirely")
    func redactsFileURL() {
        let scrubbed = LogPrivacyRedactor.scrub("Loading file:///Users/bob/wallpaper.mov now")
        #expect(scrubbed.contains("file://<redacted>"))
        #expect(!scrubbed.contains("bob"))
    }

    @Test("Redacts standalone latitude / longitude assignments")
    func redactsLatLonAssignments() {
        let scrubbed = LogPrivacyRedactor.scrub("URLError -1009: lat=37.7749, longitude: -122.4194")
        #expect(scrubbed.contains("lat=<redacted>"))
        #expect(scrubbed.contains("longitude=<redacted>"))
        #expect(!scrubbed.contains("37.7749"))
        #expect(!scrubbed.contains("-122.4194"))
    }

    @Test("Redacts token / api-key / bearer fragments")
    func redactsTokenAndBearer() {
        let scrubbed1 = LogPrivacyRedactor.scrub("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig")
        #expect(scrubbed1.contains("Bearer <redacted>"))
        #expect(!scrubbed1.contains("eyJhbGciOiJIUzI1NiJ9"))

        let scrubbed2 = LogPrivacyRedactor.scrub("Set api_key=AKIA1234567890ABCDEF in header")
        #expect(scrubbed2.contains("api_key=<redacted>"))
        #expect(!scrubbed2.contains("AKIA"))
    }

    @Test("Redacts URL userinfo (user:password@host)")
    func redactsURLUserinfo() {
        let scrubbed = LogPrivacyRedactor.scrub("Connect https://alice:s3cret@cdn.example.com/asset.mp4 now")
        #expect(scrubbed.contains("https://<redacted>@cdn.example.com"))
        #expect(!scrubbed.contains("alice"))
        #expect(!scrubbed.contains("s3cret"))
    }

    @Test("Redacts Basic authorization headers")
    func redactsBasicAuth() {
        let scrubbed = LogPrivacyRedactor.scrub("Authorization: Basic dXNlcjpwYXNzd29yZA==")
        #expect(scrubbed.contains("Basic <redacted>"))
        #expect(!scrubbed.contains("dXNlcjpwYXNzd29yZA"))
    }

    @Test("Preserves non-sensitive content untouched")
    func preservesNonSensitive() {
        let raw = "Decoder downgraded from hardware to software at frame 1024"
        let scrubbed = LogPrivacyRedactor.scrub(raw)
        #expect(scrubbed == raw)
    }

    @Test("Does not leak a username that extends the HOME path")
    func doesNotLeakPrefixExtendingUsername() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard home.hasPrefix("/Users/") else { return }

        let neighbor = home + "xyz/Movies/private.mov"
        let scrubbed = LogPrivacyRedactor.scrub(neighbor)

        #expect(!scrubbed.contains("~"))
        #expect(scrubbed == "<path>/private.mov")
    }

    @Test("Collapses own HOME to ~ at a path boundary")
    func collapsesOwnHomeAtBoundary() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard home.hasPrefix("/Users/") else { return }

        let scrubbed = LogPrivacyRedactor.scrub("\(home)/Library/Logs/runtime.log")
        #expect(scrubbed == "~/Library/Logs/runtime.log")
        #expect(!scrubbed.contains("/Users/"))
    }

    // MARK: - Classes ported from WorkshopDiagnosticRedactor

    @Test("Redacts .local machine hostnames but keeps DNS hosts")
    func redactsLocalHostname() {
        let scrubbed = LogPrivacyRedactor.scrub("Bonjour registered Johns-MacBook-Pro.local on the network")
        #expect(scrubbed.contains("<host-redacted>"))
        #expect(!scrubbed.contains("Johns-MacBook-Pro"))

        let url = LogPrivacyRedactor.scrub("GET https://cdn.example.com/a.mp4 failed")
        #expect(url.contains("cdn.example.com"))
    }

    @Test("Redacts IPv4 addresses")
    func redactsIPv4() {
        let scrubbed = LogPrivacyRedactor.scrub("Connection refused from 192.168.1.20:27036")
        #expect(scrubbed.contains("<ip-redacted>:27036"))
        #expect(!scrubbed.contains("192.168.1.20"))
    }

    @Test("Redacts IPv6 addresses")
    func redactsIPv6() {
        let scrubbed = LogPrivacyRedactor.scrub("Route via fe80:0:0:0:1ff:fe23:4567:890a is down")
        #expect(scrubbed.contains("Route via <ip-redacted> is down"))
        #expect(!scrubbed.contains("fe23"))
    }

    @Test("Redacts compressed IPv6 addresses whole, no prefix remnant")
    func redactsCompressedIPv6() {
        let linkLocal = LogPrivacyRedactor.scrub("Route via fe80::1 is down")
        #expect(linkLocal == "Route via <ip-redacted> is down")

        let short = LogPrivacyRedactor.scrub("Bound to 2001:db8::1 on port 443")
        #expect(short == "Bound to <ip-redacted> on port 443")

        let mixed = LogPrivacyRedactor.scrub("Peer 2001:db8::8a2e:370:7334 timed out")
        #expect(mixed == "Peer <ip-redacted> timed out")
        #expect(!mixed.contains("2001"))
        #expect(!mixed.contains("db8"))
    }

    @Test("Compressed IPv6 rule leaves non-address :: shapes alone")
    func preservesNonAddressDoubleColons() {
        #expect(LogPrivacyRedactor.scrub("Foo::bar") == "Foo::bar")
        #expect(LogPrivacyRedactor.scrub("::") == "::")
        #expect(LogPrivacyRedactor.scrub("range :: endIndex") == "range :: endIndex")

        let metal = "program_source:1198:24: error: use of undeclared identifier 'v'"
        #expect(LogPrivacyRedactor.scrub(metal) == metal)

        let placeholders = "<steamid-redacted> and <ip-redacted> stay put"
        #expect(LogPrivacyRedactor.scrub(placeholders) == placeholders)
    }

    @Test("Redacts SteamID64")
    func redactsSteamID64() {
        let scrubbed = LogPrivacyRedactor.scrub("Resolved owner 76561198012345678 for item 3226487183")
        #expect(scrubbed.contains("owner <steamid-redacted>"))
        #expect(!scrubbed.contains("76561198012345678"))
        #expect(scrubbed.contains("3226487183"))
    }

    @Test("Redacts SteamID3")
    func redactsSteamID3() {
        let scrubbed = LogPrivacyRedactor.scrub("SteamID: [U:1:1267132100] reported by probe")
        #expect(scrubbed.contains("<steamid-redacted>"))
        #expect(!scrubbed.contains("1267132100"))
    }

    @Test("Redacts Steam account and persona names mid-line")
    func redactsSteamAccountNames() {
        let account = LogPrivacyRedactor.scrub("doctor: Account: gaben_at_home ")
        #expect(account.contains("Account: <redacted>"))
        #expect(!account.contains("gaben_at_home"))

        let persona = LogPrivacyRedactor.scrub("probe says Persona Name: 半藏 Hanzo Main and more")
        #expect(persona.contains("Persona Name: <redacted>"))
        #expect(!persona.contains("Hanzo"))

        let banner = LogPrivacyRedactor.scrub("Logging in user 'gaben' [U:1:42] to Steam Public...OK")
        #expect(banner.contains("Logging in user '<redacted>'"))
        #expect(banner.contains("<steamid-redacted>"))
        #expect(!banner.contains("gaben"))

        let query = LogPrivacyRedactor.scrub("cached personaname=GabeN for 76561198012345678")
        #expect(query.contains("personaname=<redacted>"))
        #expect(!query.contains("GabeN"))
    }

    @Test("Redacts ssfn sentry tokens keeping the ssfn marker")
    func redactsSSFNSentryToken() {
        let scrubbed = LogPrivacyRedactor.scrub("removed ssfn1234567890123456789 from container")
        #expect(scrubbed.contains("ssfn<redacted>"))
        #expect(!scrubbed.contains("ssfn1234567890123456789"))
    }

    @Test("New rules do not eat versions, timestamps, or file:line tags")
    func preservesVersionsTimestampsAndLineTags() {
        let raw = "2026-07-07T12:34:56.789Z [WPE] [ERROR] Render.swift:42 — LiveWallpaper 0.2.0 (417) on macOS 15.5.0"
        #expect(LogPrivacyRedactor.scrub(raw) == raw)
    }

    @Test("Four-part dotted quads are redacted by design")
    func redactsFourPartDottedQuads() {
        let scrubbed = LogPrivacyRedactor.scrub("installer 1.2.3.4 finished")
        #expect(scrubbed == "installer <ip-redacted> finished")
    }

    // MARK: - Exact-output pins

    private static let pins: [(input: String, expected: String)] = [
        ("/Users/alice", "<path>/<redacted>"),
        ("open '/Users/dave' now", "open '<path>/<redacted>' now"),
        ("/Volumes/Backup/Users/carol/notes.txt", "<path>/notes.txt"),

        ("Connect https://alice:s3cret@cdn.example.com/asset.mp4 now", "Connect https://<redacted>@cdn.example.com/asset.mp4 now"),
        ("see (https://bob@host.example/x) here", "see (https://<redacted>@host.example/x) here"),
        (#""x://u:p@h/y""#, #""x://<redacted>@h/y""#),
        ("abchttps://user@host/x", "abchttps://<redacted>@host/x"),
        ("1https://user@host/x", "1https://<redacted>@host/x"),
        ("2+ssh://git@example.com/repo", "2+ssh://<redacted>@example.com/repo"),
        ("ftp://user@192.168.1.20/file", "ftp://<redacted>@<ip-redacted>/file"),

        ("Fetch https://cdn.x.com/a.mp4?token=abc&lat=37.78 failed", "Fetch https://cdn.x.com/a.mp4?<query-redacted> failed"),
        ("Failed livewallpaper://wallpaper/index.html?n=session-secret", "Failed livewallpaper://wallpaper/index.html?<query-redacted>"),
        ("https://h.example/p?q=1#frag", "https://h.example/p?<query-redacted>"),
        ("(https://h.example/p?q=1)", "(https://h.example/p?<query-redacted>"),
        ("abchttps://h.example/p?q=1", "abchttps://h.example/p?<query-redacted>"),
        ("1https://h.example/p?q=1", "1https://h.example/p?<query-redacted>"),

        ("Redirect app://trusted/callback#access-token", "Redirect app://trusted/callback#<fragment-redacted>"),
        (#""x://h/p#frag" end"#, #""x://h/p#<fragment-redacted>" end"#),
        ("-https://h/p#f", "-https://h/p#<fragment-redacted>"),
        (".x://h/p#f", ".x://h/p#<fragment-redacted>"),

        ("Loading file:///Users/bob/wallpaper.mov now", "Loading file://<redacted> now"),
        ("(file:///private/var/a.txt)", "(file://<redacted>"),
        ("file://host/share?x=1", "file://<redacted>"),

        ("/Users/alice/Movies/Sunset.mp4", "<path>/Sunset.mp4"),
        ("/Volumes/Studio/ClientX/secret.mov", "<path>/secret.mov"),
        ("/private/var/folders/ab/session.json", "<path>/session.json"),
        ("/tmp/build/out.log", "<path>/out.log"),
        ("/var/log/system.log", "<path>/system.log"),
        ("/home/eve/.config/app.toml", "<path>/app.toml"),
        ("/opt/homebrew/bin/ffmpeg", "<path>/ffmpeg"),
        ("/mnt/data/x.bin", "<path>/x.bin"),
        ("/Applications/LiveWallpaper.app/Contents/MacOS/LiveWallpaper", "<path>/LiveWallpaper"),
        ("GET https://cdn.example.com/tmp/a.mp4 failed", "GET https://cdn.example.com<path>/a.mp4 failed"),
        ("/Library/Caches/x.plist", "/Library/Caches/x.plist"),
        ("~/Library/Logs/runtime.log", "~/Library/Logs/runtime.log"),

        ("URLError -1009: lat=37.7749, longitude: -122.4194", "URLError -1009: lat=<redacted>, longitude=<redacted>"),
        ("Latitude = 12.5", "Latitude=<redacted>"),
        ("Set api_key=AKIA1234567890ABCDEF in header", "Set api_key=<redacted> in header"),
        ("password: hunter2", "password=<redacted>"),
        ("refresh-token=abc&x=1", "refresh-token=<redacted>&x=1"),
        ("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig", "Authorization: Bearer <redacted>"),
        ("Token abc123", "Token <redacted>"),
        ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "Authorization: Basic <redacted>"),

        ("Resolved owner 76561198012345678 for item 3226487183", "Resolved owner <steamid-redacted> for item 3226487183"),
        ("SteamID: [U:1:1267132100] reported by probe", "SteamID: <steamid-redacted> reported by probe"),
        ("Connection refused from 192.168.1.20:27036", "Connection refused from <ip-redacted>:27036"),
        ("Bound to 2001:db8::1 on port 443", "Bound to <ip-redacted> on port 443"),
        ("Route via fe80:0:0:0:1ff:fe23:4567:890a is down", "Route via <ip-redacted> is down"),
        ("Bonjour registered Johns-MacBook-Pro.local on the network", "Bonjour registered <host-redacted> on the network"),
        ("removed ssfn1234567890123456789 from container", "removed ssfn<redacted> from container"),
        ("cached personaname=GabeN for 76561198012345678", "cached personaname=<redacted> for <steamid-redacted>"),
        ("probe says Persona Name: 半藏 Hanzo Main and more", "probe says Persona Name: <redacted>"),
        ("doctor: Account: gaben_at_home ", "doctor: Account: <redacted> "),
        ("Logging in user 'gaben' [U:1:42] to Steam Public...OK", "Logging in user '<redacted>' <steamid-redacted> to Steam Public...OK"),
    ]

    @Test("Each rule produces its pinned output, and scrubbing that output again is a no-op", arguments: pins)
    func pinnedOutput(input: String, expected: String) {
        #expect(LogPrivacyRedactor.scrub(input) == expected)
        #expect(LogPrivacyRedactor.scrub(expected) == expected)
    }

    @Test("Own HOME alone collapses to ~")
    func pinnedBareHome() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard home.hasPrefix("/Users/") else { return }
        #expect(LogPrivacyRedactor.scrub(home) == "~")
    }

    @Test("A long unbroken letter run scrubs unchanged within a clock budget")
    func longLetterRunIsLinear() {
        let run = String(repeating: "log", count: 8000)
        var scrubbed = ""
        let elapsed = ContinuousClock().measure { scrubbed = LogPrivacyRedactor.scrub(run) }
        #expect(scrubbed == run)
        #expect(elapsed < .seconds(2))
    }
}
