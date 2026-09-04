import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

// MARK: - Output negotiation (hermetic)

@Suite("Wallpaper video output negotiation")
struct WallpaperVideoPlayerOutputNegotiationTests {

    @Test("Desktop video output negotiates NV12 before BGRA, in the scene-side order")
    func negotiatesNV12BeforeBGRA() {
        #expect(WallpaperVideoOutputNegotiation.negotiatedPixelFormats == [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA
        ])
    }

    @Test("The HDR fallback pins the output to 32BGRA only")
    func hdrFallbackPinsBGRAOnly() throws {
        let attributes = WallpaperVideoOutputNegotiation.pixelBufferAttributes(forcingBGRA: true)
        let formats = try #require(
            attributes[kCVPixelBufferPixelFormatTypeKey as String] as? [OSType]
        )
        #expect(formats == [kCVPixelFormatType_32BGRA])

        let negotiated = WallpaperVideoOutputNegotiation.pixelBufferAttributes(forcingBGRA: false)
        let negotiatedFormats = try #require(
            negotiated[kCVPixelBufferPixelFormatTypeKey as String] as? [OSType]
        )
        #expect(negotiatedFormats.first == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test("Output attributes stay IOSurface-backed and never pin a decode size")
    func attributesCarryIOSurfaceAndNoExplicitSize() {
        for forcingBGRA in [true, false] {
            let attributes = WallpaperVideoOutputNegotiation.pixelBufferAttributes(
                forcingBGRA: forcingBGRA
            )
            #expect(attributes[kCVPixelBufferMetalCompatibilityKey as String] != nil)
            #expect(attributes[kCVPixelBufferIOSurfacePropertiesKey as String] != nil)
            #expect(attributes[kCVPixelBufferWidthKey as String] == nil)
            #expect(attributes[kCVPixelBufferHeightKey as String] == nil)
        }
    }

    @Test("The composition readiness probe no longer hardcodes a BGRA output")
    func readinessProbeUsesNegotiatedFormats() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift"
        )
        let probe = try Self.slice(
            source,
            from: "func prepareForCurrentComposition(",
            to: "private func installPreparedPlayback("
        )
        let compactProbe = Self.compact(probe)

        #expect(
            compactProbe.contains(
                "WallpaperVideoOutputNegotiation.pixelBufferAttributes( forcingBGRA: self.usesExtendedDynamicRange )"
            )
        )
        #expect(!probe.contains("kCVPixelFormatType_32BGRA"))
        // The probe's output must be owned so suspension can drain it.
        #expect(compactProbe.contains("self.bindVideoOutput(nextOutput, to: item)"))
        #expect(!compactProbe.contains("item.add(nextOutput)"))
    }

    private enum SourceContractError: Error {
        case missingBoundary(String)
    }

    private static func slice(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound else {
            throw SourceContractError.missingBoundary(startMarker)
        }
        guard let end = source.range(of: endMarker, range: start ..< source.endIndex)?.lowerBound else {
            throw SourceContractError.missingBoundary(endMarker)
        }
        return String(source[start ..< end])
    }

    private static func compact(_ source: String) -> String {
        source.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Suspension and deep hibernation

@MainActor
@Suite("Wallpaper video suspension and deep hibernation", .serialized)
struct WallpaperVideoPlayerHibernationTests {

    /// Short enough to keep the suite fast, long enough that a countdown that
    /// was supposed to be cancelled has clearly had its chance.
    private static let dwell: Duration = .milliseconds(120)

    @Test("Warm suspend keeps the player, so a paused visible wallpaper never loses its last frame")
    func warmSuspendKeepsThePlayer() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        harness.player.setSuspended(true)

        #expect(harness.player.isSuspended)
        #expect(!harness.player.isHibernated)
        #expect(harness.player.player != nil)
        #expect(!harness.player.isShowingHibernationStillFrameForTesting)

        // No eligibility push: the dwell must never arm, however long we wait.
        try await Task.sleep(for: Self.dwell * 6)
        #expect(!harness.player.isHibernated)
        #expect(harness.player.player != nil)
    }

    @Test("Suspending drains every attached video output")
    func suspendDrainsBoundVideoOutputs() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        #expect(harness.player.attachVideoOutputForTesting())
        #expect(harness.player.boundVideoOutputCountForTesting == 1)

        harness.player.setSuspended(true)

        #expect(harness.player.boundVideoOutputCountForTesting == 0)
    }

    @Test("An absent wallpaper hibernates after the dwell and releases player, looper and mapping")
    func absenceDwellHibernatesAndReleasesResources() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        #expect(harness.player.hasInMemoryAssetLoaderForTesting)

        harness.player.setSuspended(true)
        harness.player.setHibernationEligible(true)

        try await Harness.waitUntil("player hibernates") { harness.player.isHibernated }

        #expect(harness.player.player == nil)
        #expect(!harness.player.hasInMemoryAssetLoaderForTesting)
        #expect(harness.player.boundVideoOutputCountForTesting == 0)
        #expect(!harness.player.isPlaying)
        // Torn down to a still frame, not to nothing — and the window survives.
        #expect(harness.player.isShowingHibernationStillFrameForTesting)
        #expect(harness.player.hasInstalledPlaybackWindow)
    }

    /// The wake rebuild is async, so eligibility can arrive while `player` is
    /// still nil. Gating the dwell on a live player cancelled it, and because
    /// eligibility is event-driven nothing pushed again — the rebuilt player then
    /// stayed fully resident for the rest of the absence.
    @Test("Going absent again during the wake rebuild still hibernates")
    func reAbsenceDuringWakeRearmsTheDwell() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        harness.player.setSuspended(true)
        harness.player.setHibernationEligible(true)
        try await Harness.waitUntil("player hibernates") { harness.player.isHibernated }

        // Wake, then go absent again inside the rebuild window.
        harness.player.setSuspended(false)
        #expect(harness.player.player == nil, "the rebuild is asynchronous, so this is the window under test")
        harness.player.setSuspended(true)
        harness.player.setHibernationEligible(true)

        try await Harness.waitUntil("player hibernates again") { harness.player.isHibernated }
        #expect(harness.player.player == nil)
        #expect(!harness.player.hasInMemoryAssetLoaderForTesting)
    }

    @Test("Resuming rebuilds the player through the normal load path")
    func wakeRebuildsThePlayer() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        harness.player.setSuspended(true)
        harness.player.setHibernationEligible(true)
        try await Harness.waitUntil("player hibernates") { harness.player.isHibernated }

        harness.player.setSuspended(false)
        harness.player.play()

        #expect(!harness.player.isHibernated)
        try await Harness.waitUntil("player rebuilds an item") {
            harness.player.player?.currentItem != nil
        }
        #expect(harness.player.hasInMemoryAssetLoaderForTesting)
        try await Harness.waitUntil("still frame is retired once the layer has a picture") {
            !harness.player.isShowingHibernationStillFrameForTesting
        }
    }

    @Test("Wake rebuilds the frame-rate and colour-space requests instead of restoring a snapshot")
    func wakeRebuildsCompositionFromLiveState() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        harness.player.setVideoColorSpace(.displayP3)
        harness.player.setFrameRateLimit(24)
        try await Harness.waitUntil("frame-rate composition builds") {
            harness.player.currentVideoComposition != nil
        }

        harness.player.setSuspended(true)
        harness.player.setHibernationEligible(true)
        try await Harness.waitUntil("player hibernates") { harness.player.isHibernated }

        // Hibernation drops the composition built against the retired asset.
        #expect(harness.player.currentVideoComposition == nil)
        #expect(harness.player.videoCompositionOwner == .none)
        // The user-facing requests are state, not a snapshot, and survive.
        #expect(harness.player.requestedFrameRateLimit == 24)
        #expect(harness.player.currentColorSpacePreference == .displayP3)

        harness.player.setSuspended(false)
        harness.player.play()

        try await Harness.waitUntil("frame-rate composition is rebuilt after wake") {
            harness.player.currentVideoComposition != nil
                && harness.player.videoCompositionOwner == .frameRate
        }
    }

    @Test("Losing eligibility during the dwell cancels hibernation")
    func eligibilityFlipCancelsTheDwell() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        harness.player.setSuspended(true)
        harness.player.setHibernationEligible(true)
        harness.player.setHibernationEligible(false)

        try await Task.sleep(for: Self.dwell * 6)

        #expect(!harness.player.isHibernated)
        #expect(harness.player.player != nil)
    }

    @Test("Resuming during the dwell cancels hibernation")
    func resumeDuringDwellCancelsHibernation() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        harness.player.setSuspended(true)
        harness.player.setHibernationEligible(true)
        harness.player.setSuspended(false)

        try await Task.sleep(for: Self.dwell * 6)

        #expect(!harness.player.isHibernated)
        #expect(harness.player.player != nil)
    }

    @Test("Eligibility pushed before the suspend still arms the dwell")
    func eligibilityBeforeSuspendStillArms() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        harness.player.setHibernationEligible(true)
        #expect(!harness.player.isHibernated)
        harness.player.setSuspended(true)

        try await Harness.waitUntil("player hibernates") { harness.player.isHibernated }
    }

    @Test("Cleanup drains an armed hibernation and stays idempotent")
    func cleanupWhileHibernatedIsIdempotent() async throws {
        let harness = try await Harness.make()

        harness.player.setSuspended(true)
        harness.player.setHibernationEligible(true)
        try await Harness.waitUntil("player hibernates") { harness.player.isHibernated }

        harness.player.cleanup()
        harness.player.cleanup()

        #expect(harness.player.isCleanedUp)
        #expect(!harness.player.hasInstalledPlaybackWindow)
        #expect(harness.player.player == nil)
        #expect(!harness.player.isShowingHibernationStillFrameForTesting)
        harness.removeFixture()
    }

    @Test("Cleanup and hibernation share one teardown path")
    func teardownIsFactoredOnce() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift"
        )
        let cleanup = try Self.slice(source, from: "\n    func cleanup() {", to: "\n    deinit {")

        #expect(cleanup.contains("retirePlaybackState()"))
        // The teardown body must live in exactly one place.
        #expect(!cleanup.contains("playerLooper?.disableLooping()"))
        #expect(!cleanup.contains("inMemoryAssetLoader = nil"))
        #expect(source.contains("private func retirePlaybackState() {"))
        #expect(source.contains("setupPlayer(with: url)"))
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let player: WallpaperVideoPlayer
        let url: URL

        static func make() async throws -> Harness {
            let url = try await SyntheticDesktopVideoFixture.writeMP4(durationSeconds: 1.5)
            let player = WallpaperVideoPlayer(
                url: url,
                frame: CGRect(x: 0, y: 0, width: 128, height: 128),
                hibernationDelay: WallpaperVideoPlayerHibernationTests.dwell
            )
            let harness = Harness(player: player, url: url)
            do {
                try await waitUntil("player enqueues its first item") {
                    player.player?.currentItem != nil
                }
            } catch {
                harness.cleanup()
                throw error
            }
            return harness
        }

        func cleanup() {
            player.cleanup()
            removeFixture()
        }

        func removeFixture() {
            try? FileManager.default.removeItem(at: url)
        }

        static func waitUntil(
            _ description: String,
            timeout: Duration = .seconds(10),
            _ condition: @MainActor () -> Bool
        ) async throws {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Timed out waiting for: \(description)")
            throw TimeoutError.timedOut(description)
        }

        enum TimeoutError: Error {
            case timedOut(String)
        }
    }

    private enum SourceContractError: Error {
        case missingBoundary(String)
    }

    private static func slice(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound else {
            throw SourceContractError.missingBoundary(startMarker)
        }
        guard let end = source.range(of: endMarker, range: start ..< source.endIndex)?.lowerBound else {
            throw SourceContractError.missingBoundary(endMarker)
        }
        return String(source[start ..< end])
    }
}

// MARK: - Synthetic MP4 fixture

private enum SyntheticDesktopVideoFixture {
    static func writeMP4(durationSeconds: TimeInterval) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-hibernate-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = 128
        let height = 128
        let frameRate: Int32 = 30
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { throw FixtureError.setupFailed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.setupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(2, Int(Double(frameRate) * durationSeconds))
        for index in 0 ..< totalFrames {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
            )
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw FixtureError.setupFailed("CVPixelBufferCreate returned \(status)")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(
                CVPixelBufferGetBaseAddress(buffer),
                Int32(40 + (index * 7) % 180),
                CVPixelBufferGetBytesPerRow(buffer) * height
            )
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: Int64(index), timescale: frameRate)
            ) else {
                throw FixtureError.setupFailed(writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw FixtureError.setupFailed(
                writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
            )
        }
        return outputURL
    }

    enum FixtureError: Error {
        case setupFailed(String)
    }
}
