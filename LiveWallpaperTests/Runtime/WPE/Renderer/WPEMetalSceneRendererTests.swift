import AppKit
import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import SwiftUI
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite("WPE Metal scene renderer")
struct WPEMetalSceneRendererTests {
    #if DEBUG
    @Test("Oracle media configuration is renderer-local and immutable once loading starts")
    func oracleMediaConfigurationIsLoadScoped() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
        )
        defer { renderer.cleanup() }
        #expect(renderer.oracleMediaSnapshot == nil && renderer.oracleMediaInputReceipt == nil)
        let empty = MonitorNowPlayingState(phase: .noPlayer, title: "")
        try renderer.configureOracleMediaSnapshot(empty)
        #expect(renderer.oracleMediaSnapshot == empty)
        try await renderer.load()
        #expect(renderer.loadGeneration == 1)
        #expect(renderer.mediaEventDispatcher == nil && renderer.mediaTextureSubscription == nil)
        #expect(throws: WPEOracleMediaSnapshotError.loadAlreadyStarted) {
            try renderer.configureOracleMediaSnapshot(.init(phase: .paused, title: "late"))
        }
        #expect(renderer.oracleMediaSnapshot == empty)
        #expect(renderer.oracleMediaInputReceipt == nil, "a scene with no media demand has no source replay")
    }
    #endif

    @Test("Created destruction and ambiguous-name writes preserve object ownership")
    func rendererAppliesOwnedDestructionAndMergedOutputs() throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        let created = WPECreatedLayerScriptState(
            key: "__created_0", imagePath: "models/bar.json", origin: .zero,
            color: SIMD3(repeating: 1), scale: SIMD3(repeating: 1), alpha: 1, visible: true
        )
        let initial = WPELayerScriptOutput(own: .init(visible: true, alpha: 1, videoCommands: []), others: [:], created: [created])
        renderer.applyLayerScriptOutput(initial, ownObjectID: "ownerA")
        renderer.applyLayerScriptOutput(initial, ownObjectID: "ownerB")
        let deletion = WPELayerScriptOutput(own: initial.own, others: [:], destroyedCreatedKeys: ["__created_0"])
        let merged = WPELayerScriptInstance.mergedOutputs(pending: deletion, newer: initial)
        #expect(merged.created.isEmpty)
        renderer.applyLayerScriptOutput(merged, ownObjectID: "ownerA")
        #expect(renderer.liveCreatedLayers["ownerA.__created_0"] == nil)
        #expect(renderer.liveCreatedLayers["ownerB.__created_0"] != nil)
        renderer.applyLayerScriptOutput(deletion, ownObjectID: "ownerA")
        #expect(renderer.liveCreatedLayers.count == 1)

        renderer.sceneScriptSharedState = WPESharedScriptState(layers: [
            .init(id: "A", name: "dup", size: .zero, origin: .zero, index: 0, parentName: nil),
            .init(id: "B", name: "dup", size: .zero, origin: .zero, index: 1, parentName: nil),
        ])
        let mutation = WPELayerScriptOutput(own: initial.own, others: [
            wpeScriptLayerIDKey("B"): .init(visible: false, alpha: 0.25, videoCommands: []),
        ])
        renderer.applyLayerScriptOutput(mutation, ownObjectID: "ownerA")
        #expect(renderer.liveLayerAlpha["B"] == 0.25)
        #expect(renderer.liveLayerAlpha["A"] == nil)
    }

    @Test("Oracle stage copies retain frame boundaries without changing the scene output")
    func oracleStageSnapshots() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        renderer.executor.oracleSceneStagesEnabled = true
        try await renderer.load()
        let stages = renderer.executor.scenePassDumps.filter { $0.label.hasPrefix("oracle.") }
        #expect(stages.map(\.label) == ["oracle.pre-bloom", "oracle.post-bloom", "oracle.post-color-correction"])
        let output = try #require(renderer.outputTexture)
        let expected = try WPEOraclePixelProbe.sample(texture: output, coordinates: [[32, 32]], commandQueue: renderer.executor.commandQueue)
        for stage in stages {
            #expect(stage.texture !== output)
            #expect(stage.texture.width == output.width && stage.texture.height == output.height)
            let actual = try WPEOraclePixelProbe.sample(texture: stage.texture, coordinates: [[32, 32]], commandQueue: renderer.executor.commandQueue)
            #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
        }
        renderer.executor.oracleSceneStagesEnabled = false
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        #expect(renderer.executor.scenePassDumps.allSatisfy { !$0.label.hasPrefix("oracle.") })
    }

    @Test("Terminal procedural geometry and disabled alpha match Windows storage pixels", arguments: [1.0, 0.375])
    func terminalProceduralEffectPublishesAuthoredVertices(alpha: Double) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let files = [
            "scene.json": """
            {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
             "general":{"orthogonalprojection":{"width":256,"height":128},"clearcolor":"0.15 0.25 0.35","cameraparallax":false},
             "objects":[{"id":1,"image":"models/procedural.json","origin":"144 52 0","size":"160 96",
                         "scale":"1.2 0.8 1","angles":"0 0 0.17","effects":[{"id":3,"file":"effects/procedural.json"}]}]}
            """,
            "models/procedural.json": #"{"material":"materials/base.json"}"#,
            "materials/base.json": #"{"passes":[{"shader":"solidlayer","blending":"normal"}]}"#,
            "effects/procedural.json": #"{"passes":[{"material":"materials/procedural.json"}]}"#,
            "materials/procedural.json": #"{"passes":[{"shader":"procedural","blending":"disabled","depthtest":"disabled","depthwrite":"disabled","cullmode":"nocull"}]}"#,
            "shaders/procedural.vert": """
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform vec2 g_Offset; // {"material":"offset","default":"0.13 -0.09"}
            uniform vec2 g_Scale; // {"material":"scale","default":"0.75 1.2"}
            uniform float g_Direction; // {"material":"angle","default":0.3}
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 uv;
            void main() {
                vec2 p = a_Position.xy - vec2(0.5);
                vec2 cs = vec2(cos(-g_Direction), sin(-g_Direction));
                p = vec2(p.x*cs.x-p.y*cs.y, p.x*cs.y+p.y*cs.x);
                p = (p+g_Offset)*g_Scale+vec2(0.5);
                gl_Position = g_ModelViewProjectionMatrix*vec4(p,0,1);
                uv = a_TexCoord;
            }
            """,
            "shaders/procedural.frag": "varying vec2 uv; void main(){gl_FragColor=vec4(uv,0.25,\(alpha));}",
        ]
        for (path, source) in files {
            let url = fixture.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.utf8).write(to: url)
        }
        let renderer = try WPEMetalSceneRenderer(descriptor: fixture.descriptor, cacheRootURL: fixture.root,
                                                 dependencyMounts: [], frame: CGRect(x: 0, y: 0, width: 256, height: 128), device: device)
        defer { renderer.cleanup() }
        try await renderer.load()
        let canonical = try #require(renderer.renderPipeline)
        #expect(canonical.layers.first?.passes.count == 3)
        #expect(canonical.layers.first?.effectPublication != nil)
        let projected = canonical.resolvingEffectPublication(passVisibility: [:], camera: renderer.cameraUniforms)
        let passes = try #require(projected.layers.first?.passes)
        #expect(passes.count == 2)
        let published = try #require(passes.last)
        #expect(published.pass.target == .scene && published.pass.blending == "disabled")
        #expect(renderer.executor.authoredShaderResultByPassID[published.id]?.vertexStage?.execution == .authoredObjectQuad)
        let pixels = try #require(renderer.outputTexture?.readAllPixels())
        // WPE 2.8.42 controls 9000270/9000276, 256x128 UNORM scene RT.
        for (x, y, rgb) in [(97, 118, [38, 64, 89]), (128, 64, [98, 102, 64]), (96, 80, [45, 159, 64])] {
            let pixel = pixels[y * 256 + x]
            #expect(abs(Int(pixel.r) - rgb[0]) <= 1 && abs(Int(pixel.g) - rgb[1]) <= 1 && abs(Int(pixel.b) - rgb[2]) <= 1)
            #expect(pixel.a == 255)
        }
    }

    @Test("Text and particles render without an authored image layer", arguments: [false, true])
    func nonImageSceneHasVisibleOutput(particle: Bool) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try particle ? MetalSceneFixture.audioResponsiveParticleScene(audioFields: false) : MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        scene["objects"] = particle
            ? [["id": "pfx", "particle": "particles/audio.json", "origin": "32 32 0", "visible": true]]
            : [["id": "text", "type": "text", "text": "MMMM", "origin": "32 32 0", "pointsize": 24, "color": "1 1 1"]]
        let data = try JSONSerialization.data(withJSONObject: scene)
        try data.write(to: url)
        let document = try WPESceneDocumentParser.parse(data: data)
        #expect(document.imageObjects.isEmpty)
        #expect(WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.root) == .degraded)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root,
            dependencyMounts: [], frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        let texture = try #require(renderer.outputTexture)
        #expect(texture.width == 64 && texture.height == 64)
        if particle {
            let system = try #require(renderer.particleSystems.first)
            #expect(renderer.particleSystems.count == 1)
            #expect(system.definition.rate == 10)
            system.applyPlaybackCommand(.play)
            system.prewarm(simulatedSeconds: 0.25)
            renderer.executor.synchronizeFrameCompletion = true
            let emitted = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
            #expect(system.liveInstanceCount > 0)
            #expect(try #require(WPEMetalTextureVisualStats.analyze(texture: emitted)).nonBlackPixelCount > 0)
        } else {
            #expect(try #require(WPEMetalTextureVisualStats.analyze(texture: texture)).nonBlackPixelCount > 0)
        }
    }

    @Test("A truly empty scene still fails instead of publishing a clear-only wallpaper")
    func emptySceneHasNoRenderablePasses() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        scene["objects"] = [] as [Any]
        try JSONSerialization.data(withJSONObject: scene).write(to: url)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root,
            dependencyMounts: [], frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
        )
        defer { renderer.cleanup() }
        await #expect(throws: WPEMetalRenderExecutorError.noRenderablePasses) { try await renderer.load() }
    }

    @Test("Only the primary texture slot is mandatory at load")
    func onlyPrimarySlotIsMandatoryAtLoad() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        defer { renderer.cleanup() }
        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/x/effect.json"),
            shader: "workshop/x/custom",
            source: .previous,
            target: .scene,
            textures: [0: .image("base.png"), 4: .asset("wegwegwegh")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: nil,
            textureBindings: [:],
            comboValues: [:],
            uniformValues: [:]
        )
        let roles = renderer.textureReferenceRoles(for: prepared)
        #expect(roles.count >= 2, "the junk slot must still be collected for loading")
        #expect(roles.first?.isRequired == true, "slot 0 stays mandatory")
        #expect(
            roles.dropFirst().allSatisfy { !$0.isRequired },
            "every auxiliary slot must be optional so one broken file can't kill the scene"
        )
    }

    @Test("Genericimage4 preloads every renderer-internal puppet clip mask")
    func genericImage4LoadsAllPuppetClipMasks() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        defer { renderer.cleanup() }
        let pass = WPERenderPass(
            id: "1.0",
            phase: .material,
            shader: "genericimage4",
            source: .image("base.png"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let firstSlot = WPERenderTargetNames.PuppetClip.maskBindingSlot(groupIndex: 0)
        let secondSlot = WPERenderTargetNames.PuppetClip.maskBindingSlot(groupIndex: 1)
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: nil,
            textureBindings: [
                firstSlot: .asset("masks/left"),
                secondSlot: .asset("masks/right"),
            ],
            comboValues: [:],
            uniformValues: [:]
        )

        let roles = renderer.textureReferenceRoles(for: prepared)
        #expect(roles.map(\.reference) == [
            .image("base.png"), .asset("masks/left"), .asset("masks/right"),
        ])
        #expect(roles.first?.isRequired == true)
        #expect(roles.dropFirst().allSatisfy { !$0.isRequired })
    }

    @Test("An FBO-sourced pass does not promote an auxiliary slot to mandatory")
    @MainActor
    func fboPrimaryLeavesAuxiliarySlotsOptional() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        defer { renderer.cleanup() }
        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/x/effect.json"),
            shader: "workshop/x/custom",
            source: .previous,
            target: .scene,
            textures: [4: .asset("wegwegwegh")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: nil,
            textureBindings: [:],
            comboValues: [:],
            uniformValues: [:]
        )
        let roles = renderer.textureReferenceRoles(for: prepared)
        #expect(
            roles.allSatisfy { !$0.isRequired },
            "no external slot is mandatory when the primary is an FBO read"
        )
    }

    @Test("Interactive Metal view accepts first mouse while click capture is enabled")
    func interactiveMetalViewAcceptsFirstMouseWhenCapturingClicks() {
        let view = WPEInteractiveMTKView(
            frame: CGRect(x: 0, y: 0, width: 16, height: 16),
            device: nil
        )

        #expect(view.acceptsFirstMouse(for: nil) == false)
        view.clickCaptureEnabled = true
        #expect(view.acceptsFirstMouse(for: nil) == true)
    }

    @Test("Frame inputs snapshot mirrors the pointer mailbox, sampler, and effective FPS")
    func frameInputsSnapshotMirrorsSources() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.25, 0.75))
        )
        defer { renderer.cleanup() }
        renderer.setClickCaptureEnabled(true)
        let published = WPEPointerFrame(
            position: SIMD2<Double>(0.1, 0.2),
            clickPosition: SIMD2<Double>(0.3, 0.4),
            isDown: true,
            isRightDown: false
        )
        renderer.mailbox.publishPointerFrame(published)
        renderer.setFrameRateCeiling(15)

        let inputs = renderer.makeFrameInputs()
        #expect(inputs.clickCaptureEnabled == true)
        #expect(inputs.pointerSample == WPEMetalPointerSample.inside(SIMD2<Double>(0.25, 0.75)))
        #expect(inputs.pointerFrame == published)
        #expect(inputs.preferredFramesPerSecond == 15)
    }

    @Test("Frame inputs carry an inactive pointer sample when the sampler is outside")
    func frameInputsCarryInactivePointerWhenOutside() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            pointerSampler: .fixedOutside()
        )
        defer { renderer.cleanup() }

        let inputs = renderer.makeFrameInputs()
        #expect(inputs.clickCaptureEnabled == false)
        #expect(inputs.pointerSample == .inactive)
        #expect(inputs.pointerSample.isInsideView == false)
    }

    @Test("Initializes with an MTKView when Metal is available")
    func initializesWithMTKView() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        #expect(renderer.nsView is MTKView)
        #expect(renderer.hasPresentedFrame == false)
    }

    @Test("Loads solidcolor scene without claiming an MTKView present before draw")
    func loadsSolidColorSceneWithoutClaimingPresentBeforeDraw() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        #expect(renderer.hasPresentedFrame == false)
        #expect(renderer.renderGraph?.layers.count == 1)
        #expect(renderer.renderPipeline?.layers.first?.passes.first?.pass.shader == "solidlayer")
    }

    @Test("Readiness combines producer completion before or after present and fails closed without one")
    func readinessCoordinatorCombinesProducerAndPresent() throws {
        let producerBeforePresent = WPEMetalFrameProductionCompletion()
        let earlySubmission = producerBeforePresent.registerSubmission()
        earlySubmission.complete(succeeded: true)
        producerBeforePresent.seal()
        let early = WPEReadinessResultRecorder()
        WPEFrameReadinessCoordinator.observe(
            generation: 3,
            frameProduction: producerBeforePresent,
            presentCompleted: true,
            publish: early.record
        )
        #expect(early.value == WPEFrameReadinessResult(
            generation: 3,
            renderCompleted: true,
            presentCompleted: true
        ))

        let producerAfterPresent = WPEMetalFrameProductionCompletion()
        let lateSubmission = producerAfterPresent.registerSubmission()
        let late = WPEReadinessResultRecorder()
        WPEFrameReadinessCoordinator.observe(
            generation: 4,
            frameProduction: producerAfterPresent,
            presentCompleted: true,
            publish: late.record
        )
        #expect(late.value == nil)
        producerAfterPresent.seal()
        lateSubmission.complete(succeeded: false)
        #expect(late.value == WPEFrameReadinessResult(
            generation: 4,
            renderCompleted: false,
            presentCompleted: true
        ))

        let missing = WPEReadinessResultRecorder()
        WPEFrameReadinessCoordinator.observe(
            generation: 5,
            frameProduction: nil,
            presentCompleted: true,
            publish: missing.record
        )
        #expect(missing.value == WPEFrameReadinessResult(
            generation: 5,
            renderCompleted: false,
            presentCompleted: true
        ))
    }

    @Test("Readiness gate rejects stale, unloaded, and already-completed generations")
    func readinessCoordinatorRejectsStaleGeneration() {
        let result = WPEFrameReadinessResult(
            generation: 9,
            renderCompleted: true,
            presentCompleted: true
        )
        #expect(WPEFrameReadinessCoordinator.isCurrent(
            result,
            didLoad: true,
            currentGeneration: 9,
            completedGeneration: nil
        ))
        #expect(!WPEFrameReadinessCoordinator.isCurrent(
            result,
            didLoad: true,
            currentGeneration: 10,
            completedGeneration: nil
        ))
        #expect(!WPEFrameReadinessCoordinator.isCurrent(
            result,
            didLoad: false,
            currentGeneration: 9,
            completedGeneration: nil
        ))
        #expect(!WPEFrameReadinessCoordinator.isCurrent(
            result,
            didLoad: true,
            currentGeneration: 9,
            completedGeneration: 9
        ))
    }

    @Test("Completed readiness generation removes steady-state tracking but keeps poster completion")
    func completedReadinessGenerationStopsSteadyStateTracking() {
        let pending = WPEFrameReadinessTrackingPlan.make(
            generation: 12,
            completedGeneration: nil,
            hasReadinessConsumer: true
        )
        #expect(pending.tracksReadiness)
        #expect(pending.requiresPresentCompletion(hasPosterConsumer: false))

        let completed = WPEFrameReadinessTrackingPlan.make(
            generation: 12,
            completedGeneration: 12,
            hasReadinessConsumer: true
        )
        #expect(!completed.tracksReadiness)
        #expect(!completed.requiresPresentCompletion(hasPosterConsumer: false))
        #expect(completed.requiresPresentCompletion(hasPosterConsumer: true))

        let noConsumer = WPEFrameReadinessTrackingPlan.make(
            generation: 13,
            completedGeneration: nil,
            hasReadinessConsumer: false
        )
        #expect(!noConsumer.tracksReadiness)
    }

    @Test("Static present retry policy keeps the loop alive then fails closed")
    func staticPresentRetryPolicyKeepsLoopThenFailsClosed() {
        #expect(
            WPEStaticPresentRetry.outcome(
                presented: true,
                sceneHasFrameDemand: false,
                retryCount: 3
            ) == .idle
        )
        #expect(
            WPEStaticPresentRetry.outcome(
                presented: false,
                sceneHasFrameDemand: true,
                retryCount: 3
            ) == .idle
        )
        #expect(
            WPEStaticPresentRetry.outcome(
                presented: false,
                sceneHasFrameDemand: false,
                retryCount: 0
            ) == .retry(count: 1)
        )
        #expect(
            WPEStaticPresentRetry.outcome(
                presented: false,
                sceneHasFrameDemand: false,
                retryCount: WPEStaticPresentRetry.maxAttempts - 2
            ) == .retry(count: WPEStaticPresentRetry.maxAttempts - 1)
        )
        #expect(
            WPEStaticPresentRetry.outcome(
                presented: false,
                sceneHasFrameDemand: false,
                retryCount: WPEStaticPresentRetry.maxAttempts - 1
            ) == .failed
        )
    }

    @Test("Present source release is exact-once with and without a poster consumer")
    func presentSourceReleaseRoutesExactlyOnce() {
        let immediate = WPEPresentReleaseRecorder()
        WPEPresentSourceReleaseRouter.route(releaseSource: immediate.recordRelease)
        #expect(immediate.releaseCount == 1)

        let delayed = WPEPresentReleaseRecorder()
        WPEPresentSourceReleaseRouter.route(
            releaseSource: delayed.recordRelease,
            consumer: delayed.hold
        )
        #expect(delayed.releaseCount == 0)
        delayed.releaseHeld()
        delayed.releaseHeld()
        #expect(delayed.releaseCount == 1)

        let abandoned = WPEPresentReleaseRecorder()
        WPEPresentSourceReleaseRouter.route(
            releaseSource: abandoned.recordRelease,
            consumer: { _ in }
        )
        #expect(abandoned.releaseCount == 1)
    }

    @Test("Scene readiness follows successful GPU completion for the current load generation")
    func sceneReadinessRequiresCurrentGPUCompletion() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        let renderActor = WPEDisplayRenderActor(backing: .main)
        await renderActor.adopt(WPERendererHandoff(renderer: renderer).renderer)
        defer { renderActor.requestStop() }

        try await renderActor.load()
        let loaded = try #require(await renderActor.rendererStateSnapshot())
        #expect(loaded.isLoaded)
        #expect(!loaded.hasPresentedFrame)
        #expect(loaded.completedPresentGeneration == nil)

        await renderActor.recordPresentCompletion(WPEFrameReadinessResult(
            generation: loaded.currentLoadGeneration,
            renderCompleted: false,
            presentCompleted: true
        ))
        let failed = try #require(await renderActor.rendererStateSnapshot())
        #expect(failed.failedPresentGeneration == loaded.currentLoadGeneration)
        #expect(!failed.hasPresentedFrame)

        await renderActor.recordPresentCompletion(WPEFrameReadinessResult(
            generation: loaded.currentLoadGeneration,
            renderCompleted: true,
            presentCompleted: false
        ))
        let presentFailed = try #require(await renderActor.rendererStateSnapshot())
        #expect(presentFailed.failedPresentGeneration == loaded.currentLoadGeneration)
        #expect(!presentFailed.hasPresentedFrame)

        await renderActor.recordPresentCompletion(WPEFrameReadinessResult(
            generation: loaded.currentLoadGeneration,
            renderCompleted: true,
            presentCompleted: true
        ))
        let ready = try #require(await renderActor.rendererStateSnapshot())
        #expect(ready.completedPresentGeneration == loaded.currentLoadGeneration)
        #expect(ready.failedPresentGeneration == nil)
        #expect(ready.hasPresentedFrame)

        await renderActor.recordPresentCompletion(WPEFrameReadinessResult(
            generation: loaded.currentLoadGeneration - 1,
            renderCompleted: false,
            presentCompleted: false
        ))
        let unchanged = try #require(await renderActor.rendererStateSnapshot())
        #expect(unchanged.completedPresentGeneration == loaded.currentLoadGeneration)
        #expect(unchanged.failedPresentGeneration == nil)
        await renderActor.teardownRenderer()
    }

    @Test("Static drawable miss retries present without re-encoding the scene")
    func staticDrawableMissRetriesPresentWithoutReencoding() async throws {
        let stack = try await StaticPresentRetryFixture.make()
        defer { stack.cleanup() }
        let renderer = stack.renderer

        let loadedID = ObjectIdentifier(try #require(renderer.outputTexture))
        let encodesBefore = renderer.frameEncodeCountForTesting
        renderer.executor.remainingForcedDrawableMissesForTesting = 1

        renderer.renderAndPresentFrame()

        #expect(ObjectIdentifier(try #require(renderer.outputTexture)) == loadedID)
        #expect(renderer.frameEncodeCountForTesting == encodesBefore)
        #expect(renderer.pendingPresentRetryCount == 1)
        #expect(renderer.failedPresentGeneration == nil)
        #expect(renderer.completedPresentGeneration == nil)
        #expect(!renderer.needsContinuousFrames)
        #expect(renderer.needsPacingLoop)
    }

    @Test("Forced rerender present miss reuses the new output on the next tick")
    func forcedRerenderPresentMissDoesNotEncodeAgainOnRetry() async throws {
        let stack = try await StaticPresentRetryFixture.make()
        defer { stack.cleanup() }
        let renderer = stack.renderer

        renderer.pendingForcedRerender = true
        renderer.executor.remainingForcedDrawableMissesForTesting = 2
        let encodesBefore = renderer.frameEncodeCountForTesting

        renderer.renderAndPresentFrame()
        #expect(renderer.frameEncodeCountForTesting == encodesBefore + 1)
        #expect(!renderer.pendingForcedRerender)
        #expect(renderer.pendingPresentRetryCount == 1)
        let afterForcedID = ObjectIdentifier(try #require(renderer.outputTexture))

        renderer.renderAndPresentFrame()
        #expect(renderer.frameEncodeCountForTesting == encodesBefore + 1)
        #expect(ObjectIdentifier(try #require(renderer.outputTexture)) == afterForcedID)
        #expect(renderer.pendingPresentRetryCount == 2)
        #expect(renderer.failedPresentGeneration == nil)
    }

    @Test("Repeated static drawable misses fail the load generation without re-encoding")
    func staticDrawableMissExhaustionFailsGeneration() async throws {
        let stack = try await StaticPresentRetryFixture.make()
        defer { stack.cleanup() }
        let renderer = stack.renderer

        let loadedID = ObjectIdentifier(try #require(renderer.outputTexture))
        let encodesBefore = renderer.frameEncodeCountForTesting
        renderer.executor.remainingForcedDrawableMissesForTesting = WPEStaticPresentRetry.maxAttempts

        for _ in 0..<WPEStaticPresentRetry.maxAttempts {
            renderer.renderAndPresentFrame()
        }

        #expect(ObjectIdentifier(try #require(renderer.outputTexture)) == loadedID)
        #expect(renderer.frameEncodeCountForTesting == encodesBefore)
        #expect(renderer.failedPresentGeneration == renderer.loadGeneration)
        #expect(renderer.pendingPresentRetryCount == 0)
        #expect(!renderer.needsPacingLoop)
        #expect(!renderer.hasPresentedFrame)
    }

    @Test("A later successful present after one miss becomes ready")
    func staticPresentSucceedsAfterOneDrawableMiss() async throws {
        let stack = try await StaticPresentRetryFixture.make()
        defer { stack.cleanup() }
        let renderer = stack.renderer
        let actor = try #require(renderer.displayActor)
        let generation = renderer.loadGeneration
        let loadedID = ObjectIdentifier(try #require(renderer.outputTexture))

        renderer.executor.remainingForcedDrawableMissesForTesting = 1
        renderer.renderAndPresentFrame()
        #expect(renderer.pendingPresentRetryCount == 1)

        renderer.renderAndPresentFrame()
        #expect(ObjectIdentifier(try #require(renderer.outputTexture)) == loadedID)

        var completed: Int?
        for _ in 0..<100 {
            let snapshot = await actor.rendererStateSnapshot()
            completed = snapshot?.completedPresentGeneration
            if completed == generation { break }
            if snapshot?.failedPresentGeneration == generation { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(completed == generation)
        #expect(renderer.failedPresentGeneration == nil)
        #expect(renderer.pendingPresentRetryCount == 0)
        #expect(renderer.hasPresentedFrame)
    }

    @Test("Async scene load failure surfaces session runtimeError and fires the change callback")
    func sceneLoadFailurePropagatesSessionRuntimeError() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        try Data("{ not valid json".utf8).write(to: fixture.root.appendingPathComponent("scene.json"))

        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let renderActor = WPEDisplayRenderActor(backing: .main)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let session = SceneWallpaperSession(window: window, renderActor: renderActor, surface: surface)
        defer { session.cleanup() }

        var changeCount = 0
        session.onRuntimeErrorChange = { changeCount += 1 }

        await renderActor.adopt(WPERendererHandoff(renderer: renderer).renderer)
        await session.beginLoad()

        let error = try #require(session.runtimeError)
        guard case .sceneRenderingFailed(let description) = error else {
            Issue.record("Expected sceneRenderingFailed, got \(error)")
            return
        }
        #expect(!description.isEmpty)
        #expect(changeCount == 1)
        #expect(error.canRetry)
        #expect(session.summary.activity == .error)
    }

    @Test("A load aborted by a missing texture keeps that load's misses for the failure report")
    func failedLoadKeepsFailureTimeResolution() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.materialTextureScene(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("materials/base.png"))

        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let renderActor = WPEDisplayRenderActor(backing: .main)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let session = SceneWallpaperSession(window: window, renderActor: renderActor, surface: surface)
        defer { session.cleanup() }

        await renderActor.adopt(WPERendererHandoff(renderer: renderer).renderer)
        await session.beginLoad()
        #expect(session.loadError != nil)
        #expect(await session.prepareForDisplay(timeout: .seconds(1)) == .failed)
        let missingAtFailure = session.rendererDiagnostics?.resolution.failureMissingResources.map(\.path) ?? []
        #expect(missingAtFailure.contains { $0.hasPrefix("materials/base") })

        await session.pollRendererState()
        let missingAfterTeardown = session.rendererDiagnostics?.resolution.failureMissingResources.map(\.path) ?? []
        #expect(missingAfterTeardown == missingAtFailure)
        let eventCount = session.rendererDiagnostics?.resolution.events.count

        await #expect(throws: (any Error).self) { try await renderActor.reload() }
        await session.pollRendererState()
        #expect(session.rendererDiagnostics?.resolution.events.count == eventCount)
    }

    @Test("System audio demand requires scene opt-in and releases during preview suspension")
    func previewSuspensionReconcilesSystemAudioDemand() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        let renderActor = WPEDisplayRenderActor(backing: .main)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let demand = RecordingSystemAudioCaptureDemand()
        let session = SceneWallpaperSession(
            window: window,
            renderActor: renderActor,
            surface: surface,
            audioCaptureDemandController: demand
        )
        defer { session.cleanup() }

        session.updateSystemAudioCaptureRequirement(false)
        #expect(demand.consumerCount == 0)
        #expect(demand.retainCount == 0)

        session.updateSystemAudioCaptureRequirement(true)
        #expect(demand.consumerCount == 1)
        #expect(session.isPlaying)

        session.applyPreviewPerformanceProfile(.suspended)
        #expect(demand.consumerCount == 0)
        #expect(!session.isPlaying)

        session.applyPerformanceProfile(.suspended)
        session.clearPreviewPerformanceOverride()
        #expect(demand.consumerCount == 0)
        #expect(!session.isPlaying)

        session.applyPerformanceProfile(.quality)
        #expect(demand.consumerCount == 1)
        session.pause()
        #expect(demand.consumerCount == 0)
        session.applyPreviewPerformanceProfile(.suspended)
        session.clearPreviewPerformanceOverride()
        #expect(demand.consumerCount == 0)

        session.play()
        #expect(demand.consumerCount == 1)
        session.applyPreviewPerformanceProfile(.suspended)
        #expect(demand.consumerCount == 0)
        #expect(demand.retainCount == demand.releaseCount)
    }

    @Test("Transition hold freezes the scene and its audio without reporting a pause")
    func transitionHoldFreezesSceneWithoutReportingPause() throws {
        let demand = RecordingSystemAudioCaptureDemand()
        let session = try Self.makeTransitionHoldSession(demand: demand)
        defer { session.cleanup() }
        session.updateSystemAudioCaptureRequirement(true)
        #expect(session.isPlaying)
        #expect(demand.consumerCount == 1)

        session.setTransitionHold(true)
        #expect(!session.isPlaying)
        #expect(demand.consumerCount == 0)
        #expect(session.summary.activity == .active)
        #expect(session.userIntendsToPlay)

        session.applyPerformanceProfile(.quality)
        #expect(!session.isPlaying)

        session.setTransitionHold(false)
        #expect(session.isPlaying)
        #expect(demand.consumerCount == 1)
        #expect(session.summary.activity == .active)
    }

    @Test("A pause pressed during a transition hold survives the release")
    func transitionHoldReleaseKeepsUserPause() throws {
        let session = try Self.makeTransitionHoldSession(demand: RecordingSystemAudioCaptureDemand())
        defer { session.cleanup() }

        session.setTransitionHold(true)
        #expect(!session.isPlaying)
        session.pause()
        session.setTransitionHold(false)

        #expect(!session.isPlaying)
        #expect(!session.userIntendsToPlay)
        #expect(session.summary.activity == .paused)
    }

    @Test("Releasing a transition hold under a suspended policy stays suspended")
    func transitionHoldReleaseKeepsPolicySuspension() throws {
        let session = try Self.makeTransitionHoldSession(demand: RecordingSystemAudioCaptureDemand())
        defer { session.cleanup() }

        session.setTransitionHold(true)
        session.applyPerformanceProfile(.quality)
        #expect(!session.isPlaying)
        session.applyPerformanceProfile(.suspended)
        #expect(session.summary.activity == .policySuspended)
        session.setTransitionHold(false)

        #expect(!session.isPlaying)
        #expect(session.summary.activity == .policySuspended)
        session.applyPerformanceProfile(.quality)
        #expect(session.isPlaying)
    }

    private static func makeTransitionHoldSession(
        demand: RecordingSystemAudioCaptureDemand
    ) throws -> SceneWallpaperSession {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return SceneWallpaperSession(
            window: window,
            renderActor: WPEDisplayRenderActor(backing: .main),
            surface: surface,
            audioCaptureDemandController: demand
        )
    }

    @Test("Scene render state is derived from the session's cached renderer state")
    func sceneRenderStateDerivesFromSessionCache() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        try Data("{ not valid json".utf8).write(to: fixture.root.appendingPathComponent("scene.json"))
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let renderActor = WPEDisplayRenderActor(backing: .main)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let session = SceneWallpaperSession(window: window, renderActor: renderActor, surface: surface)
        defer { session.cleanup() }

        #expect(SceneRenderState.derivedState(session: nil) == .notRendering)
        #expect(SceneRenderState.derivedState(session: session) == .loading(progress: nil))

        await renderActor.adopt(WPERendererHandoff(renderer: renderer).renderer)
        await session.beginLoad()
        let loaded = SceneRenderState.derivedState(session: session)
        guard case .error = loaded else {
            Issue.record("Expected the cached load failure, got \(loaded)")
            return
        }
    }

    @Test("Poster commit gate resolves success, supersession, cancellation, failure, and cleanup")
    func posterCommitGateResolvesEveryWaiter() async {
        let gate = ScenePropertyPosterCommitGate()

        let successful = gate.stage(overrides: ["enabled": .bool(true)])
        let successfulWait = Task { await gate.wait(for: successful) }
        await Task.yield()
        gate.resolve(successful, result: true)
        #expect(await successfulWait.value)
        #expect(await gate.wait(for: successful))

        let superseded = gate.stage(overrides: ["enabled": .bool(false)])
        let supersededWait = Task { await gate.wait(for: superseded) }
        await Task.yield()
        let cancelled = gate.stage(overrides: ["enabled": .bool(true)])
        #expect(!(await supersededWait.value))

        let cancelledWait = Task { await gate.wait(for: cancelled) }
        await Task.yield()
        cancelledWait.cancel()
        #expect(!(await cancelledWait.value))

        let failed = gate.stage(overrides: ["enabled": .bool(false)])
        let failedWait = Task { await gate.wait(for: failed) }
        await Task.yield()
        gate.resolve(failed, result: false)
        #expect(!(await failedWait.value))
        #expect(!(await gate.wait(for: failed)))

        let invalidated = gate.stage(overrides: ["enabled": .bool(true)])
        let invalidatedWait = Task { await gate.wait(for: invalidated) }
        await Task.yield()
        gate.invalidate()
        #expect(!(await invalidatedWait.value))
    }

    @Test("Config channel applies fire-and-forget setters in order (last write wins)")
    func configChannelAppliesLastWriteWins() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let renderActor = WPEDisplayRenderActor(backing: .main)
        defer { renderActor.requestStop() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize,
            device: device
        )
        await renderActor.adopt(WPERendererHandoff(renderer: renderer).renderer)

        let volumes = [0.11, 0.94, 0.29, 0.53, 0.06, 0.72, 0.48, 0.83, 0.15, 0.37]
        for volume in volumes {
            renderActor.submitConfig(.audioVolume(volume))
        }

        var applied = -1.0
        for _ in 0..<400 {
            applied = await renderActor.currentPendingAudioVolume() ?? -1
            if applied == 0.37 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(applied == 0.37)
    }

    @Test("Dynamic origin scripts keep otherwise static scenes on the continuous render loop")
    func dynamicOriginScriptsKeepRendererLive() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.cursorOriginScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.25, 0.75))
        )

        try await renderer.load()

        let mtkView = try #require(renderer.nsView as? MTKView)
        #expect(mtkView.isPaused == false)
        #expect(mtkView.enableSetNeedsDisplay == false)
    }

    @Test("Cursor scripts use a neutral pointer while the mouse is outside this renderer")
    func cursorScriptsUseNeutralPointerOutsideRenderer() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.cursorOriginScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 100, y: 100, width: 64, height: 64),
            device: device,
            pointerSampler: .fixedOutside()
        )

        try await renderer.load()

        let uniforms = try #require(renderer.lastRuntimeUniforms)
        #expect(uniforms.pointerPosition == SIMD2<Double>(0.5, 0.5))

        let origin = try #require(renderer.lastFramePipeline?.layers.first?.graphLayer.geometry.origin)
        #expect(abs(origin.x - 32) < 0.0001)
        #expect(abs(origin.y - 32) < 0.0001)
    }

    @Test("A non-drawn parallax root's static term follows its live origin, not the load-time one", arguments: [true, false])
    func nonDrawnParallaxRootCenterFollowsLiveOrigin(hostMoves: Bool) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.groupHostParallaxScene(hostOriginScript: hostMoves
            ? "'use strict';\\nexport function update(value) {\\n  value.x = input.cursorWorldPosition.x + 100;\\n  return value;\\n}"
            : nil)
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        try await renderer.load()
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())

        // The child sits at the host's local origin, so its live geometry origin is the host's live origin.
        let liveOrigin = try #require(renderer.lastFramePipeline?.layers.first { $0.graphLayer.objectID == "child" }?.graphLayer.geometry.origin)
        #expect((liveOrigin.x > 32) == hostMoves)
        let center = try #require(renderer.executor.parallaxRootCenterByObjectID["child"])
        #expect(center == SIMD2<Float>(Float(liveOrigin.x) - 32, Float(liveOrigin.y) - 32))
        #expect(center.y == 0)
        renderer.cleanup()
    }

    @Test("Click capture remains active when Follow Cursor is disabled")
    func clickCaptureRemainsActiveWhenFollowCursorIsDisabled() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.25, 0.75))
        )
        let view = try #require(renderer.nsView as? WPEInteractiveMTKView)
        renderer.setMouseInteractionEnabled(false)
        renderer.setClickCaptureEnabled(true)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 16, y: 16),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseMoved(with: event)

        try await renderer.load()

        let uniforms = try #require(renderer.lastRuntimeUniforms)
        #expect(uniforms.pointerPosition == SIMD2<Double>(0.5, 0.5))
        #expect(uniforms.pointerClick.position == SIMD2<Double>(0.25, 0.75))
    }

    @Test("Loads material texture bindings before rendering")
    func loadsMaterialTextureBindings() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.materialTextureScene(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let pixel = try #require(renderer.outputTexture?.readPixel(x: 32, y: 32))
        #expect(pixel.r >= 200)
        #expect(pixel.r > pixel.g)
        #expect(pixel.r > pixel.b)
    }

    @Test("Hidden text object's compute script still runs, populating shared state")
    func hiddenTextComputeScriptRunsDespiteInvisibility() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.hiddenComputeTextScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let answer = renderer.sharedScriptValueForTesting("answer") as? Double
        #expect(answer == 42)
    }

    @Test("Text content scripts keep an otherwise static scene on the continuous render loop")
    func textContentScriptsKeepRendererLive() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.hiddenComputeTextScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let mtkView = try #require(renderer.nsView as? MTKView)
        #expect(mtkView.isPaused == false)
        #expect(mtkView.enableSetNeedsDisplay == false)
    }

    @Test("A text value script alone can hide an image layer in the rendered frame")
    func textValueScriptAloneHidesImageLayer() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.textScriptCrossLayerScene(
            initBody: "thisScene.getLayer('B').visible = false;"
        )
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())

        let imageLayer = try #require(renderer.lastFramePipeline?.layers.first { $0.graphLayer.objectID == "b" })
        #expect(imageLayer.graphLayer.visible == false, "text script's hide of B never reached the frame pipeline")
    }

    @Test("A text value script hiding another text layer reaches that text's draw state")
    func textValueScriptHidesAnotherTextLayer() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.textScriptCrossLayerScene(
            initBody: "thisScene.getLayer('TB').visible = false; thisScene.getLayer('TB').alpha = 0.25;"
        )
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())

        #expect(renderer.layerObjectIDByName["TB"] == "tb")
        #expect(renderer.liveLayerVisibilityIncludingText["tb"] == false, "text layer TB still drawn after a script hid it")
        #expect(renderer.liveTextAlpha["tb"] == 0.25, "text draw ignores the script-set alpha of TB")
    }

    @Test("Renders layers created by SceneScript")
    func rendersSceneScriptCreatedLayers() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.sceneScriptCreatedLayerScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let pixel = try #require(renderer.outputTexture?.readPixel(x: 32, y: 32))
        #expect(pixel.r >= 200)
        #expect(pixel.r > pixel.g)
        #expect(pixel.r > pixel.b)
    }

    @Test("Namespaced string visualizer draws bar0 and 63 clones with their published geometry", arguments: [0.0, 90.0], [false, true])
    func rendersNamespacedVisualizer(angleDegrees: Double, workshopShader: Bool) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.sceneScriptVisualizerScene(angleDegrees: angleDegrees, workshopShader: workshopShader)
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
        )
        try await renderer.load()
        #expect(renderer.sceneScriptSharedState?.get("initComplete") as? Bool == true)
        let layers = try #require(renderer.lastFramePipeline?.layers)
        #expect(layers.count == 64)
        #expect(layers.allSatisfy { $0.passes.count == (workshopShader ? 2 : 1) })
        if workshopShader {
            expectIndependentWorkshopTargets(layers)
        }
        expectVisualizerGeometry(layers, angleDegrees: angleDegrees)
        let output = try #require(renderer.outputTexture)
        let source = try #require(renderer.loadedTextures["materials/bar.png"])
        let sourcePixel = try #require(source.readAllPixels()?.first)
        #expect(sourcePixel.r > 250 && sourcePixel.g < 5 && sourcePixel.b < 5 && sourcePixel.a == 255)
        let pixels = try #require(output.readAllPixels())
        printVisualizerDiagnostics(renderer: renderer, output: output, pixels: pixels, layers: layers,
                                   angleDegrees: angleDegrees, workshopShader: workshopShader)
        let minimumRed: UInt8 = workshopShader ? 80 : 200
        var redPixels = 0, farRightRedPixels = 0
        for y in 0 ..< output.height {
            for x in 0 ..< output.width {
                let pixel = pixels[y * output.width + x]
                if pixel.r > minimumRed, pixel.g < 20, pixel.b < 20 {
                    redPixels += 1
                    if x > 48 {
                        farRightRedPixels += 1
                    }
                }
            }
        }
        #expect(redPixels > 128)
        #expect(farRightRedPixels > 16) // Cannot be satisfied by bar0 alone.
        if angleDegrees == 0 {
            // bar0 occupies world y=4...6 when bottom-aligned; a center anchor
            // only reaches y=5. This pixel distinguishes the actual draw path.
            let anchored = pixels[58 * output.width + 4]
            print("[VisualizerAnchor] \(anchored)")
            #expect(anchored.r > minimumRed && anchored.g < 20)
        }
        renderer.cleanup()
        #expect(renderer.liveCreatedLayers.isEmpty)
        #expect(renderer.liveLayerPresentation.isEmpty)
        #expect(renderer.lastFramePipeline == nil)
    }

    private func expectIndependentWorkshopTargets(_ layers: [WPEPreparedRenderLayer]) {
        #expect(layers.allSatisfy { $0.passes[0].uniformValues["g_UserAlpha"] == .number(0.5) })
        var targets = Set<String>()
        for layer in layers {
            guard case let .layerComposite(target) = layer.passes[0].pass.target else {
                Issue.record("workshop material lost its independent offscreen target")
                continue
            }
            #expect(targets.insert(target).inserted)
            #expect(layer.passes[1].pass.source == .fbo(target))
            #expect(layer.passes[1].textureReferences.contains(.fbo(target)))
            #expect(layer.passes[1].pass.target == .scene)
        }
        #expect(targets.count == 64)
    }

    private func expectVisualizerGeometry(_ layers: [WPEPreparedRenderLayer], angleDegrees: Double) {
        #expect(layers.last?.graphLayer.objectID == "bar")
        #expect(layers.first?.graphLayer.objectID == "bar.__created_62")
        #expect(layers.allSatisfy { $0.graphLayer.geometry.alignment == .bottom })
        #expect(layers.allSatisfy { abs($0.graphLayer.geometry.angles.z - angleDegrees * .pi / 180) < 0.0001 })
        #expect(layers.allSatisfy { $0.graphLayer.geometry.scale == SIMD3(0.5, 0.25, 0) })
        #expect(layers.dropLast().allSatisfy { $0.graphLayer.parallaxDepth == .zero })
        #expect(layers.map(\.graphLayer.sortIndex) == Array(0 ..< 64))
    }

    private func printVisualizerDiagnostics(
        renderer: WPEMetalSceneRenderer, output: MTLTexture, pixels: [MetalPixel],
        layers: [WPEPreparedRenderLayer], angleDegrees: Double, workshopShader: Bool
    ) {
        var histogram: [String: Int] = [:]
        for pixel in pixels {
            histogram["\(pixel.r),\(pixel.g),\(pixel.b),\(pixel.a)", default: 0] += 1
        }
        print("[VisualizerPixels] angle=\(angleDegrees) workshop=\(workshopShader) output=\(output.width)x\(output.height) format=\(output.pixelFormat.rawValue) scene=\(renderer.sceneRenderSize) colors=\(histogram.sorted { $0.value > $1.value }.prefix(8))")
        for (key, texture) in renderer.loadedTextures.sorted(by: { $0.key < $1.key }) {
            let pixel = texture.readAllPixels()?.first
            print("[VisualizerSource] \(key) \(texture.width)x\(texture.height) format=\(texture.pixelFormat.rawValue) pixel=\(String(describing: pixel))")
        }
        for layer in [layers[0], layers[layers.count - 1]] {
            print("[VisualizerLayer] id=\(layer.id) geometry=\(layer.graphLayer.geometry)")
            for pass in layer.passes {
                print("[VisualizerPass] id=\(pass.id) shader=\(pass.pass.shader) source=\(pass.pass.source) target=\(pass.pass.target) textures=\(pass.textureBindings) constants=\(pass.uniformValues)")
            }
        }
    }

    @Test("Disjoint presentation assignments from separate scripts retain each other's fields")
    func disjointLayerPresentationAssignmentsMerge() async throws {
        let fixture = try MetalSceneFixture.sceneScriptCreatedLayerScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        try await renderer.load()
        let neutral = WPELayerScriptState(visible: true, alpha: 1, videoCommands: [], visibleAssigned: false, alphaAssigned: false)
        renderer.applyLayerScriptOutput(.init(own: neutral, others: [:], presentation: ["Template": .init(alignment: "bottom")]), ownObjectID: "A")
        renderer.applyLayerScriptOutput(.init(own: neutral, others: [:], presentation: ["Template": .init(parallaxDepth: SIMD2(0.1, 0.2))]), ownObjectID: "B")
        #expect(renderer.liveLayerPresentation["template"]?.alignment == "bottom")
        #expect(renderer.liveLayerPresentation["template"]?.parallaxDepth == SIMD2(0.1, 0.2))
        renderer.applyLayerScriptOutput(.init(own: neutral, others: [:]), ownObjectID: "C")
        #expect(renderer.liveLayerPresentation["template"]?.alignment == "bottom")
        renderer.cleanup()
    }

    @Test("Angles scripts are WPE degrees: returning 90 turns a horizontal bar vertical")
    func anglesScriptOutputConvertsDegreesToRadians() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.anglesScriptScene(
            anglesValue: "0 0 0",
            anglesScript: "'use strict';\nexport function update(value) { value.z = 90; return value; }"
        )
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let texture = try #require(renderer.outputTexture)
        #expect(try #require(texture.readPixel(x: 32, y: 12)).r >= 200)
        #expect(try #require(texture.readPixel(x: 32, y: 52)).r >= 200)
        #expect(try #require(texture.readPixel(x: 12, y: 32)).r < 100)
        #expect(try #require(texture.readPixel(x: 52, y: 32)).r < 100)
    }

    @Test("Angles script seeds convert from scene radians to script degrees")
    func anglesScriptSeedConvertsRadiansToDegrees() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.anglesScriptScene(
            anglesValue: "0 0 1.5707963",
            anglesScript: "'use strict';\nexport function update(value) { value.z = (value.z > 45) ? 90 : 0; return value; }"
        )
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let texture = try #require(renderer.outputTexture)
        #expect(try #require(texture.readPixel(x: 32, y: 12)).r >= 200)
        #expect(try #require(texture.readPixel(x: 32, y: 52)).r >= 200)
        #expect(try #require(texture.readPixel(x: 12, y: 32)).r < 100)
        #expect(try #require(texture.readPixel(x: 52, y: 32)).r < 100)
    }

    @Test("Resolves dependency-mounted texture references")
    func resolvesDependencyMountedTextures() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.dependencyTextureScene()
        defer { fixture.cleanup() }
        let dependencyRoot = try #require(fixture.dependencyRoot)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: dependencyRoot)],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let pixel = try #require(renderer.outputTexture?.readPixel(x: 32, y: 32))
        #expect(pixel.g >= 245)
        #expect(pixel.g > pixel.r)
        #expect(pixel.g > pixel.b)
    }

    @Test("Load failure populates loadDiagnostics with a SceneLoadDiagnostic")
    func loadFailurePopulatesDiagnostics() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = SceneDescriptor(
            workshopID: UUID().uuidString,
            cacheRelativePath: "wpe-cache/missing-\(UUID().uuidString)",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        let nonExistentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalDiagnostics-\(UUID().uuidString)", isDirectory: true)

        let renderer = try WPEMetalSceneRenderer(
            descriptor: descriptor,
            cacheRootURL: nonExistentRoot,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        await #expect(throws: (any Error).self) {
            try await renderer.load()
        }

        let diagnostic = try #require(renderer.loadDiagnostics)
        if case .fileMissing(_, let path) = diagnostic {
            #expect(path == descriptor.entryFile)
        } else {
            Issue.record("Expected .fileMissing diagnostic, got \(diagnostic)")
        }
    }

    @Test("A damaged material file is not a capability gap, and a texture format the GPU can't sample is")
    func loadDiagnosticSeparatesDamageFromCapabilityGaps() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = SceneDescriptor(
            workshopID: UUID().uuidString,
            cacheRelativePath: "wpe-cache/missing-\(UUID().uuidString)",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        let renderer = try WPEMetalSceneRenderer(
            descriptor: descriptor,
            cacheRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("WPEMetalDiagnostics-\(UUID().uuidString)", isDirectory: true),
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        defer { renderer.cleanup() }
        func diagnostic(_ error: any Error) -> SceneLoadDiagnostic {
            renderer.diagnostic(for: error, fallbackPath: nil, layerName: "L")
        }

        let damagedJSON = "Couldn't parse m.json as JSON"
        #expect(diagnostic(SceneResourceResolver.ResolveError.materialUnresolved(reason: damagedJSON)) == .other(layer: "L", message: damagedJSON))
        for gap in [WPEMetalTextureLoaderError.unsupportedFormat(.rgba1010102), .unsupportedCompressedFormat(.bc7)] {
            let reason = try #require(gap.errorDescription)
            #expect(diagnostic(gap) == .materialUnresolved(layer: "L", reason: reason), "\(gap)")
        }
        let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let builtinLayer = try #require(#expect(throws: SceneResourceResolver.ResolveError.self) {
            _ = try SceneResourceResolver(cacheRootURL: emptyRoot).resolveImage(relativePath: "models/util/solidlayer.json")
        })
        let builtinGap = diagnostic(builtinLayer)
        #expect(!SceneFailureCause.make(builtinGap).canRetry, "a missing built-in layer offers Retry: \(builtinGap)")

        // Controls: an executor gap stays a gap; a malformed payload stays unclassified.
        let noPasses = diagnostic(WPEMetalRenderExecutorError.noRenderablePasses)
        if case let .materialUnresolved(layer, _) = noPasses {
            #expect(layer == "L")
        } else {
            Issue.record("A scene with no renderable passes no longer reads as a capability gap: \(noPasses)")
        }
        let malformed = WPEMetalTextureLoaderError.malformedPayload("x")
        let malformedMessage = try #require(malformed.errorDescription)
        #expect(diagnostic(malformed) == .other(layer: "L", message: malformedMessage))
    }

    @Test("Successful reload clears stale loadDiagnostics")
    func reloadClearsStaleDiagnostics() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()
        try await renderer.reload()

        #expect(renderer.loadDiagnostics == nil)
    }

    @Test("Computes runtime uniforms from clock pointer and performance profile during load render")
    func computesRuntimeUniformsDuringLoadRender() async throws {
        WPEOracleMode.testingOverride = false
        defer { WPEOracleMode.testingOverride = nil }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 5,
            hour: 12,
            minute: 0,
            second: 0
        ).date)

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            frameClock: WPEMetalFrameClock(
                loadTime: 100,
                currentMediaTime: { 101.25 },
                currentDate: { date },
                calendar: calendar
            ),
            pointerSampler: .fixed(SIMD2<Double>(0.25, 0.75))
        )
        renderer.applyPerformanceProfile(.suspended)

        try await renderer.load()

        let uniforms = try #require(renderer.lastRuntimeUniforms)
        #expect(abs(uniforms.time - 1.25) < 0.0001)
        #expect(abs(uniforms.daytime - 0.5) < 0.0001)
        #expect(uniforms.brightness == 1)
        #expect(uniforms.pointerPosition == SIMD2<Double>(0.25, 0.75))
    }

    @Test("A suspended span does not advance the scene runtime after resume")
    func suspendedSpanDoesNotAdvanceRuntime() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let now = OSAllocatedUnfairLock(initialState: 10.0)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            frameClock: WPEMetalFrameClock(loadTime: 0, currentMediaTime: { now.withLock { $0 } })
        )
        renderer.applyPerformanceProfile(.suspended)
        now.withLock { $0 = 130 }
        renderer.applyPerformanceProfile(.quality)
        now.withLock { $0 = 130.1 }

        let time = renderer.frameClock.runtimeUniforms(
            profile: .quality,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        ).time
        #expect(abs(time - 10.1) < 0.0001)
    }

    @Test("Loads preview snapshot from Metal offscreen output")
    func loadsPreviewSnapshotFromMetalOutput() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }

        let key = WPESceneDebugArtifacts.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let snapshot = try #require(renderer.cachedSnapshot)
        #expect(snapshot.size.width == 64)
        #expect(snapshot.size.height == 64)
    }

    @Test("Scene debug artifacts do not emit render heartbeat lines")
    func sceneDebugArtifactsSkipRenderHeartbeat() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }

        WPESceneDebugArtifacts.shared.setEnabledForTesting(true)
        defer { WPESceneDebugArtifacts.shared.setEnabledForTesting(nil) }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        let log = try await Self.sceneDebugLog(
            for: fixture.descriptor.workshopID,
            containing: "load() succeeded; rendered first texture; awaiting present"
        )
        #expect(log.contains("[load.begin]"))
        #expect(!log.contains("[heartbeat]"))
    }

    @Test("Texture load failure attributes diagnostic to the WPE object name that referenced it")
    func textureLoadDiagnosticsUseLayerObjectName() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.missingTextureScene()
        defer { fixture.cleanup() }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        await #expect(throws: (any Error).self) {
            try await renderer.load()
        }

        let diagnostic = try #require(renderer.loadDiagnostics)
        #expect(diagnostic.errorDescription.contains("Hero Layer"))
        #expect(!diagnostic.errorDescription.lowercased().contains("texture"))
        #expect(!diagnostic.errorDescription.lowercased().contains("shader"))
    }

    @Test("A failed load tears its partial scene down instead of stranding it")
    func failedLoadRetiresPartialScene() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.missingTextureScene()
        defer { fixture.cleanup() }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        await #expect(throws: (any Error).self) {
            try await renderer.load()
        }

        // Only these two: this scene throws before `particleSystems` or
        // `outputTexture` are ever set, so asserting those would pass either way.
        #expect(renderer.renderGraph == nil)
        #expect(renderer.renderPipeline == nil)
        // Diagnostics must be produced before the teardown, which resets the
        // tracer and drops the snapshot: reordering would blank every failure message.
        #expect(renderer.loadDiagnostics != nil)
    }

    @Test("Texture candidate generator treats dotted basenames as extension-less")
    func textureCandidatesHandlesDottedBasenames() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        let dotted = renderer.textureCandidates(
            for: "anime-girl-sleeping-saber-fate-grand-order-4k-wallpaper-uhdpaper.com-600@5@f"
        )
        #expect(
            dotted.contains("materials/anime-girl-sleeping-saber-fate-grand-order-4k-wallpaper-uhdpaper.com-600@5@f.png"),
            "Dotted basename must still try the materials/.png fallback"
        )
        #expect(
            dotted.contains("materials/anime-girl-sleeping-saber-fate-grand-order-4k-wallpaper-uhdpaper.com-600@5@f.tex")
        )

        let underscored = renderer.textureCandidates(for: "91VDetfVuOL._UF1000,1000_QL80_DpWeblab_")
        #expect(underscored.contains("materials/91VDetfVuOL._UF1000,1000_QL80_DpWeblab_.png"))
        #expect(underscored.contains("materials/91VDetfVuOL._UF1000,1000_QL80_DpWeblab_.tex"))

        let generated = renderer.textureCandidates(
            for: "__yuuki_shibou_yuugi_de_meshi_wo_kuu_drawn_by_nekometaru__ae12f81d42ef9a8b610029375bac6b70"
        )
        #expect(generated.contains("materials/__yuuki_shibou_yuugi_de_meshi_wo_kuu_drawn_by_nekometaru__ae12f81d42ef9a8b610029375bac6b70.tex"))
        #expect(generated.contains("__yuuki_shibou_yuugi_de_meshi_wo_kuu_drawn_by_nekometaru__ae12f81d42ef9a8b610029375bac6b70"))

        #expect(
            renderer.textureCandidates(for: "logo.png")
                == ["logo.png", "logo.png.tex", "materials/logo.png", "materials/logo.png.tex"]
        )
        #expect(renderer.textureCandidates(for: "atlas.tex") == ["atlas.tex"])

        let bare = renderer.textureCandidates(for: "halo")
        #expect(bare.contains("materials/halo.tex"))
        #expect(bare.contains("materials/halo.png"))
        #expect(bare.contains("halo"))

        #expect(
            renderer.textureCandidates(for: "models/陨石/saturn2_A_diffuse").first
                == "materials/models/陨石/saturn2_A_diffuse.tex",
            "A model-relative material texture must try its converted materials/ mirror"
        )
    }

    @Test("Default preferredFramesPerSecond is 30 (WPE-compatible)")
    func defaultPreferredFPSIsThirty() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        let mtkView = try #require(renderer.nsView as? MTKView)
        #expect(mtkView.preferredFramesPerSecond == 30)
        #expect(WPEMetalSceneRenderer.defaultPreferredFPS == 30)
    }

    @Test("setFrameRateLimit re-targets the MTKView's preferredFramesPerSecond")
    func setFrameRateLimitRetargetsMTKView() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        let mtkView = try #require(renderer.nsView as? MTKView)

        renderer.setFrameRateCeiling(60)
        #expect(mtkView.preferredFramesPerSecond == 60)

        renderer.setFrameRateCeiling(15)
        #expect(mtkView.preferredFramesPerSecond == 15)

        renderer.setFrameRateCeiling(0)
        #expect(mtkView.preferredFramesPerSecond == 1)
    }

    @Test("setAudioMuted before load is no-op on the renderer (no crash) and seeds runtime state")
    func setAudioMutedBeforeLoadIsSafe() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        renderer.setAudioMuted(true)
        renderer.setAudioVolume(0.4)
        #expect(renderer.pendingAudioMuted == true)
        #expect(renderer.pendingAudioVolume == 0.4)

        renderer.setAudioMuted(true)
        renderer.setAudioVolume(0.4)
        #expect(renderer.pendingAudioMuted == true)
        #expect(renderer.pendingAudioVolume == 0.4)

        renderer.setAudioMuted(false)
        #expect(renderer.pendingAudioMuted == false)
        #expect(renderer.pendingAudioVolume == 0.4)
    }

    @Test("Audio startup is deferred until the first present, not started during load")
    func audioStartupIsDeferredUntilPresent() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.soundScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )

        try await renderer.load()

        #expect(renderer.debugSoundRuntimeActive == false)
        #expect(renderer.debugAudioStartupPending == true)

        renderer.cleanup()
        #expect(renderer.debugAudioStartupPending == false)
    }

    @Test("A shader-only g_AudioSpectrum scene demands system audio capture")
    func shaderOnlyAudioSpectrumSceneDemandsCapture() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.audioSpectrumEffectScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        defer { renderer.cleanup() }

        try await renderer.load()

        #expect(renderer.sceneSupportsAudioProcessing == true)
    }

    @Test("An audio-free scene keeps the capture demand off")
    func audioFreeSceneKeepsCaptureDemandOff() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        defer { renderer.cleanup() }

        try await renderer.load()

        #expect(renderer.sceneSupportsAudioProcessing == false)
    }

    @Test("A scene whose only audio consumer is a particle emitter demands capture")
    func audioResponsiveParticleSceneDemandsCapture() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.audioResponsiveParticleScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        defer { renderer.cleanup() }

        try await renderer.load()

        #expect(renderer.particleSystems.count == 1,
                "fixture emitter must register — a skipped system would fake the flag result")
        #expect(renderer.sceneSupportsAudioProcessing == true)
    }

    @Test("A particle emitter without audio fields keeps the capture demand off")
    func mutedParticleSceneKeepsCaptureDemandOff() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.audioResponsiveParticleScene(audioFields: false)
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        defer { renderer.cleanup() }

        try await renderer.load()

        #expect(renderer.particleSystems.count == 1)
        #expect(renderer.sceneSupportsAudioProcessing == false)
    }

    @Test("Fragment g_AudioSpectrum without an AUDIOPROCESSING combo requires capture")
    func audioCapturePredicateFragmentMentionNoCombo() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: "uniform float g_AudioSpectrum32Left[32];\nvoid main() {}"
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == true)
    }

    @Test("Vertex g_AudioSpectrum without an AUDIOPROCESSING combo requires capture")
    func audioCapturePredicateVertexMentionNoCombo() {
        let pipeline = Self.audioPredicatePipeline(
            vertexSource: "uniform float g_AudioSpectrum16Left[16];\nvoid main() {}"
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == true)
    }

    @Test("AUDIOPROCESSING == 0 compiles the audio branch out — no capture")
    func audioCapturePredicateComboZeroDisables() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: "#if AUDIOPROCESSING\nuniform float g_AudioSpectrum32Left[32];\n#endif\nvoid main() {}",
            comboValues: ["AUDIOPROCESSING": 0]
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == false)
    }

    @Test("A lowercase audioprocessing combo > 0 still requires capture")
    func audioCapturePredicateLowercaseComboEnabled() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: "uniform float g_AudioSpectrum32Left[32];\nvoid main() {}",
            comboValues: ["audioprocessing": 2]
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == true)
    }

    @Test("AUDIOPROCESSING == 0 does not veto a read outside the guard")
    func audioCapturePredicateComboZeroUnguardedReadStillCaptures() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: """
            // [COMBO] {"combo":"AUDIOPROCESSING","default":0}
            uniform float g_AudioSpectrum32Left[32];
            void main() { gl_FragColor = vec4(g_AudioSpectrum32Left[0]); }
            """,
            comboValues: ["AUDIOPROCESSING": 0]
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == true)
    }

    @Test("The #else arm of an audio guard is live when the combo is 0")
    func audioCapturePredicateElseBranchLiveAtComboZero() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: """
            #if AUDIOPROCESSING
            void main() { gl_FragColor = vec4(1.0); }
            #else
            uniform float g_AudioSpectrum32Left[32];
            void main() { gl_FragColor = vec4(g_AudioSpectrum32Left[0]); }
            #endif
            """,
            comboValues: ["AUDIOPROCESSING": 0]
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == true)
    }

    @Test("A lowercase g_audiospectrum spelling still requires capture")
    func audioCapturePredicateLowercaseSpectrumSpelling() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: "uniform float g_audiospectrum32left[32];\nvoid main() {}"
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == true)
    }

    @Test("#ifdef AUDIOPROCESSING is live at combo 0 — the macro is always defined")
    func audioCapturePredicateIfdefIsLiveAtComboZero() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: """
            #ifdef AUDIOPROCESSING
            uniform float g_AudioSpectrum32Left[32];
            void main() { gl_FragColor = vec4(g_AudioSpectrum32Left[0]); }
            #endif
            """,
            comboValues: ["AUDIOPROCESSING": 0]
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == true)
    }

    @Test("A comment naming AUDIOPROCESSING in a foreign #if is not a guard")
    func audioCapturePredicateCommentInForeignConditionIsNotAGuard() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: """
            #if FOO /* AUDIOPROCESSING */
            uniform float g_AudioSpectrum32Left[32];
            void main() { gl_FragColor = vec4(g_AudioSpectrum32Left[0]); }
            #endif
            """,
            comboValues: ["AUDIOPROCESSING": 0]
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == true)
    }

    @Test("Whitespace after # does not unbalance the guard walk")
    func audioCapturePredicateWhitespaceEndifKeepsLaterReadLive() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: """
            #if AUDIOPROCESSING
            uniform float unused;
            # endif
            uniform float g_AudioSpectrum32Left[32];
            void main() { gl_FragColor = vec4(g_AudioSpectrum32Left[0]); }
            """,
            comboValues: ["AUDIOPROCESSING": 0]
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == true)
    }

    @Test("A builtin pass without shader source never requires capture")
    func audioCapturePredicateNilShader() {
        let pipeline = Self.audioPredicatePipeline(shader: nil)
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == false)
    }

    @Test("An audio-free shader never requires capture")
    func audioCapturePredicateNoAudioAnywhere() {
        let pipeline = Self.audioPredicatePipeline(
            fragmentSource: "uniform float g_Time;\nvoid main() {}"
        )
        #expect(WPEMetalSceneRenderer.pipelineRequiresAudioCapture(pipeline) == false)
    }

    private static func audioPredicatePipeline(
        vertexSource: String = "void main() {}",
        fragmentSource: String = "void main() {}",
        comboValues: [String: Int] = [:]
    ) -> WPEPreparedRenderPipeline {
        audioPredicatePipeline(
            shader: WPEShaderProgram(
                name: "effects/probe",
                vertexSource: vertexSource,
                fragmentSource: fragmentSource,
                isBuiltin: false
            ),
            comboValues: comboValues
        )
    }

    private static func audioPredicatePipeline(
        shader: WPEShaderProgram?,
        comboValues: [String: Int] = [:]
    ) -> WPEPreparedRenderPipeline {
        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/probe/effect.json"),
            shader: "effects/probe",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: shader,
            textureBindings: [:],
            comboValues: comboValues,
            uniformValues: [:]
        )
        let layer = WPERenderLayer(
            objectID: "1",
            objectName: "Probe",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: .identity,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass]
        )
        return WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [prepared])
        ])
    }

    private static func sceneDebugLog(for workshopID: String, containing marker: String) async throws -> String {
        let root = try #require(WPESceneDebugArtifacts.rootURL)
        let fm = FileManager.default
        for _ in 0..<100 {
            let folders = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for folder in folders where folder.lastPathComponent.contains(workshopID) {
                let logURL = folder.appendingPathComponent("scene.log")
                guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { continue }
                if log.contains(marker) {
                    return log
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    /// `space.pointer` snaps to centre off-scene for parallax; the shader pair must not.
    /// cursorripple reads `g_PointerPosition − g_PointerPositionLast` per frame — a teleport
    /// fakes a huge delta and paints an edge→centre force streak on every exit/re-entry.
    @Test("An off-scene pointer holds the last live position for shader delta consumers")
    func offScenePointerHoldsLastLivePosition() throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        renderer.sceneRenderSize = CGSize(width: 64, height: 64)

        func context(_ sample: WPEMetalPointerSample) -> WPEMetalRuntimeUniforms {
            renderer.sampleFrameContext(inputs: WPEFrameInputs(
                clickCaptureEnabled: false, pointerSample: sample,
                pointerFrame: .neutral, preferredFramesPerSecond: 60
            )).uniforms
        }

        let live = context(.inside(SIMD2(0.2, 0.5)))
        #expect(live.pointerPosition == SIMD2(0.2, 0.5))
        let moved = context(.inside(SIMD2(0.6, 0.5)))
        #expect(moved.pointerPosition == SIMD2(0.6, 0.5))
        #expect(moved.pointerPositionLast == SIMD2(0.2, 0.5))

        let off = context(.inactive)
        #expect(off.pointerPosition == SIMD2(0.6, 0.5))
        #expect(off.pointerPositionLast == SIMD2(0.6, 0.5))

        let back = context(.inside(SIMD2(0.1, 0.9)))
        #expect(back.pointerPosition == SIMD2(0.1, 0.9))
        #expect(back.pointerPositionLast == SIMD2(0.1, 0.9))
    }

    @Test("An oracle frame override keeps its pointer while the live pointer is off-scene")
    func oraclePointerIsNotReplacedByHeldPointer() throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        WPEOracleMode.testingOverride = true
        let renderer: WPEMetalSceneRenderer
        do {
            defer { WPEOracleMode.testingOverride = nil }
            renderer = try WPEMetalSceneRenderer(
                descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
                frame: CGRect(x: 0, y: 0, width: 64, height: 64),
                device: #require(MTLCreateSystemDefaultDevice())
            )
        }
        defer { renderer.cleanup() }
        renderer.sceneRenderSize = CGSize(width: 64, height: 64)
        let oraclePointer = try #require(renderer.oracleFrameOverride).pointer
        renderer.previousPointer = SIMD2(0.9, 0.1)
        try #require(oraclePointer != renderer.previousPointer)

        let context = renderer.sampleFrameContext(inputs: WPEFrameInputs(
            clickCaptureEnabled: false, pointerSample: .inactive,
            pointerFrame: .neutral, preferredFramesPerSecond: 60
        ))

        #expect(context.pointer == oraclePointer)
        #expect(context.uniforms.pointerPosition == oraclePointer)
        #expect(context.uniforms.pointerPositionLast == oraclePointer)
    }

    @Test("A non-.tex texture path's payload probe does not mask the converted file's decode error")
    func payloadProbeDoesNotMaskTextureDecodeError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data(#"{ "material": "materials/hero.json" }"#.utf8)
            .write(to: root.appendingPathComponent("models/hero.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/foo.variant"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("hero.json"))
        try Data("TEXV0005\0TEXI0001\0corrupt".utf8).write(to: materials.appendingPathComponent("foo.variant.tex"))
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{ "id": "hero", "name": "Hero Layer", "type": "image", "image": "models/hero.json",
                        "origin": "0.5 0.5 0", "scale": "1 1 1", "alpha": 1 }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        let renderer = try WPEMetalSceneRenderer(
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString, cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json", capabilityTier: .imageOnly
            ),
            cacheRootURL: root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }

        await #expect(throws: (any Error).self) {
            try await renderer.load()
        }

        let diagnostic = try #require(renderer.loadDiagnostics)
        guard case .texture = diagnostic else {
            Issue.record("Expected the .tex decode failure, got \(diagnostic)")
            return
        }
    }
}

