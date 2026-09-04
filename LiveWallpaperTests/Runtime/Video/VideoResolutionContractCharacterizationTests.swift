import AppKit
@preconcurrency import AVFoundation
import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Video resolution characterization baselines", .serialized)
struct VideoResolutionContractCharacterizationTests {
    @Test("Current local-only player contains no HLS-only resolution preference path")
    func currentLocalPlayerHasNoHLSResolutionPreferencePath() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift"
        )

        #expect(!source.contains("preferredMaximumResolution"))
        #expect(!source.contains("applyResolutionCap"))
        #expect(!source.contains("attachedScreen"))
    }

    @Test("Current local measurement baseline uses AVPlayerLayer and source-sized compositions")
    func localPresentationAndCompositionSizingBaseline() throws {
        let playerSource = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift"
        )
        let frameRatePolicy = try Self.slice(
            playerSource,
            from: "func setFrameRateLimit(",
            to: "private func applyRequestedFrameRateLimitIfReady"
        )
        let compactFrameRatePolicy = Self.compact(frameRatePolicy)

        #expect(compactFrameRatePolicy.contains("videoTrack.load(.naturalSize)"))
        #expect(compactFrameRatePolicy.contains("videoTrack.load(.preferredTransform)"))
        #expect(compactFrameRatePolicy.contains("let displayed = naturalSize.applying(transform)"))
        #expect(
            compactFrameRatePolicy.contains(
                "let renderSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))"
            )
        )
        #expect(compactFrameRatePolicy.contains("compositionConfig.renderSize = renderSize"))
        #expect(compactFrameRatePolicy.contains("mutableComposition.renderSize = renderSize"))
        #expect(!frameRatePolicy.contains("attachedScreen"))
        #expect(!frameRatePolicy.contains("preferredMaximumResolution"))

        let containerSource = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/VideoContainerView.swift"
        )
        let playerHost = try Self.slice(
            containerSource,
            from: "final class PlayerHostView: NSView",
            to: "// MARK: - VideoContainerView"
        )
        let compactPlayerHost = Self.compact(playerHost)

        #expect(compactPlayerHost.contains("let layer = AVPlayerLayer()"))
        #expect(compactPlayerHost.contains("playerLayer?.videoGravity = gravity"))
        #expect(compactPlayerHost.contains("playerLayer?.frame = bounds"))
        #expect(
            compactPlayerHost.contains(
                "if let scale = window?.backingScaleFactor { playerLayer?.contentsScale = scale }"
            )
        )
    }

    @Test("WPE video output attributes take a size cap without upscaling")
    func wpeOutputSizingBaseline() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Assets/WPEVideoTextureSource.swift"
        )
        let attributesBuilder = try Self.slice(
            source,
            from: "static func pixelBufferAttributes(",
            to: "private static func makeStillPixelBuffer"
        )
        let publishPath = try Self.slice(
            source,
            from: "private func publish(pixelBuffer:",
            to: "private func retire("
        )

        #expect(attributesBuilder.contains("kCVPixelBufferPixelFormatTypeKey"))
        #expect(attributesBuilder.contains("kCVPixelBufferMetalCompatibilityKey"))
        #expect(attributesBuilder.contains("kCVPixelBufferIOSurfacePropertiesKey"))
        #expect(attributesBuilder.contains("kCVPixelBufferWidthKey"))
        #expect(attributesBuilder.contains("kCVPixelBufferHeightKey"))
        #expect(attributesBuilder.contains("if let outputSize"))

        let compactPublishPath = Self.compact(publishPath)
        #expect(compactPublishPath.contains("let width = CVPixelBufferGetWidth(pixelBuffer)"))
        #expect(compactPublishPath.contains("let height = CVPixelBufferGetHeight(pixelBuffer)"))
        #expect(compactPublishPath.contains(".bgra8Unorm_srgb, width, height, 0"))
        #expect(compactPublishPath.contains(".bgra8Unorm, width, height, 0"))
        // Working texture still follows the (possibly capped) buffer, not the file.
        #expect(compactPublishPath.contains("CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)"))
        #expect(compactPublishPath.contains(".r8Unorm, lumaWidth, lumaHeight, 0"))
        #expect(compactPublishPath.contains(".rg8Unorm, chromaWidth, chromaHeight, 1"))
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
