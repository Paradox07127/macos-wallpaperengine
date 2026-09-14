import Foundation

/// Best-effort privacy scrubber for logs, persistent diagnostics and user-facing errors.
/// Preserves extensions, DNS hosts and error codes so the message stays actionable.
public enum LogPrivacyRedactor {
    public static func scrub(_ raw: String) -> String {
        var result = raw

        // Boundary-anchored so a home like `/Users/al` doesn't eat into
        // `/Users/alice` and defeat the `/Users/<name>` rule below.
        if let regex = Self.homePathRegex {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "~")
        }

        for rule in Self.rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }

        return result
    }

    /// Flattens an untrusted author-supplied title: a CR/LF inside one would forge extra
    /// log entries, and an overlong one would crowd out the bug-report excerpt.
    public static func sanitizedTitle(_ raw: String, maxLength: Int = 80) -> String {
        let cap = max(1, maxLength)
        let flattened = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                ? " " : scalar
        }))
        let collapsed = flattened
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > cap else { return collapsed }
        return String(collapsed.prefix(cap - 1)) + "…"
    }

    /// `" — <title>"` for a log line, or `""` when there is no usable title.
    public static func titleFragment(_ raw: String?, maxLength: Int = 80) -> String {
        guard let raw else { return "" }
        let title = sanitizedTitle(raw, maxLength: maxLength)
        return title.isEmpty ? "" : " — \(title)"
    }

    // MARK: - Precompiled rules

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(pattern: String, template: String) {
            // Patterns are the hardcoded literals in `rules` below — a typo should
            // crash at first use in development, not silently skip redaction.
            self.regex = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }
    }

    private static let homePathRegex: NSRegularExpression? = {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return nil }
        // `(?=/|$)` keeps the match to a whole path component, so a home that prefixes
        // another user's path is left to the `/Users/<name>` rule.
        return try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: home) + #"(?=/|$)"#)
    }()

    private static let rules: [Rule] = [
        // `/Users/<name>` (or `/Volumes/.../Users/<name>`) → keep relative path useful for triage.
        Rule(pattern: #"/Users/[^/\s'"]+"#, template: "/Users/<redacted>"),
        // URL userinfo for any hierarchical scheme.
        Rule(pattern: #"([A-Za-z][A-Za-z0-9+.-]*://)[^/\s'"@]+@([^/\s'"]+)"#, template: "$1<redacted>@$2"),
        // Query/fragment can carry signed CDN credentials, session nonces, coordinates and
        // OAuth tokens; covers custom schemes as well as http(s).
        Rule(pattern: ##"([A-Za-z][A-Za-z0-9+.-]*://[^\s'"?#]+)\?[^\s'"#]*(?:#[^\s'"]*)?"##, template: "$1?<query-redacted>"),
        Rule(pattern: ##"([A-Za-z][A-Za-z0-9+.-]*://[^\s'"#]+)#[^\s'"]*"##, template: "$1#<fragment-redacted>"),
        Rule(pattern: #"file://[^\s'"]+"#, template: "file://<redacted>"),
        // Common absolute roots: keep only the final component for extension/type triage —
        // directory names can identify a person or organization.
        Rule(
            pattern: #"/(?:Users|Volumes|private|tmp|var|home|opt|mnt|Applications)(?:/[^/\s'"]*)*/([^/\s'"]+)"#,
            template: "<path>/$1"
        ),
        // Standalone lat/lon assignments — re-thrown error strings sometimes
        // surface coordinates without a host (`URL Error -1009: lat=37.7…`).
        Rule(pattern: #"(?i)\b(lat(?:itude)?|lon(?:gitude)?)\s*[=:]\s*-?\d{1,3}(?:\.\d+)?"#, template: "$1=<redacted>"),
        Rule(pattern: #"(?i)\b(token|api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password)\s*[=:]\s*([^&\s'"]+)"#, template: "$1=<redacted>"),
        Rule(pattern: #"(?i)\b(Bearer|Token)\s+[A-Za-z0-9._~+/=-]+"#, template: "$1 <redacted>"),
        // Basic authorization headers — base64 of `user:pw` is just as sensitive.
        Rule(pattern: #"(?i)\bBasic\s+[A-Za-z0-9+/=]+"#, template: "Basic <redacted>"),

        // Rules below are duplicated from `WorkshopDiagnosticRedactor`: it is Pro-only, so
        // it cannot be referenced from here.

        // 17-digit SteamID64 (`7656119` prefix + 10 digits).
        Rule(pattern: #"\b7656119\d{10}\b"#, template: "<steamid-redacted>"),
        // SteamID3 form `[U:1:<accountid>]` as emitted by SteamCMD `+info`.
        Rule(pattern: #"\[U:\d+:\d+\]"#, template: "<steamid-redacted>"),
        // IPv4 dotted quad. A four-part version string is deliberately eaten — over-redaction
        // is the safe direction; three-group versions survive.
        Rule(pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, template: "<ip-redacted>"),
        // Compressed IPv6. Must run before the expanded rule below: that one matches only
        // single-colon chains, so on `::` forms it would eat just the tail and leak the routing
        // prefix. The flanking guards let `std::vector` through; fully hex-shaped tokens are eaten.
        Rule(pattern: #"(?<![A-Za-z0-9:])(?:[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4})*::(?:[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4})*)?|::[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4})*)(?![A-Za-z0-9:])"#, template: "<ip-redacted>"),
        // Expanded IPv6, deliberately permissive (2+ hex groups); ISO-8601 timestamps are
        // immune because the `T` leaves no word boundary before `12:34:56`.
        Rule(pattern: #"\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{1,4}\b"#, template: "<ip-redacted>"),
        // `.local` Bonjour hostnames derive from the user's device name; scoped to `.local`
        // so ordinary DNS hosts stay readable.
        Rule(pattern: #"(?i)\b[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.local\b"#, template: "<host-redacted>"),
        // `ssfn*` Steam sentry file names (serial-like session tokens).
        Rule(pattern: #"ssfn[A-Za-z0-9]+"#, template: "ssfn<redacted>"),
        // Steam persona / account names, matched mid-line: log lines arrive timestamp-prefixed,
        // so a `^` anchor would never fire.
        Rule(pattern: #"personaname=[^&\s]+"#, template: "personaname=<redacted>"),
        // Persona is free-form (spaces, kanji, emoji) → eat to end of line.
        Rule(pattern: #"(?i)\b(Persona Name):[ \t]*\S[^\n]*"#, template: "$1: <redacted>"),
        Rule(pattern: #"(?i)\b(Account):[ \t]*\S+"#, template: "$1: <redacted>"),
        // SteamCMD login banner: `Logging in user '<name>' [U:1:N] to Steam…`.
        Rule(pattern: #"Logging in user '[^']+'"#, template: "Logging in user '<redacted>'"),
    ]
}
