import AppKit
@preconcurrency import AVFoundation
import CoreVideo
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import Testing

@MainActor
@Suite("Wallpaper video displayed-frame capture", .serialized, .timeLimit(.minutes(1)))
struct WallpaperVideoPlayerDisplayedFrameCaptureTests {
    private static let windowFrame = CGRect(x: 0, y: 0, width: 320, height: 180)
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    @Test("Aspect fill covers the whole backing store with the frame as the layer shows it")
    func aspectFillMatchesTheLayer() async throws {
        let harness = try await Harness.make(fitMode: .aspectFill)
        defer { harness.cleanup() }
        try await harness.waitUntilPlaying()

        let pixels = try await harness.capture()
        let backing = try harness.backingPixelSize()
        #expect(pixels.width == backing.width && pixels.height == backing.height)

        let midY = pixels.height * 3 / 4
        expectColor(pixels.rgba(x: 1, y: midY), (255, 0, 0, 255), "left edge is red, no letterbox")
        expectColor(pixels.rgba(x: pixels.width - 2, y: midY), (0, 0, 255, 255), "right edge is blue, no letterbox")
        expectColor(pixels.rgba(x: pixels.width / 4, y: midY), (255, 0, 0, 255), "red half")
        expectColor(pixels.rgba(x: pixels.width * 3 / 4, y: midY), (0, 0, 255, 255), "blue half")
        let top = pixels.rgba(x: pixels.width / 2, y: 1)
        #expect(top.g > 200 && top.r < 40 && top.b < 40, "the green band is the top of the picture, got \(top)")
    }

    @Test("Aspect fit that leaves side bars declines the capture")
    func aspectFitWithBarsReturnsNil() async throws {
        // 4:3 in a 16:9 window: the picture leaves an eighth of the width uncovered on each side.
        let harness = try await Harness.make(fitMode: .aspectFit)
        defer { harness.cleanup() }
        try await harness.waitUntilPlaying()

        let texture = await harness.player.captureDisplayedFrame(
            device: harness.device, pixelFormat: .bgra8Unorm, colorSpace: Self.sRGB
        )
        #expect(texture == nil)
    }

    @Test("Aspect fit with the window's own aspect ratio covers the backing store")
    func aspectFitWithMatchingRatioCaptures() async throws {
        let harness = try await Harness.make(fitMode: .aspectFit, videoSize: (320, 180))
        defer { harness.cleanup() }
        try await harness.waitUntilPlaying()

        let pixels = try await harness.capture()
        let backing = try harness.backingPixelSize()
        #expect(pixels.width == backing.width && pixels.height == backing.height)
        let midY = pixels.height * 3 / 4
        expectColor(pixels.rgba(x: 1, y: midY), (255, 0, 0, 255), "left edge is red, no bar")
        expectColor(pixels.rgba(x: pixels.width - 2, y: midY), (0, 0, 255, 255), "right edge is blue, no bar")
        let top = pixels.rgba(x: pixels.width / 2, y: 1)
        #expect(top.g > 200 && top.r < 40 && top.b < 40, "the green band is the top of the picture, got \(top)")
    }

    @Test("An sRGB-encoding target stores the same bytes as a plain one")
    func srgbTargetMatchesPlainTarget() async throws {
        let harness = try await Harness.make(fitMode: .aspectFill, solidBGRA: [0x40, 0x60, 0xA0, 0xFF])
        defer { harness.cleanup() }
        try await harness.waitUntilPlaying()

        let plain = try await harness.capture(pixelFormat: .bgra8Unorm)
        let encoded = try await harness.capture(pixelFormat: .rgba8Unorm_srgb)
        #expect(plain.width == encoded.width && plain.height == encoded.height)
        let points = [(plain.width / 2, plain.height / 2), (2, 2), (plain.width - 3, plain.height - 3)]
        for (x, y) in points {
            let expected = plain.rgba(x: x, y: y)
            #expect(expected.r > 120 && expected.r < 200, "control: the fixture is mid-tone, got \(expected)")
            expectColor(encoded.rgba(x: x, y: y), (expected.r, expected.g, expected.b, expected.a), "pixel \(x),\(y)")
        }
    }