@MainActor
private struct StaticPresentRetryFixture {
    let fixture: MetalSceneFixture
    let renderer: WPEMetalSceneRenderer
    let window: NSWindow

    static func make() async throws -> Self {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        do {
            let renderer = try WPEMetalSceneRenderer(
                descriptor: fixture.descriptor,
                cacheRootURL: fixture.root,
                dependencyMounts: [],
                frame: CGRect(x: 0, y: 0, width: 64, height: 64),
                device: device
            )
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 64, height: 64),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = renderer.nsView
            window.parkOffScreen()
            if let layer = renderer.nsView.layer as? CAMetalLayer {
                let size = renderer.nsView.convertToBacking(renderer.nsView.bounds).size
                if size.width > 0, size.height > 0 {
                    layer.drawableSize = size
                }
            }
            try await renderer.load()
            return Self(fixture: fixture, renderer: renderer, window: window)
        } catch {
            fixture.cleanup()
            throw error
        }
    }

    func cleanup() {
        renderer.cleanup()
        window.close()
        fixture.cleanup()
    }
}

@MainActor
private final class RecordingSystemAudioCaptureDemand: SystemAudioCaptureDemandControlling {
    private(set) var consumerCount = 0
    private(set) var retainCount = 0
    private(set) var releaseCount = 0

