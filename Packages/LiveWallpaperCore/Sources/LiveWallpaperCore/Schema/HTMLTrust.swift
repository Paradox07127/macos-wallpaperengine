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

    /// `URL.host` hands back an IPv6 literal without its brackets, so putting it
    /// straight into a URL string yields an unparseable `http://fc00::1:3000`.
    private var hostInURL: String {
        host.contains(":") ? "[\(host)]" : host
    }

    public var rawValue: String {
        "\(scheme)://\(hostInURL):\(port)"
    }

    public var displayName: String {
        if port == Self.defaultPort(for: scheme) {
            return "\(scheme)://\(hostInURL)"
        }
        return rawValue
    }

    public var description: String { rawValue }

    /// Cleartext vs TLS. Answers "is the transport encrypted", nothing else —
    /// the UI shows its HTTP warning from this.
    public var isSecure: Bool { scheme == "https" }

    /// W3C Secure Contexts treats loopback as a potentially trustworthy origin even over http, which
    /// is why browsers give `http://localhost` the same powers as https. Traffic never leaves the
    /// machine, so there is no network position from which to tamper with it.
    /// <https://w3c.github.io/webappsec-secure-contexts/>
    public var isLoopback: Bool { Self.isLoopbackHost(host) }

    /// Expects an already-lowercased host, as stored.
    public static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "localhost." { return true }
        if host.hasSuffix(".localhost") || host.hasSuffix(".localhost.") { return true }
        if let address = ipv6Address(host) {
            return address == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        }
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
        if let address = ipv6Address(host) {
            // fc00::/7 unique-local, fe80::/10 link-local — compared as
            // networks, because "fc::1" spells fc but is 0x00fc, a public address.
            if address[0] & 0xFE == 0xFC { return true }
            return address[0] == 0xFE && address[1] & 0xC0 == 0x80
        }
        guard let address = ipv4Address(host) else { return false }
        switch (UInt8(truncatingIfNeeded: address >> 24), UInt8(truncatingIfNeeded: address >> 16)) {
        case (10, _): return true                      // 10.0.0.0/8
        case (172, 16...31): return true               // 172.16.0.0/12
        case (192, 168): return true                   // 192.168.0.0/16
        case (169, 254): return true                   // 169.254.0.0/16 link-local
        default: return false
        }
    }

    /// Parsed by the resolver the connection will use, not by our own spelling
    /// rules: `inet_aton` reads a leading zero as octal, so `010.0.0.1` dials
    /// the public 8.0.0.1 and must not be judged as if it were decimal.
    private static func ipv4Address(_ host: String) -> UInt32? {
        var address = in_addr()
        guard host.withCString({ inet_aton($0, &address) }) != 0 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    /// URL.host strips the brackets from `[::1]`; accept both spellings.
    private static func ipv6Address(_ host: String) -> [UInt8]? {
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        var address = in6_addr()
        guard bare.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    /// 127.0.0.0/8 — the whole block, not just 127.0.0.1.
    private static func isIPv4Loopback(_ host: String) -> Bool {
        guard let address = ipv4Address(host) else { return false }
        return UInt8(truncatingIfNeeded: address >> 24) == 127
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
