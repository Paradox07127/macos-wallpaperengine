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

    @Test("Effect-only script readers keep a static scene active", arguments: ["constant", "visibility", "shared"])
    func effectOnlyScriptsKeepFrames(family: String) async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }
        try await stack.load()
        let key = WPEEffectConstantScriptKey(passID: "solid", uniform: "g_Alpha")
        if family == "shared" {
            renderer.sharedEffectConstantReadFans[key] = ("animatedAlpha", .scalar)
        } else {
            let instance = try WPEDynamicTransformScriptInstance(
                script: family == "visibility"
                    ? "export function update(value) { return !value; }"
                    : "export function update(value) { return value + 0.1; }",
                seed: SIMD3<Double>(1, 0, 0),
                valueShape: family == "visibility" ? .boolean : .scalar,
                canvasSize: SIMD2<Double>(64, 64),
                batchDispatcher: renderer.sceneScriptBatchDispatcher
            )
            if family == "visibility" {
                renderer.effectVisibilityScriptInstances["solid"] = instance
            } else {
                renderer.effectConstantScriptInstances[key] = instance
            }
        }
        renderer.synchronizeFrameDemand()
        #expect(renderer.frameDemand.contains(.scripts))
        #expect(renderer.needsContinuousFrames)
        #expect(!stack.surface.mtkView.isPaused)
        for instance in renderer.effectConstantScriptInstances.values {
            _ = instance.destroy()
        }
        for instance in renderer.effectVisibilityScriptInstances.values {
            _ = instance.destroy()
        }
        renderer.effectConstantScriptInstances.removeAll()
        renderer.effectVisibilityScriptInstances.removeAll()
        renderer.sharedEffectConstantReadFans.removeAll()
        renderer.synchronizeFrameDemand()
        #expect(renderer.frameDemand.isEmpty)
        #expect(stack.surface.mtkView.isPaused)
    }

    @Test("Authored origin animation keeps frames without shaders or scripts")
    func authoredOriginKeepsFrames() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }
        try await stack.load()
        renderer.dynamicOriginAnimations["solid"] = Self.animatedValue
        renderer.synchronizeFrameDemand()
        #expect(renderer.needsContinuousFrames)
        #expect(!stack.surface.mtkView.isPaused)
        renderer.dynamicOriginAnimations.removeAll()
        renderer.synchronizeFrameDemand()
        #expect(renderer.frameDemand.isEmpty)
    }

    @Test("Retired origin animation cannot restart pacing during a failed wake")
    func retiredOriginAnimationStaysIdle() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }
        try await stack.load()
        renderer.dynamicOriginAnimations["solid"] = Self.animatedValue
        renderer.synchronizeFrameDemand()
        #expect(renderer.needsContinuousFrames)
        renderer.applyPerformanceProfile(.suspended)
        #expect(await stack.actor.hibernate())
        #expect(renderer.dynamicOriginAnimations.isEmpty)
        renderer.applyPerformanceProfile(.quality)
        #expect(renderer.frameDemand.isEmpty)
        #expect(stack.surface.mtkView.isPaused)

        try Data("invalid scene".utf8).write(to: fixture.root.appendingPathComponent("scene.json"))
        var reloadFailed = false
        do {
            try await stack.actor.reload()
        } catch {
            reloadFailed = true
        }
        #expect(reloadFailed)
        #expect(!renderer.didLoad)
        #expect(renderer.frameDemand.isEmpty)
        #expect(stack.surface.mtkView.isPaused)
    }

    @Test("Animated uniforms on a builtin pass retain continuous frame demand")
    func builtinAnimatedUniformKeepsFrames() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        defer { stack.renderer.cleanup() }
        try await stack.load()
        let pipeline = try #require(stack.renderer.renderPipeline)
        let layer = try #require(pipeline.layers.first)
        let original = try #require(layer.passes.first)
        let animatedPass = WPEPreparedRenderPass(
            pass: original.pass, shader: original.shader,
            textureBindings: original.textureBindings, comboValues: original.comboValues,
            uniformValues: ["g_Alpha": .animated(Self.animatedValue)]
        )
        let animated = WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(
            graphLayer: layer.graphLayer, passes: [animatedPass]
        )])
        #expect(WPEMetalSceneRenderer.pipelineHasAnimatedPasses(animated))
        #expect(!WPEMetalSceneRenderer.pipelineHasAnimatedPasses(pipeline))
    }

    /// A mesh without animation clips is a static prop; only clips (or the layer's own
    /// alpha/colour animation) justify continuous frames.
    @Test("A puppet model animates only when it carries animation clips")
    func staticModelDoesNotDemandFrames() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        defer { stack.renderer.cleanup() }
        try await stack.load()
        let pipeline = try #require(stack.renderer.renderPipeline)
        let layer = try #require(pipeline.layers.first)
        let staticModel = WPEPuppetModel(version: 23, meshes: [])
        let still = WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(
            graphLayer: layer.graphLayer, puppetModel: staticModel, passes: layer.passes
        )])
        #expect(!WPEMetalSceneRenderer.pipelineHasAnimatedPasses(still))
        let clip = WPEPuppetAnimation(id: 0, name: "idle", mode: "loop", fps: 30, frameCount: 30, channels: [])
        let animated = WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(
            graphLayer: layer.graphLayer,
            puppetModel: WPEPuppetModel(version: 23, meshes: [], animations: [clip]),
            passes: layer.passes
        )])
        #expect(WPEMetalSceneRenderer.pipelineHasAnimatedPasses(animated))
    }

    private static var animatedValue: WPESceneAnimatedValue {
        WPESceneAnimatedValue(
            animation: WPESceneNumericAnimation(
                tracks: [[.init(frame: 0, value: 0), .init(frame: 30, value: 1)], [], []],
                fps: 30, length: 30, mode: "loop", wrapLoop: true
            ), scalarFallback: 0, vectorFallback: [0, 0, 0]
        )
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

        renderer.dynamicTextureSources["video/clip.mp4"] = StubDynamicTextureSource()
        #expect(renderer.frameDemand.contains(.dynamicTextures))
        #expect(renderer.needsContinuousFrames)
        #expect(stack.surface.mtkView.isPaused == false)

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

    @Test("Pointer-locked emitters do not keep the loop running while the cursor is off-display")
    func pointerLockedParticlesDoNotDemandFramesWhilePointerAbsent() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        let renderer = stack.renderer
        defer { renderer.cleanup() }
        try await stack.load()

        let system = try #require(WPEParticleSystem(
            definition: WPEParticleDefinitionParser.parse(dictionary: [
                "maxcount": 8,
                "emitter": [["rate": 5]],
                "controlpoint": [[
                    "id": 0,
                    "offset": "0 0 0",
                    "flags": 1,
                ]],
            ]),
            device: device,
            seed: 0xB3
        ))
        #expect(system.tracksPointer)
        #expect(system.isBlockedOnAbsentPointer)

        renderer.particleSystems = [system]
        renderer.synchronizeFrameDemand()
        #expect(!renderer.frameDemand.contains(.particles))
        #expect(!renderer.needsContinuousFrames)
        #expect(stack.surface.mtkView.isPaused)

        system.pointerCentered = SIMD2<Float>(1, 1)
        renderer.synchronizeFrameDemand()
        #expect(!system.isBlockedOnAbsentPointer)
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
