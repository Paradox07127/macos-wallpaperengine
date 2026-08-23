import Foundation
import Testing
@testable import LiveWallpaper

@Suite("ClaudeSessionScanner: discovery + liveness")
struct ClaudeSessionScannerTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("projects/-Users-me-proj", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        return root
    }

    private func writeTranscript(root: URL, projectDir: String, sessionId: String, ageHours: Double) throws {
        let dir = root.appendingPathComponent("projects/\(projectDir)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionId).jsonl")
        try "{\"type\":\"user\",\"sessionId\":\"\(sessionId)\"}\n".data(using: .utf8)!.write(to: url)
        let mtime = Date().addingTimeInterval(-ageHours * 3600)
        try FileManager.default.setAttributes([.modificationDate: mtime],
                                              ofItemAtPath: url.path(percentEncoded: false))
    }

    private func writeDescriptor(root: URL, pid: Int32, sessionId: String, startedAt: Date?) throws {
        var dict: [String: Any] = ["pid": Int(pid), "sessionId": sessionId, "cwd": "/Users/me/proj", "kind": "interactive"]
        if let startedAt { dict["startedAt"] = startedAt.timeIntervalSince1970 * 1000 }
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: root.appendingPathComponent("sessions/\(pid).json"))
    }

    @Test("discovers recent transcripts, newest first, and skips stale ones")
    func discoversRecentTranscripts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "recent", ageHours: 1)
        try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "older", ageHours: 10)
        try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "stale", ageHours: 100)

        var scanner = ClaudeSessionScanner(rootURL: root)
        let found = try scanner.discoverTranscripts()

        let ids = found.map(\.sessionId)
        #expect(ids.contains("recent"))
        #expect(ids.contains("older"))
        #expect(!ids.contains("stale"), "transcript beyond 48h lookback must be excluded")
        #expect(ids.first == "recent", "newest transcript must sort first")
    }

    @Test("discovery caps at the limit")
    func discoveryRespectsLimit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 0..<10 {
            try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "s\(i)", ageHours: Double(i) * 0.1)
        }
        var scanner = ClaudeSessionScanner(rootURL: root)
        let found = try scanner.discoverTranscripts(limit: 3)
        #expect(found.count == 3)
    }

    @Test("discovery on an unreadable projects root throws")
    func discoveryThrowsWhenRootMissing() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        var scanner = ClaudeSessionScanner(rootURL: bogus)
        var thrown: (any Error)?
        do {
            _ = try scanner.discoverTranscripts()
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
    }

    @Test("current process pid is alive; pid 99999999 is dead")
    func livenessReflectsRealProcesses() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfStart = ClaudeSessionScanner.processStartTime(pid: selfPID)
        try writeDescriptor(root: root, pid: selfPID, sessionId: "live-session", startedAt: selfStart)
        try writeDescriptor(root: root, pid: 99_999_999, sessionId: "dead-session", startedAt: Date())

        let scanner = ClaudeSessionScanner(rootURL: root)
        let descriptors = scanner.loadPIDDescriptors()
        #expect(descriptors.count == 2)

        let liveness = scanner.livenessBySession(descriptors)
        #expect(liveness["live-session"] == true)
        #expect(liveness["dead-session"] == false)
    }

    @Test("PID-reuse guard rejects a live PID whose recorded start time is wrong")
    func pidReuseGuardRejectsMismatchedStart() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let bogusStart = Date(timeIntervalSince1970: 1_000)
        try writeDescriptor(root: root, pid: selfPID, sessionId: "reused", startedAt: bogusStart)

        let scanner = ClaudeSessionScanner(rootURL: root)
        let descriptors = scanner.loadPIDDescriptors()
        if ClaudeSessionScanner.processStartTime(pid: selfPID) != nil {
            #expect(scanner.isAlive(descriptors[0]) == false)
        }
    }

    @Test("missing sessions dir yields no descriptors, not an error")
    func missingSessionsDirIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionScannerTests-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = ClaudeSessionScanner(rootURL: root)
        #expect(scanner.loadPIDDescriptors().isEmpty)
    }

    private func directoryModifiedAt(_ url: URL) throws -> Date {
        try #require(
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        )
    }

    private func appendLine(root: URL, projectDir: String, sessionId: String, mtime: Date) throws {
        let url = root
            .appendingPathComponent("projects/\(projectDir)", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"assistant\"}\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: mtime],
                                              ofItemAtPath: url.path(percentEncoded: false))
    }

    // MARK: - Scan scope

    @Test("an unchanged tree is not re-listed")
    func unchangedTreeIsNotRelisted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "a", ageHours: 1)
        try writeTranscript(root: root, projectDir: "-Users-me-other", sessionId: "b", ageHours: 2)

        var scanner = ClaudeSessionScanner(rootURL: root)
        let first = try scanner.discoverTranscripts()
        let listingsAfterFirst = scanner.directoryListingCount
        #expect(listingsAfterFirst == 3, "projects root + two project directories")

        let second = try scanner.discoverTranscripts()
        #expect(scanner.directoryListingCount == listingsAfterFirst,
                "a tree nobody touched must cost zero directory listings")
        #expect(first.map(\.sessionId) == second.map(\.sessionId))
    }

    @Test("an append to an already-listed transcript is seen although its directory never changed")
    func appendedTranscriptIsRediscovered() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-me-proj", isDirectory: true)

        // Beyond the lookback on the first pass: listed, but not reported.
        try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "resumed", ageHours: 100)
        var scanner = ClaudeSessionScanner(rootURL: root)
        #expect(!(try scanner.discoverTranscripts().map(\.sessionId).contains("resumed")))

        let directoryMTimeBefore = try directoryModifiedAt(projectDir)
        try appendLine(root: root, projectDir: "-Users-me-proj", sessionId: "resumed", mtime: Date())

        #expect(try directoryModifiedAt(projectDir) == directoryMTimeBefore,
                "precondition: an append must not move the directory mtime, or this test proves nothing")
        #expect(try scanner.discoverTranscripts().map(\.sessionId).contains("resumed"),
                "a live session appending to an old transcript must come back into view")
    }

    @Test("a transcript added to an already-listed directory is discovered")
    func newTranscriptInKnownDirectoryIsDiscovered() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "first", ageHours: 1)
        var scanner = ClaudeSessionScanner(rootURL: root)
        _ = try scanner.discoverTranscripts()
        let listingsBefore = scanner.directoryListingCount

        try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "second", ageHours: 0)
        let found = try scanner.discoverTranscripts().map(\.sessionId)
        #expect(found.contains("second"))
        #expect(found.contains("first"))
        #expect(scanner.directoryListingCount > listingsBefore,
                "a directory whose entries changed must be re-listed")
    }

    @Test("a brand new project directory is discovered")
    func newProjectDirectoryIsDiscovered() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "known", ageHours: 1)
        var scanner = ClaudeSessionScanner(rootURL: root)
        _ = try scanner.discoverTranscripts()

        try writeTranscript(root: root, projectDir: "-Users-me-fresh", sessionId: "newborn", ageHours: 0)
        let found = try scanner.discoverTranscripts().map(\.sessionId)
        #expect(found.contains("newborn"))
        #expect(found.contains("known"))
    }

    @Test("a deleted transcript stops being reported")
    func deletedTranscriptDisappears() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTranscript(root: root, projectDir: "-Users-me-proj", sessionId: "doomed", ageHours: 1)
        var scanner = ClaudeSessionScanner(rootURL: root)
        #expect(try scanner.discoverTranscripts().map(\.sessionId).contains("doomed"))

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("projects/-Users-me-proj/doomed.jsonl"))
        #expect(!(try scanner.discoverTranscripts().map(\.sessionId).contains("doomed")))
    }
}
