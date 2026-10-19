#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os
import Testing

@MainActor
@Suite("Scene load progress delivery", .serialized)
struct SceneLoadProgressTests {
    private func makeSession(backing: WPEDisplayRenderActor.Backing = .main) throws -> (SceneWallpaperSession, WPEDisplayRenderActor) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let actor = WPEDisplayRenderActor(backing: backing)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return (SceneWallpaperSession(window: window, renderActor: actor, surface: surface), actor)
    }

    private func block(_ actor: WPEDisplayRenderActor) async -> (Task<Void, Never>, DispatchSemaphore) {
        let release = DispatchSemaphore(value: 0)
        let (started, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let blocker = Task {
            await actor.run { _ in
                continuation.yield(())
                _ = release.wait(timeout: .now() + 10)
            }
        }
        for await _ in started {
            break
        }
        continuation.finish()
        return (blocker, release)
    }

    @Test("Parity delivers actual read, pipeline and first-frame progress in order")
    func parityLoadDeliversProgress() async throws {
        let (session, actor) = try makeSession()
        let fixture = try ParityLifecycleFixture.make()
        defer { session.cleanup(); fixture.cleanup() }
        try await actor.adoptParity(fixture.inputs(surface: session.spanSurface, actor: actor))
        let progress = OSAllocatedUnfairLock<[String]>(initialState: [])
        await actor.setProgressHandler { text in progress.withLock { $0.append(text) } }
        try await actor.load()
        #expect(progress.withLock { $0 } == [
            String(localized: "Reading scene", bundle: .appLanguage),
            String(localized: "Preparing render pipeline", bundle: .appLanguage),
            String(localized: "Rendering scene", bundle: .appLanguage),
        ])
        #expect(await actor.rendererStateSnapshot()?.isLoaded == true)
    }

    @Test("Preparing before actual startup adoption waits for the first legitimate scene and span load")
    func preparingBeforeAdoptionWaitsForFirstLoad() async throws {
        for spans in [false, true] {
            let (owner, actor) = try makeSession(backing: .renderThread)
            let fixture = try ParityLifecycleFixture.make()
            defer { fixture.cleanup(); owner.cleanup() }
            let surface = owner.spanSurface
            owner.wallpaperWindow?.contentView = surface.mtkView
            surface.attach(client: WPERenderSurfaceClientShim(renderActor: actor, backing: .renderThread))

            let member = OSAllocatedUnfairLock<SceneSpanWallpaperSession?>(initialState: nil)
            let spanFrames = spans ? WPESceneSpanFrames() : nil
            if let frames = spanFrames {
                let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
                let group = SceneSpanWallpaperGroup(id: UUID(), descriptor: fixture.descriptor, owner: owner,
                                                    frames: frames, density: 1, displayFrames: [screen.id: screen.frame])
                let made = try group.makeMember(for: screen, configuration: ScreenConfiguration(screenID: screen.id, wallpaper: .scene(fixture.descriptor)))
                member.withLock { $0 = made }
            } else {
                owner.wallpaperWindow?.orderBack(nil)
            }
            defer { member.withLock { $0 }?.cleanup() }
            let (blocker, release) = await block(actor)
            defer { release.signal() }
            owner.startAdoptingParityScene(fixture.inputs(surface: surface, actor: actor, frames: spanFrames))
            let preparation = Task {
                if let member = member.withLock({ $0 }) {
                    return await member.prepareForDisplay(timeout: .seconds(5))
                }
                return await owner.prepareForDisplay(timeout: .seconds(5))
            }
            try await Task.sleep(for: .milliseconds(50))
            release.signal()
            await blocker.value
            let frames = Task {
                while !Task.isCancelled {
                    await actor.renderFrame()
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            defer { frames.cancel() }
            let result = await preparation.value
            #expect(result == .ready)
            #expect(owner.loadError == nil)
            #expect(await actor.rendererStateSnapshot()?.isLoaded == true)
        }
    }
}
#endif
