import Foundation
@testable import LiveWallpaper
import os
import Testing

@Suite("Ogg async scheduling and lifetime", .serialized)
struct OggAudioTranscoderSchedulingTests {
    @Test("Coalesced waiters share one decode; cancelling one does not cancel the others")
    func coalescesAndCancelsIndependently() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = DecodeGate()
        defer { gate.release() }
        let transcoder = fixture.transcoder(gate: gate)
        let first = Task { await transcoder.transcodedM4A(forOgg: fixture.source) }
        let second = Task { await transcoder.transcodedM4A(forOgg: fixture.source) }
        try await poll { await transcoder.workSnapshot.waiters == 2 }
        #expect(gate.starts == 1)
        first.cancel()
        #expect(await first.value == nil)
        #expect(await transcoder.workSnapshot.running == 1)
        gate.release()
        let result = await second.value
        #expect(result != nil)
        #expect(await transcoder.transcodedM4A(forOgg: fixture.source) == result)
        #expect(gate.starts == 1)
        try await poll { await transcoder.workSnapshot.running == 0 }
    }

    @Test("Timeout resumes all waiters but keeps the actual decode slot and lease until return")
    func timeoutKeepsSlotAndLease() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = DecodeGate()
        defer { gate.release() }
        let released = OSAllocatedUnfairLock(initialState: false)
        let transcoder = fixture.transcoder(gate: gate, deadline: 0.15)
        var access: OggSourceAccess? = OggSourceAccess(release: { released.withLock { $0 = true } })
        let first = Task { [access] in await transcoder.transcodedM4A(forOgg: fixture.source, access: access) }
        access = nil
        try await poll { gate.starts == 1 }
        let second = Task { await transcoder.transcodedM4A(forOgg: fixture.source) }
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(!released.withLock { $0 })
        #expect(await transcoder.workSnapshot.running == 1)
        #expect(await transcoder.workSnapshot.pending == 0)
        #expect(await transcoder.transcodedM4A(forOgg: fixture.source) == nil)
        gate.release()
        try await poll { await transcoder.workSnapshot.running == 0 }
        try await poll { released.withLock { $0 } }
        #expect(try fixture.cacheFiles().isEmpty)
        #expect(gate.starts == 1)
    }

    @Test("Cancelling a queued job prevents execution and releases its captured resource")
    func queuedCancellationReleasesResources() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = DecodeGate()
        defer { gate.release() }
        let transcoder = fixture.transcoder(gate: gate)
        let running = Task { await transcoder.transcodedM4A(forOgg: fixture.source) }
        try await poll { gate.starts == 1 }
        let other = try fixture.source(named: "other.ogg")
        let released = OSAllocatedUnfairLock(initialState: false)
        var access: OggSourceAccess? = OggSourceAccess(release: { released.withLock { $0 = true } })
        let queued = Task { [access] in await transcoder.transcodedM4A(forOgg: other, access: access) }
        access = nil
        try await poll { await transcoder.workSnapshot.pending == 2 }
        queued.cancel()
        #expect(await queued.value == nil)
        try await poll { released.withLock { $0 } }
        #expect(gate.starts == 1)
        gate.release()
        _ = await running.value
        try await poll { await transcoder.workSnapshot.running == 0 }
        #expect(gate.starts == 1)
    }

    @Test("A cancelled old generation cannot delete or poison a replacement result")
    func lateCancelledGenerationCannotAffectReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = DecodeGate()
        defer { gate.release() }
        let transcoder = fixture.transcoder(gate: gate, concurrency: 2)
        let old = Task { await transcoder.transcodedM4A(forOgg: fixture.source) }
        try await poll { gate.starts == 1 }
        old.cancel()
        #expect(await old.value == nil)
        let replacement = Task { await transcoder.transcodedM4A(forOgg: fixture.source) }
        try await poll { gate.starts == 2 }
        gate.release(index: 2)
        let result = try #require(await replacement.value)
        #expect(try String(contentsOf: result, encoding: .utf8) == "decode 2")
        gate.release(index: 1)
        try await poll { await transcoder.workSnapshot.running == 0 }
        #expect(await transcoder.transcodedM4A(forOgg: fixture.source) == result)
        #expect(try String(contentsOf: result, encoding: .utf8) == "decode 2")
        #expect(try fixture.cacheFiles().count == 1)
    }

    @Test("Pending jobs are bounded without creating a worker for every request")
    func boundsPendingWork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = DecodeGate()
        defer { gate.release() }
        let transcoder = fixture.transcoder(gate: gate, maximumPending: 2)
        let first = Task { await transcoder.transcodedM4A(forOgg: fixture.source) }
        try await poll { gate.starts == 1 }
        let secondURL = try fixture.source(named: "second.ogg")
        let second = Task { await transcoder.transcodedM4A(forOgg: secondURL) }
        try await poll { await transcoder.workSnapshot.pending == 2 }
        let rejectedURL = try fixture.source(named: "rejected.ogg")
        #expect(await transcoder.transcodedM4A(forOgg: rejectedURL) == nil)
        #expect(gate.starts == 1)
        gate.release()
        #expect(await first.value != nil)
        #expect(await second.value != nil)
        try await poll { await transcoder.workSnapshot.running == 0 }
        #expect(gate.starts == 2)
    }

    @Test("Already cancelled requests never enter the decoder")
    func cancelledBeforeAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = DecodeGate()
        defer { gate.release() }
        let transcoder = fixture.transcoder(gate: gate)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await transcoder.transcodedM4A(forOgg: fixture.source)
        }
        #expect(await task.value == nil)
        #expect(gate.starts == 0)
    }

    @Test("Cache maintenance removes only old owned staging files and preserves running decoders")
    func sweepsOrphansWithoutTouchingLiveStaging() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = DecodeGate()
        defer { gate.release() }
        let transcoder = fixture.transcoder(gate: gate)
        let orphan = fixture.cache.appendingPathComponent(".\(String(repeating: "a", count: 64)).\(UUID().uuidString).m4a.partial")
        let unrelated = fixture.cache.appendingPathComponent(".other.partial")
        for file in [orphan, unrelated] {
            try Data("old".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: file.path)
        }
        let task = Task { await transcoder.transcodedM4A(forOgg: fixture.source) }
        try await poll { gate.starts == 1 }
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        let staged = try #require(gate.firstDestination)
        let livePartial = staged.appendingPathExtension("partial")
        try Data("in progress".utf8).write(to: livePartial)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: livePartial.path)
        await transcoder.sweepCacheForTesting()
        #expect(FileManager.default.fileExists(atPath: livePartial.path))
        gate.release()
        #expect(await task.value != nil)
        try await poll { await transcoder.workSnapshot.running == 0 }
        #expect(!FileManager.default.fileExists(atPath: livePartial.path))
    }

    private func poll(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 400 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Condition did not become true")
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let cache: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            cache = root.appendingPathComponent("cache")
            source = root.appendingPathComponent("source.ogg")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: source)
        }

        func source(named name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }

        func transcoder(gate: DecodeGate, concurrency: Int = 1, maximumPending: Int = 32, deadline: TimeInterval = 5) -> OggAudioTranscoder {
            OggAudioTranscoder(
                cacheDirectory: cache, maximumConcurrent: concurrency, maximumPending: maximumPending,
                deadline: deadline, decode: { _, destination, _ in gate.decode(to: destination) }
            )
        }

        func cacheFiles() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The deliberately blocked fake is called on the bounded GCD decode queue, never on a Swift task.
    private final class DecodeGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var count = 0
        private var destinations: [URL] = []
        var firstDestination: URL? {
            condition.lock(); defer { condition.unlock() }; return destinations.first
        }

        private var released: Set<Int> = []
        private var allReleased = false
        var starts: Int {
            condition.lock(); defer { condition.unlock() }; return count
        }

        func decode(to destination: URL) -> URL? {
            condition.lock()
            count += 1
            destinations.append(destination)
            let index = count
            while !allReleased, !released.contains(index) {
                condition.wait()
            }
            condition.unlock()
            // Deliberately ignore cancellation to model an uninterruptible framework call returning late.
            do {
                try Data("decode \(index)".utf8).write(to: destination)
                return destination
            } catch { return nil }
        }

        func release(index: Int? = nil) {
            condition.lock()
            if let index {
                released.insert(index)
            } else {
                allReleased = true
            }
            condition.broadcast()
            condition.unlock()
        }
    }
}
