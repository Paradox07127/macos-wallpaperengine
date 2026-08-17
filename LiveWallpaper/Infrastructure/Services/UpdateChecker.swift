import Foundation
import LiveWallpaperCore

/// Throttled GitHub release checker. Compares against the tag only — both SKUs
/// share one release and one `MARKETING_VERSION`, so no asset matching is
/// involved and the same check serves Lite and Pro.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum Status: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(LatestRelease)
        case failed(reason: String)
    }

    struct LatestRelease: Equatable, Sendable {
        let tagName: String
        let version: SemanticVersion
        let releasePageURL: URL
        let publishedAt: Date?
        let body: String
    }

    private(set) var status: Status = .idle
    /// Time of the latest network attempt, regardless of outcome.
    private(set) var lastCheckedAt: Date?

    /// Earliest instant an automatic check may run again.
    private var nextEligibleAt: Date?

    /// Suppresses only the selected tag; newer releases remain eligible.
    var skippedVersionTag: String? {
        get { defaults.string(forKey: Self.skippedVersionKey) }
        set { defaults.set(newValue, forKey: Self.skippedVersionKey) }
    }

    static let releasesAPI = URL(
        string: "https://api.github.com/repos/Paradox07127/macos-wallpaperengine/releases?per_page=10"
    ) ?? URL(fileURLWithPath: "/")
    static let releasesPage = URL(
        string: "https://github.com/Paradox07127/macos-wallpaperengine/releases"
    ) ?? URL(fileURLWithPath: "/")

    static let tagPrefix = "loomscreen-v"
    static let throttleInterval: TimeInterval = 60 * 60 * 12
    /// Failure backoff is shorter than the success interval but prevents relaunch retry storms.
    static let failureRetryInterval: TimeInterval = 60 * 60
    static let maximumReleaseBodyCharacters = 4_000
    static let trustedGitHubHost = "github.com"
    static let trustedReleasesPathPrefix = "/Paradox07127/macos-wallpaperengine/releases/"

    private static let lastCheckedKey = "loomscreen.update.lastCheckedAt"
    private static let nextEligibleKey = "loomscreen.update.nextEligibleAt"
    private static let skippedVersionKey = "loomscreen.update.skippedVersion"
    private let transport: any UpdateCheckerTransport
    private let now: @Sendable () -> Date
    private let currentVersion: SemanticVersion
    private let defaults: UserDefaults

    init(
        transport: any UpdateCheckerTransport = URLSessionUpdateCheckerTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        currentVersionString: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        defaults: UserDefaults = .appScoped()
    ) {
        self.transport = transport
        self.now = now
        self.defaults = defaults
        self.currentVersion = SemanticVersion(parsing: currentVersionString ?? "0.0.0")
            ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        if let stored = defaults.object(forKey: Self.lastCheckedKey) as? Date {
            self.lastCheckedAt = stored
        }
        if let nextEligible = defaults.object(forKey: Self.nextEligibleKey) as? Date {
            self.nextEligibleAt = nextEligible
        } else if let stored = self.lastCheckedAt {
            // Upgrade path: installs that predate the split still honor the
            // 12 h window off their recorded last-checked time.
            self.nextEligibleAt = stored.addingTimeInterval(Self.throttleInterval)
        }
    }

    /// Checks for a release, optionally bypassing the automatic-check throttle.
    func checkNow(force: Bool) async {
        guard status != .checking else { return }
        let attemptedAt = now()
        if !force, let eligible = nextEligibleAt {
            let remaining = eligible.timeIntervalSince(attemptedAt)
            // Clock rollback or absurd wait → run check, do not extend suppression.
            let rolledBack = lastCheckedAt.map { attemptedAt < $0 } ?? false
            if !rolledBack, remaining > 0, remaining <= Self.throttleInterval {
                Logger.debug("Skipping update check (throttle window not elapsed).", category: .updates)
                return
            }
        }
        status = .checking
        recordLastChecked(attemptedAt)
        do {
            let releases = try await transport.fetchReleases(from: Self.releasesAPI)
            status = evaluate(releases: releases)
            scheduleNextEligible(after: Self.throttleInterval, from: attemptedAt)
        } catch {
            // Generic user-facing string so a hostile response can't smuggle
            // implementation details into the UI.
            Logger.error("Update check failed: \(String(describing: error))", category: .updates)
            status = .failed(reason: "Unable to check for updates right now.")
            scheduleNextEligible(after: Self.failureRetryInterval, from: attemptedAt)
        }
    }

    /// Dismisses the currently available release until a newer tag appears.
    func skipCurrentAvailable() {
        if case .available(let release) = status {
            skippedVersionTag = release.tagName
            status = .upToDate
        }
    }

    private func recordLastChecked(_ stamp: Date) {
        lastCheckedAt = stamp
        defaults.set(stamp, forKey: Self.lastCheckedKey)
    }

    private func scheduleNextEligible(after interval: TimeInterval, from stamp: Date) {
        let next = stamp.addingTimeInterval(interval)
        nextEligibleAt = next
        defaults.set(next, forKey: Self.nextEligibleKey)
    }

    private func evaluate(releases: [GitHubRelease]) -> Status {
        let candidates: [LatestRelease] = releases.compactMap { release in
            guard !release.draft, !release.prerelease else { return nil }
            guard release.tagName.hasPrefix(Self.tagPrefix) else { return nil }
            guard let version = SemanticVersion(parsing: release.tagName) else { return nil }
            return LatestRelease(
                tagName: release.tagName,
                version: version,
                releasePageURL: Self.trustedReleasePageURL(release.htmlURL),
                publishedAt: release.publishedAt,
                body: release.body.map { String($0.prefix(Self.maximumReleaseBodyCharacters)) } ?? ""
            )
        }

        guard let newest = candidates.max(by: { $0.version < $1.version }) else {
            Logger.debug("No published Loomscreen releases yet.", category: .updates)
            return .upToDate
        }
        guard newest.version > currentVersion else {
            return .upToDate
        }
        if newest.tagName == skippedVersionTag {
            Logger.debug("User has skipped \(newest.tagName).", category: .updates)
            return .upToDate
        }
        return .available(newest)
    }

    /// Trusted GitHub Releases URL only; anything else falls back to the canonical page.
    private static func trustedReleasePageURL(_ url: URL?) -> URL {
        guard let url, isTrustedGitHubURL(url, pathPrefix: trustedReleasesPathPrefix)
        else { return releasesPage }
        return url
    }

    private static func isTrustedGitHubURL(_ url: URL, pathPrefix: String) -> Bool {
        let standardized = url.standardized
        return standardized.scheme?.lowercased() == "https"
            && standardized.host?.lowercased() == trustedGitHubHost
            && standardized.path.hasPrefix(pathPrefix)
    }
}

