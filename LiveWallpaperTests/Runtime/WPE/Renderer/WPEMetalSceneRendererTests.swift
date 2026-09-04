import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@MainActor
@Suite("WPE Metal scene renderer")
struct WPEMetalSceneRendererTests {

    @Test("Only the primary texture slot is mandatory at load")
    func onlyPrimarySlotIsMandatoryAtLoad() throws {
        // The loader now walks all 8 custom slots, so a pass that declares junk
        // in a trailing slot (2955378002's "wegwegwegh") would abort the whole
        // scene load before the encode-time fallback could ever run. Slot 0 IS
        // the layer, so it stays fatal.
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
        // Effect passes routinely read the previous target in slot 0. That
        // reference is not an external file, so it is dropped by the
        // external-only filter — and whichever auxiliary slot survived first
        // inherited "index 0 means primary" and became load-fatal.
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
        defer { renderActor.shutdown() }

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

        // A visible, playing, quality-profile scene must not acquire the global
        // Core Audio process-tap lease unless its document explicitly opts into
        // audio processing. This false branch is the privacy/resource boundary.
        session.updateSystemAudioCaptureRequirement(false)
        #expect(demand.consumerCount == 0)
        #expect(demand.retainCount == 0)

        session.updateSystemAudioCaptureRequirement(true)
        #expect(demand.consumerCount == 1)
        #expect(session.isPlaying)

        session.applyPreviewPerformanceProfile(.suspended)
        #expect(demand.consumerCount == 0)
        #expect(!session.isPlaying)

        // Clearing the preview override must not defeat a suspended system
        // policy or a manual pause.
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

    @Test("Scene preview lifecycle rejects refreshes after disappearance and across re-entry")
    func scenePreviewLifecycleRejectsStaleRefreshes() {
        var lifecycle = ScenePreviewLifecycleState()
        let firstSession = NSObject()
        let secondSession = NSObject()
        let firstSessionID = ObjectIdentifier(firstSession)
        let secondSessionID = ObjectIdentifier(secondSession)
        let first = lifecycle.begin(sessionID: firstSessionID)
        #expect(lifecycle.accepts(
            first,
            sessionID: firstSessionID,
            isCancelled: false
        ))
        #expect(!lifecycle.accepts(
            first,
            sessionID: firstSessionID,
            isCancelled: true
        ))
        #expect(!lifecycle.accepts(
            first,
            sessionID: secondSessionID,
            isCancelled: false
        ))

        lifecycle.invalidate()
        #expect(!lifecycle.accepts(
            first,
            sessionID: firstSessionID,
            isCancelled: false
        ))

        let second = lifecycle.begin(sessionID: secondSessionID)
        #expect(second != first)
        #expect(!lifecycle.accepts(
            first,
            sessionID: firstSessionID,
            isCancelled: false
        ))
        #expect(lifecycle.accepts(
            second,
            sessionID: secondSessionID,
            isCancelled: false
        ))
    }

    @Test("Scene preview polls only while renderer state is unsettled")
    func scenePreviewPollingStopsAtTerminalStates() {
        #expect(SceneRenderState.idle.needsPreviewPolling)
        #expect(SceneRenderState.loading.needsPreviewPolling)
        #expect(!SceneRenderState.ready.needsPreviewPolling)
        #expect(!SceneRenderState.notRendering.needsPreviewPolling)
        #expect(!SceneRenderState.error(.sceneResourceMissing).needsPreviewPolling)
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

    @Test("Scene preview identity tracks sessions, stable overrides, and exact commits")
    func scenePreviewTaskIdentityTracksSessionReplacement() {
        let firstSession = NSObject()
        let secondSession = NSObject()
        let absent = ScenePreviewTaskIdentity(
            workshopID: "42",
            sessionID: nil,
            propertyOverridesRevision: ScenePropertyOverridesRevision([:]),
            propertyCommitSequence: nil
        )
        let first = ScenePreviewTaskIdentity(
            workshopID: "42",
            sessionID: ObjectIdentifier(firstSession),
            propertyOverridesRevision: ScenePropertyOverridesRevision([
                "enabled": .bool(true),
            ]),
            propertyCommitSequence: 1
        )
        let sameFirst = ScenePreviewTaskIdentity(
            workshopID: "42",
            sessionID: ObjectIdentifier(firstSession),
            propertyOverridesRevision: ScenePropertyOverridesRevision([
                "enabled": .bool(true),
            ]),
            propertyCommitSequence: 1
        )
        let replacement = ScenePreviewTaskIdentity(
            workshopID: "42",
            sessionID: ObjectIdentifier(secondSession),
            propertyOverridesRevision: ScenePropertyOverridesRevision([
                "enabled": .bool(true),
            ]),
            propertyCommitSequence: 1
        )
        let propertyEdit = ScenePreviewTaskIdentity(
            workshopID: "42",
            sessionID: ObjectIdentifier(firstSession),
            propertyOverridesRevision: ScenePropertyOverridesRevision([
                "enabled": .bool(false),
            ]),
            propertyCommitSequence: 2
        )
        let reordered = ScenePreviewTaskIdentity(
            workshopID: "42",
            sessionID: ObjectIdentifier(firstSession),
            propertyOverridesRevision: ScenePropertyOverridesRevision([
                "z": .number(2),
                "a": .string("x"),
            ]),
            propertyCommitSequence: 3
        )
        let sameReordered = ScenePreviewTaskIdentity(
            workshopID: "42",
            sessionID: ObjectIdentifier(firstSession),
            propertyOverridesRevision: ScenePropertyOverridesRevision([
                "a": .string("x"),
                "z": .number(2),
            ]),
            propertyCommitSequence: 3
        )
        let repeatedValueCommit = ScenePreviewTaskIdentity(
            workshopID: "42",
            sessionID: ObjectIdentifier(firstSession),
            propertyOverridesRevision: first.propertyOverridesRevision,
            propertyCommitSequence: 4
        )

        #expect(absent != first)
        #expect(first == sameFirst)
        #expect(first != replacement)
        #expect(first != propertyEdit)
        #expect(reordered == sameReordered)
        #expect(first != repeatedValueCommit)
    }

    @Test("Config channel applies fire-and-forget setters in order (last write wins)")
    func configChannelAppliesLastWriteWins() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let renderActor = WPEDisplayRenderActor(backing: .main)
        defer { renderActor.shutdown() }
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

    /// `performLoad` builds the render graph and pipeline BEFORE it uploads
    /// textures, so a texture failure lands on a renderer that already owns
    /// them — plus, further in, video decoders, particle buffers and text
    /// atlases. `didLoad = false` then makes all of it unreachable: no tick
    /// samples it, and `hibernate()` refuses to collect it (`guard didLoad`), so
    /// it lived until the user retried or switched wallpaper.
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

        // These two specifically: `performLoad` assigns them before it uploads
        // textures, so they are the only state this fixture proves was published
        // and then collected. Asserting `particleSystems.isEmpty` or
        // `outputTexture == nil` here would pass with or without the teardown —
        // this scene throws before either is ever set.
        #expect(renderer.renderGraph == nil)
        #expect(renderer.renderPipeline == nil)
        // The teardown resets the tracer and drops the snapshot the failure
        // report reads, so the diagnostics have to be produced BEFORE it runs.
        // Reordering them silently blanks every scene-failure message.
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

        // A nonsense ceiling still has to leave a drivable link.
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

        // Idempotent: repeating the same calls leaves the seeded state unchanged.
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
        // GitHub #133: most workshop scenes never set `supportsaudioprocessing`
        // and have no scripts — the audio response lives in shader uniforms.
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
        // No audio shader, no script, no authored flag — the emitter's
        // audioprocessingmode is the sole reason capture must run.
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
        // The [COMBO] annotation alone injects AUDIOPROCESSING=0 into comboValues;
        // the unguarded read below stays compiled in regardless.
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
        // The runtime resolves frame globals case-insensitively
        // (canonicalNameByLowercased), so this spelling receives live data.
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
        // `# endif` must pop the guard, or the unguarded read below is
        // wrongly judged compiled-out.
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
}

