import Foundation
@testable import LiveWallpaper
import Testing

@Suite("SteamCMD subscription refresh")
struct SteamCMDSubscriptionRefreshTests {
    private let request = "[2026-10-21 01:15:36] [AppID 431960] Requesting updated subscription list\n"
    private let changed = "[2026-10-21 01:15:37] [AppID 431960] Subscribed items changed. Number of items: 1 (update time: 200)\n"
    private let unchanged = "[2026-10-21 01:15:37] [AppID 431960] Subscribed items did not change. Number of items: 1 (cache update time: 300)\n"

    @Test("Old acknowledgements cannot authorize a cached list or a restarted process")
    func oldLogIsNotARefresh() throws {
        let log = try fixture(request + changed)
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        let refresh = SteamCMDSubscriptionRefresh(logURL: log)
        refresh.poll()
        #expect(refresh.completion == nil)
        try append(changed, to: log)
        refresh.poll()
        #expect(refresh.completion == nil)
        try append(request + changed, to: log)
        refresh.poll()
        #expect(refresh.completion?.subscriptions(in: ledger()) == ["123"])

        let restart = SteamCMDSubscriptionRefresh(logURL: log)
        restart.poll()
        #expect(restart.completion == nil)
    }

    @Test("A delayed complete response is required, then the ledger must match its version and count")
    func delayedResponseRejectsOldCache() throws {
        let log = try fixture("")
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        let refresh = SteamCMDSubscriptionRefresh(logURL: log)
        try append(request, to: log)
        refresh.poll()
        #expect(refresh.completion == nil)
        // A child can flush the acknowledgement across several writes.
        try append(String(changed.dropLast(3)), to: log)
        refresh.poll()
        #expect(refresh.completion == nil)
        try append(String(changed.suffix(3)), to: log)
        refresh.poll()
        let completion = try #require(refresh.completion)
        #expect(completion.subscriptions(in: ledger(time: "100")) == nil)
        #expect(completion.subscriptions(in: ledger(id: nil)) == nil)
        #expect(completion.subscriptions(in: ledger(appID: "730")) == nil)
        #expect(completion.subscriptions(in: ledger()) == ["123"])
        #expect(completion.subscriptions(in: String(ledger().dropLast(3))) == nil)
    }

    @Test("Only a current unchanged response authorizes an existing ledger")
    func unchangedResponseConfirmsCache() throws {
        let log = try fixture("")
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        let refresh = SteamCMDSubscriptionRefresh(logURL: log)
        try append(request + unchanged.replacingOccurrences(of: "431960", with: "730"), to: log)
        refresh.poll()
        #expect(refresh.completion == nil)
        try append(unchanged, to: log)
        refresh.poll()
        let completion = try #require(refresh.completion)
        // Cache update time is a local check time, not the server list version.
        #expect(completion.subscriptions(in: ledger(time: "100")) == ["123"])
        #expect(completion.subscriptions(in: ledger(id: nil)) == nil)
        try append(request, to: log)
        refresh.poll()
        #expect(refresh.completion == nil)
    }

    @Test("A confirmed empty list is distinct from an absent or unconfirmed cache")
    func confirmedEmptyList() throws {
        let log = try fixture("")
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        let refresh = SteamCMDSubscriptionRefresh(logURL: log)
        try append(request + changed.replacingOccurrences(of: "items: 1", with: "items: 0"), to: log)
        refresh.poll()
        let completion = try #require(refresh.completion)
        #expect(completion.subscriptions(in: ledger(id: nil)) == [])
        #expect(completion.subscriptions(in: "") == nil)
    }

    @Test("A linked log is not followed, while a newly created regular log is readable")
    func missingAndLinkedLogs() throws {
        let log = try fixture("")
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: log)
        let refresh = SteamCMDSubscriptionRefresh(logURL: log)
        let outside = log.deletingLastPathComponent().appendingPathComponent("other.txt")
        try (request + changed).write(to: outside, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: outside)
        refresh.poll()
        #expect(refresh.completion == nil)
        try FileManager.default.removeItem(at: log)
        try (request + changed).write(to: log, atomically: false, encoding: .utf8)
        refresh.poll()
        #expect(refresh.completion?.subscriptions(in: ledger()) == ["123"])
    }

    private func ledger(time: String = "200", id: String? = "123", appID: String = "431960") -> String {
        let item = id.map { "\"0\" { \"publishedfileid\" \"\($0)\" }" } ?? ""
        return "\"subscribedfiles\" { \"appid\" \"\(appID)\" \"time_last_updated\" \"\(time)\" \(item) }"
    }

    private func fixture(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("workshop_log.txt")
        try text.write(to: log, atomically: false, encoding: .utf8)
        return log
    }

    private func append(_ text: String, to log: URL) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