    func retain() {
        retainCount += 1
        consumerCount += 1
    }

    func release() {
        releaseCount += 1
        consumerCount = max(0, consumerCount - 1)
    }
}

struct MetalSceneFixture {
    let root: URL
    let descriptor: SceneDescriptor
    var dependencyRoot: URL?

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        if let dependencyRoot {
            try? FileManager.default.removeItem(at: dependencyRoot)
        }
    }

    static func solidColorScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "solid",
            "name": "Solid",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "color": "1 0 0",
            "alpha": 1
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func cursorOriginScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "cursor",
            "name": "Cursor Flower",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "color": "0 0 1",
            "alpha": 1,
            "origin": {
              "value": "10 10 0",
              "script": "'use strict';\\nexport function update(value) {\\n  value.x = input.cursorWorldPosition.x;\\n  value.y = input.cursorWorldPosition.y;\\n  return value;\\n}"
            }
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func groupHostParallaxScene(hostOriginScript: String?) throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hostOrigin = hostOriginScript.map { #"{ "value": "32 32 0", "script": "\#($0)" }"# } ?? #""32 32 0""#
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "host",
            "name": "Host",
            "type": "group",
            "origin": \(hostOrigin)
          }, {
            "id": "child",
            "name": "Child",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "parent": "host",
            "color": "1 0 0",
            "alpha": 1,
            "origin": "0 0 0",
            "size": "8 8 0"
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func materialTextureScene(color: CGColor) throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try writePNG(at: materials.appendingPathComponent("base.png"), color: color)
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: models.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/base.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        try writeScene(imagePath: "models/base.json", to: root)
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func sceneScriptVisualizerScene(angleDegrees: Double = 0, workshopShader: Bool = false) throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEVisualizer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models/workshop/12345", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        // This fixture asserts channel values, so both the source color and PNG
        // drawing space must be sRGB rather than device-dependent RGB.
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let red = try #require(CGColor(colorSpace: sRGB, components: [1, 0, 0, 1]))
        try writePNG(at: materials.appendingPathComponent("bar.png"), color: red, colorSpace: sRGB)
        try Data(#"{"material":"materials/bar.json"}"#.utf8).write(to: models.appendingPathComponent("bar.json"))
        try Data(#"{"passes":[{"shader":"genericimage2","textures":["materials/bar.png"]}]}"#.utf8)
            .write(to: materials.appendingPathComponent("bar.json"))
        if workshopShader {
            let shaders = root.appendingPathComponent("shaders/workshop/12345", isDirectory: true)
            try FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: true)
            // Authored here for this regression: equivalent model/material/shader
            // shape to the real bar, without Workshop artwork or source copying.
            let vertex = """
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() { v_TexCoord = a_TexCoord; gl_Position = vec4(a_Position, 1.0); }
            """
            let fragment = """
            uniform sampler2D g_Texture0;
            uniform float g_UserAlpha; // {"material":"Alpha","default":1}
            uniform vec3 g_TintColor; // {"material":"color","default":"1 1 1"}
            varying vec2 v_TexCoord;
            void main() {
                gl_FragColor = texture2D(g_Texture0, v_TexCoord) * vec4(g_TintColor, g_UserAlpha);
            }
            """
            try Data(vertex.utf8).write(to: shaders.appendingPathComponent("tint.vert"))
            try Data(fragment.utf8).write(to: shaders.appendingPathComponent("tint.frag"))
            try Data(#"{"autosize":true,"material":"materials/bar.json"}"#.utf8)
                .write(to: models.appendingPathComponent("bar.json"))
            try Data(#"{"passes":[{"shader":"workshop/12345/tint","textures":["materials/bar.png"],"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","constantshadervalues":{"Alpha":0.5,"color":"1 1 1"}}]}"#.utf8)
                .write(to: materials.appendingPathComponent("bar.json"))
        }
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64, "auto": true]],
            "objects": [[
                "id": "bar", "name": "MAIN", "image": WPEVisualizerScriptFixture.imagePath,
                "origin": "4 4 0", "size": "8 8", "scale": "1 1 1", "parallaxDepth": "0.2 0.2",
                "visible": ["value": true, "script": WPEVisualizerScriptFixture.script.replacingOccurrences(
                    of: "bars[i].angles = new Vec3(0, 0, 0)",
                    with: "bars[i].angles = new Vec3(0, 0, \(angleDegrees))"
                )],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: scene).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(root: root, descriptor: SceneDescriptor(
            workshopID: UUID().uuidString, cacheRelativePath: "wpe-cache/test",
            entryFile: "scene.json", capabilityTier: .imageOnly
        ), dependencyRoot: nil)
    }

    static func sceneScriptCreatedLayerScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try writePNG(at: materials.appendingPathComponent("base.png"), color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: models.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/base.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        let script = """
        export function init() {
            thisScene.createLayer({
                image: "models/base.json",
                origin: new Vec3(32, 32, 0),
                color: new Vec3(1, 1, 1),
                alpha: 1,
                scale: new Vec3(1, 1, 1),
                visible: true
            });
        }
        export function update() {}
        """
        let escapedScript = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [
            {
              "id": "template",
              "name": "Template",
              "type": "image",
              "image": "models/base.json",
              "origin": "1000 1000 0",
              "scale": "1 1 1",
              "visible": false,
              "alpha": 1
            },
            {
              "id": "host",
              "name": "MAIN",
              "solid": true,
              "visible": {
                "value": true,
                "script": "\(escapedScript)"
              }
            }
          ]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func anglesScriptScene(anglesValue: String, anglesScript: String) throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try writePNG(at: materials.appendingPathComponent("base.png"), color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: models.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/base.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        let escapedScript = anglesScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "bar",
            "name": "Bar",
            "type": "image",
            "image": "models/base.json",
            "origin": "32 32 0",
            "size": "48 10",
            "scale": "1 1 1",
            "alpha": 1,
            "angles": {
              "value": "\(anglesValue)",
              "script": "\(escapedScript)"
            }
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func hiddenComputeTextScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let computeScript = "'use strict';\\nexport function update(value) { shared.answer = 42; return value; }"
        let readerScript = "'use strict';\\nexport function update(value) { return String(shared.answer); }"
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [
            {
              "id": "backdrop", "name": "Backdrop", "type": "image",
              "image": "models/util/solidlayer.json",
              "color": "0 0 1", "alpha": 1
            },
            {
              "id": "compute", "name": "日志", "type": "text",
              "font": "systemfont_arial", "visible": false,
              "origin": "32 32 0",
              "text": { "value": "log", "script": "\(computeScript)" }
            },
            {
              "id": "reader", "name": "readout", "type": "text",
              "font": "systemfont_arial", "visible": true,
              "origin": "32 32 0",
              "text": { "value": "0", "script": "\(readerScript)" }
            }
          ]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    /// Image layer "B" plus text layers "TA" (value script running `initBody` in init) and "TB"; no other scripts.
    static func textScriptCrossLayerScene(initBody: String) throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = "'use strict';\\nexport function init() { \(initBody) }\\nexport function update(value) { return value; }"
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [
            {
              "id": "b", "name": "B", "type": "image",
              "image": "models/util/solidlayer.json",
              "color": "1 0 0", "alpha": 1
            },
            {
              "id": "ta", "name": "TA", "type": "text",
              "font": "systemfont_arial", "visible": true,
              "origin": "32 32 0",
              "text": { "value": "A", "script": "\(script)" }
            },
            {
              "id": "tb", "name": "TB", "type": "text",
              "font": "systemfont_arial", "visible": true,
              "origin": "32 32 0",
              "text": "B"
            }
          ]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func missingTextureScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data(#"{ "material": "materials/missing-material.json" }"#.utf8)
            .write(to: models.appendingPathComponent("hero.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/missing.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("missing-material.json"))
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "hero",
            "name": "Hero Layer",
            "type": "image",
            "image": "models/hero.json",
            "origin": "0.5 0.5 0",
            "scale": "1 1 1",
            "alpha": 1
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func dependencyTextureScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["../123/materials/dep.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: root.appendingPathComponent("model.json"))
        try writeScene(imagePath: "model.json", to: root)

        let dependencyRoot = root.deletingLastPathComponent()
            .appendingPathComponent("WPEMetalSceneDependency-\(UUID().uuidString)", isDirectory: true)
        let dependencyMaterials = dependencyRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencyMaterials, withIntermediateDirectories: true)
        try writePNG(at: dependencyMaterials.appendingPathComponent("dep.png"), color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: dependencyRoot
        )
    }

    static func soundScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try writePNG(at: materials.appendingPathComponent("base.png"), color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: models.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/base.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [
            { "id": "img", "name": "Img", "type": "image", "image": "models/base.json", "origin": "0.5 0.5 0", "scale": "1 1 1", "alpha": 1 },
            { "id": "snd", "name": "Loop", "type": "sound", "sound": ["sounds/loop.mp3"] }
          ]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func audioSpectrumEffectScene() throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        let effectMaterials = root.appendingPathComponent("materials/effects", isDirectory: true)
        let effects = root.appendingPathComponent("effects/audioprobe", isDirectory: true)
        let shaders = root.appendingPathComponent("shaders/effects", isDirectory: true)
        for directory in [models, materials, effectMaterials, effects, shaders] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writePNG(at: materials.appendingPathComponent("base.png"), color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: models.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/base.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "material": "materials/effects/audioprobe.json" }] }"#.utf8)
            .write(to: effects.appendingPathComponent("effect.json"))
        try Data(#"{ "passes": [{ "shader": "effects/audioprobe" }] }"#.utf8)
            .write(to: effectMaterials.appendingPathComponent("audioprobe.json"))
        let vertex = """
        attribute vec3 a_Position;
        void main() { gl_Position = vec4(a_Position, 1.0); }
        """
        try Data(vertex.utf8).write(to: shaders.appendingPathComponent("audioprobe.vert"))
        let fragment = """
        uniform float g_AudioSpectrum32Left[32];
        void main() { gl_FragColor = vec4(g_AudioSpectrum32Left[0]); }
        """
        try Data(fragment.utf8).write(to: shaders.appendingPathComponent("audioprobe.frag"))
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "img",
            "name": "Img",
            "type": "image",
            "image": "models/base.json",
            "origin": "0.5 0.5 0",
            "scale": "1 1 1",
            "alpha": 1,
            "effects": [{ "id": 1, "name": "AudioProbe", "file": "effects/audioprobe/effect.json", "visible": true }]
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    static func audioResponsiveParticleScene(audioFields: Bool = true) throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalSceneRenderer-\(UUID().uuidString)", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        let particles = root.appendingPathComponent("particles", isDirectory: true)
        for directory in [materials, particles] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writePNG(at: materials.appendingPathComponent("spark.png"), color: CGColor(red: 1, green: 1, blue: 0, alpha: 1))
        try Data(#"{ "passes": [{ "shader": "genericparticle", "textures": ["materials/spark.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("spark.json"))
        let audioKeys = audioFields
            ? #""audioprocessingmode": 1, "audioprocessingfrequencystart": 0, "audioprocessingfrequencyend": 15, "audioamount": 2,"#
            : ""
        let particle = """
        {
          "material": "materials/spark.json",
          "maxcount": 20,
          "emitter": [{
            "name": "sphererandom",
            \(audioKeys)
            "rate": 10,
            "origin": "0 0 0"
          }],
          "initializer": [{ "name": "lifetimerandom", "min": 1, "max": 1 }]
        }
        """
        try Data(particle.utf8).write(to: particles.appendingPathComponent("audio.json"))
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "solid",
            "name": "Solid",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "color": "1 0 0",
            "alpha": 1
          }, {
            "id": "pfx",
            "name": "Audio Particles",
            "particle": "particles/audio.json",
            "origin": "0.5 0.5 0",
            "visible": true
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    private static func writeScene(imagePath: String, to root: URL) throws {
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "image",
            "name": "Image",
            "type": "image",
            "image": "\(imagePath)",
            "origin": "32 32 0",
            "scale": "1 1 1",
            "alpha": 1
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
    }

    private static func writePNG(at url: URL, color: CGColor, colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()) throws {
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "fixture", code: -1)
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw NSError(domain: "fixture", code: -2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "fixture", code: -3)
        }
    }
}

private final class WPEReadinessResultRecorder: @unchecked Sendable { // `lock` protects callback-thread access.
    private let lock = NSLock()
    private var storage: WPEFrameReadinessResult?

    var value: WPEFrameReadinessResult? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ result: WPEFrameReadinessResult) {
        lock.lock()
        storage = result
        lock.unlock()
    }
}

private final class WPEPresentReleaseRecorder: @unchecked Sendable { // `lock` protects the count and held callback.
    private let lock = NSLock()
    private var count = 0
    private var held: (@Sendable () -> Void)?

    var releaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordRelease() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func hold(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        held = callback
        lock.unlock()
    }

    func releaseHeld() {
        lock.lock()
        let callback = held
        lock.unlock()
        callback?()
    }
}

private struct MetalPixel {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
}

private extension MTLTexture {
    /// One coherent GPU readback for the whole fixture, rather than a new blit
    /// and command-buffer wait for each of the 4,096 pixels.
    func readAllPixels() -> [MetalPixel]? {
        guard [.rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb].contains(pixelFormat),
              let staged = WPEMetalTextureSnapshotter.stagedForCPURead(self) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        staged.getBytes(&bytes, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let isBGRA = pixelFormat == .bgra8Unorm || pixelFormat == .bgra8Unorm_srgb
        return stride(from: 0, to: bytes.count, by: 4).map {
            MetalPixel(r: bytes[$0 + (isBGRA ? 2 : 0)], g: bytes[$0 + 1],
                       b: bytes[$0 + (isBGRA ? 0 : 2)], a: bytes[$0 + 3])
        }
    }

    func readPixel(x: Int, y: Int) -> MetalPixel? {
        let supportedFormats: [MTLPixelFormat] = [.rgba8Unorm, .rgba8Unorm_srgb]
        guard supportedFormats.contains(pixelFormat),
              x >= 0, x < width,
              y >= 0, y < height else {
            return nil
        }
        // Renderer outputs are `.private`; stage into CPU-visible storage first.
        guard let staged = WPEMetalTextureSnapshotter.stagedForCPURead(self) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        staged.getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        let index = (y * width + x) * 4
        return MetalPixel(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2], a: bytes[index + 3])
    }
}

@Suite("WPEMetalTextureSnapshotter formats")
struct WPEMetalTextureSnapshotterFormatTests {
    private func makeTexture(format: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func pixel(of image: NSImage, x: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try #require(cg.dataProvider?.data as Data?)
        let index = x * 4
        return (data[index], data[index + 1], data[index + 2], data[index + 3])
    }

    @Test("BGRA8 sources are swizzled to RGBA")
    func bgraSwizzle() throws {
        let texture = try makeTexture(format: .bgra8Unorm, width: 1, height: 1)
        var bytes: [UInt8] = [10, 20, 30, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
        let image = try #require(WPEMetalTextureSnapshotter.shared.snapshot(from: texture))
        let px = try pixel(of: image, x: 0)
        #expect(px.r == 30 && px.g == 20 && px.b == 10 && px.a == 255)
    }

    @Test("RGBA16Float authored HDR posters apply the measured terminal transfer")
    func rgba16FloatConverts() throws {
        let texture = try makeTexture(format: .rgba16Float, width: 2, height: 1)
        var halves: [UInt16] = [
            0x4000, 0x3C00, 0x0000, 0x3C00,
            0x3800, 0x3800, 0x3800, 0x3C00
        ]
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: &halves, bytesPerRow: 16)
        let image = try #require(WPEMetalTextureSnapshotter.shared.snapshot(from: texture))
        let hot = try pixel(of: image, x: 0)
        #expect(hot.r == 255 && hot.g == 255 && hot.b == 0 && hot.a == 255)
        let mid = try pixel(of: image, x: 1)
        #expect(abs(Int(mid.r) - 210) <= 2 && abs(Int(mid.g) - 210) <= 2 && abs(Int(mid.b) - 210) <= 2)
    }
}

@Suite("WPE hover hit rect")
struct WPEHoverHitRectTests {
    private func geometry(
        origin: SIMD3<Double>,
        size: CGSize,
        scale: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        alignment: WPESceneAlignment = .center
    ) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: origin,
            scale: scale,
            angles: SIMD3<Double>(0, 0, 0),
            alignment: alignment,
            size: size,
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
    }

    @Test("Orthographic hover centre converts the authored Y-up origin to pointer space")
    func orthographicHoverCentreConvertsAuthoredYUpOrigin() throws {
        let scene = CGSize(width: 3840, height: 2160)
        // Authored near the TOP of the canvas in Y-up terms.
        let rect = try #require(WPEMetalSceneRenderer.hoverHitRect(
            geometry: geometry(origin: SIMD3<Double>(2061, 1900, 0), size: CGSize(width: 427, height: 113)),
            sceneSize: scene,
            projection: nil
        ))
        // Y-down pointer space: 2160 - 1900 = 260, i.e. still near the top.
        #expect(rect.center == SIMD2<Double>(2061, 260))
        #expect(rect.half.x == 213.5)

        let low = try #require(WPEMetalSceneRenderer.hoverHitRect(
            geometry: geometry(origin: SIMD3<Double>(100, 200, 0), size: CGSize(width: 427, height: 113)),
            sceneSize: scene,
            projection: nil
        ))
        #expect(low.center.y == 1960)
    }

    @Test("Perspective hover centre keeps its existing conversion")
    func perspectiveHoverCentreKeepsExistingConversion() throws {
        let scene = CGSize(width: 3840, height: 2160)
        let rect = try #require(WPEMetalSceneRenderer.hoverHitRect(
            geometry: geometry(origin: SIMD3<Double>(0, 0, 0), size: CGSize(width: 400, height: 400)),
            sceneSize: scene,
            projection: (center: SIMD2<Double>(120, 300), depthScale: 0.5)
        ))
        #expect(rect.center == SIMD2<Double>(1920 + 120, 1080 - 300))
        #expect(rect.half == SIMD2<Double>(100, 100))
    }

    @Test("Hover half-extent keeps its reachability floor")
    func hoverHalfExtentKeepsReachabilityFloor() throws {
        let scene = CGSize(width: 3840, height: 2160)
        let rect = try #require(WPEMetalSceneRenderer.hoverHitRect(
            geometry: geometry(origin: SIMD3<Double>(500, 500, 0), size: CGSize(width: 4, height: 4)),
            sceneSize: scene,
            projection: nil
        ))
        #expect(rect.half == SIMD2<Double>(43.2, 43.2))
    }

    private func hits(
        _ alignment: WPESceneAlignment,
        _ point: SIMD2<Double>,
        projection: (center: SIMD2<Double>, depthScale: Double)? = nil
    ) throws -> Bool {
        let rect = try #require(WPEMetalSceneRenderer.hoverHitRect(
            geometry: geometry(
                origin: SIMD3<Double>(500, 500, 0),
                size: CGSize(width: 100, height: 100),
                alignment: alignment
            ),
            sceneSize: CGSize(width: 1000, height: 1000),
            projection: projection
        ))
        return abs(point.x - rect.center.x) <= rect.half.x && abs(point.y - rect.center.y) <= rect.half.y
    }

    @Test("Top-left aligned hit box covers the drawn quad, not the area around its origin")
    func topLeftAlignedHitBoxCoversDrawnQuad() throws {
        // Drawn quad spans x 500...600 and, Y-down, y 500...600.
        #expect(try hits(.topLeft, SIMD2<Double>(575, 575)))
        #expect(try !hits(.topLeft, SIMD2<Double>(475, 475)))
        #expect(try hits(.left, SIMD2<Double>(575, 500)))
        #expect(try !hits(.left, SIMD2<Double>(475, 500)))
    }

    @Test("Centre aligned hit box stays centred on the origin")
    func centreAlignedHitBoxStaysOnOrigin() throws {
        #expect(try !hits(.center, SIMD2<Double>(575, 575)))
        #expect(try hits(.center, SIMD2<Double>(475, 475)))
    }

    @Test("Perspective hit box applies the alignment offset at the projected size")
    func perspectiveHitBoxAppliesAlignmentOffset() throws {
        // Projected centre (0, 0) is scene pixel (500, 500); depth 0.5 draws a 50x50 quad spanning 500...550.
        let projection = (center: SIMD2<Double>(0, 0), depthScale: 0.5)
        #expect(try hits(.topLeft, SIMD2<Double>(540, 540), projection: projection))
        #expect(try !hits(.topLeft, SIMD2<Double>(480, 480), projection: projection))
    }
}

