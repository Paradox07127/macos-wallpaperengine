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

}
