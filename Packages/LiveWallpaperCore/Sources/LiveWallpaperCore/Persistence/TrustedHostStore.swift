import Foundation
import Observation

@MainActor
public protocol TrustedHostPersisting {
    func load() -> [String]
    func save(_ origins: [String])
}

/// Allowlist of remote HTML origins that may run JavaScript. Persistence is injected;
/// the app wires `SettingsManager` in `SettingsManagerStoreBindings.swift`.
@MainActor
@Observable
public final class TrustedHostStore {
    /// Sorted, de-duped, HTTPS-only browser origins.
    public private(set) var origins: [TrustedHTMLOrigin]
    @ObservationIgnored private let persistence: any TrustedHostPersisting

    public init(persistence: any TrustedHostPersisting) {
        self.persistence = persistence
        let loaded = persistence.load()
        self.origins = Self.normalizeOrigins(loaded)
        if loaded != hosts {
            persistence.save(hosts)
        }
    }

    /// Raw origin strings for persistence / settings cleanup (legacy name).
    private var hosts: [String] { origins.map(\.rawValue) }

    /// Immutable embed-only platform origins (YouTube nocookie, Vimeo player).
    /// Pre-trusted because `normalizingForWallpaper` rewrites paste URLs here; not user-revocable / not persisted.
    public static let builtInTrustedOrigins: Set<TrustedHTMLOrigin> = {
        let raw = [
            "https://www.youtube-nocookie.com",
            "https://youtube-nocookie.com",
            "https://player.vimeo.com",
        ]
        return Set(raw.compactMap(TrustedHTMLOrigin.init(persistedValue:)))
    }()

    public var originSet: Set<TrustedHTMLOrigin> {
        Set(origins).union(Self.builtInTrustedOrigins)
    }

    /// Built-in allowlist membership (UI hides Revoke for these).
    public func isBuiltInTrusted(_ origin: TrustedHTMLOrigin) -> Bool {
        Self.builtInTrustedOrigins.contains(origin)
    }

    @discardableResult
    public func trust(_ origin: TrustedHTMLOrigin) -> Bool {
        guard origin.isSecure, !originSet.contains(origin) else { return false }
        origins = Self.normalizeOrigins(hosts + [origin.rawValue])
        persist()
        return true
    }

    @discardableResult
    public func revoke(_ origin: TrustedHTMLOrigin) -> Bool {
        guard !Self.builtInTrustedOrigins.contains(origin) else { return false }
        guard origins.contains(origin) else { return false }
        origins.removeAll { $0 == origin }
        persist()
        return true
    }

    public func resetAfterSettingsCleared() {
        origins.removeAll()
    }

    private func persist() {
        persistence.save(hosts)
    }

    public static func normalizeOrigins(_ raw: [String]) -> [TrustedHTMLOrigin] {
        Array(Set(raw.compactMap(TrustedHTMLOrigin.init(persistedValue:))
            .filter(\.isSecure)))
            .sorted()
    }
}
