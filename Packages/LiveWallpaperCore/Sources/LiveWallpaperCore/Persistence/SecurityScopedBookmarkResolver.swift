import Foundation

/// `bookmarkDataIsStale` must be observed on every resolve (Apple's one-shot grace);
/// dropping it loses the grant silently after a restart or an inode change.
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
        /// false = resolved by the unscoped fallback: the URL carries no sandbox extension.
        public let isSecurityScoped: Bool

        public init(url: URL, bookmarkData: Data, didRefresh: Bool, isSecurityScoped: Bool = true) {
            self.url = url
            self.bookmarkData = bookmarkData
            self.didRefresh = didRefresh
            self.isSecurityScoped = isSecurityScoped
        }
    }

    private struct Resolution: Sendable {
        let url: URL
        let isStale: Bool
        let isSecurityScoped: Bool
    }

    public enum Failure: Error, LocalizedError, Sendable {
        case missing
        case resolutionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missing:
                String(localized: "No saved access to this item. Choose it again.", bundle: .appLanguage, comment: "Bookmark resolution error.")
            case .resolutionFailed(let reason):
                String(localized: "Couldn't restore access to this item: \(reason)", bundle: .appLanguage, comment: "Bookmark resolution error. The placeholder is the system reason.")
            }
        }
    }

    public let resolveData: @Sendable (Data) throws -> (URL, Bool)
    public let refreshData: @Sendable (URL) throws -> Data
    private let resolveDetailed: @Sendable (Data) throws -> Resolution

    /// Every resolved URL is reported as security-scoped.
    public init(
        resolveData: @escaping @Sendable (Data) throws -> (URL, Bool),
        refreshData: @escaping @Sendable (URL) throws -> Data
    ) {
        self.resolveData = resolveData
        self.refreshData = refreshData
        resolveDetailed = { data in
            let (url, isStale) = try resolveData(data)
            return Resolution(url: url, isStale: isStale, isSecurityScoped: true)
        }
    }

    /// Falls back to `resolveUnscoped` when `resolveScoped` throws, and reports which one answered.
    public init(
        resolveScoped: @escaping @Sendable (Data) throws -> (URL, Bool),
        resolveUnscoped: @escaping @Sendable (Data) throws -> (URL, Bool),
        refreshData: @escaping @Sendable (URL) throws -> Data
    ) {
        let resolveDetailed: @Sendable (Data) throws -> Resolution = { data in
            do {
                let (url, isStale) = try resolveScoped(data)
                return Resolution(url: url, isStale: isStale, isSecurityScoped: true)
            } catch {
                let scopedError = error as NSError
                Logger.warning(
                    "[bookmark] scoped resolve refused (\(scopedError.domain) \(scopedError.code)); falling back to unscoped resolve",
                    category: .fileAccess
                )
                let (url, isStale) = try resolveUnscoped(data)
                return Resolution(url: url, isStale: isStale, isSecurityScoped: false)
            }
        }
        self.resolveDetailed = resolveDetailed
        resolveData = { data in
            let resolution = try resolveDetailed(data)
            return (resolution.url, resolution.isStale)
        }
        self.refreshData = refreshData
    }

    public func resolve(_ data: Data?, target: Target) -> Result<Resolved, Failure> {
        guard let data else {
            return .failure(.missing)
        }

        let url: URL
        let isStale: Bool
        let isSecurityScoped: Bool
        do {
            let resolution = try resolveDetailed(data)
            (url, isStale, isSecurityScoped) = (resolution.url, resolution.isStale, resolution.isSecurityScoped)
        } catch {
            Logger.warning(
                "[bookmark/\(target.label)] resolve failed: \(error.localizedDescription)",
                category: .fileAccess
            )
            return .failure(.resolutionFailed(error.localizedDescription))
        }

        guard isStale else {
            return .success(Resolved(url: url, bookmarkData: data, didRefresh: false, isSecurityScoped: isSecurityScoped))
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
            didRefresh: refreshedData != nil,
            isSecurityScoped: isSecurityScoped
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
    /// Always re-resolve: memoizing the URL breaks scoped access — cache work results,
    /// never the URL.
    public static let live = SecurityScopedBookmarkResolver(
        resolveScoped: { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        },
        resolveUnscoped: { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
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
