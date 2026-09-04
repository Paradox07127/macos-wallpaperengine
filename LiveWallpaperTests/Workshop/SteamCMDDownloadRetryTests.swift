import Foundation
import Testing
@testable import LiveWallpaper

/// The managed install's four packages are ~25 MB over one `URLSession`
/// download. Before this policy a single dropped connection failed the whole
/// install, and re-running it was the user's only recourse.
@Suite("SteamCMD package download retry")
struct SteamCMDDownloadRetryTests {
    /// Records attempts and waits so the interleaving is assertable, and so a
    /// test never actually sleeps.
    private final class ScriptedDownload {
        private(set) var attempts = 0
        private(set) var waits: [TimeInterval] = []
        private var outcomes: [Bool]

        init(_ outcomes: [Bool]) { self.outcomes = outcomes }

        func run() -> Bool {
            SteamCMDDownloadRetryPolicy.run(
                attempt: { _ in
                    attempts += 1
                    return outcomes.isEmpty ? false : outcomes.removeFirst()
                },
                wait: { waits.append($0) }
            )
        }
    }

    @Test("A transport failure is retried once and can then succeed")
    func transientFailureIsRetried() {
        let download = ScriptedDownload([false, true])

        #expect(download.run())
        #expect(download.attempts == 2)
        #expect(download.waits == [SteamCMDDownloadRetryPolicy.retryDelay])
    }

    @Test("Control: a first-try success never retries and never waits")
    func successDoesNotRetry() {
        let download = ScriptedDownload([true])

        #expect(download.run())
        #expect(download.attempts == 1)
        #expect(download.waits.isEmpty)
    }

    @Test("Control: a persistent failure gives up instead of looping")
    func persistentFailureIsBounded() {
        let download = ScriptedDownload([false, false, true])

        #expect(!download.run())
        // The third outcome — a success — must never be reached: an outage has
        // to fail the install promptly rather than retry until the caller's
        // 900-second queue budget expires.
        //
        // Literal counts, not `maxAttempts`: asserting the loop ran exactly
        // `maxAttempts` times restates the implementation, and stayed green
        // when the budget was mutated to 1.
        #expect(download.attempts == 2)
        #expect(download.waits == [SteamCMDDownloadRetryPolicy.retryDelay])
    }

    /// Source-level, because the connector target is not linked into the test
    /// bundle: the retry only means anything if the install's own download call
    /// routes through it, and `downloadOnce` must stay the single un-retried
    /// primitive so two retry mechanisms cannot compound.
    @Test("The install's download routes through the retry policy")
    func installDownloadUsesThePolicy() throws {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        let start = try #require(
            source.range(of: "private static func download("),
            "SteamConnector.swift has no download( — the scan is misconfigured, not passing."
        )
        let body = String(source[start.lowerBound...].prefix(600))
        #expect(body.contains("SteamCMDDownloadRetryPolicy.run"))
        #expect(body.contains("downloadOnce("))
        // The digest gate is a separate outcome and must not be inside the
        // retried region: identical bytes arriving twice are not transient.
        let onceStart = try #require(source.range(of: "private static func downloadOnce("))
        let onceBody = String(source[onceStart.lowerBound...].prefix(1_200))
        #expect(!onceBody.contains("SteamCMDDownloadRetryPolicy"))
    }
}
