import Foundation

/// Browser-origin trust key (scheme + host + effective port). Trusting one
/// origin must not grant privileges to other schemes, ports, or subdomains.
public struct TrustedHTMLOrigin: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(url: URL) {
        guard
            let rawScheme = url.scheme?.lowercased(),
            rawScheme == "http" || rawScheme == "https",
            let rawHost = url.host?.lowercased(),
            !rawHost.isEmpty,
            let effectivePort = url.port ?? Self.defaultPort(for: rawScheme)
        else { return nil }

        scheme = rawScheme
        host = rawHost
        port = effectivePort
    }

    /// Accepts new persisted origin strings (`https://host:443`) plus legacy host-only values, which migrate to HTTPS on the default port.
    public init?(persistedValue: String) {
        let value = persistedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.contains("://") {
            guard let url = URL(string: value), let origin = TrustedHTMLOrigin(url: url) else { return nil }
            self = origin
            return
        }

        let host = value.lowercased()
        guard
            !host.isEmpty,
            host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            !host.contains("/"),
            !host.contains(":")
        else { return nil }

        scheme = "https"
        self.host = host
        port = 443
    }

    public var rawValue: String {
        "\(scheme)://\(host):\(port)"
    }

    public var displayName: String {
        if port == Self.defaultPort(for: scheme) {
            return "\(scheme)://\(host)"
        }
        return rawValue
    }

    public var description: String { rawValue }

    /// Cleartext vs TLS. Answers "is the transport encrypted", nothing else —
    /// the UI shows its HTTP warning from this.
    public var isSecure: Bool { scheme == "https" }

    /// W3C Secure Contexts treats loopback as a potentially trustworthy origin
    /// even over http, which is why browsers give `http://localhost` the same
    /// powers as https. Traffic never leaves the machine, so there is no
    /// network position from which to tamper with it.
    /// <https://w3c.github.io/webappsec-secure-contexts/>
    public var isLoopback: Bool { Self.isLoopbackHost(host) }

    /// Expects an already-lowercased host, as stored.
    public static func isLoopbackHost(_ host: String) -> Bool {
        // URL.host strips the brackets from [::1]; accept both spellings.
        if host == "::1" || host == "[::1]" { return true }
        if host == "localhost" || host == "localhost." { return true }
        if host.hasSuffix(".localhost") || host.hasSuffix(".localhost.") { return true }
        return isIPv4Loopback(host)
    }

    /// Private-network literals (RFC 1918 + link-local, and the IPv6
    /// equivalents). Cleartext here is still tamperable by anyone already on
    /// the same LAN, so unlike loopback these are *eligible* for trust rather
    /// than trusted outright — the user has to grant it per origin.
    public var isPrivateNetwork: Bool { Self.isPrivateNetworkHost(host) }

    /// Eligible to be granted JavaScript at all. Loopback is excluded because
    /// it never needs an allowlist entry.
    public var canBeTrusted: Bool { isSecure || isPrivateNetwork }

    /// Expects an already-lowercased host, as stored.
    public static func isPrivateNetworkHost(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        // IPv6 unique-local (fc00::/7) and link-local (fe80::/10).
        if bare.contains(":") {
            return bare.hasPrefix("fc") || bare.hasPrefix("fd") || bare.hasPrefix("fe8")
                || bare.hasPrefix("fe9") || bare.hasPrefix("fea") || bare.hasPrefix("feb")
        }
        guard let octets = ipv4Octets(bare) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true                      // 10.0.0.0/8
        case (172, 16...31): return true               // 172.16.0.0/12
        case (192, 168): return true                   // 192.168.0.0/16
        case (169, 254): return true                   // 169.254.0.0/16 link-local
        default: return false
        }
    }

    /// Strict dotted-quad parse; rejects anything that is not exactly 4 octets.
    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    /// 127.0.0.0/8 — the whole block, not just 127.0.0.1.
    private static func isIPv4Loopback(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else { return false }
        return octets[0] == 127
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    public static func < (lhs: TrustedHTMLOrigin, rhs: TrustedHTMLOrigin) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let origin = TrustedHTMLOrigin(persistedValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid trusted HTML origin: \(raw)"
            )
        }
        self = origin
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Whether the active HTML source may run JS/WebGPU. Untrusted remotes force JS-off
/// in the builder regardless of `HTMLConfig.allowJavaScript`.
public enum HTMLTrust: Equatable, Sendable {
    case localContent
    case trustedRemote(origin: TrustedHTMLOrigin)
    case untrustedRemote(origin: TrustedHTMLOrigin)

    public static func evaluate(source: HTMLSource, trustedOrigins: Set<TrustedHTMLOrigin>) -> HTMLTrust {
        switch source {
        case .file, .folder, .inline:
            return .localContent
        case .url(let url):
            guard let origin = TrustedHTMLOrigin(url: url) else {
                return .localContent
            }
            // Loopback is trusted without an allowlist entry, so a local dev
            // server works out of the box and cannot be revoked by accident.
            if origin.isLoopback {
                return .trustedRemote(origin: origin)
            }
            return trustedOrigins.contains(origin) ? .trustedRemote(origin: origin) : .untrustedRemote(origin: origin)
        }
    }

    /// Untrusted remote always forces JS off.
    public func effectiveAllowJavaScript(requested: Bool) -> Bool {
        switch self {
        case .untrustedRemote: return false
        default: return requested
        }
    }

    /// Untrusted remote force-mutes so a pasted URL cannot ambush with autoplay audio.
    public func effectiveMuteAudio(requested: Bool) -> Bool {
        switch self {
        case .untrustedRemote: return true
        default: return requested
        }
    }

    public func effectiveAudioVolume(requested: Double) -> Double {
        switch self {
        case .untrustedRemote: return 0
        default: return requested
        }
    }
}
