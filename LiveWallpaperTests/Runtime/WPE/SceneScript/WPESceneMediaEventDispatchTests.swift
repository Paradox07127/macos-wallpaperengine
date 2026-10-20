import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing
import UniformTypeIdentifiers

/// Nothing in this file may reach `NowPlayingMonitor.shared`, which observes the user's real Spotify/Music via DistributedNotificationCenter.
@MainActor
final class FakeNowPlayingSource: WPENowPlayingEventSource {
    private var handlers: [UUID: @Sendable (UInt64, MonitorNowPlayingState) -> Void] = [:]
    private var ordinal: UInt64 = 0

    var subscriberCount: Int {
        handlers.count
    }
    private(set) var replayedState = MonitorNowPlayingState(phase: .noPlayer, title: "")

    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        handlers[id] = handler
        // Mirrors NowPlayingMonitor: subscribing replays current state at once.
        handler(ordinal, replayedState)
    }

    func unsubscribe(id: UUID) {
        handlers.removeValue(forKey: id)
    }

    func push(_ state: MonitorNowPlayingState) {
        replayedState = state
        ordinal += 1
        for handler in handlers.values { handler(ordinal, state) }
    }

    /// Same state, next ordinal — the diff gate must swallow this.
    func repush() {
        push(replayedState)
    }
}

