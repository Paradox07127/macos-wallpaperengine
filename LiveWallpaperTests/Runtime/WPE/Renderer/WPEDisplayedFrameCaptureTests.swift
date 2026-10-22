#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import Metal
import MetalFX
import os
import QuartzCore
import Testing

@MainActor
@Suite("Displayed-frame capture", .serialized)
struct WPEDisplayedFrameCaptureTests {
    @Test(
        "Capture replays the present pass onto an owned texture",
        .timeLimit(.minutes(1))
    )
    func captureMatchesPresentedDrawable() async throws {
        let stack = try await CaptureStack.presented(size: CGSize(width: 96, height: 64))
        defer { stack.teardown() }
        let drawable = try #require(stack.layer.lastDrawable).texture
        let expected = try stack.bytes(drawable)
        let capture = try #require(await stack.capture())

        #expect(capture.texture.storageMode == .private)
        #expect(capture.texture.usage.contains([.renderTarget, .shaderRead]))
        #expect(capture.texture.width == drawable.width && capture.texture.height == drawable.height)
        #expect(capture.pixelFormat == drawable.pixelFormat && capture.texture.pixelFormat == drawable.pixelFormat)
        #expect(capture.colorSpace?.name == CGColorSpace.sRGB)
        #expect(!capture.isEDR)
        let actual = try stack.bytes(capture.texture)
        #expect(actual.count == expected.count)
        let worst = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? .max
        #expect(worst <= 1)
        // `.contain` letterboxes the all-red square scene: a black bar beside a red centre, so an empty capture cannot match.
        let row = 32 * drawable.width * 4
        #expect(Array(expected[row ..< row + 4]) == [0, 0, 0, 255])
        let centre = row + drawable.width / 2 * 4
        #expect(Array(expected[centre ..< centre + 4]) == [255, 0, 0, 255])
    }

