import Foundation
import Testing
@testable import LiveWallpaper

@Suite("SteamCMD package download retry")
struct SteamCMDDownloadRetryTests {
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
        // Literal counts, not `maxAttempts`: asserting against the constant
        // restates the implementation.
        #expect(download.attempts == 2)
        #expect(download.waits == [SteamCMDDownloadRetryPolicy.retryDelay])
    }

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