@Suite("WPE particle host origin delta")
struct WPEParticleHostOriginDeltaTests {
    /// The delta rides `projection.padding`, the same Y-up channel as the parallax
    /// offset; both inputs are Y-up, so Y is not negated.
    @Test("Host moving up moves its particles up")
    func hostMovingUpMovesParticlesUp() {
        let delta = WPEMetalSceneRenderer.particleHostOriginDelta(
            now: SIMD3<Double>(100, 700, 0),
            seed: SIMD3<Double>(100, 500, 0)
        )
        #expect(delta == SIMD2<Float>(0, 200))
    }

    @Test("Host moving down moves its particles down")
    func hostMovingDownMovesParticlesDown() {
        let delta = WPEMetalSceneRenderer.particleHostOriginDelta(
            now: SIMD3<Double>(100, 300, 0),
            seed: SIMD3<Double>(100, 500, 0)
        )
        #expect(delta == SIMD2<Float>(0, -200))
    }

    @Test("Horizontal delta passes through unchanged")
    func horizontalDeltaPassesThroughUnchanged() {
        let delta = WPEMetalSceneRenderer.particleHostOriginDelta(
            now: SIMD3<Double>(340, 500, 0),
            seed: SIMD3<Double>(100, 500, 0)
        )
        #expect(delta == SIMD2<Float>(240, 0))
    }
}

