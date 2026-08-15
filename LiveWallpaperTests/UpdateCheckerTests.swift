import Foundation
import Testing
@testable import LiveWallpaper

@Suite("SemanticVersion parsing and ordering")
struct SemanticVersionTests {
    @Test("Parses bare semver triples")
    func parsesBareSemver() {
        let v = SemanticVersion(parsing: "1.2.3")
        #expect(v == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test("Accepts the v / loomscreen-v prefixes we publish")
    func acceptsKnownPrefixes() {
        #expect(SemanticVersion(parsing: "v1.0.0") == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(SemanticVersion(parsing: "loomscreen-v2.10.5") == SemanticVersion(major: 2, minor: 10, patch: 5))
        #expect(SemanticVersion(parsing: "lwp-v0.4.1") == nil, "the retired lwp-v prefix must no longer parse")
    }

    @Test("Keeps pre-release identifiers and orders them below the final release")
    func parsesPrereleaseIdentifiers() {
        #expect(SemanticVersion(parsing: "0.6.0-beta.1") != SemanticVersion(major: 0, minor: 6, patch: 0))
        #expect(SemanticVersion(parsing: "0.6.0-beta.1") == SemanticVersion(
            major: 0, minor: 6, patch: 0, prerelease: ["beta", "1"]
        ))
        #expect(SemanticVersion(parsing: "0.6.0-beta.1")! < SemanticVersion(parsing: "0.6.0")!)
        #expect(SemanticVersion(parsing: "0.6.0-beta.1")! < SemanticVersion(parsing: "0.6.0-beta.2")!)
        #expect(SemanticVersion(parsing: "0.6.0-beta.9")! < SemanticVersion(parsing: "0.6.0-rc.1")!)
        #expect(SemanticVersion(parsing: "0.6.0-beta")! < SemanticVersion(parsing: "0.6.0-beta.1")!)
        #expect(SemanticVersion(parsing: "0.5.1")! < SemanticVersion(parsing: "0.6.0-beta.1")!)
        #expect(SemanticVersion(parsing: "loomscreen-v0.6.0-beta.1")! < SemanticVersion(parsing: "loomscreen-v0.6.0")!)
    }

    @Test("Ignores build metadata but not pre-release identifiers")
    func stripsSuffixMetadata() {
        #expect(SemanticVersion(parsing: "1.0.0+build42") == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(SemanticVersion(parsing: "1.0.0-beta.1+sha") == SemanticVersion(
            major: 1, minor: 0, patch: 0, prerelease: ["beta", "1"]
        ))
    }

    @Test("Defaults missing patch component to zero")
    func defaultsMissingPatchToZero() {
        #expect(SemanticVersion(parsing: "1.5") == SemanticVersion(major: 1, minor: 5, patch: 0))
    }

    @Test("Rejects garbage")
    func rejectsGarbage() {
        #expect(SemanticVersion(parsing: "garbage") == nil)
        #expect(SemanticVersion(parsing: "") == nil)
        #expect(SemanticVersion(parsing: "1") == nil)
        #expect(SemanticVersion(parsing: "a.b.c") == nil)
    }

    @Test("Orders components lexicographically (major dominates minor dominates patch)")
    func ordering() {
        #expect(SemanticVersion(major: 1, minor: 0, patch: 0) < SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion(major: 1, minor: 0, patch: 9) < SemanticVersion(major: 1, minor: 1, patch: 0))
        #expect(SemanticVersion(major: 1, minor: 0, patch: 0) < SemanticVersion(major: 1, minor: 0, patch: 1))
        #expect(SemanticVersion(major: 1, minor: 10, patch: 0) > SemanticVersion(major: 1, minor: 9, patch: 99))
    }
}

@Suite("UpdateChecker state-machine flows", .serialized)
@MainActor
struct UpdateCheckerTests {
    private var defaultsSuite: UserDefaults {
        UserDefaults.appScoped()
    }