/// Transport seam for release checks.
protocol UpdateCheckerTransport: Sendable {
    func fetchReleases(from url: URL) async throws -> [GitHubRelease]
}

/// GitHub release fields required by the update UI.
struct GitHubRelease: Decodable, Sendable, Equatable {
    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let htmlURL: URL?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case publishedAt = "published_at"
        case htmlURL = "html_url"
        case assets
    }

    struct Asset: Decodable, Sendable, Equatable {
        let name: String
        let browserDownloadURL: URL?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

/// Ephemeral GitHub transport with strict origin and response-size validation.
struct URLSessionUpdateCheckerTransport: UpdateCheckerTransport {
    private let session: URLSession

    static let maximumResponseBytes = 512 * 1024
    static let requestTimeoutSeconds: TimeInterval = 15

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            self.session = URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
        }
    }

    func fetchReleases(from url: URL) async throws -> [GitHubRelease] {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Loomscreen-UpdateChecker", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedNetworkFetch.fetch(request, session: session, byteCap: Self.maximumResponseBytes)
        } catch is BoundedNetworkFetch.ResponseTooLarge {
            throw URLError(.dataLengthExceedsMaximum)
        }

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == "api.github.com" else {
            // Reject unexpected response host before decode (redirect injection).
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("json") else {
            throw URLError(.cannotParseResponse)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LossyArray<GitHubRelease>.self, from: data)
        // All-decode-fail is error (1h retry), not "up to date" (12h).
        if decoded.elements.isEmpty, decoded.droppedCount > 0 {
            throw URLError(.cannotParseResponse)
        }
        return decoded.elements
    }
}

/// Decodes valid array elements while counting malformed entries.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        var dropped = 0
        if let count = container.count { result.reserveCapacity(count) }
        while !container.isAtEnd {
            let indexBefore = container.currentIndex
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                // Consume the malformed element so the cursor advances past it.
                _ = try? container.decode(AnyDecodableSkip.self)
                dropped += 1
            }
            // Safety net: if neither decode advanced the cursor, bail rather
            // than spin forever on a decoder that won't consume the element.
            if container.currentIndex == indexBefore { break }
        }
        elements = result
        droppedCount = dropped
    }
}

/// Advances an unkeyed container past one malformed JSON value.
struct AnyDecodableSkip: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url,
           url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "api.github.com" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
