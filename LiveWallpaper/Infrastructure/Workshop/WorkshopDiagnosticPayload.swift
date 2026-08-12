#if !LITE_BUILD
import AppKit
import Foundation

/// Redacted Workshop diagnostic payload suitable for copying into an issue.
struct WorkshopDiagnosticPayload: Codable, Equatable, Sendable {
    let phase: Phase
    let ts: String
    let regexMatch: String?
    let tail: String
    let appVersion: String
    let macos: String
    let arch: String

    enum Phase: String, Codable, Equatable, Sendable {
        case metadata
        case doctor
        case download
        case `import`
        case search
    }

    init(
        phase: Phase,
        regexMatch: String?,
        tail: String,
        timestamp: Date = Date(),
        appVersion: String = WorkshopDiagnosticPayload.runningAppVersion,
        macOSVersion: String = WorkshopDiagnosticPayload.runningMacOSVersion,
        architecture: String = WorkshopDiagnosticPayload.runningArchitecture
    ) {
        self.phase = phase
        self.regexMatch = regexMatch
        self.tail = WorkshopDiagnosticRedactor.redact(tail)
        self.appVersion = appVersion
        self.macos = macOSVersion
        self.arch = architecture
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.ts = formatter.string(from: timestamp)
    }

    private enum CodingKeys: String, CodingKey {
        case phase
        case ts
        case regexMatch = "regex_match"
        case tail
        case appVersion = "app_version"
        case macos
        case arch
    }

    /// Encodes readable, stable JSON for user-submitted diagnostics.
    func encodedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// False when pasteboard write fails (don't toast success on denial).
    @MainActor
    @discardableResult
    func copyToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(encodedJSON(), forType: .string)
    }

    // MARK: - Static helpers

    static let runningAppVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }()

    static let runningMacOSVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    static let runningArchitecture: String = {
        // App ships arm64-only (ARCHS = arm64).
        return "arm64"
    }()
}

/// Scrub secrets/PII before user-visible diagnostic text hits pasteboard/disk.
enum WorkshopDiagnosticRedactor {

    static func redact(_ raw: String) -> String {
        var output = raw

        // Steam Web API key (32-hex, case-insensitive, word-bounded).
        output = output.replacingOccurrences(
            of: #"(?i)\bkey=[a-f0-9]{32}\b"#,
            with: "key=<redacted>",
            options: .regularExpression
        )

        // 17-digit SteamID64 (`7656119` prefix + 10 digits).
        output = output.replacingOccurrences(of: #"\b7656119\d{10}\b"#, with: "<steamid>", options: .regularExpression)

        // SteamID3 `[U:1:N]` (SteamCMD +info).
        output = output.replacingOccurrences(
            of: #"\[U:\d+:\d+\]"#,
            with: "<steamid3>",
            options: .regularExpression
        )

        // IPv4 dotted quad.
        output = output.replacingOccurrences(of: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, with: "<ipv4>", options: .regularExpression)

        // Compressed IPv6 before expanded rule (else `::` leaks the prefix).
        output = output.replacingOccurrences(
            of: #"(?<![A-Za-z0-9:])(?:[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4})*::(?:[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4})*)?|::[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4})*)(?![A-Za-z0-9:])"#,
            with: "<ipv6>",
            options: .regularExpression
        )

        // Expanded IPv6 (permissive; false positives OK in diagnostics).
        output = output.replacingOccurrences(
            of: #"\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{1,4}\b"#,
            with: "<ipv6>",
            options: .regularExpression
        )

        // cellid/serverid in query, CellID:, and cellid: forms.
        output = output.replacingOccurrences(
            of: #"(?i)\b(cellid|serverid)[:= ]+\d+\b"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )

        // Email.
        output = output.replacingOccurrences(of: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, with: "<email>", options: .regularExpression)

        // ssfn* (SteamCMD session token file names).
        output = output.replacingOccurrences(of: #"ssfn[A-Za-z0-9]+"#, with: "<ssfn>", options: .regularExpression)

        // Home directory.
        let home = NSHomeDirectory()
        if !home.isEmpty {
            output = output.replacingOccurrences(of: home, with: "<home>")
        }

        // POSIX username word-boundary (Steam workdir owner).
        let username = NSUserName()
        if !username.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: username)
            output = output.replacingOccurrences(
                of: "\\b\(escaped)\\b",
                with: "<username>",
                options: .regularExpression
            )
        }

        // personaname= query strings.
        output = output.replacingOccurrences(of: #"personaname=[^&\s]+"#, with: "personaname=<redacted>", options: .regularExpression)

        // Persona Name line (SteamCMD may emit trailing spaces).
        output = output.replacingOccurrences(
            of: #"(?im)^Persona Name:\s*\S.*?\s*$"#,
            with: "Persona Name: <redacted>",
            options: .regularExpression
        )

        // Steam Account: login name (distinct from POSIX username).
        output = output.replacingOccurrences(
            of: #"(?im)^Account:\s*\S+\s*$"#,
            with: "Account: <redacted>",
            options: .regularExpression
        )

        // Login banner username (SteamID3 handled separately).
        output = output.replacingOccurrences(
            of: #"Logging in user '[^']+'"#,
            with: "Logging in user '<redacted>'",
            options: .regularExpression
        )

        return output
    }
}
#endif