    private func resetDefaults() {
        defaultsSuite.removeObject(forKey: "loomscreen.update.lastCheckedAt")
        defaultsSuite.removeObject(forKey: "loomscreen.update.nextEligibleAt")
        defaultsSuite.removeObject(forKey: "loomscreen.update.skippedVersion")
    }

    @Test("Surfaces .available when a strictly newer Loomscreen release exists")
    func reportsAvailableForNewerLoomscreenTag() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.1.0", asset: "Loomscreen-1.1.0.dmg")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        guard case .available(let release) = checker.status else {
            Issue.record("Expected .available, got \(String(describing: checker.status))")
            return
        }
        #expect(release.tagName == "loomscreen-v1.1.0")
        #expect(release.version == SemanticVersion(major: 1, minor: 1, patch: 0))
    }

    @Test("Reports .upToDate when the newest tag matches the running version")
    func reportsUpToDateWhenSameVersion() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.0.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.status == .upToDate)
    }

    @Test("Ignores draft and prerelease tags")
    func ignoresDraftAndPrerelease() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v2.0.0", draft: true),
            release(tag: "loomscreen-v1.5.0", prerelease: true),
            release(tag: "loomscreen-v1.0.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.status == .upToDate)
    }

    @Test("Offers the final release to someone running that version's pre-release build")
    func offersFinalReleaseToPrereleaseBuild() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v0.6.0", asset: "Loomscreen-0.6.0.dmg"),
            release(tag: "loomscreen-v0.6.0-beta.2", prerelease: true)
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "0.6.0-beta.1"
        )

        await checker.checkNow(force: false)

        guard case .available(let release) = checker.status else {
            Issue.record("Expected .available, got \(String(describing: checker.status))")
            return
        }
        #expect(release.tagName == "loomscreen-v0.6.0")
    }

    @Test("Ignores tags missing the loomscreen-v prefix (e.g. Pro tags)")
    func ignoresProTags() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "v3.5.0"),
            release(tag: "loomscreen-v1.0.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.status == .upToDate)
    }

    @Test("Honors user-skipped version")
    func honorsSkippedVersion() async {
        resetDefaults()
        defaultsSuite.set("loomscreen-v1.1.0", forKey: "loomscreen.update.skippedVersion")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.1.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.status == .upToDate)
    }

    @Test("Still surfaces newer-than-skipped tags")
    func newerThanSkippedStillSurfaces() async {
        resetDefaults()
        defaultsSuite.set("loomscreen-v1.1.0", forKey: "loomscreen.update.skippedVersion")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.2.0"),
            release(tag: "loomscreen-v1.1.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        guard case .available(let release) = checker.status else {
            Issue.record("Expected .available, got \(String(describing: checker.status))")
            return
        }
        #expect(release.tagName == "loomscreen-v1.2.0")
    }

    @Test("Reports .failed when the transport throws")
    func reportsFailedOnTransportError() async {
        resetDefaults()
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "test failure" }
        }
        let transport = StubTransport(error: TestError())
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        guard case .failed(let reason) = checker.status else {
            Issue.record("Expected .failed, got \(String(describing: checker.status))")
            return
        }
        #expect(reason == "Unable to check for updates right now.")
    }

    @Test("A failed check records the truthful lastCheckedAt but only backs off failureRetryInterval")
    func failedFetchUsesShortRetryWindow() async {
        resetDefaults()
        struct TestError: Error { }
        let transport = StubTransport(error: TestError())
        let attemptInstant = Date(timeIntervalSince1970: 1_000_000)
        let checker = UpdateChecker(
            transport: transport,
            now: { attemptInstant },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.lastCheckedAt == attemptInstant)
        #expect(defaultsSuite.object(forKey: "loomscreen.update.lastCheckedAt") as? Date == attemptInstant)
        let expectedNext = attemptInstant.addingTimeInterval(UpdateChecker.failureRetryInterval)
        #expect(defaultsSuite.object(forKey: "loomscreen.update.nextEligibleAt") as? Date == expectedNext)
        guard case .failed = checker.status else {
            Issue.record("Expected .failed after transport error.")
            return
        }
    }

    @Test("A transient failure does NOT suppress the next auto-check for the full 12h window")
    func transientFailureRetriesAfterShortWindow() async {
        resetDefaults()
        struct TestError: Error { }
        let failInstant = Date(timeIntervalSince1970: 1_000_000)
        let failing = StubTransport(error: TestError())
        let firstChecker = UpdateChecker(
            transport: failing,
            now: { failInstant },
            currentVersionString: "1.0.0"
        )
        await firstChecker.checkNow(force: false)
        #expect(failing.fetchCount == 1)

        let retryInstant = failInstant.addingTimeInterval(90 * 60)
        let succeeding = StubTransport(releases: [
            release(tag: "loomscreen-v2.0.0")
        ])
        let secondChecker = UpdateChecker(
            transport: succeeding,
            now: { retryInstant },
            currentVersionString: "1.0.0"
        )
        await secondChecker.checkNow(force: false)

        #expect(succeeding.fetchCount == 1, "A retry after the short failure window must fetch.")
        guard case .available = secondChecker.status else {
            Issue.record("Expected .available on the successful retry.")
            return
        }
    }

    @Test("A successful check schedules the full 12h throttle window")
    func successSchedulesFullThrottle() async {
        resetDefaults()
        let instant = Date(timeIntervalSince1970: 1_000_000)
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.0.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { instant },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        let expectedNext = instant.addingTimeInterval(UpdateChecker.throttleInterval)
        #expect(defaultsSuite.object(forKey: "loomscreen.update.nextEligibleAt") as? Date == expectedNext)
        #expect(checker.status == .upToDate)
    }

    @Test("Upgraders with only a legacy lastCheckedAt still honor the 12h window")
    func legacyLastCheckedDerivesThrottle() async {
        resetDefaults()
        let last = Date(timeIntervalSince1970: 1_000_000)
        defaultsSuite.set(last, forKey: "loomscreen.update.lastCheckedAt")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v9.9.9")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { last.addingTimeInterval(60 * 60) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(transport.fetchCount == 0, "Derived 12h window must still throttle upgraders.")
        #expect(checker.status == .idle)
    }

    @Test("Treats backwards-running wall clock as stale (proceeds with the check)")
    func clockSkewTreatedAsStale() async {
        resetDefaults()
        let futureLastCheck = Date(timeIntervalSince1970: 2_000_000)
        defaultsSuite.set(futureLastCheck, forKey: "loomscreen.update.lastCheckedAt")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.1.0", asset: "Loomscreen-1.1.0.dmg")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(transport.fetchCount == 1)
        guard case .available = checker.status else {
            Issue.record("Expected .available; clock skew should not suppress checks.")
            return
        }
    }

    @Test("Falls back to the canonical releases page when html_url is hostile")
    func hostileHtmlUrlFallsBackToCanonical() async {
        resetDefaults()
        let hostile = GitHubRelease(
            tagName: "loomscreen-v1.1.0",
            body: nil,
            draft: false,
            prerelease: false,
            publishedAt: nil,
            htmlURL: URL(string: "https://evil.example.com/releases/tag/loomscreen-v1.1.0"),
            assets: []
        )
        let transport = StubTransport(releases: [hostile])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        guard case .available(let release) = checker.status else {
            Issue.record("Expected .available, got \(String(describing: checker.status))")
            return
        }
        #expect(release.releasePageURL == UpdateChecker.releasesPage)
    }

    @Test("Truncates oversized release notes body")
    func truncatesOversizedBody() async {
        resetDefaults()
        let large = String(repeating: "x", count: 10_000)
        let bigBody = GitHubRelease(
            tagName: "loomscreen-v1.1.0",
            body: large,
            draft: false,
            prerelease: false,
            publishedAt: nil,
            htmlURL: URL(string: "https://github.com/Paradox07127/macos-wallpaperengine/releases/tag/loomscreen-v1.1.0"),
            assets: []
        )
        let transport = StubTransport(releases: [bigBody])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        guard case .available(let release) = checker.status else {
            Issue.record("Expected .available, got \(String(describing: checker.status))")
            return
        }
        #expect(release.body.count == UpdateChecker.maximumReleaseBodyCharacters)
    }

    @Test("Skips network call when inside the 12-hour throttle window")
    func skipsThrottledCalls() async {
        resetDefaults()
        let recent = Date(timeIntervalSince1970: 1_000_000)
        defaultsSuite.set(recent, forKey: "loomscreen.update.lastCheckedAt")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v9.9.9")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { recent.addingTimeInterval(60 * 60) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.status == .idle)
        #expect(transport.fetchCount == 0)
    }

    @Test("Honors force=true even when inside the throttle window")
    func forceIgnoresThrottle() async {
        resetDefaults()
        let recent = Date(timeIntervalSince1970: 1_000_000)
        defaultsSuite.set(recent, forKey: "loomscreen.update.lastCheckedAt")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v2.0.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { recent.addingTimeInterval(60 * 60) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: true)

        #expect(transport.fetchCount == 1)
        guard case .available(let release) = checker.status else {
            Issue.record("Expected .available, got \(String(describing: checker.status))")
            return
        }
        #expect(release.tagName == "loomscreen-v2.0.0")
    }

    @Test("skipCurrentAvailable persists the tag and clears the banner")
    func skipCurrentPersistsTag() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.1.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)
        checker.skipCurrentAvailable()

        #expect(checker.status == .upToDate)
        #expect(defaultsSuite.string(forKey: "loomscreen.update.skippedVersion") == "loomscreen-v1.1.0")
    }

    @Test("Decodes a realistic GitHub Releases response")
    func decodesRealisticJSON() throws {
        let json = """
        [
          {
            "tag_name": "loomscreen-v1.0.1",
            "body": "First public release.",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-06-01T12:00:00Z",
            "html_url": "https://github.com/Paradox07127/macos-wallpaperengine/releases/tag/loomscreen-v1.0.1",
            "assets": [
              {
                "name": "Loomscreen-1.0.1.dmg",
                "browser_download_url": "https://github.com/Paradox07127/macos-wallpaperengine/releases/download/loomscreen-v1.0.1/Loomscreen-1.0.1.dmg"
              }
            ]
          }
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let releases = try decoder.decode([GitHubRelease].self, from: Data(json.utf8))
        #expect(releases.count == 1)
        let r = releases[0]
        #expect(r.tagName == "loomscreen-v1.0.1")
        #expect(r.draft == false)
        #expect(r.prerelease == false)
        #expect(r.assets.first?.name == "Loomscreen-1.0.1.dmg")
        #expect(r.htmlURL?.absoluteString.contains("loomscreen-v1.0.1") == true)
    }

    @Test("One malformed release object doesn't fail decoding the rest of the array")
    func lossyArraySalvagesValidReleasesAroundAMalformedOne() throws {
        let json = """
        [
          { "tag_name": "loomscreen-v1.0.0", "draft": false, "prerelease": false, "assets": [] },
          { "tag_name": "loomscreen-v1.1.0", "draft": false, "prerelease": "not-a-bool", "assets": [] },
          { "tag_name": "loomscreen-v1.2.0", "draft": false, "prerelease": false, "assets": [] }
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let releases = try decoder.decode(LossyArray<GitHubRelease>.self, from: Data(json.utf8)).elements

        #expect(releases.map(\.tagName) == ["loomscreen-v1.0.0", "loomscreen-v1.2.0"])
    }

    @Test("A completely non-array payload still fails (lossiness is per-element, not per-response)")
    func lossyArrayStillThrowsOnNonArrayRoot() {
        let json = "{ \"not\": \"an array\" }"
        let decoder = JSONDecoder()
        #expect(throws: (any Error).self) {
            try decoder.decode(LossyArray<GitHubRelease>.self, from: Data(json.utf8))
        }
    }

    // MARK: - Helpers

    private func release(
        tag: String,
        asset: String? = nil,
        draft: Bool = false,
        prerelease: Bool = false
    ) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            body: nil,
            draft: draft,
            prerelease: prerelease,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            htmlURL: URL(string: "https://github.com/Paradox07127/macos-wallpaperengine/releases/tag/\(tag)"),
            assets: asset.map { name in
                [GitHubRelease.Asset(
                    name: name,
                    browserDownloadURL: URL(string: "https://github.com/Paradox07127/macos-wallpaperengine/releases/download/\(tag)/\(name)")
                )]
            } ?? []
        )
    }
}

