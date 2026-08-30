import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing
import UniformTypeIdentifiers

/// GitHub issue #133, second half: `MediaPlaybackEvent` exists now, but nothing
/// ever calls the handlers, so media scenes still render blank text and static
/// UI. WPE has no `register*Listener` and no opt-in flag — the engine calls
/// conventionally-named exported functions on each property script module.
///
/// Every test here drives an injected `FakeNowPlayingSource`. Nothing in this
/// file may reach `NowPlayingMonitor.shared`, which observes the user's real
/// Spotify/Music via DistributedNotificationCenter.
@MainActor
final class FakeNowPlayingSource: WPENowPlayingEventSource {
    private var handlers: [UUID: @Sendable (UInt64, MonitorNowPlayingState) -> Void] = [:]
    private var ordinal: UInt64 = 0

    /// The demand-gate assertion: a scene with no media handler must never
    /// reach `subscribe`.
    var subscriberCount: Int { handlers.count }
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

@Suite("WPE SceneScript media event dispatch", .serialized)
@MainActor
struct WPESceneMediaEventDispatchTests {
    private let isolatedGovernor = WPESceneScriptExecutionGovernor(limit: 4)

    private func textInstance(script: String) throws -> LiveWallpaper.WPESceneScriptInstance {
        try LiveWallpaper.WPESceneScriptInstance(
            script: script,
            initialValue: "no-media",
            setupBudget: 2,
            tickBudget: 0.5,
            governor: isolatedGovernor
        )
    }

    private func layerInstance(script: String) throws -> LiveWallpaper.WPELayerScriptInstance {
        try LiveWallpaper.WPELayerScriptInstance(
            script: script,
            setupBudget: 2,
            tickBudget: 0.5,
            initialVisible: false,
            governor: isolatedGovernor
        )
    }

    private func document(scripts: [String: String]) throws -> WPESceneDocument {
        var object: [String: Any] = [
            "id": "1", "name": "label", "type": "text", "text": "0%"
        ]
        for (field, script) in scripts {
            switch field {
            case "text": object["text"] = ["value": "0%", "script": script]
            case "visible": object["visible"] = ["value": true, "script": script]
            case "scale": object["scale"] = ["value": "1 1 1", "script": script]
            default: break
            }
        }
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [object]
        ]
        return try WPESceneDocumentParser.parse(
            data: try JSONSerialization.data(withJSONObject: payload, options: [])
        )
    }

    // MARK: - 1. mediaPlaybackChanged reaches a layer-visibility script

    /// The canonical corpus body, e.g. scene 3713073223's visibility script.
    @Test("A layer script's mediaPlaybackChanged receives state 1 while playing")
    func playbackChangedReachesLayerScript() throws {
        let instance = try layerInstance(script: """
        var mediaState = MediaPlaybackEvent.PLAYBACK_STOPPED;
        export function mediaPlaybackChanged(event) { mediaState = event.state; }
        export function update() {
            thisLayer.visible = mediaState === MediaPlaybackEvent.PLAYBACK_PLAYING;
        }
        """)
        #expect(instance.mediaHandlers.playback, "the module exports the handler")
        instance.dispatchMediaEvent(.playbackChanged(.playing))
        // update() must be able to read what the handler stored.
        #expect(instance.tick()?.own.visible == true)

        instance.dispatchMediaEvent(.playbackChanged(.paused))
        #expect(instance.tick()?.own.visible == false)
    }

    // MARK: - 2. mediaPropertiesChanged reaches a text script

    @Test("A text script's mediaPropertiesChanged receives title and artist")
    func propertiesChangedReachesTextScript() throws {
        let instance = try textInstance(script: """
        var line = 'none';
        export function mediaPropertiesChanged(event) {
            line = event.title + ' - ' + event.artist;
        }
        export function update(value) { return line; }
        """)
        #expect(instance.mediaHandlers.properties)
        instance.dispatchMediaEvent(.propertiesChanged(
            WPESceneMediaProperties(title: "Redbone", artist: "Childish Gambino")
        ))
        #expect(instance.tickString() == "Redbone - Childish Gambino")
    }

