#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import Metal
import os
import QuartzCore
import Testing

@MainActor
@Suite("Displayed-frame capture", .serialized)
struct WPEDisplayedFrameCaptureTests {
    @Test(
        "Capture replays the present pass onto an owned texture, running or suspended",
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    func captureMatchesPresentedDrawable(suspendFirst: Bool) async throws {
        let stack = try await CaptureStack.presented(size: CGSize(width: 96, height: 64))
        defer { stack.teardown() }
        let drawable = try #require(stack.layer.lastDrawable).texture
        let expected = try stack.bytes(drawable)
        if suspendFirst {
            stack.renderer.applyPerformanceProfile(.suspended)
        }

        let capture = try #require(await stack.actor.captureDisplayedFrame())

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

    @Test("A frame that never reached the screen yields no capture", .timeLimit(.minutes(1)))
    func nilBeforeFirstPresent() async throws {
        let stack = try CaptureStack.make(size: CGSize(width: 96, height: 64))
        defer { stack.teardown() }
        await stack.actor.adopt(WPERendererHandoff(renderer: stack.renderer).renderer)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        stack.renderer.outputTexture = try #require(stack.layer.device?.makeTexture(descriptor: descriptor))

        #expect(await stack.actor.captureDisplayedFrame() == nil)
    }

    @Test("A hibernated scene has no output to capture", .timeLimit(.minutes(1)))
    func nilAfterHibernate() async throws {
        let stack = try await CaptureStack.presented(size: CGSize(width: 96, height: 64))
        defer { stack.teardown() }
        stack.renderer.applyPerformanceProfile(.suspended)
        #expect(await stack.actor.hibernate())
        #expect(stack.renderer.outputTexture == nil)

        #expect(await stack.actor.captureDisplayedFrame() == nil)
    }

    @Test("A capture waiting on the GPU does not block frame ticks", .timeLimit(.minutes(1)))
    func pendingCaptureLeavesRenderLoopRunning() async throws {
        let stack = try await CaptureStack.presented(size: CGSize(width: 96, height: 64))
        defer { stack.teardown() }
        let renderer = stack.renderer
        let source = try ObjectIdentifier(#require(renderer.outputTexture))
        let tracker = renderer.executor.presentTracker
        try await Self.poll("earlier presents drained") { !tracker.isInFlight(source) }

        // Holds the queue so the capture stays in flight until the test releases it.
        let event = try #require(stack.layer.device?.makeSharedEvent())
        let gate = try #require(renderer.executor.commandQueue.makeCommandBuffer())
        gate.encodeWaitForEvent(event, value: 1)
        gate.commit()

        let finished = OSAllocatedUnfairLock(initialState: false)
        let pending = Task { [actor = stack.actor] in
            let capture = await actor.captureDisplayedFrame()
            finished.withLock { $0 = true }
            return capture
        }
        try await Self.poll("capture committed behind the gate") { tracker.isInFlight(source) }
        renderer.renderAndPresentFrame()
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
            let capture = try #require(await stack.actor.captureDisplayedFrame())
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
    let fixture: MetalSceneFixture
    let surface: WPERenderSurface
    let layer: DrawableRecordingLayer
    let renderer: WPEMetalSceneRenderer
    let actor: WPEDisplayRenderActor

    static func make(size: CGSize) throws -> Self {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        // The stock fixture's layer has no size; stretch it over the whole 64x64 world.
        let sceneURL = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["origin"] = "32 32 0"
        objects[0]["size"] = "64 64"
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: sceneURL)
        let surface = WPERenderSurface(frame: CGRect(origin: .zero, size: size), device: device, allowsHDR: false)
        let layer = DrawableRecordingLayer()
        layer.device = device
        layer.pixelFormat = surface.metalLayer.pixelFormat
        WPEDisplayHDROutput.apply(to: layer, hdrOutputEnabled: false)
        layer.framebufferOnly = false
        layer.drawableSize = size
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: layer),
            drawableSize: size,
            presentFitMode: .contain,
            device: device
        )
        return Self(
            fixture: fixture, surface: surface, layer: layer, renderer: renderer,
            actor: WPEDisplayRenderActor(backing: .main)
        )
    }

    static func presented(size: CGSize) async throws -> Self {
        let stack = try make(size: size)
        await stack.actor.adopt(WPERendererHandoff(renderer: stack.renderer).renderer)
        try await stack.actor.load()
        stack.renderer.renderAndPresentFrame()
        _ = try #require(stack.layer.lastDrawable)
        return stack
    }

    func teardown() {
        renderer.cleanup()
        fixture.cleanup()
    }

    /// Readback on the renderer's own queue, so it is ordered after every present and capture already committed.
    func bytes(_ texture: MTLTexture) throws -> [UInt8] {
        let bytesPerPixel = texture.pixelFormat == .rgba16Float ? 8 : 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false
        )
        descriptor.storageMode = .shared
        let staging = try #require(texture.device.makeTexture(descriptor: descriptor))
        let command = try #require(renderer.executor.commandQueue.makeCommandBuffer())
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