private final class StubTransport: UpdateCheckerTransport, @unchecked Sendable {
    private let response: Result<[GitHubRelease], Error>
    private(set) var fetchCount = 0

    init(releases: [GitHubRelease]) {
        self.response = .success(releases)
    }

    init(error: Error) {
        self.response = .failure(error)
    }

    func fetchReleases(from url: URL) async throws -> [GitHubRelease] {
        fetchCount += 1
        switch response {
        case .success(let releases): return releases
        case .failure(let error): throw error
        }
    }
}

@Suite("URLSessionUpdateCheckerTransport bounded fetch")
struct URLSessionUpdateCheckerTransportBoundedFetchTests {
    @Test("Rejects a declared Content-Length over the cap before reading any body")
    func rejectsOversizedDeclaredLength() async {
        UpdateCheckerURLProtocolStub.plan = { _ in
            .http(
                status: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Content-Length": "\(URLSessionUpdateCheckerTransport.maximumResponseBytes + 1)",
                ],
                body: Data("[]".utf8)
            )
        }
        let transport = Self.makeTransport()
        do {
            _ = try await transport.fetchReleases(from: UpdateChecker.releasesAPI)
            Issue.record("Expected fetchReleases to throw")
        } catch let urlError as URLError {
            #expect(urlError.code == .dataLengthExceedsMaximum)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }
    }