extension WPEMetalSceneRendererTests {
    @Test("A parsed directional light illuminates generic4 with zero ambient and skylight")
    func directionalLightIlluminatesZeroAmbientModel() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func sample(lightingEnabled: Bool) async throws -> [Float] {
            let fixture = try MetalSceneFixture.directionalModelScene(lightingEnabled: lightingEnabled)
            defer { fixture.cleanup() }
            let sceneData = try Data(contentsOf: fixture.root.appendingPathComponent("scene.json"))
            let parsed = try WPESceneDocumentParser.parse(data: sceneData)
            #expect(parsed.lightObjects.count == 1)
            #expect(parsed.lightObjects.first?.intensity == 5)
            #expect(parsed.general.lightAmbientColor == .zero)
            #expect(parsed.general.lightSkylightColor == .zero)
            let renderer = try WPEMetalSceneRenderer(
                descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
                frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
            )
            defer { renderer.cleanup() }
            try await renderer.load()
            let output = try #require(renderer.outputTexture)
            let staging = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
            let region = MTLRegionMake2D(output.width / 2, output.height / 2, 1, 1)
            let rgba: [Float]
            switch output.pixelFormat {
            case .rgba16Float:
                var pixel = [UInt16](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes {
                    staging.getBytes($0.baseAddress!, bytesPerRow: 8, from: region, mipmapLevel: 0)
                }
                rgba = pixel.map { Float(Float16(bitPattern: $0)) }
            case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb:
                var pixel = [UInt8](repeating: 0, count: 4)
                staging.getBytes(&pixel, bytesPerRow: 4, from: region, mipmapLevel: 0)
                if output.pixelFormat == .bgra8Unorm || output.pixelFormat == .bgra8Unorm_srgb {
                    pixel.swapAt(0, 2)
                }
                rgba = pixel.map { Float($0) / 255 }
            default:
                throw NSError(domain: "WPEDirectionalLightingFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Unsupported readback format \(output.pixelFormat)"])
            }
            return rgba
        }
        let control = try await sample(lightingEnabled: false)
        try #require(control[0] > 0.2 && control[1] > 0.2 && control[2] > 0.2,
                     "LIGHTING0 must prove the same model and texture cover this pixel, got \(control)")
        let rgba = try await sample(lightingEnabled: true)
        #expect(rgba[0] > 0.05 && rgba[1] > 0.05 && rgba[2] > 0.05,
                "zero ambient is intentional: generic4 must consume the parsed directional light, got \(rgba)")
    }
}