    /// The docs are explicit that most players fill in only title and artist.
    /// Scripts concatenate these fields, so `undefined` would render the literal
    /// text "undefined" on the wallpaper.
    @Test("Fields we cannot source arrive as empty strings, never undefined")
    func unavailableFieldsAreEmptyStrings() throws {
        let instance = try textInstance(script: """
        var report = 'none';
        export function mediaPropertiesChanged(event) {
            var fields = ['subTitle', 'albumTitle', 'albumArtist', 'genres', 'contentType'];
            report = fields.map(function (f) {
                return typeof event[f] === 'string' ? f + '=str' : f + '=' + typeof event[f];
            }).join(',');
        }
        export function update(value) { return report; }
        """)
        instance.dispatchMediaEvent(.propertiesChanged(WPESceneMediaProperties(title: "t")))
        #expect(
            instance.tickString()
                == "subTitle=str,albumTitle=str,albumArtist=str,genres=str,contentType=str"
        )
    }

    // MARK: - 3. Field diff, not every tick

    @Test("An unchanged snapshot delivered twice calls each handler once")
    func unchangedSnapshotIsNotRedelivered() {
        var gate = WPESceneMediaDiffGate()
        let playing = WPESceneMediaSnapshot(
            state: .playing,
            properties: WPESceneMediaProperties(title: "Redbone", artist: "Gambino")
        )
        // First delivery after load forces all three events.
        #expect(gate.events(for: playing).count == 3)
        // Same snapshot again: nothing moved, so nothing is dispatched.
        #expect(gate.events(for: playing).isEmpty)

        // Only the state moved.
        var paused = playing
        paused.state = .paused
        #expect(gate.events(for: paused) == [.playbackChanged(.paused)])

        // Only the properties moved.
        var nextTrack = paused
        nextTrack.properties.title = "Sober"
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

        // Cold launch: nothing has been reported yet — that is the ABSENCE of an
        // observation, not one. Delivering PLAYBACK_STOPPED latched author
        // scripts that gate on stop, and delivering the EMPTY properties made
        // scenes run their track-change animation into a blank title and park
        // there (3326873240's flip froze at scale 0). WPE simply does not call
        // handlers until it has data.
        let awaiting = WPESceneMediaSnapshot(
            MonitorNowPlayingState(phase: .awaitingFirstEvent, title: "")
        )
        #expect(gate.events(for: awaiting).isEmpty)
        #expect(gate.events(for: awaiting).isEmpty, "replays of the unknown state stay silent")

        // The first real snapshot is the first delivery: every field force-fires.
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

    // MARK: - 4. A throwing handler backs off alone

    /// Keyed by handler name, like the cursor handlers: a broken
    /// `mediaPropertiesChanged` must not take down `update()` — that is exactly
    /// the failure mode issue #133 reported, one level down.
    @Test("A throwing media handler is backed off without disabling update()")
    func throwingHandlerDoesNotGateUpdate() throws {
        let instance = try textInstance(script: """
        var playback = 'none';
        export function mediaPropertiesChanged(event) { throw new Error('boom'); }
        export function mediaPlaybackChanged(event) { playback = 'state' + event.state; }
        export function update(value) { return playback; }
        """)
        for _ in 0 ..< 8 {
            instance.dispatchMediaEvent(.propertiesChanged(WPESceneMediaProperties(title: "t")))
        }
        // The other media handler still runs...
        instance.dispatchMediaEvent(.playbackChanged(.playing))
        #expect(instance.tickString() == "state1")
        // ...and so does update().
        instance.dispatchMediaEvent(.playbackChanged(.paused))
        #expect(instance.tickString() == "state2")
    }

    // MARK: - 5. Demand gate

    @Test("A scene exporting no media handler creates no subscription")
    func noHandlerMeansNoSubscription() throws {
        let source = FakeNowPlayingSource()
        let silent = try document(scripts: [
            "text": "export function update(value) { return value; }"
        ])
        #expect(!WPESceneMediaEventDispatcher.isNeeded(by: silent))
        #expect(source.subscriberCount == 0)
    }

    @Test("A scene exporting a media handler does subscribe and does receive events")
    func handlerMeansSubscription() throws {
        let source = FakeNowPlayingSource()
        let scene = try document(scripts: [
            "text": """
            export function mediaPropertiesChanged(event) {}
            export function update(value) { return value; }
            """
        ])
        #expect(WPESceneMediaEventDispatcher.isNeeded(by: scene))
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        dispatcher.start()
        #expect(source.subscriberCount == 1)
        // The synchronous replay on subscribe is the first, forced delivery.
        #expect(dispatcher.mailbox.drain().count == 3)

        source.push(MonitorNowPlayingState(phase: .playing, title: "Redbone", artist: "Gambino"))
        let events = dispatcher.mailbox.drain()
        #expect(events.contains(.playbackChanged(.playing)))
        #expect(events.contains(.propertiesChanged(WPESceneMediaProperties(
            title: "Redbone", artist: "Gambino"
        ))))

        // An unchanged repush posts nothing — the mailbox stays empty.
        source.repush()
        #expect(dispatcher.mailbox.drain().isEmpty)
    }

    /// `mediaPlaybackChanged` is authored on visibility scripts, not text ones,
    /// so the demand scan has to cover every script slot a corpus scene uses.
    @Test("The demand scan sees a handler on a visibility script too")
    func demandScanCoversVisibilityScripts() throws {
        let scene = try document(scripts: [
            "visible": """
            export function mediaPlaybackChanged(event) {
                thisLayer.visible = event.state !== MediaPlaybackEvent.PLAYBACK_STOPPED;
            }
            """
        ])
        #expect(WPESceneMediaEventDispatcher.isNeeded(by: scene))
    }

    // MARK: - 6. Teardown

    @Test("Teardown releases the subscription")
    func stopReleasesSubscription() throws {
        let source = FakeNowPlayingSource()
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        dispatcher.start()
        #expect(source.subscriberCount == 1)
        dispatcher.stop()
        #expect(source.subscriberCount == 0)

        // A push after teardown must not reach the retired scene's mailbox.
        _ = dispatcher.mailbox.drain()
        source.push(MonitorNowPlayingState(phase: .playing, title: "Later"))
        #expect(dispatcher.mailbox.drain().isEmpty)
    }

    // MARK: - 7. The third runtime (origin/scale/color/shader-constant scripts)

    private func transformInstance(script: String) throws -> WPEDynamicTransformScriptInstance {
        try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(1920, 1080),
            setupBudget: 2,
            tickBudget: 0.5,
            governor: isolatedGovernor
        )
    }

    /// Corpus scenes 3326873240 / 3369989878 / 3510729512 all bind
    /// `mediaPlaybackChanged` to `scale/script` and `origin/script`, which the
    /// dynamic-transform runtime hosts. It received nothing before this.
    @Test("A dynamic-transform script's mediaPlaybackChanged receives state")
    func playbackChangedReachesTransformScript() throws {
        let instance = try transformInstance(script: """
        var mediaState = MediaPlaybackEvent.PLAYBACK_STOPPED;
        export function mediaPlaybackChanged(event) { mediaState = event.state; }
        export function update(value) { return new Vec3(mediaState, mediaState, mediaState); }
        """)
        #expect(instance.mediaHandlers.playback, "the module exports the handler")
        instance.dispatchMediaEvent(.playbackChanged(.playing))
        #expect(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5))?.x == 1)

        instance.dispatchMediaEvent(.playbackChanged(.paused))
        #expect(instance.tick(pointerPosition: SIMD2<Double>(0.5, 0.5))?.x == 2)
    }

    /// A transform script that exports nothing media-shaped must stay untouched:
    /// `handles` is what keeps every non-media scale script off the event lane.
    @Test("A dynamic-transform script without a media handler reports no demand")
    func transformWithoutHandlerReportsNoDemand() throws {
        let instance = try transformInstance(script: """
        export function update(value) { return value; }
        """)
        #expect(!instance.mediaHandlers.playback)
        #expect(!instance.mediaHandlers.properties)
        #expect(!instance.mediaHandlers.thumbnail)
    }

    // MARK: - 8. mediaThumbnailChanged payload

    /// Reports `hasThumbnail` plus each colour as `x,y,z` — or `not-vec3` if the
    /// field is not a real `Vec3`, which corpus colour scripts require (they call
    /// `.mix()` on it and return the result as the transform value).
    private static let thumbnailProbeScript = """
    var report = 'none';
    export function mediaThumbnailChanged(event) {
        var names = [
            'primaryColor', 'secondaryColor', 'tertiaryColor',
            'textColor', 'highContrastColor'
        ];
        report = event.hasThumbnail + '|' + names.map(function (name) {
            var c = event[name];
            if (!(c instanceof Vec3)) { return 'not-vec3'; }
            return c.x.toFixed(3) + ',' + c.y.toFixed(3) + ',' + c.z.toFixed(3);
        }).join(';');
    }
    export function update(value) { return report; }
    """

    private func thumbnailReport(for thumbnail: WPESceneMediaThumbnail) throws -> [String] {
        let instance = try textInstance(script: Self.thumbnailProbeScript)
        #expect(instance.mediaHandlers.thumbnail)
        instance.dispatchMediaEvent(.thumbnailChanged(thumbnail))
        return instance.tickString().components(separatedBy: "|")
    }

    @Test("A script sees hasThumbnail true and five Vec3 colours when art is present")
    func thumbnailChangedDeliversFiveVectors() throws {
        let artwork = try Self.solidImage(SIMD3<Double>(0.85, 0.1, 0.1))
        let thumbnail = try #require(WPEMediaArtworkPalette.palette(from: artwork))
        let report = try thumbnailReport(for: thumbnail)
        #expect(report.first == "true")
        let colors = try #require(report.last).components(separatedBy: ";")
        #expect(colors.count == 5)
        #expect(!colors.contains("not-vec3"), "corpus colour scripts call Vec3 methods on these")
        // Red-dominant art: the primary's red channel leads by a wide margin.
        #expect(thumbnail.primaryColor.x > 0.6)
        #expect(thumbnail.primaryColor.x > thumbnail.primaryColor.y + 0.4)
    }

    /// The documented no-artwork fallback: black accents, white text. A scene
    /// tinting with `primaryColor` and labelling with `textColor` stays legible.
    @Test("A script sees hasThumbnail false and the neutral fallback when art is nil")
    func thumbnailChangedWithoutArtworkIsNeutral() throws {
        var cache = WPEMediaArtworkPaletteCache()
        let thumbnail = cache.thumbnail(for: nil)
        #expect(thumbnail == WPESceneMediaThumbnail.absent)
        #expect(!thumbnail.hasThumbnail)
        #expect(thumbnail.primaryColor == SIMD3<Double>(0, 0, 0))
        #expect(thumbnail.secondaryColor == SIMD3<Double>(0, 0, 0))
        #expect(thumbnail.tertiaryColor == SIMD3<Double>(0, 0, 0))
        #expect(thumbnail.textColor == SIMD3<Double>(1, 1, 1))
        #expect(thumbnail.highContrastColor == SIMD3<Double>(1, 1, 1))

        let report = try thumbnailReport(for: thumbnail)
        #expect(report.first == "false")
        #expect(report.last == "0.000,0.000,0.000;0.000,0.000,0.000;0.000,0.000,0.000;"
            + "1.000,1.000,1.000;1.000,1.000,1.000")
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

    /// The failure mode a naive most-frequent-bucket vote has: 90% of the pixels
    /// are near-white, so it would report near-white and the scene's accent UI
    /// would go blank.
    @Test("A mostly near-white image reports its accent, not the near-white")
    func nearWhiteBackgroundDoesNotWinTheVote() throws {
        let artwork = try Self.image(width: 100, height: 100) { x, y in
            // Bottom 10 rows are a saturated blue accent; the rest is near-white.
            y >= 90 ? SIMD3<Double>(0.05, 0.15, 0.95) : SIMD3<Double>(0.96, 0.96, 0.94)
        }
        let palette = try #require(WPEMediaArtworkPalette.palette(from: artwork))
        #expect(palette.primaryColor.z > 0.7, "the blue accent must win")
        #expect(palette.primaryColor.x < 0.4, "and it must not be the near-white field")
    }

    /// A black-and-white cover has no chromatic pixels at all. The neutral bucket
    /// is the only thing standing between it and a divide-by-zero mean, and that
    /// branch only exists because near-neutral pixels are held out of the vote.
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

        // End to end, through the extractor: textColor tracks it.
        let darkPalette = try #require(WPEMediaArtworkPalette.palette(from: Self.solidImage(dark)))
        #expect(darkPalette.highContrastColor == SIMD3<Double>(1, 1, 1))
        #expect(darkPalette.textColor == darkPalette.highContrastColor)
        let lightPalette = try #require(WPEMediaArtworkPalette.palette(from: Self.solidImage(light)))
        #expect(lightPalette.highContrastColor == SIMD3<Double>(0, 0, 0))
        #expect(lightPalette.textColor == lightPalette.highContrastColor)
    }

    /// The cache must not be the reason two different covers look the same.
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
        // Forced first delivery covers all three events.
        #expect(gate.events(for: snapshot).count == 3)
        // Same art again: nothing moved.
        #expect(gate.events(for: snapshot).isEmpty)

        snapshot.thumbnail = blue
        #expect(gate.events(for: snapshot) == [.thumbnailChanged(blue)])
        #expect(gate.events(for: snapshot).isEmpty)

        // Losing the art is a change too — the scene must drop back to neutral.
        snapshot.thumbnail = .absent
        #expect(gate.events(for: snapshot) == [.thumbnailChanged(.absent)])
    }

    // MARK: - 11. mediaTimelineChanged

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

    /// Corpus scenes 2955378002 / 3326873240 / 3369989878 / 3510729512 bind
    /// `mediaTimelineChanged` on `origin` and `scale` — the dynamic-transform
    /// runtime. The other two runtimes are asserted here as well because a scene
    /// may bind the same handler to a text or visibility script.
    @Test("A script's mediaTimelineChanged receives position and duration in seconds")
    func timelineChangedReachesEveryRuntime() throws {
        let transform = try transformInstance(script: """
        var pos = -1, dur = -1;
        export function mediaTimelineChanged(event) { pos = event.position; dur = event.duration; }
        export function update(value) { return new Vec3(pos, dur, 0); }
        """)
        #expect(transform.mediaHandlers.timeline, "the module exports the handler")
        transform.dispatchMediaEvent(.timelineChanged(
            WPESceneMediaTimeline(position: 42.5, duration: 217)
        ))
        let value = try #require(transform.tick(pointerPosition: SIMD2<Double>(0.5, 0.5)))
        #expect(value.x == 42.5, "position, in seconds")
        #expect(value.y == 217, "duration, in seconds")

        let text = try textInstance(script: """
        var line = 'none';
        export function mediaTimelineChanged(event) {
            line = event.position + '/' + event.duration;
        }
        export function update(value) { return line; }
        """)
        #expect(text.mediaHandlers.timeline)
        text.dispatchMediaEvent(.timelineChanged(WPESceneMediaTimeline(position: 3, duration: 8)))
        #expect(text.tickString() == "3/8")

        let layer = try layerInstance(script: """
        var seen = false;
        export function mediaTimelineChanged(event) { seen = event.duration > 0; }
        export function update() { thisLayer.visible = seen; }
        """)
        #expect(layer.mediaHandlers.timeline)
        layer.dispatchMediaEvent(.timelineChanged(WPESceneMediaTimeline(position: 1, duration: 8)))
        #expect(layer.tick()?.own.visible == true)
    }

    /// A raw `position` can be up to ~5s stale (Apple Music has no position in its
    /// notification, so a 5s AppleScript poll fills it in). Delivering it raw
    /// would make every progress bar lag by up to a poll interval.
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

    /// The docs tell authors the callback may never fire, so silence is
    /// contract-compliant. Sending zeros would paint a fake `0:00 / 0:00` bar.
    @Test("Without a position or without a duration the handler is never called")
    func missingTimelineDataDeliversNothing() throws {
        let source = FakeNowPlayingSource()
        let clock = FakeClock(now: 1_000)
        let dispatcher = dispatcher(source, clock: clock)
        dispatcher.start()
        _ = dispatcher.mailbox.drain()

        // Apple Music before the poll lands: duration known, position not.
        source.push(MonitorNowPlayingState(
            phase: .playing,
            title: "Redbone",
            duration: 300,
            position: nil,
            positionSampledAt: nil
        ))
        #expect(timelineEvents(in: dispatcher.mailbox.drain()).isEmpty)

        // A player that reports a position but no duration (live stream).
        source.push(MonitorNowPlayingState(
            phase: .playing,
            title: "Stream",
            duration: nil,
            position: 12,
            positionSampledAt: 1_000
        ))
        #expect(timelineEvents(in: dispatcher.mailbox.drain()).isEmpty)
    }

    @Test("A scene exporting only mediaTimelineChanged subscribes")
    func timelineOnlySceneSubscribes() throws {
        let source = FakeNowPlayingSource()
        let scene = try document(scripts: [
            "scale": """
            export function mediaTimelineChanged(event) {}
            export function update(value) { return value; }
            """
        ])
        #expect(WPESceneMediaEventDispatcher.isNeeded(by: scene))
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        dispatcher.start()
        #expect(source.subscriberCount == 1)

        let silent = try document(scripts: [
            "scale": "export function update(value) { return value; }"
        ])
        #expect(!WPESceneMediaEventDispatcher.isNeeded(by: silent))
        #expect(source.subscriberCount == 1, "the silent scene added no second subscription")
    }

    @Test("A scene exporting only mediaThumbnailChanged subscribes")
    func thumbnailOnlySceneSubscribes() throws {
        let source = FakeNowPlayingSource()
        let scene = try document(scripts: [
            "scale": """
            export function mediaThumbnailChanged(event) {}
            export function update(value) { return value; }
            """
        ])
        #expect(WPESceneMediaEventDispatcher.isNeeded(by: scene))
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        dispatcher.start()
        #expect(source.subscriberCount == 1)

        // ...while a scene with no media handler at all still costs nothing.
        let silent = try document(scripts: [
            "scale": "export function update(value) { return value; }"
        ])
        #expect(!WPESceneMediaEventDispatcher.isNeeded(by: silent))
        #expect(source.subscriberCount == 1, "the silent scene added no second subscription")
    }
}