@MainActor
private struct StaticPresentRetryFixture {
    let fixture: MetalSceneFixture
    let renderer: WPEMetalSceneRenderer
    let window: NSWindow

    static func make() async throws -> Self {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
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
        window.orderBack(nil)
        if let layer = renderer.nsView.layer as? CAMetalLayer {
            let size = renderer.nsView.convertToBacking(renderer.nsView.bounds).size
            if size.width > 0, size.height > 0 {
                layer.drawableSize = size
            }
        }
        try await renderer.load()
        return Self(fixture: fixture, renderer: renderer, window: window)
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

private struct MetalSceneFixture {
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
                origin: new Vec3(0.5, 0.5, 0),
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
            "origin": "0.5 0.5 0",
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

    /// One drawable emitter whose only audio hookup is the emitter's own
    /// `audioprocessing*` fields — no audio shader, script, or authored flag.
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
            "origin": "0.5 0.5 0",
            "scale": "1 1 1",
            "alpha": 1
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
    }

    private static func writePNG(at url: URL, color: CGColor) throws {
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
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

    @Test("RGBA16Float HDR sources clamp and sRGB-encode (the 'hdr': true poster fix)")
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
        #expect(abs(Int(mid.r) - 188) <= 2 && abs(Int(mid.g) - 188) <= 2 && abs(Int(mid.b) - 188) <= 2)
    }
}

@Suite("WPE hover hit rect")
struct WPEHoverHitRectTests {
    private func geometry(
        origin: SIMD3<Double>,
        size: CGSize,
        scale: SIMD3<Double> = SIMD3<Double>(1, 1, 1)
    ) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: origin,
            scale: scale,
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: size,
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
    }

    /// 3146703458's song list: authored origins are Y-UP (bottom-left), the pointer
    /// arrives Y-DOWN, so an unconverted ortho centre inverted every hover — the top
    /// entry highlighted the bottom one.
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

        // A layer authored near the BOTTOM must land near the bottom, not the top.
        let low = try #require(WPEMetalSceneRenderer.hoverHitRect(
            geometry: geometry(origin: SIMD3<Double>(100, 200, 0), size: CGSize(width: 427, height: 113)),
            sceneSize: scene,
            projection: nil
        ))
        #expect(low.center.y == 1960)
    }

    // Control: the perspective branch already converted, and must not change.
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
}

@Suite("WPE particle host origin delta")
struct WPEParticleHostOriginDeltaTests {
    /// 3509243656's `MAIN 0-1` and 3448877775 drive a particle host's origin from a
    /// script. The delta rides `projection.padding`, the same Y-up channel as the
    /// parallax offset, and both inputs are authored Y-up — so a host moving UP must
    /// move its particles UP. Negating Y sent them the opposite way.
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

    // Control: X was always correct and must stay untouched.
    @Test("Horizontal delta passes through unchanged")
    func horizontalDeltaPassesThroughUnchanged() {
        let delta = WPEMetalSceneRenderer.particleHostOriginDelta(
            now: SIMD3<Double>(340, 500, 0),
            seed: SIMD3<Double>(100, 500, 0)
        )
        #expect(delta == SIMD2<Float>(240, 0))
    }
}
