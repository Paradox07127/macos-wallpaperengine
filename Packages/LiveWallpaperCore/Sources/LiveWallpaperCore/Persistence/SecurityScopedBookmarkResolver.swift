import Foundation

/// Central security-scoped bookmark resolve + stale refresh.
/// `bookmarkDataIsStale` must be observed every resolve (Apple one-shot grace);
/// historically dropped at most call sites → silent grant loss after restart/inode change.
public struct SecurityScopedBookmarkResolver: Sendable {
    /// Persist hook for a refreshed grant. Save both original + refreshed and CAS
    /// against current storage so a late refresh cannot resurrect a cleared re-grant.
    public struct Target: Sendable {
        public let label: String
        public let save: @Sendable (_ original: Data, _ refreshed: Data) -> Void

        public init(
            label: String,
            save: @escaping @Sendable (_ original: Data, _ refreshed: Data) -> Void = { _, _ in }
        ) {
            self.label = label
            self.save = save
        }
    }

    public struct Resolved: Sendable {
        public let url: URL
        public let bookmarkData: Data
        public let didRefresh: Bool

        public init(url: URL, bookmarkData: Data, didRefresh: Bool) {
            self.url = url
            self.bookmarkData = bookmarkData
            self.didRefresh = didRefresh
        }
    }

    public enum Failure: Error, LocalizedError, Sendable {
        case missing
        case resolutionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missing:
                return "No bookmark is stored for this resource."
            case .resolutionFailed(let reason):
                return "Failed to resolve bookmark: \(reason)"
            }
        }
    }

    public let resolveData: @Sendable (Data) throws -> (URL, Bool)
    public let refreshData: @Sendable (URL) throws -> Data

    public init(
        resolveData: @escaping @Sendable (Data) throws -> (URL, Bool),
        refreshData: @escaping @Sendable (URL) throws -> Data
    ) {
        self.resolveData = resolveData
        self.refreshData = refreshData
    }

    public func resolve(_ data: Data?, target: Target) -> Result<Resolved, Failure> {
        guard let data else {
            return .failure(.missing)
        }

        let url: URL
        let isStale: Bool
        do {
            (url, isStale) = try resolveData(data)
        } catch {
            Logger.warning(
                "[bookmark/\(target.label)] resolve failed: \(error.localizedDescription)",
                category: .fileAccess
            )
            return .failure(.resolutionFailed(error.localizedDescription))
        }

        guard isStale else {
            return .success(Resolved(url: url, bookmarkData: data, didRefresh: false))
        }

        var refreshedData: Data?
        Self.withScopedAccess(url) { _ in
            do {
                let fresh = try refreshData(url)
                refreshedData = fresh
                target.save(data, fresh)
                Logger.info(
                    "[bookmark/\(target.label)] was stale; refreshed in place",
                    category: .fileAccess
                )
            } catch {
                Logger.warning(
                    "[bookmark/\(target.label)] stale and refresh failed: \(error.localizedDescription) — current URL still usable but re-grant may be needed next launch",
                    category: .fileAccess
                )
            }
        }

        return .success(Resolved(
            url: url,
            bookmarkData: refreshedData ?? data,
            didRefresh: refreshedData != nil
        ))
    }

    @discardableResult
    public static func withScopedAccess<R>(
        _ url: URL,
        _ work: (Bool) throws -> R
    ) rethrows -> R {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try work(didStart)
    }
}

extension SecurityScopedBookmarkResolver {
    /// Always re-resolve. URL memoization (2026-08-03) broke scoped access /
    /// Steam adopt ("Operation not permitted") — cache work results, never the URL.
    public static let live = SecurityScopedBookmarkResolver(
        resolveData: { data in
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return (url, isStale)
            } catch {
                var plainStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &plainStale
                )
                return (url, plainStale)
            }
        },
        refreshData: { url in
            try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    )

    public static var shared: SecurityScopedBookmarkResolver { .live }
}

// MARK: - Typed targets shared by all SKUs

extension SecurityScopedBookmarkResolver.Target {
    /// Resolve without persisting a refresh (thumbnail / existence check).
    public static var transient: Self {
        Self(label: "transient")
    }
}
