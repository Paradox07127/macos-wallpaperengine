#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import Testing

@Suite("Scene span producer ownership", .serialized)
@MainActor
struct WPESceneSpanProducerTests {
    @Test("A span producer publishes GPU-complete output without a display drawable")
    func offscreenProductionAndReadiness() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 128, height: 64), device: device, allowsHDR: false)
        let actor = WPEDisplayRenderActor(label: "scene-span-producer-test")
        let frames = WPESceneSpanFrames()
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            surfaceControl: WPERenderThreadFramePacer(surface: surface, renderActor: actor),
            mailbox: surface.mailbox, presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: CGSize(width: 128, height: 64), device: device
        )
        renderer.spanFrames = frames
        renderer.executor.spanOutputTextureLimit = 10
        renderer.executor.remainingForcedDrawableMissesForTesting = 1000
        await actor.adopt(renderer)
        try await actor.load()
        for _ in 0 ..< 100 where frames.latest() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let frame = try #require(frames.latest())
        let snapshot = try #require(await actor.rendererStateSnapshot())
        #expect(snapshot.isLoaded)
        #expect(!snapshot.hasPresentedFrame, "GPU production alone must not open the audio/readiness gate")
        #expect(frame.sourceSize == CGSize(width: 64, height: 64), "Desktop size must not replace the author's scene canvas")

        await actor.recordPresentCompletion(.init(generation: frame.generation, renderCompleted: true, presentCompleted: true))
        #expect(await actor.rendererStateSnapshot()?.hasPresentedFrame == true)
        await actor.teardownRenderer()
        #expect(frames.latest() == nil)
        await actor.shutdown()
    }

    @Test("A shared output lease prevents texture recycling until its final reader releases it")
    func pinnedTextureAndBoundedPool() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.spanOutputTextureLimit = 4
        var packets: [WPESceneSpanFrame] = []
        for sequence in 1 ... 4 {
            let texture = try executor.makeOutputTexture(size: CGSize(width: 16, height: 16))
            packets.append(.init(texture: texture, generation: 1, sequence: UInt64(sequence),
                                 sourceSize: CGSize(width: 16, height: 16), fitMode: .stretch, tracker: executor.presentTracker))
        }
        let original = try #require(packets.first?.texture)
        #expect(executor.presentTracker.isInFlight(ObjectIdentifier(original)))
        #expect(throws: WPEMetalFrameInFlightBudgetExhausted.self) {
            try executor.makeOutputTexture(size: CGSize(width: 16, height: 16))
        }
        packets.removeAll()
        #expect(!executor.presentTracker.isInFlight(ObjectIdentifier(original)))
        #expect(try executor.makeOutputTexture(size: CGSize(width: 16, height: 16)) === original)
        #expect(executor.outputTexturePool.count == 4)
    }

    @Test("The Metal present shader slices adjacent displays without repeating the full scene")
    func presentShaderSlices() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 1, mipmapped: false)
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = .shaderRead
        let source = try #require(device.makeTexture(descriptor: sourceDescriptor))
        var pixels: [UInt8] = (0 ..< 64).flatMap { $0 < 32 ? [UInt8(255), 0, 0, 255] : [UInt8(0), 0, 255, 255] }
        pixels.withUnsafeMutableBytes {
            source.replace(region: MTLRegionMake2D(0, 0, 64, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256)
        }
        let pipeline = try executor.renderPipeline(vertexName: "wpe_present_vertex", fragmentName: "wpe_present_authored_fragment", colorPixelFormat: .rgba8Unorm)
        let canvas = CGRect(x: -32, y: 0, width: 64, height: 1)
        for (x, expected) in [(-32, [UInt8(255), 0, 0, 255]), (0, [UInt8(0), 0, 255, 255])] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: 1, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .renderTarget
            let target = try #require(device.makeTexture(descriptor: descriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let commandBuffer = try #require(executor.commandQueue.makeCommandBuffer())
            let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            var uniforms = try #require(WPEPresentUniforms.make(fitMode: .stretch, sourceWidth: 64, sourceHeight: 1, targetWidth: 64, targetHeight: 1)
                .sliced(to: .init(canvasFrame: canvas, screenFrame: CGRect(x: x, y: 0, width: 32, height: 1))))
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<WPEPresentUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            #expect(commandBuffer.status == .completed)
            var result = [UInt8](repeating: 0, count: 128)
            result.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: 128, from: MTLRegionMake2D(0, 0, 32, 1), mipmapLevel: 0)
            }
            for index in 0 ..< 32 {
                let pixel = Array(result[(index * 4) ..< (index * 4 + 4)])
                #expect(pixel == expected)
            }
        }
    }

    @Test("Pointers in desktop gaps and inactive displays cannot drive the shared scene")
    func pointerHoles() {
        let geometry = WPEPointerMailbox.Geometry(viewFrameInScreen: CGRect(x: -200, y: 0, width: 500, height: 100),
                                                  interactiveFrames: [CGRect(x: -200, y: 0, width: 200, height: 100)])
        #expect(WPEPointerMailbox.pointerSample(forScreenLocation: CGPoint(x: -100, y: 50), geometry: geometry).isInsideView)
        #expect(!WPEPointerMailbox.pointerSample(forScreenLocation: CGPoint(x: 50, y: 50), geometry: geometry).isInsideView)
        #expect(!WPEPointerMailbox.pointerSample(forScreenLocation: CGPoint(x: 200, y: 50), geometry: geometry).isInsideView)
    }
}
#endif
