#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import Testing
@testable import LiveWallpaper

// MARK: - Particle permanent-idle classification (unit level)

struct WPEParticlePermanentIdleTests {
    private func makeSystem(
        _ json: [String: Any],
        device: MTLDevice
    ) throws -> WPEParticleSystem {
        let definition = WPEParticleDefinitionParser.parse(dictionary: json)
        return try #require(WPEParticleSystem(definition: definition, device: device, seed: 0xB3))
    }

    @Test("A one-shot burst is idle only after it fired and every particle died")
    func oneShotBurstBecomesPermanentlyIdle() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try makeSystem([
            "maxcount": 8,
            "emitter": [["rate": 0, "instantaneous": 4]],
            "initializer": [["name": "lifetimerandom", "min": 0.05, "max": 0.1]],
        ], device: device)

        system.tick(now: 0)
        #expect(system.liveInstanceCount == 4)
        #expect(!system.isPermanentlyIdle)

        system.tick(now: 1)
        #expect(system.liveInstanceCount == 0)
        #expect(system.isPermanentlyIdle)
    }

    @Test("A rate emitter is never idle, even between births with nothing alive")
    func rateEmitterStaysLive() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try makeSystem([
            "maxcount": 8,
            "emitter": [["rate": 1]],
            "initializer": [["name": "lifetimerandom", "min": 0.05, "max": 0.05]],
        ], device: device)

        // First tick has dt == 0: nothing spawned yet, but the emitter can.
        system.tick(now: 0)
        #expect(system.liveInstanceCount == 0)
        #expect(!system.isPermanentlyIdle)
    }

    @Test("A duration-bounded rate emitter goes idle once the window closed and all died")
    func durationBoundedEmitterBecomesIdle() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try makeSystem([
            "maxcount": 64,
            "emitter": [["rate": 60, "duration": 0.2]],
            "initializer": [["name": "lifetimerandom", "min": 0.05, "max": 0.1]],
        ], device: device)

        var sawLiveParticles = false
        var t = 0.0
        while t <= 1.5 {
            system.tick(now: t)
            if system.liveInstanceCount > 0 { sawLiveParticles = true }
            // Inside the emission window the system must never classify idle.
            if t <= 0.2 { #expect(!system.isPermanentlyIdle) }
            t += 0.05
        }
        #expect(sawLiveParticles)
        #expect(system.liveInstanceCount == 0)
        #expect(system.isPermanentlyIdle)
    }

    @Test("An unfired burst behind a start delay is not idle")
    func unfiredDelayedBurstStaysLive() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try makeSystem([
            "maxcount": 8,
            "starttime": 100,
            "emitter": [["rate": 0, "instantaneous": 2]],
            "initializer": [["name": "lifetimerandom", "min": 0.05, "max": 0.1]],
        ], device: device)

        system.tick(now: 0)
        system.tick(now: 1)
        #expect(system.liveInstanceCount == 0)
        #expect(!system.isPermanentlyIdle)
    }

    @Test("An eventfollow child without a duration stays live for future parent births")
    func eventFollowChildStaysLive() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = try makeSystem([
            "maxcount": 8,
            "emitter": [["rate": 0, "instantaneous": 1]],
            "initializer": [["name": "lifetimerandom", "min": 0.05, "max": 0.1]],
        ], device: device)
        system.requiresFollowParent = true

        system.tick(now: 0)
        system.tick(now: 1000)
        #expect(system.liveInstanceCount == 0)
        #expect(!system.isPermanentlyIdle)
    }
}

// MARK: - Renderer frame demand (loaded static fixture)

