#if !LITE_BUILD
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE deep hibernate", .serialized)
struct WPESceneHibernateTests {
    @Test("Hibernate releases the loaded runtime state and reload restores the same frame")
    func hibernateReleasesAndReloadRestoresFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }
        try await stack.load()

        let hashBefore = try Self.textureSHA256(try #require(renderer.outputTexture))

        // Sentinels prove the release paths run even though the fixture scene is
        // texture-free: hibernate must sweep static textures, dynamic sources,
        // particles, and on-demand bookkeeping alike.
        renderer.loadedTextures["sentinel"] = try Self.makeTexture(device: device)
        renderer.dynamicTextureSources["sentinel"] = HibernateStubSource()
        renderer.onDemandVideoKeyByID = ["obj": "sentinel"]
        renderer.particleSystems = [try #require(WPEParticleSystem(
            definition: WPEParticleDefinitionParser.parse(dictionary: [
                "maxcount": 8,
                "emitter": [["rate": 5]],
            ]),
            device: device,
            seed: 0xB3
        ))]

        renderer.applyPerformanceProfile(.suspended)
        #expect(stack.surface.mtkView.isPaused)

        let hibernated = await stack.actor.hibernate()
        #expect(hibernated)
        #expect(!renderer.didLoad)
        #expect(renderer.loadedTextures.isEmpty)
        #expect(renderer.dynamicTextureSources.isEmpty)
        #expect(renderer.onDemandVideoKeyByID.isEmpty)
        #expect(renderer.particleSystems.isEmpty)
        #expect(renderer.renderPipeline == nil)
        #expect(renderer.outputTexture == nil)
        #expect(renderer.soundRuntime == nil)
        // Production side stays stopped while hibernated: the surface is paused
        // and a stray draw callback renders nothing.
        #expect(stack.surface.mtkView.isPaused)
        renderer.renderAndPresentFrame()
        #expect(renderer.outputTexture == nil)

        // Wake = plain reload; the rebuilt first frame must match the original.
        try await stack.actor.reload()
        renderer.applyPerformanceProfile(.quality)
        #expect(renderer.didLoad)
        let hashAfter = try Self.textureSHA256(try #require(renderer.outputTexture))
        #expect(hashAfter == hashBefore)
    }

    @Test("Hibernate refuses when nothing is loaded")
    func hibernateWithoutLoadIsRejected() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        defer { stack.renderer.cleanup() }
        await stack.actor.adopt(WPERendererHandoff(renderer: stack.renderer).renderer)

        let hibernated = await stack.actor.hibernate()
        #expect(hibernated == false)
    }

    @Test("Session hibernates after the eligibility dwell and wakes with a reload")
    func sessionHibernatesAndWakes() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let actor = WPEDisplayRenderActor(backing: .main)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            projectManifestRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let session = SceneWallpaperSession(
            window: window,
            renderActor: actor,
            surface: surface,
            audioCaptureDemandController: HibernateStubAudioDemand(),
            hibernationDelay: .milliseconds(50)
        )
        defer { session.cleanup() }
        session.startAdoptingRenderer(WPERendererHandoff(renderer: renderer))
        try await Self.poll("initial load") {
            await actor.rendererStateSnapshot()?.isLoaded == true
        }

        session.applyPerformanceProfile(.suspended)
        session.setHibernationEligible(true)
        try await Self.poll("hibernate after dwell") { session.isHibernated }
        let hibernatedSnapshot = await actor.rendererStateSnapshot()
        #expect(hibernatedSnapshot?.isLoaded == false)

        session.applyPerformanceProfile(.quality)
        try await Self.poll("wake reload") {
            // `&&`'s right operand is a non-async autoclosure, so the await
            // must live in its own statement.
            guard session.isHibernated == false else { return false }
            return await actor.rendererStateSnapshot()?.isLoaded == true
        }
        #expect(session.loadError == nil)
    }

    @Test("Eligibility flapping cancels the dwell instead of hibernating")
    func eligibilityFlapCancelsDwell() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let actor = WPEDisplayRenderActor(backing: .main)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            projectManifestRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let session = SceneWallpaperSession(
            window: window,
            renderActor: actor,
            surface: surface,
            audioCaptureDemandController: HibernateStubAudioDemand(),
            hibernationDelay: .milliseconds(80)
        )
        defer { session.cleanup() }
        session.startAdoptingRenderer(WPERendererHandoff(renderer: renderer))
        try await Self.poll("initial load") {
            await actor.rendererStateSnapshot()?.isLoaded == true
        }

        session.applyPerformanceProfile(.suspended)
        session.setHibernationEligible(true)
        session.setHibernationEligible(false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!session.isHibernated)
        let snapshot = await actor.rendererStateSnapshot()
        #expect(snapshot?.isLoaded == true)
    }

    // MARK: - Helpers

    private static func poll(
        _ label: String,
        timeout: Duration = .seconds(10),
        until condition: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for: \(label)")
    }

    private static func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false
        )
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private static func textureSHA256(_ texture: MTLTexture) throws -> String {
        try #require(texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb)
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return SHA256.hash(data: Data(bytes))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class HibernateStubSource: WPEDynamicTextureSource {
    func texture(at time: TimeInterval) -> MTLTexture? { nil }
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}
    func invalidate() {}
}

@MainActor
private final class HibernateStubAudioDemand: SystemAudioCaptureDemandControlling {
    func retain() {}
    func release() {}
}
#endif