    @Test("Linear span presentation and capture preserve RGB, including extended values", .timeLimit(.minutes(1)))
    func linearSpanCaptureKeepsOutputDomain() async throws {
        let size = CGSize(width: 96, height: 64)
        let stack = try CaptureStack.make(size: size)
        defer { stack.teardown() }
        let device = try #require(stack.layer.device)
        let source = try Self.linearSource(device: device)
        stack.layer.pixelFormat = .rgba16Float
        WPEDisplayHDROutput.apply(to: stack.layer, hdrOutputEnabled: true)
        let frames = WPESceneSpanFrames()
        frames.reset(generation: 1)
        let canvas = CGRect(origin: .zero, size: size)
        let presenter = try WPESceneSpanPresenter(
            device: device, layer: WPEPresentLayer(layer: stack.layer), frames: frames,
            state: WPESceneSpanPresentationState(), producer: stack.actor,
            configuration: .init(canvasFrame: canvas, screenFrame: canvas), density: 1
        )
        #expect(frames.publish(
            .init(texture: source, generation: 1, sequence: 1, sourceSize: CGSize(width: 2, height: 2),
                  fitMode: .stretch, colorTransfer: .linear, tracker: stack.executor.presentTracker),
            generation: 1, sequence: 1
        ))
        presenter.present()
        let drawable = try #require(stack.layer.lastDrawable).texture
        #expect(presenter.executor.lastPresentPass?.colorTransfer == .linear)
        let capture: WPEDisplayedFrameCapture? = await withCheckedContinuation { continuation in
            presenter.executor.encodeDisplayedFrameCapture(colorSpace: stack.layer.colorspace) {
                continuation.resume(returning: $0)
            }
        }
        let captured = try #require(capture)
        #expect(captured.isEDR && captured.pixelFormat == .rgba16Float)
        #expect(captured.colorSpace?.name == CGColorSpace.extendedLinearSRGB)
        let presented = try stack.bytes(drawable)
        let replayed = try stack.bytes(captured.texture)
        #expect(replayed == presented)
        // Independent source values: the authored HDR path would decode red,
        // clamp green=2 to 1, and discard negative blue.
        let centre = (captured.texture.height / 2 * captured.texture.width + captured.texture.width / 2) * 8
        let expected: [Float] = [Float(Float16(0.214)), 2, -0.25, 1]
        for channel in 0 ..< 4 {
            let offset = centre + channel * 2
            let bits = UInt16(replayed[offset]) | UInt16(replayed[offset + 1]) << 8
            #expect(abs(Float(Float16(bitPattern: bits)) - expected[channel]) < 0.001)
        }
    }

    @Test("Linear raw snapshots retain float RGB and source alpha", .timeLimit(.minutes(1)))
    func linearSnapshotDoesNotRepeatAuthoredHDRTransfer() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let texture = try Self.linearSource(device: device)
        let snapshotter = WPEMetalTextureSnapshotter()
        let image = try #require(await snapshotter.snapshotAsync(
            from: .init(texture: texture, colorTransfer: .linear)
        ))
        let linear = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(linear.colorSpace?.name == CGColorSpace.extendedLinearSRGB)
        #expect(linear.bitsPerComponent == 32 && linear.bitsPerPixel == 128)
        #expect(linear.bitmapInfo.contains(.floatComponents))
        let data = try #require(linear.dataProvider?.data) as Data
        let expected: [Float] = [Float(Float16(0.214)), 2, -0.25, 0.125]
        for channel in 0 ..< 4 {
            let actual = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: channel * 4, as: Float.self) }
            #expect(actual == expected[channel])
        }
        // Existing callers remain authored unless their producer marks the packet.
        let authored = try #require(snapshotter.snapshot(from: texture))
        let oldRepresentation = try #require(authored.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(oldRepresentation.colorSpace?.name == CGColorSpace.sRGB)
        #expect(oldRepresentation.bitsPerComponent == 8)
    }

    @Test("MetalFX capture preserves the producer transfer and writes opaque alpha",
          .enabled(if: WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler), .timeLimit(.minutes(1)),
          arguments: [WPEPresentColorTransfer.linear, .authored], [0.125, 1.0])
    func metalFXHDRCaptureMatchesPresentedPixels(transfer: WPEPresentColorTransfer, alpha: Double) async throws {
        let stack = try CaptureStack.make(size: CGSize(width: 128, height: 128))
        defer { stack.teardown() }
        let device = try #require(stack.layer.device)
        let source = try Self.linearSource(device: device, edge: 64, pixel: [0.214, 0.5, 2, Float16(alpha)])
        stack.layer.pixelFormat = .rgba16Float
        WPEDisplayHDROutput.apply(to: stack.layer, hdrOutputEnabled: true)
        let captured = try await Self.captureMetalFX(stack, source: source, transfer: transfer)
        var expected: [Float] = [Float(Float16(0.214)), 0.5, 2, 1]
        if transfer == .authored {
            expected = expected.prefix(3).map {
                let value = min(max($0, 0), 1)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            } + [1]
        }
        // MetalFX's HDR filter is not an identity even for constant fields.
        // Use the platform API directly, with independently decoded input, as the consumer reference.
        let referenceInput = expected.prefix(3).map { Float16($0) } + [transfer == .linear ? Float16(alpha) : 1]
        let reference = try Self.nativeMetalFXHDR(stack, pixel: referenceInput)
        for point in [(32, 32), (64, 64), (96, 96)] {
            for channel in 0 ..< 4 {
                let offset = (point.1 * 128 + point.0) * 8 + channel * 2
                let bits = UInt16(captured[offset]) | UInt16(captured[offset + 1]) << 8
                let value = Float(Float16(bitPattern: bits))
                if channel == 3 {
                    #expect(value == 1)
                } else {
                    let wantedBits = UInt16(reference[offset]) | UInt16(reference[offset + 1]) << 8
                    let wanted = Float(Float16(bitPattern: wantedBits))
                    #expect(abs(value - wanted) <= 0.01)
                    if transfer == .linear, channel == 2 {
                        #expect(value > 1, "The already-linear highlight must survive presentation")
                    }
                }
            }
        }
    }

    @Test("Native and MetalFX SDR capture decode typed sRGB input once with opaque alpha",
          .enabled(if: WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler), .timeLimit(.minutes(1)))
    func metalFXSDRCaptureMatchesPresentedPixels() async throws {
        let stack = try CaptureStack.make(size: CGSize(width: 128, height: 128))
        defer { stack.teardown() }
        let device = try #require(stack.layer.device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: 64, height: 64, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let pixels = Array(repeating: [UInt8](arrayLiteral: 80, 128, 180, 32), count: 64 * 64).flatMap(\.self)
        pixels.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 64 * 4)
        }
        let executor = stack.executor
        executor.metalFXUpscaler = nil
        let nativePresented = try executor.present(texture: source, layer: stack.layer, fitMode: .stretch,
                                                   colorTransfer: .authored)
        try #require(nativePresented)
        try #require(executor.lastPresentPass?.usedMetalFX == false)
        let native = try stack.bytes(#require(stack.layer.lastDrawable).texture)
        for point in [(32, 32), (64, 64), (96, 96)] {
            let offset = (point.1 * 128 + point.0) * 4
            for (channel, expected) in [80, 128, 180, 255].enumerated() {
                #expect(abs(Int(native[offset + channel]) - expected) <= 2)
            }
        }
        let captured = try await Self.captureMetalFX(stack, source: source, transfer: .authored)
        for point in [(32, 32), (64, 64), (96, 96)] {
            let offset = (point.1 * 128 + point.0) * 4
            for (channel, expected) in [80, 128, 180, 255].enumerated() {
                #expect(abs(Int(captured[offset + channel]) - expected) <= 2)
            }
        }
    }

    @Test("Losing the MetalFX scaler cannot silently capture a bilinear substitute",
          .enabled(if: WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler), .timeLimit(.minutes(1)))
    func missingMetalFXScalerRejectsCapture() async throws {
        let stack = try CaptureStack.make(size: CGSize(width: 128, height: 128))
        defer { stack.teardown() }
        let device = try #require(stack.layer.device)
        let source = try Self.linearSource(device: device, edge: 64, pixel: [0.214, 0.5, 2, 0.125])
        let executor = stack.executor
        stack.layer.pixelFormat = .rgba16Float
        WPEDisplayHDROutput.apply(to: stack.layer, hdrOutputEnabled: true)
        _ = try #require(device.makeDefaultLibrary())
        executor.metalFXUpscaler = WPEMetalFXSpatialUpscaler(device: device)
        let presented = try executor.present(texture: source, layer: stack.layer, fitMode: .stretch, colorTransfer: .linear)
        try #require(presented)
        try #require(executor.lastPresentPass?.usedMetalFX == true)
        _ = try stack.bytes(#require(stack.layer.lastDrawable).texture)
        executor.metalFXUpscaler = nil
        let result: WPEDisplayedFrameCapture? = await withCheckedContinuation { continuation in
            executor.encodeDisplayedFrameCapture(colorSpace: stack.layer.colorspace) {
                continuation.resume(returning: $0)
            }
        }
        #expect(result == nil)
    }

    @Test("A frame that never reached the screen yields no capture", .timeLimit(.minutes(1)))
    func nilBeforeFirstPresent() async throws {
        let stack = try CaptureStack.make(size: CGSize(width: 96, height: 64))
        defer { stack.teardown() }
        #expect(await stack.capture() == nil)
    }

    @Test("A retired presentation has no output to capture", .timeLimit(.minutes(1)))
    func nilAfterRetirement() async throws {
        let stack = try await CaptureStack.presented(size: CGSize(width: 96, height: 64))
        defer { stack.teardown() }
        stack.executor.releaseTransientResources()

        #expect(await stack.capture() == nil)
    }

    @Test("A capture waiting on the GPU does not block CPU frame preparation", .timeLimit(.minutes(1)))
    func pendingCaptureLeavesRenderLoopRunning() async throws {
        let stack = try await CaptureStack.presented(size: CGSize(width: 96, height: 64))
        defer { stack.teardown() }
        let source = try ObjectIdentifier(#require(stack.executor.lastPresentPass?.source))
        let tracker = stack.executor.presentTracker
        try await Self.poll("earlier presents drained") { !tracker.isInFlight(source) }

        // Holds the queue so the capture stays in flight until the test releases it.
        let event = try #require(stack.layer.device?.makeSharedEvent())
        let gate = try #require(stack.executor.commandQueue.makeCommandBuffer())
        gate.encodeWaitForEvent(event, value: 1)
        gate.commit()

        let finished = OSAllocatedUnfairLock(initialState: false)
        let pending = Task {
            let capture = await stack.capture()
            finished.withLock { $0 = true }
            return capture
        }
        try await Self.poll("capture committed behind the gate") { tracker.isInFlight(source) }
        _ = try stack.executor.makeOutputTexture(size: CGSize(width: 64, height: 64))
        #expect(!finished.withLock { $0 })

        event.signaledValue = 1
        #expect(await pending.value != nil)
    }

    @Test("4K capture cost", .timeLimit(.minutes(1)))
    func fourKCaptureCost() async throws {
        let stack = try await CaptureStack.presented(size: CGSize(width: 3840, height: 2160))
        defer { stack.teardown() }
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0 ..< 3 {
            let start = clock.now
            let capture = try #require(await stack.capture())
            samples.append(clock.now - start)
            #expect(capture.texture.width == 3840 && capture.texture.height == 2160)
        }
        print("[displayed-frame-capture] 4K capture: \(samples)")
    }

    private static func poll(
        _ label: String,
        timeout: Duration = .seconds(10),
        until condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for: \(label)")
    }

    private static func captureMetalFX(_ stack: CaptureStack, source: MTLTexture,
                                       transfer: WPEPresentColorTransfer) async throws -> [UInt8] {
        let device = try #require(stack.layer.device)
        _ = try #require(device.makeDefaultLibrary())
        let executor = stack.executor
        executor.metalFXUpscaler = WPEMetalFXSpatialUpscaler(device: device)
        let didPresent = try executor.present(texture: source, layer: stack.layer, fitMode: .stretch, colorTransfer: transfer)
        try #require(didPresent)
        let pass = try #require(executor.lastPresentPass)
        try #require(pass.usedMetalFX, "A bilinear fallback does not verify the MetalFX consumer")
        #expect(pass.colorTransfer == transfer)
        let drawable = try #require(stack.layer.lastDrawable).texture
        let presented = try stack.bytes(drawable)
        let result: WPEDisplayedFrameCapture? = await withCheckedContinuation { continuation in
            executor.encodeDisplayedFrameCapture(colorSpace: stack.layer.colorspace) {
                continuation.resume(returning: $0)
            }
        }
        let capture = try #require(result)
        #expect(capture.pixelFormat == stack.layer.pixelFormat)
        #expect(capture.isEDR == (stack.layer.pixelFormat == .rgba16Float))
        #expect(capture.colorSpace == stack.layer.colorspace)
        let captured = try stack.bytes(capture.texture)
        #expect(captured == presented, "Capture must reproduce the spatial scaler, not the ordinary present pass")
        return captured
    }

    private static func linearSource(device: MTLDevice, edge: Int = 2,
                                     pixel: [Float16] = [0.214, 2, -0.25, 0.125]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: edge, height: edge, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let components = Array(repeating: pixel, count: edge * edge).flatMap(\.self)
        components.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, edge, edge), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: edge * 8
            )
        }
        return texture
    }

    /// External platform reference: no WPE present encoder, upscaler wrapper or transfer shader.
    private static func nativeMetalFXHDR(_ stack: CaptureStack, pixel: [Float16]) throws -> [UInt8] {
        let device = try #require(stack.layer.device)
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = 64
        descriptor.inputHeight = 64
        descriptor.outputWidth = 128
        descriptor.outputHeight = 128
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.colorProcessingMode = .hdr
        let scaler = try #require(descriptor.makeSpatialScaler(device: device))
        let source = try linearSource(device: device, edge: 64, pixel: pixel)
        try #require(source.usage.isSuperset(of: scaler.colorTextureUsage))
        let texture = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 128, height: 128, mipmapped: false
        )
        texture.storageMode = .private
        texture.usage = scaler.outputTextureUsage.union(.renderTarget)
        let target = try #require(device.makeTexture(descriptor: texture))
        let command = try #require(stack.executor.commandQueue.makeCommandBuffer())
        scaler.colorTexture = source
        scaler.outputTexture = target
        scaler.inputContentWidth = 64
        scaler.inputContentHeight = 64
        scaler.encode(commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed && command.error == nil)
        return try stack.bytes(target)
    }
}