@Suite("WPE shared media events", .serialized)
@MainActor
struct WPESceneMediaEventDispatchTests {
    @Test("An unchanged snapshot delivered twice calls each handler once")
    func unchangedSnapshotIsNotRedelivered() {
        var gate = WPESceneMediaDiffGate()
        let playing = WPESceneMediaSnapshot(
            state: .playing,
            properties: WPESceneMediaProperties(title: "Redbone", artist: "Gambino")
        )
        // First delivery after load forces all three events.
        #expect(gate.events(for: playing).count == 3)
        #expect(gate.events(for: playing).isEmpty)

        var paused = playing
        paused.state = .paused
        #expect(gate.events(for: paused) == [.playbackChanged(.paused)])

        var nextTrack = paused
        nextTrack.properties?.title = "Sober"
        #expect(
            gate.events(for: nextTrack)
                == [.propertiesChanged(nextTrack.properties)]
        )
        #expect(gate.events(for: nextTrack).isEmpty)
    }

    @Test("A now-playing state maps onto the frozen playback constants")
    func phaseMapping() {
        func snapshot(_ phase: MonitorNowPlayingPhase) -> WPESceneMediaPlaybackState {
            WPESceneMediaSnapshot(MonitorNowPlayingState(phase: phase, title: "t")).state
        }
        #expect(snapshot(.playing) == .playing)
        #expect(snapshot(.paused) == .paused)
        #expect(snapshot(.noPlayer) == .stopped)
        #expect(snapshot(.awaitingFirstEvent) == .stopped)
        #expect(WPESceneMediaPlaybackState.stopped.rawValue == 0)
        #expect(WPESceneMediaPlaybackState.playing.rawValue == 1)
        #expect(WPESceneMediaPlaybackState.paused.rawValue == 2)
    }

    @Test("A cold launch withholds every event until the source actually reports")
    func awaitingFirstEventWithholdsEverything() {
        var gate = WPESceneMediaDiffGate()

        // Cold launch: nothing has been reported yet — that is the ABSENCE of an observation, not a "stopped" one.
        let awaiting = WPESceneMediaSnapshot(
            MonitorNowPlayingState(phase: .awaitingFirstEvent, title: "")
        )
        #expect(gate.events(for: awaiting).isEmpty)
        #expect(gate.events(for: awaiting).isEmpty, "replays of the unknown state stay silent")

        let playing = WPESceneMediaSnapshot(
            MonitorNowPlayingState(phase: .playing, title: "Into the Sky")
        )
        let first = gate.events(for: playing)
        #expect(first.contains(.playbackChanged(.playing)))
        #expect(first.contains { if case .propertiesChanged = $0 { return true }; return false })
        #expect(first.contains { if case .thumbnailChanged = $0 { return true }; return false })

        // Control: a genuine "no player is running" IS a real state, and still
        // reaches the scene on first delivery.
        var noPlayerGate = WPESceneMediaDiffGate()
        let noPlayer = WPESceneMediaSnapshot(
            MonitorNowPlayingState(phase: .noPlayer, title: "")
        )
        #expect(noPlayerGate.events(for: noPlayer).contains(.playbackChanged(.stopped)))
    }

    // MARK: - 9. Colour extraction on synthetic images

    /// sRGB PNG bytes, built here so the corpus is not involved.
    private static func image(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> SIMD3<Double>
    ) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let color = pixel(x, y)
                let index = (y * width + x) * 4
                bytes[index] = UInt8((color.x * 255).rounded())
                bytes[index + 1] = UInt8((color.y * 255).rounded())
                bytes[index + 2] = UInt8((color.z * 255).rounded())
                bytes[index + 3] = 255
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func solidImage(_ color: SIMD3<Double>) throws -> Data {
        try image(width: 64, height: 64) { _, _ in color }
    }

    @Test("A solid red image yields a red-dominant primary, deterministically")
    func solidImageYieldsItsOwnColor() throws {
        let artwork = try Self.solidImage(SIMD3<Double>(0.9, 0.05, 0.05))
        let first = try #require(WPEMediaArtworkPalette.palette(from: artwork))
        let second = try #require(WPEMediaArtworkPalette.palette(from: artwork))
        #expect(first == second, "extraction must not depend on dictionary order")
        #expect(first.hasThumbnail)
        #expect(first.primaryColor.x > 0.8)
        #expect(first.primaryColor.y < 0.2)
        #expect(first.primaryColor.z < 0.2)
        // Nothing else is in the image, so the other two are synthesized shades —
        // still distinct from the primary, never a copy of it.
        #expect(first.secondaryColor != first.primaryColor)
        #expect(first.tertiaryColor != first.primaryColor)
        #expect(first.tertiaryColor != first.secondaryColor)
    }

    /// A naive most-frequent-bucket vote would report the near-white 90% and the scene's accent UI would go blank.
    @Test("A mostly near-white image reports its accent, not the near-white")
    func nearWhiteBackgroundDoesNotWinTheVote() throws {
        let artwork = try Self.image(width: 100, height: 100) { x, y in
            y >= 90 ? SIMD3<Double>(0.05, 0.15, 0.95) : SIMD3<Double>(0.96, 0.96, 0.94)
        }
        let palette = try #require(WPEMediaArtworkPalette.palette(from: artwork))
        #expect(palette.primaryColor.z > 0.7, "the blue accent must win")
        #expect(palette.primaryColor.x < 0.4, "and it must not be the near-white field")
    }

    /// A greyscale cover has no chromatic pixels: the neutral bucket is the only thing between it and a divide-by-zero mean.
    @Test("A greyscale image falls back to the neutral vote instead of NaN")
    func greyscaleArtworkUsesTheNeutralFallback() throws {
        let artwork = try Self.image(width: 64, height: 64) { _, y in
            y < 48 ? SIMD3<Double>(0.5, 0.5, 0.5) : SIMD3<Double>(0.85, 0.85, 0.85)
        }
        let palette = try #require(WPEMediaArtworkPalette.palette(from: artwork))
        #expect(palette.primaryColor.x.isFinite)
        #expect(palette.primaryColor.y.isFinite)
        #expect(palette.primaryColor.z.isFinite)
        #expect(abs(palette.primaryColor.x - 0.5) < 0.1, "the larger grey field wins")
        #expect(abs(palette.primaryColor.x - palette.primaryColor.y) < 0.02)
    }

    @Test("highContrastColor is white on a dark primary and black on a light one")
    func highContrastFollowsTheContrastRatio() throws {
        let dark = SIMD3<Double>(0.05, 0.05, 0.12)
        let light = SIMD3<Double>(0.95, 0.93, 0.80)
        #expect(WPEMediaArtworkPalette.highContrastColor(against: dark) == SIMD3<Double>(1, 1, 1))
        #expect(WPEMediaArtworkPalette.highContrastColor(against: light) == SIMD3<Double>(0, 0, 0))

        let darkPalette = try #require(WPEMediaArtworkPalette.palette(from: Self.solidImage(dark)))
        #expect(darkPalette.highContrastColor == SIMD3<Double>(1, 1, 1))
        #expect(darkPalette.textColor == darkPalette.highContrastColor)
        let lightPalette = try #require(WPEMediaArtworkPalette.palette(from: Self.solidImage(light)))
        #expect(lightPalette.highContrastColor == SIMD3<Double>(0, 0, 0))
        #expect(lightPalette.textColor == lightPalette.highContrastColor)
    }

    @Test("The palette cache returns the same art unchanged and re-extracts new art")
    func paletteCacheKeysOnTheArtworkBytes() throws {
        var cache = WPEMediaArtworkPaletteCache()
        let red = try Self.solidImage(SIMD3<Double>(0.9, 0.05, 0.05))
        let blue = try Self.solidImage(SIMD3<Double>(0.05, 0.05, 0.9))
        let first = cache.thumbnail(for: red)
        #expect(cache.thumbnail(for: red) == first)
        let next = cache.thumbnail(for: blue)
        #expect(next != first)
        #expect(next.primaryColor.z > next.primaryColor.x)
    }

    // MARK: - 10. Thumbnail diff gate and demand

    @Test("An unchanged thumbnail does not re-fire; a changed one does")
    func thumbnailDiffGate() throws {
        var gate = WPESceneMediaDiffGate()
        let red = try #require(
            WPEMediaArtworkPalette.palette(from: Self.solidImage(SIMD3<Double>(0.9, 0.05, 0.05)))
        )
        let blue = try #require(
            WPEMediaArtworkPalette.palette(from: Self.solidImage(SIMD3<Double>(0.05, 0.05, 0.9)))
        )
        var snapshot = WPESceneMediaSnapshot(
            state: .playing,
            properties: WPESceneMediaProperties(title: "Redbone"),
            thumbnail: red
        )
        #expect(gate.events(for: snapshot).count == 3)
        #expect(gate.events(for: snapshot).isEmpty)

        snapshot.thumbnail = blue
        #expect(gate.events(for: snapshot) == [.thumbnailChanged(blue)])
        #expect(gate.events(for: snapshot).isEmpty)

        snapshot.thumbnail = .absent
        #expect(gate.events(for: snapshot) == [.thumbnailChanged(.absent)])
    }

    /// The delivery clock, injected so an interpolated position is deterministic.
    /// Nothing here may consult the wall clock: the assertion is an exact number.
    @MainActor
    private final class FakeClock {
        var now: Double
        init(now: Double) { self.now = now }
    }

    private func timelineEvents(in events: [WPESceneMediaEvent]) -> [WPESceneMediaTimeline] {
        events.compactMap { event in
            if case let .timelineChanged(timeline) = event { return timeline }
            return nil
        }
    }

    private func dispatcher(
        _ source: FakeNowPlayingSource,
        clock: FakeClock
    ) -> WPESceneMediaEventDispatcher {
        WPESceneMediaEventDispatcher(source: source, now: { clock.now })
    }

    /// A raw `position` can be up to ~5s stale (Apple Music reports none, a 5s poll fills it in), so delivering it raw would lag every progress bar.
    @Test("While playing, the delivered position is advanced to the delivery clock")
    func positionIsInterpolatedWhilePlaying() throws {
        let source = FakeNowPlayingSource()
        let clock = FakeClock(now: 1_000)
        let dispatcher = dispatcher(source, clock: clock)
        dispatcher.start()
        _ = dispatcher.mailbox.drain()

        clock.now = 1_007
        source.push(MonitorNowPlayingState(
            phase: .playing,
            title: "Redbone",
            duration: 300,
            position: 12,
            positionSampledAt: 1_000
        ))
        #expect(
            timelineEvents(in: dispatcher.mailbox.drain())
                == [WPESceneMediaTimeline(position: 19, duration: 300)]
        )
    }

    @Test("While paused, the delivered position is not advanced by the clock")
    func pausedPositionIsNotAdvanced() throws {
        let source = FakeNowPlayingSource()
        let clock = FakeClock(now: 1_000)
        let dispatcher = dispatcher(source, clock: clock)
        dispatcher.start()
        _ = dispatcher.mailbox.drain()

        clock.now = 1_090
        source.push(MonitorNowPlayingState(
            phase: .paused,
            title: "Redbone",
            duration: 300,
            position: 12,
            positionSampledAt: 1_000
        ))
        #expect(
            timelineEvents(in: dispatcher.mailbox.drain())
                == [WPESceneMediaTimeline(position: 12, duration: 300)]
        )
    }

    /// Without the clamp a stalled source would report a position past the end,
    /// and a progress bar authored as `position / duration` would overrun its track.
    @Test("An interpolated position is clamped to the duration")
    func positionIsClampedToDuration() throws {
        let source = FakeNowPlayingSource()
        let clock = FakeClock(now: 1_000)
        let dispatcher = dispatcher(source, clock: clock)
        dispatcher.start()
        _ = dispatcher.mailbox.drain()

        clock.now = 1_060
        source.push(MonitorNowPlayingState(
            phase: .playing,
            title: "Redbone",
            duration: 300,
            position: 290,
            positionSampledAt: 1_000
        ))
        #expect(
            timelineEvents(in: dispatcher.mailbox.drain())
                == [WPESceneMediaTimeline(position: 300, duration: 300)]
        )
    }

    /// Silence is contract-compliant here; sending zeros would paint a fake `0:00 / 0:00` bar.
    @Test("Without a position or without a duration the handler is never called")
    func missingTimelineDataDeliversNothing() throws {
        let source = FakeNowPlayingSource()
        let clock = FakeClock(now: 1_000)
        let dispatcher = dispatcher(source, clock: clock)
        dispatcher.start()
        _ = dispatcher.mailbox.drain()

        // Apple Music before the poll lands.
        source.push(MonitorNowPlayingState(
            phase: .playing,
            title: "Redbone",
            duration: 300,
            position: nil,
            positionSampledAt: nil
        ))
        #expect(timelineEvents(in: dispatcher.mailbox.drain()).isEmpty)

        // A live stream: a position but no duration.
        source.push(MonitorNowPlayingState(
            phase: .playing,
            title: "Stream",
            duration: nil,
            position: 12,
            positionSampledAt: 1_000
        ))
        #expect(timelineEvents(in: dispatcher.mailbox.drain()).isEmpty)
    }

}