private extension MetalSceneFixture {
    static func directionalModelScene(lightingEnabled: Bool) throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEDirectionalModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        try writePNG(at: root.appendingPathComponent("materials/white.png"), color: CGColor(gray: 1, alpha: 1))
        let material: [String: Any] = ["passes": [["shader": "generic4", "textures": ["materials/white.png"],
                                                   "constantshadervalues": ["color": "0.5 0.5 0.5", "roughness": 1, "metallic": 0.14],
                                                   "combos": ["LIGHTING": lightingEnabled ? 1 : 0, "REFLECTION": 0], "blending": "disabled", "cullmode": "nocull",
                                                   "depthtest": "disabled", "depthwrite": "disabled"]]]
        try JSONSerialization.data(withJSONObject: material).write(to: root.appendingPathComponent("materials/lit.json"))
        var mdl = Data("MDLV0016".utf8)
        func u32(_ value: UInt32) {
            var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { mdl.append(contentsOf: $0) }
        }
        func f32(_ value: Float) {
            u32(value.bitPattern)
        }
        u32(0x0000_0F00); mdl.append(UInt8(0)); u32(1); u32(1)
        mdl.append(contentsOf: "materials/lit.json".utf8); mdl.append(UInt8(0))
        u32(0); u32(0x0000_000F); u32(4 * 12 * 4)
        // Native directional CB is a vector toward the light (DXBC dot(N,L)
        // uses it without negation). An unrotated light publishes world -X.
        // Give the plane a constant -X normal while retaining screen coverage.
        let vertices: [(Float, Float, Float, Float)] = [(-16, -16, 0, 1), (16, -16, 1, 1), (-16, 16, 0, 0), (16, 16, 1, 0)]
        for (x, y, u, v) in vertices {
            for value in [x, y, 0, -1, 0, 0, 0, 0, 1, 1, u, v] {
                f32(value)
            }
        }
        u32(6 * 2)
        for index: UInt16 in [0, 1, 2, 2, 1, 3] {
            var v = index.littleEndian; Swift.withUnsafeBytes(of: &v) { mdl.append(contentsOf: $0) }
        }
        try mdl.write(to: root.appendingPathComponent("models/lit.mdl"))
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64, "auto": true],
                        "ambientcolor": "0 0 0", "skylightcolor": "0 0 0", "hdr": true],
            "objects": [
                ["id": "lit-model", "name": "Directional control", "solid": true,
                 "model": "models/lit.mdl", "origin": "32 32 -1", "scale": "1 1 1"],
                ["id": "directional", "light": "ldirectional", "angles": "0 0 0", "origin": "0 0 0",
                 "color": "1 1 1", "intensity": 5, "visible": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: scene).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(root: root, descriptor: SceneDescriptor(
            workshopID: UUID().uuidString, cacheRelativePath: "wpe-cache/test", entryFile: "scene.json", capabilityTier: .degraded
        ), dependencyRoot: nil)
    }
}

