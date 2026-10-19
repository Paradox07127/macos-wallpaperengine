import AppKit
@preconcurrency import AVFoundation
import CoreVideo
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import QuartzCore
import Testing

@MainActor
@Suite("Wallpaper session frame capture", .serialized, .timeLimit(.minutes(1)))
struct WallpaperSessionFrameCaptureTests {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    @Test("A video session captures at the requested format and the window's backing size",
          arguments: [MTLPixelFormat.bgra8Unorm, .rgba16Float])
    func videoSessionHonoursTheRequest(pixelFormat: MTLPixelFormat) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await SolidVideoFixture.writeMP4()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = WallpaperVideoPlayer(url: url, frame: CGRect(x: 0, y: 0, width: 320, height: 180), fitMode: .aspectFill)
        let session = VideoWallpaperSession(player: player)
        defer { session.cleanup() }
        try await Self.waitUntil("the layer has a picture") { player.isPlaying && player.isReadyForDisplay }

        let capture = try #require(
            await session.captureDisplayedFrame(device: device, pixelFormat: pixelFormat, colorSpace: Self.sRGB)
        )

        let contentView = try #require(player.playbackWindow?.contentView)
        let backing = contentView.convertToBacking(contentView.bounds)
        #expect(capture.texture.width == Int(backing.width.rounded()))
        #expect(capture.texture.height == Int(backing.height.rounded()))
        #expect(capture.texture.pixelFormat == pixelFormat)
        #expect(capture.colorSpace?.name == CGColorSpace.sRGB)
        #expect(!capture.isEDR)
    }

    @Test("A web session has no frame to give")
    func ambientSessionDeclines() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let session = AmbientWallpaperSession(window: NSWindow(), wallpaperType: .html, performanceTarget: nil)
        defer { session.cleanup() }
        #expect(await session.captureDisplayedFrame(device: device, pixelFormat: .bgra8Unorm, colorSpace: Self.sRGB) == nil)
    }

    @Test("A session without its own capture declines")
    func defaultImplementationDeclines() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let session = BareSession()
        #expect(await session.captureDisplayedFrame(device: device, pixelFormat: .bgra8Unorm, colorSpace: Self.sRGB) == nil)
    }

    #if !LITE_BUILD
    @Test("A scene session hands back the render actor's capture, ignoring the requested format")
    func sceneSessionForwardsToTheRenderActor() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = CGSize(width: 96, height: 64)
        let fixture = try ParityLifecycleFixture.make()
        defer { fixture.cleanup() }
        let surface = WPERenderSurface(frame: CGRect(origin: .zero, size: size), device: device, allowsHDR: false)
        let actor = WPEDisplayRenderActor(backing: .main)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface.mtkView
        surface.attach(client: WPERenderSurfaceClientShim(renderActor: actor, backing: .main))
        window.orderBack(nil)
        let session = SceneWallpaperSession(window: window, renderActor: actor, surface: surface)
        defer { session.cleanup() }
        let requestedFormat: MTLPixelFormat = .rgba16Float
        let requestedSpace = try #require(CGColorSpace(name: CGColorSpace.displayP3))

        try await actor.adoptParity(fixture.inputs(surface: surface, actor: actor))
        #expect(await session.captureDisplayedFrame(device: device, pixelFormat: requestedFormat, colorSpace: requestedSpace) == nil)

        try await actor.load()
        for _ in 0 ..< 30 {
            await actor.renderFrame()
            if await actor.rendererStateSnapshot()?.hasPresentedFrame == true {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await actor.rendererStateSnapshot()?.parity != nil)
        let direct = try #require(await actor.captureDisplayedFrame())
        let forwarded = try #require(
            await session.captureDisplayedFrame(device: device, pixelFormat: requestedFormat, colorSpace: requestedSpace)
        )

        #expect(direct.pixelFormat != requestedFormat)
        #expect(forwarded.texture.pixelFormat == direct.pixelFormat)
        #expect(forwarded.texture.width == direct.texture.width && forwarded.texture.height == direct.texture.height)
        #expect(forwarded.colorSpace?.name == direct.colorSpace?.name)
        #expect(forwarded.isEDR == direct.isEDR)
        let actual = try await Self.pixels(direct.texture, device: device)
        #expect(try await Self.pixels(forwarded.texture, device: device) == actual,
                "the session changed the render actor's completed GPU frame")
        let isRGBA = [.rgba8Unorm, MTLPixelFormat.rgba8Unorm_srgb].contains(direct.pixelFormat)
        let blue = isRGBA ? 2 : 0
        let red = isRGBA ? 0 : 2
        #expect(actual[blue] > 240 && actual[1] < 10 && actual[red] < 10 && actual[3] > 240,
                "the capture did not contain the fixture's blue clear frame")
    }

    private static func pixels(_ texture: any MTLTexture, device: any MTLDevice) async throws -> [UInt8] {
        try #require([MTLPixelFormat.bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb].contains(texture.pixelFormat))
        let bytesPerRow = texture.width * 4
        let count = bytesPerRow * texture.height
        let buffer = try #require(device.makeBuffer(length: count, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
                  sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: count)
        blit.endEncoding()
        let completed = await withCheckedContinuation { continuation in
            command.addCompletedHandler { finished in
                continuation.resume(returning: finished.status == .completed)
            }
            command.commit()
        }
        try #require(completed)
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: count))
    }
    #endif

    private static func waitUntil(
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
        throw CancellationError()
    }
}

@MainActor
private final class BareSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .html
    let summary: WallpaperSessionSummary = .notConfigured
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow? = nil

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func cleanup() {}

    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }
}

/// A short single-colour MP4, enough for the player to put a frame on its layer.
private enum SolidVideoFixture {
    static func writeMP4(width: Int = 64, height: Int = 48, frameCount: Int = 60) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-frame-capture-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        let frame = try #require(created)
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(frame) * height)
        }
        CVPixelBufferUnlockBaseAddress(frame, [])

        for index in 0 ..< frameCount {
            while !input.isReadyForMoreMediaData {
                await Task.yield()
            }
            try #require(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        try #require(writer.status == .completed)
        return url
    }
}
