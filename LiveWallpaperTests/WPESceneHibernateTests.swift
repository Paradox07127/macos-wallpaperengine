#if !LITE_BUILD
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
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
        renderer.onDemandVideoKeyByID = ["obj": ["sentinel"]]
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

    @Test("Manually paused session hibernates after its own dwell and unpause reloads")
    func manualPauseHibernatesAfterOwnDwell() async throws {
        // Absence dwell is effectively infinite so only the pause class can fire.
        let harness = try HibernateSessionHarness.make(
            hibernationDelay: .seconds(3600),
            userPauseHibernationDelay: .milliseconds(50)
        )
        defer { harness.teardown() }
        let session = harness.session
        try await Self.poll("initial load") {
            await harness.actor.rendererStateSnapshot()?.isLoaded == true
        }

        session.pause()
        // Routine policy refreshes push absence ineligibility constantly; they
        // must not cancel the pause-class dwell.
        session.setHibernationEligible(false)
        try await Self.poll("hibernate after pause dwell") { session.isHibernated }
        let hibernatedSnapshot = await harness.actor.rendererStateSnapshot()
        #expect(hibernatedSnapshot?.isLoaded == false)

        session.play()
        try await Self.poll("wake reload after unpause") {
            guard session.isHibernated == false else { return false }
            return await harness.actor.rendererStateSnapshot()?.isLoaded == true
        }
        #expect(session.loadError == nil)
    }

    @Test("Unpausing before the pause dwell elapses cancels it")
    func unpauseBeforePauseDwellCancels() async throws {
        let harness = try HibernateSessionHarness.make(
            hibernationDelay: .seconds(3600),
            userPauseHibernationDelay: .milliseconds(120)
        )
        defer { harness.teardown() }
        let session = harness.session
        try await Self.poll("initial load") {
            await harness.actor.rendererStateSnapshot()?.isLoaded == true
        }

        session.pause()
        session.play()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!session.isHibernated)
        let snapshot = await harness.actor.rendererStateSnapshot()
        #expect(snapshot?.isLoaded == true)
    }

    @Test("Critical memory pressure hibernates immediately, bypassing every dwell")
    func criticalPressureBypassesDwell() async throws {
        let harness = try HibernateSessionHarness.make(
            hibernationDelay: .seconds(3600),
            userPauseHibernationDelay: .seconds(3600)
        )
        defer { harness.teardown() }
        let session = harness.session
        try await Self.poll("initial load") {
            await harness.actor.rendererStateSnapshot()?.isLoaded == true
        }

        session.applyPerformanceProfile(.suspended)
        session.setCriticalMemoryPressureActive(true)
        try await Self.poll("immediate hibernate") { session.isHibernated }
        let hibernatedSnapshot = await harness.actor.rendererStateSnapshot()
        #expect(hibernatedSnapshot?.isLoaded == false)

        // Pressure cleared: the policy refresh restores quality and wakes.
        session.applyPerformanceProfile(.quality)
        try await Self.poll("wake reload after pressure clears") {
            guard session.isHibernated == false else { return false }
            return await harness.actor.rendererStateSnapshot()?.isLoaded == true
        }
        #expect(session.loadError == nil)
    }

    @Test("Critical pressure from the watcher hibernates an installed scene session")
    func criticalPressureWatcherHibernatesInstalledScene() async throws {
        let nsScreen = try #require(NSScreen.screens.first)
        let screen = Screen(nsScreen: nsScreen)
        let watcher = HibernateFakePressureWatcher()
        let harness = try HibernateSessionHarness.make(
            hibernationDelay: .seconds(3600),
            userPauseHibernationDelay: .seconds(3600)
        )
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            memoryPressureWatcher: watcher,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer {
            manager.tearDownForTermination()
            harness.fixture.cleanup()
        }
        let liveScreen = try #require(manager.screens.first(where: { $0.id == screen.id }))
        liveScreen.installRuntimeSession(harness.session)
        try await Self.poll("initial load") {
            await harness.actor.rendererStateSnapshot()?.isLoaded == true
        }

        watcher.emit(.critical)
        try await Self.poll("watcher-driven immediate hibernate") {
            harness.session.isHibernated
        }
        #expect(manager.isUnderMemoryPressure)
        let snapshot = await harness.actor.rendererStateSnapshot()
        #expect(snapshot?.isLoaded == false)
    }

    @Test("A scene installed while pressure is already critical still hibernates")
    func sessionInstalledUnderCriticalPressureHibernates() async throws {
        let nsScreen = try #require(NSScreen.screens.first)
        let screen = Screen(nsScreen: nsScreen)
        let watcher = HibernateFakePressureWatcher()
        let harness = try HibernateSessionHarness.make(
            hibernationDelay: .seconds(3600),
            userPauseHibernationDelay: .seconds(3600)
        )
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            memoryPressureWatcher: watcher,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer {
            manager.tearDownForTermination()
            harness.fixture.cleanup()
        }

        // Pressure is critical BEFORE the wallpaper exists — the restore-at-launch
        // and swap-in cases. A level-change-only push never reaches this session.
        watcher.emit(.critical)
        // The watcher hop is a MainActor Task — drain it so the level change is
        // fully applied BEFORE the session exists. Without this barrier the
        // install races ahead and the test degenerates into the already-covered
        // "pressure arrives after install" ordering.
        try await Self.poll("pressure applied before install") {
            manager.isUnderMemoryPressure
        }
        let liveScreen = try #require(manager.screens.first(where: { $0.id == screen.id }))
        liveScreen.installRuntimeSession(harness.session)
        try await Self.poll("initial load") {
            await harness.actor.rendererStateSnapshot()?.isLoaded == true
        }
        manager.refreshPerformancePolicyForAllScreens()

        try await Self.poll("hibernate under standing critical pressure") {
            harness.session.isHibernated
        }
        let snapshot = await harness.actor.rendererStateSnapshot()
        #expect(snapshot?.isLoaded == false)
    }

    @Test("Pressure returning to normal revokes the critical-pressure dwell")
    func normalPressureRevokesCriticalDwell() async throws {
        let nsScreen = try #require(NSScreen.screens.first)
        let screen = Screen(nsScreen: nsScreen)
        let watcher = HibernateFakePressureWatcher()
        // Long dwells: only the critical path could hibernate inside the poll
        // window, so a hibernate here proves the emergency outlived the emergency.
        let harness = try HibernateSessionHarness.make(
            hibernationDelay: .seconds(3600),
            userPauseHibernationDelay: .seconds(3600)
        )
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            memoryPressureWatcher: watcher,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer {
            manager.tearDownForTermination()
            harness.fixture.cleanup()
        }
        let liveScreen = try #require(manager.screens.first(where: { $0.id == screen.id }))
        liveScreen.installRuntimeSession(harness.session)
        try await Self.poll("initial load") {
            await harness.actor.rendererStateSnapshot()?.isLoaded == true
        }

        // User pauses (its own 3600s dwell), then a pressure spike comes and goes
        // while the session stays suspended for that unrelated reason.
        harness.session.pause()
        watcher.emit(.critical)
        watcher.emit(.normal)

        try? await Task.sleep(for: .milliseconds(1500))
        #expect(
            harness.session.isHibernated == false,
            "Critical-pressure dwell survived the pressure and hibernated on its 1s retry cadence, bypassing the manual-pause dwell"
        )
    }

    @Test("A wake reload that fails is retried once and heals the session")
    func failedWakeReloadRetriesAutomatically() async throws {
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
            hibernationDelay: .milliseconds(50),
            wakeRetryDelay: .milliseconds(400)
        )
        defer { session.cleanup() }
        session.startAdoptingRenderer(WPERendererHandoff(renderer: renderer))
        try await Self.poll("initial load") {
            await actor.rendererStateSnapshot()?.isLoaded == true
        }

        session.applyPerformanceProfile(.suspended)
        session.setHibernationEligible(true)
        try await Self.poll("hibernate after dwell") { session.isHibernated }

        // Stashing the entry file makes exactly the wake reload fail; the wake
        // has no user behind it, so without a retry the session stays dead.
        let entry = fixture.root.appendingPathComponent("scene.json")
        let stash = fixture.root.appendingPathComponent("scene.json.stashed")
        try FileManager.default.moveItem(at: entry, to: stash)
        session.applyPerformanceProfile(.quality)
        try await Self.poll("wake reload fails") { session.loadError != nil }
        try FileManager.default.moveItem(at: stash, to: entry)

        try await Self.poll("automatic retry heals the session") {
            guard session.loadError == nil else { return false }
            return await actor.rendererStateSnapshot()?.isLoaded == true
        }
        #expect(!session.isHibernated)
    }

    @Test("A newer wake supersedes the retry still pending from the wake it replaced")
    func newerWakeSupersedesPendingRetry() async throws {
        let retryDelay = Duration.milliseconds(1500)
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
            hibernationDelay: .milliseconds(50),
            wakeRetryDelay: retryDelay
        )
        defer { session.cleanup() }
        session.startAdoptingRenderer(WPERendererHandoff(renderer: renderer))
        try await Self.poll("initial load") {
            await actor.rendererStateSnapshot()?.isLoaded == true
        }

        let entry = fixture.root.appendingPathComponent("scene.json")
        let stash = fixture.root.appendingPathComponent("scene.json.stashed")

        // Wake #1 fails and starts counting down to its retry.
        session.applyPerformanceProfile(.suspended)
        session.setHibernationEligible(true)
        try await Self.poll("first hibernate") { session.isHibernated }
        try FileManager.default.moveItem(at: entry, to: stash)
        session.applyPerformanceProfile(.quality)
        try await Self.poll("first wake fails") { session.loadError != nil }
        let firstRetryDeadline = ContinuousClock.now + retryDelay

        // Heal and hibernate again *inside* that countdown, so wake #2 starts
        // from a loaded renderer while wake #1 is still asleep. The extra hold
        // keeps the two retry deadlines far enough apart to tell them apart.
        try FileManager.default.moveItem(at: stash, to: entry)
        await session.retry()
        #expect(session.loadError == nil)
        try await Task.sleep(for: .milliseconds(900))
        session.applyPerformanceProfile(.suspended)
        session.setHibernationEligible(true)
        try await Self.poll("second hibernate") { session.isHibernated }
        try FileManager.default.moveItem(at: entry, to: stash)
        session.applyPerformanceProfile(.quality)
        try await Self.poll("second wake fails") { session.loadError != nil }
        let secondRetryDeadline = ContinuousClock.now + retryDelay

        // Between the two deadlines only wake #2 may still be alive. A stale
        // wake #1 reloads here on top of the live one and, when that fails,
        // flips `isHibernated` behind its back — the live wake then heals the
        // scene and leaves the flag set on a loaded session, which can never
        // hibernate again.
        try await Task.sleep(until: firstRetryDeadline + .milliseconds(400), clock: .continuous)
        #expect(
            ContinuousClock.now < secondRetryDeadline,
            "rig broken: the two retry windows overlapped, so this proves nothing"
        )
        #expect(!session.isHibernated, "a superseded wake acted after a newer wake replaced it")

        // M4 unchanged: the live wake's own give-up still restores the gate.
        try await Self.poll("live wake restores the hibernated gate") { session.isHibernated }
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