@MainActor
@Suite("WPE frame demand", .serialized)
struct WPEFrameDemandTests {
    @Test("A static scene reports an empty frame demand")
    func staticSceneHasEmptyDemand() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }
        try await stack.load()

        #expect(renderer.frameDemand == [])
        #expect(!renderer.needsContinuousFrames)
        #expect(stack.surface.mtkView.isPaused)
    }

    @Test("Fully released on-demand videos carry no demand; a rebuilt source re-arms the loop")
    func releasedOnDemandVideoSettlesAndRebuildRearms() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }
        try await stack.load()

        // Scene has releasable videos, all currently released (hidden).
        renderer.onDemandVideoKeyByID = ["layer-1": ["video/clip.mp4"]]
        #expect(!renderer.needsContinuousFrames)

        // Reveal path: `rebuildOnDemandVideo` re-inserts the source; the didSet
        // must re-arm pacing without waiting for a profile event.
        renderer.dynamicTextureSources["video/clip.mp4"] = StubDynamicTextureSource()
        #expect(renderer.frameDemand.contains(.dynamicTextures))
        #expect(renderer.needsContinuousFrames)
        #expect(stack.surface.mtkView.isPaused == false)

        // Hide path: releasing the last source settles the loop again.
        renderer.dynamicTextureSources.removeValue(forKey: "video/clip.mp4")
        #expect(!renderer.needsContinuousFrames)
        #expect(stack.surface.mtkView.isPaused)
        #expect(stack.surface.mtkView.enableSetNeedsDisplay)
    }

    @Test("Finished particle systems stop demanding frames; live emitters keep them")
    func particleDemandFollowsLiveness() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }
        try await stack.load()

        let finished = try #require(WPEParticleSystem(
            definition: WPEParticleDefinitionParser.parse(dictionary: [
                "maxcount": 8,
                "emitter": [["rate": 0, "instantaneous": 2]],
                "initializer": [["name": "lifetimerandom", "min": 0.05, "max": 0.1]],
            ]),
            device: device,
            seed: 0xB3
        ))
        finished.tick(now: 0)
        finished.tick(now: 1)
        #expect(finished.isPermanentlyIdle)

        renderer.particleSystems = [finished]
        renderer.synchronizeFrameDemand()
        #expect(!renderer.frameDemand.contains(.particles))
        #expect(!renderer.needsContinuousFrames)
        #expect(stack.surface.mtkView.isPaused)

        let live = try #require(WPEParticleSystem(
            definition: WPEParticleDefinitionParser.parse(dictionary: [
                "maxcount": 8,
                "emitter": [["rate": 5]],
            ]),
            device: device,
            seed: 0xB3
        ))
        renderer.particleSystems = [finished, live]
        renderer.synchronizeFrameDemand()
        #expect(renderer.frameDemand.contains(.particles))
        #expect(renderer.needsContinuousFrames)
        #expect(stack.surface.mtkView.isPaused == false)
    }

    @Test("The runtime-activity mirror publishes idle for a static scene and flips with demand")
    func runtimeActivityMirrorFollowsDemand() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }

        let published = OSAllocatedUnfairLock<[WPESceneRuntimeActivity]>(initialState: [])
        renderer.onRuntimeActivityChange = { activity in
            published.withLock { $0.append(activity) }
        }
        try await stack.load()

        let afterLoad = published.withLock { $0.last }
        #expect(afterLoad == WPESceneRuntimeActivity(producesFrames: false, audible: false))

        renderer.setClickCaptureEnabled(true)
        let afterCapture = published.withLock { $0.last }
        #expect(afterCapture == WPESceneRuntimeActivity(producesFrames: true, audible: false))

        renderer.setClickCaptureEnabled(false)
        let afterRelease = published.withLock { $0.last }
        #expect(afterRelease == WPESceneRuntimeActivity(producesFrames: false, audible: false))
    }
}

// MARK: - Shared fixture (mirrors the RR03 liveness harness)

private final class StubDynamicTextureSource: WPEDynamicTextureSource {
    func texture(at time: TimeInterval) -> MTLTexture? { nil }
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}
    func invalidate() {}
}

@MainActor
struct FrameDemandRendererStack {
    let renderer: WPEMetalSceneRenderer
    let surface: WPERenderSurface
    let actor: WPEDisplayRenderActor

    static func make(_ fixture: FrameDemandFixture) throws -> Self {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
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
        return Self(renderer: renderer, surface: surface, actor: WPEDisplayRenderActor(backing: .main))
    }

    func load() async throws {
        await actor.adopt(WPERendererHandoff(renderer: renderer).renderer)
        try await actor.load()
    }
}

struct FrameDemandFixture {
    let root: URL
    let descriptor: SceneDescriptor

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-demand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scene = try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64, "auto": true]],
            "objects": [[
                "id": "solid",
                "name": "Solid",
                "type": "image",
                "image": "models/util/solidlayer.json",
                "color": "0 0 1",
                "alpha": 1,
                "visible": true,
            ]],
        ], options: [.sortedKeys])
        try scene.write(to: root.appendingPathComponent("scene.json"))
        let project = try JSONSerialization.data(withJSONObject: [
            "workshopid": "frame-demand-fixture",
            "type": "scene",
            "file": "scene.json",
        ], options: [.sortedKeys])
        try project.write(to: root.appendingPathComponent("project.json"))
        return Self(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: "frame-demand-fixture",
                cacheRelativePath: "wpe-cache/frame-demand-fixture",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