/// Keeps the last vended drawable so the test can read back exactly what was presented.
private final class DrawableRecordingLayer: CAMetalLayer {
    private(set) var lastDrawable: CAMetalDrawable?

    override func nextDrawable() -> CAMetalDrawable? {
        let drawable = super.nextDrawable()
        lastDrawable = drawable
        return drawable
    }
}

@MainActor
private struct CaptureStack {
    let layer: DrawableRecordingLayer
    let executor: WPEMetalPresenter
    let actor: WPEDisplayRenderActor

    static func make(size: CGSize) throws -> Self {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = DrawableRecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        WPEDisplayHDROutput.apply(to: layer, hdrOutputEnabled: false)
        layer.framebufferOnly = false
        layer.drawableSize = size
        return try Self(layer: layer, executor: WPEMetalPresenter(device: device),
                        actor: WPEDisplayRenderActor(backing: .main))
    }

    static func presented(size: CGSize) async throws -> Self {
        let stack = try make(size: size)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let source = try #require(stack.layer.device?.makeTexture(descriptor: descriptor))
        let pixels = Array(repeating: [UInt8](arrayLiteral: 255, 0, 0, 255), count: 64 * 64).flatMap(\.self)
        pixels.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 64 * 4)
        }
        #expect(try stack.executor.present(texture: source, layer: stack.layer, fitMode: .contain))
        _ = try #require(stack.layer.lastDrawable)
        return stack
    }

    func capture() async -> WPEDisplayedFrameCapture? {
        await withCheckedContinuation { continuation in
            executor.encodeDisplayedFrameCapture(colorSpace: layer.colorspace) {
                continuation.resume(returning: $0)
            }
        }
    }

    func teardown() {
        executor.releaseTransientResources()
        actor.requestStop()
    }

    /// Readback on the presenter's own queue, so it is ordered after every present and capture already committed.
    func bytes(_ texture: MTLTexture) throws -> [UInt8] {
        let bytesPerPixel = texture.pixelFormat == .rgba16Float ? 8 : 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false
        )
        descriptor.storageMode = .shared
        let staging = try #require(texture.device.makeTexture(descriptor: descriptor))
        let command = try #require(executor.commandQueue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin()
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        let bytesPerRow = texture.width * bytesPerPixel
        var result = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        result.withUnsafeMutableBytes {
            staging.getBytes(
                $0.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
            )
        }
        return result
    }
}
#endif