    @Test("Aborts once the streamed body exceeds the cap when Content-Length is absent")
    func abortsOnOversizedStreamedBody() async {
        let oversized = Data(repeating: 0x5B, count: URLSessionUpdateCheckerTransport.maximumResponseBytes + 1)
        UpdateCheckerURLProtocolStub.plan = { _ in
            .http(status: 200, headers: ["Content-Type": "application/json"], body: oversized)
        }
        let transport = Self.makeTransport()
        do {
            _ = try await transport.fetchReleases(from: UpdateChecker.releasesAPI)
            Issue.record("Expected fetchReleases to throw")
        } catch let urlError as URLError {
            #expect(urlError.code == .dataLengthExceedsMaximum)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }
    }

    @Test("Still decodes a normal-size response")
    func succeedsForNormalResponse() async throws {
        let json = """
        [{"tag_name":"loomscreen-v1.0.0","body":null,"draft":false,"prerelease":false,"published_at":"2026-06-01T12:00:00Z","html_url":"https://github.com/Paradox07127/macos-wallpaperengine/releases/tag/loomscreen-v1.0.0","assets":[]}]
        """
        UpdateCheckerURLProtocolStub.plan = { _ in
            .http(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        }
        let transport = Self.makeTransport()
        let releases = try await transport.fetchReleases(from: UpdateChecker.releasesAPI)
        #expect(releases.map(\.tagName) == ["loomscreen-v1.0.0"])
    }

    private static func makeTransport() -> URLSessionUpdateCheckerTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateCheckerURLProtocolStub.self]
        return URLSessionUpdateCheckerTransport(session: URLSession(configuration: config))
    }
}

private final class UpdateCheckerURLProtocolStub: URLProtocol, @unchecked Sendable {
    enum Plan: @unchecked Sendable {
        case http(status: Int, headers: [String: String], body: Data)
        case error(Error)
    }

    nonisolated(unsafe) static var plan: (@Sendable (URLRequest) -> Plan)?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let plan = Self.plan else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch plan(request) {
        case let .http(status, headers, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