extension WPEMetalSceneRendererTests {
    @Test("Directional light scripts and full parent matrices publish together in each frame")
    func directionalLightAndParentScriptsShareFramePublication() async throws {
        let fixture = try MetalSceneFixture.directionalModelScene(lightingEnabled: true)
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        let angleScript = "export function init(value) { value.z = 90; return value; } export function update(value) { value.z = 90 + Math.max(0, engine.runtime - 1) * 30; return value; }"
        objects[1]["parent"] = "light-host"
        objects[1]["angles"] = ["value": "0 0 0", "script": angleScript]
        objects[1]["color"] = ["value": "1 1 1", "script": "export function init(value) { return new Vec3(0.25, 0.5, 0.75); } export function update(value) { return new Vec3(0.25 + Math.max(0, engine.runtime - 1) * 0.1, 0.5, 0.75); }"]
        objects[1]["castshadow"] = true
        objects.append(["id": "light-host", "type": "group", "origin": "10 20 30", "scale": "2 3 4",
                        "angles": ["value": "0 0 0", "script": angleScript]])
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: url)
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: url))
        #expect(WPESceneScriptInstanceInventory(document: document).transform == 3)
        let now = OSAllocatedUnfairLock(initialState: 1.0)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice()),
            frameClock: WPEMetalFrameClock(loadTime: 0, currentMediaTime: { now.withLock { $0 } })
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        #expect(renderer.dynamicAnglesScriptInstances["directional"] != nil)
        #expect(renderer.dynamicColorScriptInstances["directional"] != nil)
        let initial = try #require(renderer.lastFrameDirectionalLighting.lights.first)
        #expect(abs(initial.uniforms.direction.x - 1) < 0.001)
        #expect(abs(initial.uniforms.direction.y) < 0.001)
        #expect(initial.uniforms.radiance == SIMD4<Float>(1.25, 2.5, 3.75, 0))
        #expect(initial.castShadow)
        #expect(renderer.lastFrameDirectionalLighting.metadata.y == 1)
        now.withLock { $0 = 2 }
        // One older job may still own an outcome slot. Two completed submissions
        // ensure time2 has executed before its outputs are consumed below.
        for _ in 0 ..< 2 {
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
            // Existing transform ticks publish asynchronously. Queue barriers after
            // their submitted work observe actual completion, without an arbitrary sleep.
            if let completion = renderer.lastOracleSceneScriptBatchCompletion {
                try #require(completion.wait(timeout: .now() + 1), "script batch did not complete within its bounded wait")
            } else {
                try #require(renderer.orderedLayerScriptBatch == nil, "barriers require parallel-worker submission")
                let barriers = (0 ..< renderer.sceneScriptBatchDispatcher.width).map { _ in
                    let lane = renderer.sceneScriptBatchDispatcher.reserveLane()
                    return WPESceneScriptBatchDispatcher.Job(queue: lane.queue, work: {})
                }
                let completion = try #require(renderer.sceneScriptBatchDispatcher.submit(barriers, trackingCompletion: true))
                try #require(completion.wait(timeout: .now() + 1), "script batch did not complete within its bounded wait")
            }
        }
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        #expect(abs((renderer.lastStableScriptTransforms.angles["directional"]?.z ?? 0) - 2 * .pi / 3) < 0.001)
        #expect(abs((renderer.lastStableScriptTransforms.angles["light-host"]?.z ?? 0) - 2 * .pi / 3) < 0.001)
        let moved = try #require(renderer.lastFrameDirectionalLighting.lights.first)
        // Both rotations are now 120 degrees. Rz(120)*S(2,3)*Rz(120)*(-X)
        // is (1.75, 1.25*sqrt(3), 0), before normalization. Translation has no effect.
        let length = sqrt(7.75)
        #expect(abs(moved.uniforms.direction.x - Float(1.75 / length)) < 0.001)
        #expect(abs(moved.uniforms.direction.y - Float(1.25 * sqrt(3) / length)) < 0.001)
        #expect(abs(moved.uniforms.radiance.x - 1.75) < 0.001)
        #expect(moved.uniforms.radiance.y == 2.5 && moved.uniforms.radiance.z == 3.75)
        #expect(renderer.executor.currentDirectionalLighting == .empty, "frame lighting must not leak to an unrelated executor render")
    }
}