    @Test("A paused player still yields its current frame and keeps existing outputs bound")
    func pausedPlayerYieldsFrame() async throws {
        let harness = try await Harness.make(fitMode: .aspectFill)
        defer { harness.cleanup() }
        try await harness.waitUntilPlaying()
        harness.player.pause()
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.player.player?.timeControlStatus == .paused)
        #expect(harness.player.attachVideoOutputForTesting())

        let pixels = try await harness.capture()
        expectColor(pixels.rgba(x: pixels.width / 4, y: pixels.height * 3 / 4), (255, 0, 0, 255), "red half")
        #expect(harness.player.boundVideoOutputCountForTesting == 1)
    }

    @Test("A player held paused before it ever played still yields its first frame")
    func neverPlayedPlayerYieldsFrame() async throws {
        let harness = try await Harness.make(fitMode: .aspectFill, holdPaused: true)
        defer { harness.cleanup() }
        try await Harness.waitUntil("the layer has a picture") { harness.player.isReadyForDisplay }
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.player.player?.timeControlStatus == .paused)

        let pixels = try await harness.capture()
        expectColor(pixels.rgba(x: pixels.width * 3 / 4, y: pixels.height * 3 / 4), (0, 0, 255, 255), "blue half")
    }

    @Test("Extended dynamic range declines the capture")
    func extendedDynamicRangeReturnsNil() async throws {
        let harness = try await Harness.make(fitMode: .aspectFill)
        defer { harness.cleanup() }
        try await harness.waitUntilPlaying()
        harness.player.setVideoColorSpace(.rec2020HDR)
        #expect(harness.player.usesExtendedDynamicRange)

        let texture = await harness.player.captureDisplayedFrame(
            device: harness.device, pixelFormat: .bgra8Unorm, colorSpace: Self.sRGB
        )
        #expect(texture == nil)
    }

    @Test("A cleaned-up player declines the capture")
    func cleanedUpPlayerReturnsNil() async throws {
        let harness = try await Harness.make(fitMode: .aspectFill)
        defer { harness.removeFixture() }
        try await harness.waitUntilPlaying()
        harness.player.cleanup()

        let texture = await harness.player.captureDisplayedFrame(
            device: harness.device, pixelFormat: .bgra8Unorm, colorSpace: Self.sRGB
        )
        #expect(texture == nil)
    }

    @Test("Capture latency for a 1920x1080 video")
    func fullHDLatency() async throws {
        let harness = try await Harness.make(
            fitMode: .aspectFill,
            videoSize: (1920, 1080),
            windowFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        defer { harness.cleanup() }
        try await harness.waitUntilPlaying()
        try await Task.sleep(for: .milliseconds(300))

        let start = ContinuousClock.now
        let texture = await harness.player.captureDisplayedFrame(
            device: harness.device, pixelFormat: .bgra8Unorm, colorSpace: Self.sRGB
        )
        let elapsed = ContinuousClock.now - start
        let size = texture.map { "\($0.width)x\($0.height)" } ?? "nil"
        print("captureDisplayedFrame 1920x1080 video -> \(size) texture in \(elapsed)")
        #expect(texture != nil)
    }

    // MARK: - Helpers

    private func expectColor(
        _ actual: (r: Int, g: Int, b: Int, a: Int),
        _ expected: (Int, Int, Int, Int),
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let deltas = [actual.r - expected.0, actual.g - expected.1, actual.b - expected.2, actual.a - expected.3]
        #expect(
            deltas.allSatisfy { abs($0) <= 3 },
            "\(label): got \(actual), expected \(expected)",
            sourceLocation: sourceLocation
        )
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        /// false = the texture stores RGBA.
        let isBGRA: Bool

        /// `y` counts from the top row.
        func rgba(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let offset = (y * width + x) * 4
            let (red, blue) = isBGRA ? (offset + 2, offset) : (offset, offset + 2)
            return (Int(bytes[red]), Int(bytes[offset + 1]), Int(bytes[blue]), Int(bytes[offset + 3]))
        }
    }

    @MainActor
    private struct Harness {
        let player: WallpaperVideoPlayer
        let url: URL
        let device: any MTLDevice

        static func make(
            fitMode: VideoFitMode,
            holdPaused: Bool = false,
            videoSize: (width: Int, height: Int) = (192, 144),
            windowFrame: CGRect = WallpaperVideoPlayerDisplayedFrameCaptureTests.windowFrame,
            solidBGRA: [UInt8]? = nil
        ) async throws -> Harness {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let url = try await SplitColorVideoFixture.writeMP4(
                width: videoSize.width, height: videoSize.height, solidBGRA: solidBGRA
            )
            let player = WallpaperVideoPlayer(url: url, frame: windowFrame, fitMode: fitMode)
            if holdPaused {
                player.pause()
            }
            let harness = Harness(player: player, url: url, device: device)
            do {
                try await waitUntil("player enqueues its first item") { player.player?.currentItem != nil }
            } catch {
                harness.cleanup()
                throw error
            }
            return harness
        }

        func waitUntilPlaying() async throws {
            try await Self.waitUntil("playback starts") { player.isPlaying }
            try await Self.waitUntil("the layer has a picture") { player.isReadyForDisplay }
        }

        func backingPixelSize() throws -> (width: Int, height: Int) {
            let contentView = try #require(player.playbackWindow?.contentView)
            let backing = contentView.convertToBacking(contentView.bounds)
            return (Int(backing.width.rounded()), Int(backing.height.rounded()))
        }

        func capture(pixelFormat: MTLPixelFormat = .bgra8Unorm) async throws -> Pixels {
            let texture = try #require(
                await player.captureDisplayedFrame(
                    device: device,
                    pixelFormat: pixelFormat,
                    colorSpace: WallpaperVideoPlayerDisplayedFrameCaptureTests.sRGB
                )
            )
            #expect(texture.pixelFormat == pixelFormat)
            #expect(texture.usage.contains(.shaderRead) && texture.usage.contains(.renderTarget))
            return try read(texture)
        }

        private func read(_ texture: any MTLTexture) throws -> Pixels {
            let bytesPerRow = texture.width * 4
            let length = bytesPerRow * texture.height
            let buffer = try #require(device.makeBuffer(length: length, options: .storageModeShared))
            let queue = try #require(device.makeCommandQueue())
            let commandBuffer = try #require(queue.makeCommandBuffer())
            let blit = try #require(commandBuffer.makeBlitCommandEncoder())
            blit.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                to: buffer,
                destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: length
            )
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let bytes = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: length))
            return Pixels(width: texture.width, height: texture.height, bytes: bytes, isBGRA: texture.pixelFormat == .bgra8Unorm)
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
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Timed out waiting for: \(description)")
            throw TimeoutError.timedOut(description)
        }

        enum TimeoutError: Error {
            case timedOut(String)
        }
    }
}