/// Loaded-session fixture for dwell-policy tests: real renderer + actor +
/// window, with both hibernation dwells injectable.
@MainActor
private struct HibernateSessionHarness {
    let fixture: FrameDemandFixture
    let actor: WPEDisplayRenderActor
    let session: SceneWallpaperSession

    static func make(
        hibernationDelay: Duration,
        userPauseHibernationDelay: Duration
    ) throws -> Self {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try FrameDemandFixture.make()
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
            hibernationDelay: hibernationDelay,
            userPauseHibernationDelay: userPauseHibernationDelay
        )
        session.startAdoptingRenderer(WPERendererHandoff(renderer: renderer))
        return Self(fixture: fixture, actor: actor, session: session)
    }

    func teardown() {
        session.cleanup()
        fixture.cleanup()
    }
}

private final class HibernateFakePressureWatcher: MemoryPressureWatching {
    private struct State {
        var level = SystemMemoryPressureLevel.normal
        var handler: SystemMemoryPressureChangeHandler?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(onChange: SystemMemoryPressureChangeHandler?) {
        state.withLock { $0.handler = onChange }
    }

    func stop() {
        state.withLock { $0.handler = nil }
    }

    func currentLevel() -> SystemMemoryPressureLevel {
        state.withLock { $0.level }
    }

    func emit(_ level: SystemMemoryPressureLevel) {
        let handler = state.withLock { state -> SystemMemoryPressureChangeHandler? in
            state.level = level
            return state.handler
        }
        handler?(level)
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