extension WPEMetalSceneRendererTests {
    @Test("Directional lighting ABI retains authored color and shadow requests without fabricating a parent")
    func directionalLightingCPUContract() {
        #expect(MemoryLayout<WPEMetalDirectionalLightUniforms>.stride == 32)
        let light = WPESceneLightObject(id: "light", name: "Light", type: .directional, authoredType: "ldirectional",
                                        origin: .zero, scale: SIMD3(repeating: 1), angles: .zero, color: SIMD3(0.25, 0.5, 0.75),
                                        intensity: 5, castShadow: true)
        let resolved = WPESceneDirectionalLightingSnapshot.make(lights: [light], localTransforms: [:],
                                                                parentByID: [:], ownVisibilityByID: [:])
        #expect(resolved.lights.first?.uniforms.direction == SIMD4<Float>(-1, 0, 0, 0))
        #expect(resolved.lights.first?.uniforms.radiance == SIMD4<Float>(1.25, 2.5, 3.75, 0))
        #expect(resolved.metadata == SIMD4<UInt32>(1, 1, 0, 0))
        let incomplete = WPESceneDirectionalLightingSnapshot.make(lights: [light], localTransforms: [:],
                                                                  parentByID: ["light": "missing"], ownVisibilityByID: [:])
        #expect(incomplete.lights.isEmpty)
        #expect(incomplete.unresolvedObjectIDs == ["light"])
        let hidden = WPESceneDirectionalLightingSnapshot.make(lights: [light], localTransforms: [:],
                                                              parentByID: [:], ownVisibilityByID: ["light": false])
        #expect(hidden.lights.isEmpty && hidden.metadata.x == 0)
        #expect(hidden.uniformPayload.count == 1, "even an empty light list must bind a valid zero record")
    }

    @Test("Directional lights resolve through text and particle parents; missing or cyclic parents still reject")
    func directionalLightingResolvesTextAndParticleParents() throws {
        let quarterTurn = "0 0 \(Double.pi / 2)"
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": [
                ["id": "label", "text": "A", "origin": "4 5 0", "angles": quarterTurn],
                ["id": "emitter", "particle": "particles/none.json", "origin": "6 7 0", "angles": quarterTurn],
                ["id": "text-light", "light": "ldirectional", "parent": "label", "color": "1 1 1", "intensity": 1],
                ["id": "particle-light", "light": "ldirectional", "parent": "emitter", "color": "1 1 1", "intensity": 1],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene))
        let transforms = WPEMetalSceneRenderer.lightingLocalTransforms(in: document)
        let lighting = WPESceneDirectionalLightingSnapshot.make(
            lights: document.lightObjects, localTransforms: transforms,
            parentByID: document.objectParentByID, ownVisibilityByID: [:]
        )
        #expect(lighting.unresolvedObjectIDs.isEmpty)
        #expect(Set(lighting.lights.map(\.objectID)) == ["text-light", "particle-light"])
        for light in lighting.lights {
            // Rz(90°) turns the local -X basis into world -Y.
            #expect(abs(light.uniforms.direction.x) < 0.001 && abs(light.uniforms.direction.y + 1) < 0.001, "\(light.objectID)")
        }
        let light = try #require(document.lightObjects.first { $0.id == "text-light" })
        let missing = WPESceneDirectionalLightingSnapshot.make(
            lights: [light], localTransforms: transforms, parentByID: ["text-light": "ghost"], ownVisibilityByID: [:]
        )
        #expect(missing.lights.isEmpty && missing.unresolvedObjectIDs == ["text-light"])
        let cyclic = WPESceneDirectionalLightingSnapshot.make(
            lights: [light], localTransforms: transforms,
            parentByID: ["text-light": "label", "label": "emitter", "emitter": "label"], ownVisibilityByID: [:]
        )
        #expect(cyclic.lights.isEmpty && cyclic.unresolvedObjectIDs == ["text-light"])
    }

    @Test("A directional light parented to a particle emitter contributes in the rendered frame")
    func directionalLightUnderParticleParentPublishes() async throws {
        let fixture = try MetalSceneFixture.directionalModelScene(lightingEnabled: true)
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[1]["parent"] = "emitter"
        objects.append(["id": "emitter", "particle": "particles/none.json", "origin": "0 0 0", "angles": "0 0 \(Double.pi / 2)"])
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: url)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        #expect(renderer.lastFrameDirectionalLighting.unresolvedObjectIDs.isEmpty)
        let light = try #require(renderer.lastFrameDirectionalLighting.lights.first)
        #expect(abs(light.uniforms.direction.x) < 0.001 && abs(light.uniforms.direction.y + 1) < 0.001)
    }
}

extension WPEMetalSceneRendererTests {
    @Test("Opaque generic4 keeps padded RGB; translucent generic4 keeps authored alpha")
    func modelNormalBlendKeepsPaddedRGB() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func sample(blending: String, paddingAlpha: UInt8) async throws -> ([Float], [Float]) {
            let fixture = try MetalSceneFixture.directionalModelScene(lightingEnabled: false)
            defer { fixture.cleanup() }
            let materialURL = fixture.root.appendingPathComponent("materials/lit.json")
            var material = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: materialURL)) as? [String: Any])
            var passes = try #require(material["passes"] as? [[String: Any]])
            passes[0]["textures"] = ["materials/padded.tex"]
            passes[0]["blending"] = blending
            material["passes"] = passes
            try JSONSerialization.data(withJSONObject: material).write(to: materialURL)
            var tex = Data()
            func u32(_ value: UInt32) {
                var littleEndian = value.littleEndian
                Swift.withUnsafeBytes(of: &littleEndian) { tex.append(contentsOf: $0) }
            }
            func magic(_ value: String) {
                tex.append(contentsOf: value.utf8)
                tex.append(0)
            }
            magic("TEXV0005")
            magic("TEXI0001")
            // Straight RGBA, authored clamp UVs, physical 8x4 / logical 4x4.
            for value: UInt32 in [0, 2, 8, 4, 4, 4, 0] {
                u32(value)
            }
            magic("TEXB0001")
            for value: UInt32 in [1, 1, 8, 4, 8 * 4 * 4] {
                u32(value)
            }
            for _ in 0 ..< 4 {
                for column in 0 ..< 8 {
                    tex.append(contentsOf: [255, 255, 255, column < 4 ? 255 : paddingAlpha])
                }
            }
            try tex.write(to: fixture.root.appendingPathComponent("materials/padded.tex"))
            let renderer = try WPEMetalSceneRenderer(
                descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
                frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
            )
            defer { renderer.cleanup() }
            try await renderer.load()
            let output = try #require(renderer.outputTexture)
            let staging = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
            func pixel(x: Int) throws -> [Float] {
                let region = MTLRegionMake2D(x, output.height / 2, 1, 1)
                switch output.pixelFormat {
                case .rgba16Float:
                    var lanes = [UInt16](repeating: 0, count: 4)
                    lanes.withUnsafeMutableBytes {
                        staging.getBytes($0.baseAddress!, bytesPerRow: 8, from: region, mipmapLevel: 0)
                    }
                    return lanes.map { Float(Float16(bitPattern: $0)) }
                case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb:
                    var lanes = [UInt8](repeating: 0, count: 4)
                    staging.getBytes(&lanes, bytesPerRow: 4, from: region, mipmapLevel: 0)
                    if output.pixelFormat == .bgra8Unorm || output.pixelFormat == .bgra8Unorm_srgb {
                        lanes.swapAt(0, 2)
                    }
                    return lanes.map { Float($0) / 255 }
                default:
                    throw NSError(domain: "WPEModelPaddingFixture", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Unsupported readback format \(output.pixelFormat)"])
                }
            }
            return try (pixel(x: 20), pixel(x: 44))
        }
        for blending in ["normal", "disabled"] {
            let (opaque, padded) = try await sample(blending: blending, paddingAlpha: 0)
            try #require(opaque.prefix(3).allSatisfy { $0 > 0.2 }, "Unpadded model coverage control: \(opaque)")
            for channel in 0 ..< 3 {
                #expect(abs(padded[channel] - opaque[channel]) < 0.03,
                        "Opaque material \(blending) must retain padding RGB regardless of source alpha: \(padded), \(opaque)")
            }
            #expect(abs(padded[3] - opaque[3]) < 0.01,
                    "Opaque RGB-only writes must preserve canvas alpha on both samples: \(padded), \(opaque)")
        }
        let (opaque, transparent) = try await sample(blending: "translucent", paddingAlpha: 0)
        try #require(opaque.prefix(3).allSatisfy { $0 > 0.2 }, "Translucent coverage control: \(opaque)")
        #expect(transparent.prefix(3).allSatisfy { $0 < 0.01 }, "Translucent alpha-zero must reveal black background: \(transparent)")
        let (_, partial) = try await sample(blending: "translucent", paddingAlpha: 128)
        for channel in 0 ..< 3 {
            #expect(partial[channel] > 0.05 && partial[channel] < opaque[channel] - 0.05,
                    "Translucent material must preserve fractional alpha: \(partial), \(opaque)")
        }
    }
}