// MARK: - Fixture

/// Top quarter green; below it the left half is red and the right half blue. Tagged Rec.709 so the decoded
/// buffer carries the colour attachments the capture has to honour.
private enum SplitColorVideoFixture {
    /// `solidBGRA` replaces the split pattern with one colour; nil keeps the pattern.
    static func writeMP4(
        width: Int,
        height: Int,
        solidBGRA: [UInt8]? = nil,
        durationSeconds: TimeInterval = 2,
        frameRate: Int32 = 30
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("displayed-frame-capture-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        var encoded = false
        defer {
            if !encoded {
                if writer.status == .writing {
                    writer.cancelWriting()
                }
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw FixtureError.setupFailed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.setupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let frame = try makePatternBuffer(width: width, height: height, solidBGRA: solidBGRA)
        let totalFrames = max(2, Int(Double(frameRate) * durationSeconds))
        for index in 0 ..< totalFrames {
            while !input.isReadyForMoreMediaData {
                await Task.yield()
            }
            guard adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: frameRate)) else {
                throw FixtureError.setupFailed(writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw FixtureError.setupFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        encoded = true
        return outputURL
    }

    private static func makePatternBuffer(width: Int, height: Int, solidBGRA: [UInt8]?) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw FixtureError.setupFailed("CVPixelBufferCreate returned \(status)")
        }
        let green: [UInt8] = [0, 255, 0, 255]
        let red: [UInt8] = [0, 0, 255, 255]
        let blue: [UInt8] = [255, 0, 0, 255]
        let bandRow = (0 ..< width).flatMap { _ in solidBGRA ?? green }
        let splitRow = (0 ..< width).flatMap { solidBGRA ?? ($0 < width / 2 ? red : blue) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw FixtureError.setupFailed("no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0 ..< height {
            let source = row < height / 4 ? bandRow : splitRow
            source.withUnsafeBytes { bytes in
                (base + row * bytesPerRow).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        return buffer
    }

    enum FixtureError: Error {
        case setupFailed(String)
    }
}
