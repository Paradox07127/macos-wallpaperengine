import Testing
import Foundation
import CoreGraphics
@testable import LiveWallpaper

@Suite("RowMetadata subtitle formatting")
struct PlaylistRowMetadataTests {
    @Test("Subtitle composes resolution, duration, and folder with dot separators")
    func fullSubtitle() {
        let meta = RowMetadata(
            resolution: CGSize(width: 1920, height: 1080),
            duration: 30,
            folder: "Wallpapers"
        )
        #expect(meta.subtitle == "1080p · 0:30 · Wallpapers")
    }

    @Test("Missing resolution drops only the resolution segment")
    func missingResolution() {
        let meta = RowMetadata(
            resolution: nil,
            duration: 30,
            folder: "Wallpapers"
        )
        #expect(meta.subtitle == "0:30 · Wallpapers")
    }

    @Test("Missing duration drops only the duration segment")
    func missingDuration() {
        let meta = RowMetadata(
            resolution: CGSize(width: 1920, height: 1080),
            duration: nil,
            folder: "Wallpapers"
        )
        #expect(meta.subtitle == "1080p · Wallpapers")
    }

    @Test("Empty metadata produces empty subtitle")
    func emptySubtitle() {
        let meta = RowMetadata.empty
        #expect(meta.subtitle == "")
    }

    @Test("Resolution bucketing covers SD through 8K")
    func resolutionBuckets() {
        let cases: [(CGSize, String)] = [
            (CGSize(width: 640, height: 480), "480p"),
            (CGSize(width: 1280, height: 720), "720p"),
            (CGSize(width: 1920, height: 1080), "1080p"),
            (CGSize(width: 2560, height: 1440), "1440p"),
            (CGSize(width: 3840, height: 2160), "4K"),
            (CGSize(width: 7680, height: 4320), "8K"),
        ]
        for (size, expected) in cases {
            let meta = RowMetadata(resolution: size, duration: nil, folder: nil)
            #expect(meta.subtitle == expected, "size=\(size) expected=\(expected)")
        }
    }

    @Test("Unusual resolutions fall back to raw WxH")
    func unusualResolution() {
        let meta = RowMetadata(
            resolution: CGSize(width: 800, height: 100),
            duration: nil,
            folder: nil
        )
        #expect(meta.subtitle == "800×100")
    }

    @Test("Duration formats minutes/seconds without hours when under one hour")
    func durationUnderHour() {
        let meta = RowMetadata(
            resolution: nil,
            duration: 65,
            folder: nil
        )
        #expect(meta.subtitle == "1:05")
    }

    @Test("Duration includes hours when at least one hour")
    func durationWithHours() {
        let meta = RowMetadata(
            resolution: nil,
            duration: 3661,
            folder: nil
        )
        #expect(meta.subtitle == "1:01:01")
    }

    @Test("Non-positive duration is treated as missing")
    func nonPositiveDuration() {
        let meta = RowMetadata(
            resolution: CGSize(width: 1920, height: 1080),
            duration: 0,
            folder: "Wallpapers"
        )
        #expect(meta.subtitle == "1080p · Wallpapers")
    }
}

@MainActor
@Suite("Playlist metadata request lifecycle", .serialized)
struct PlaylistMetadataLifecycleTests {
    private final class Probe {
        var releases: [Int: CheckedContinuation<Void, Never>] = [:]
        var started = 0
        var active = 0
        var peak = 0
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(condition())
    }

    @Test func staleInvalidatedProducerCannotRepopulateCache() async throws {
        let probe = Probe()
        let gate = PreviewWorkGate(limit: 2)
        let service = MetadataService(gate: gate) { _ in
            probe.started += 1
            let generation = probe.started
            await withCheckedContinuation { probe.releases[generation] = $0 }
            return RowMetadata(resolution: nil, duration: Double(generation), folder: nil)
        }
        let bookmark = Data([1])
        let old = Task { await service.metadata(for: bookmark) }
        try await waitUntil { probe.started == 1 }
        service.invalidate(bookmark)
        #expect(await old.value == .empty)
        let replacement = Task { await service.metadata(for: bookmark) }
        try await waitUntil { probe.started == 2 }
        probe.releases[2]?.resume()
        #expect(await replacement.value.duration == 2)
        probe.releases[1]?.resume()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await gate.activeCount > 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(await gate.activeCount == 0)
        #expect(await service.metadata(for: bookmark).duration == 2)
        #expect(probe.started == 2)
    }

    @Test func cancellingOneRowKeepsOtherConsumerAndCache() async throws {
        let probe = Probe()
        let service = MetadataService { _ in
            probe.started += 1
            await withCheckedContinuation { probe.releases[1] = $0 }
            return RowMetadata(resolution: nil, duration: 42, folder: nil)
        }
        let bookmark = Data([2])
        let first = Task { await service.metadata(for: bookmark) }
        try await waitUntil { probe.started == 1 }
        let second = Task { await service.metadata(for: bookmark) }
        try await waitUntil { service.requests.waiterCount == 2 }
        first.cancel()
        #expect(await first.value == .empty)
        probe.releases[1]?.resume()
        #expect(await second.value.duration == 42)
        #expect(await service.metadata(for: bookmark).duration == 42)
        #expect(probe.started == 1)
    }

    @Test func abandonedQueuedRowDoesNotOpenMedia() async throws {
        let probe = Probe()
        let service = MetadataService(gate: PreviewWorkGate(limit: 1)) { _ in
            probe.started += 1
            await withCheckedContinuation { probe.releases[1] = $0 }
            return RowMetadata(resolution: nil, duration: 1, folder: nil)
        }
        let holder = Task { await service.metadata(for: Data([1])) }
        try await waitUntil { probe.started == 1 }
        let queued = Task { await service.metadata(for: Data([2])) }
        try await waitUntil { service.requests.requestCount == 2 }
        queued.cancel()
        #expect(await queued.value == .empty)
        probe.releases[1]?.resume()
        #expect(await holder.value.duration == 1)
        #expect(probe.started == 1)
        #expect(service.requests.requestCount == 0)
    }

    @Test func distinctMediaLoadsRespectBudget() async {
        let probe = Probe()
        let service = MetadataService { data in
            probe.active += 1
            probe.peak = max(probe.peak, probe.active)
            defer { probe.active -= 1 }
            try? await Task.sleep(for: .milliseconds(2))
            return RowMetadata(resolution: nil, duration: Double(data[0]), folder: nil)
        }
        let tasks = (1 ... 40).map { value in Task { await service.metadata(for: Data([UInt8(value)])) } }
        for (index, task) in tasks.enumerated() {
            #expect(await task.value.duration == Double(index + 1))
        }
        #expect(probe.peak == 2)
        #expect(service.requests.requestCount == 0)
    }
}
