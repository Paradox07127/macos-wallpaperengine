import Foundation
import Observation

@MainActor
public protocol TrustedHostPersisting {
    func load() -> [String]
    func save(_ origins: [String])
}

/// Allowlist of remote HTML origins that may run JavaScript.
@MainActor
@Observable
public final class TrustedHostStore {
    /// Sorted, de-duped browser origins eligible for JavaScript (HTTPS, plus
    /// private-network literals the user explicitly trusted).
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

    public func isBuiltInTrusted(_ origin: TrustedHTMLOrigin) -> Bool {
        Self.builtInTrustedOrigins.contains(origin)
    }

    @discardableResult
    public func trust(_ origin: TrustedHTMLOrigin) -> Bool {
        guard origin.canBeTrusted, !originSet.contains(origin) else { return false }
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

    /// Filters on the same predicate as `trust`; otherwise a granted LAN origin
    /// would be dropped on the next launch and the grant would silently expire.
    public static func normalizeOrigins(_ raw: [String]) -> [TrustedHTMLOrigin] {
        Array(Set(raw.compactMap(TrustedHTMLOrigin.init(persistedValue:))
            .filter(\.canBeTrusted)))
            .sorted()
    }
}
