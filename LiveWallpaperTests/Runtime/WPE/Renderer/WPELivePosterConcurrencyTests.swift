import AppKit
@testable import LiveWallpaper
import Metal
import Testing

@MainActor
@Suite("Live poster actor isolation", .serialized)
struct WPELivePosterConcurrencyTests {
    @Test("Concurrent poster registration, cancellation and teardown stay on the owning executor", arguments: [false, true])
    func concurrentRequests(useMainExecutor: Bool) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let handoff = try WPERendererHandoff(renderer: WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
        ))
        let actor = WPEDisplayRenderActor(backing: useMainExecutor ? .main : .renderThread)
        await actor.adopt(handoff.renderer)
        try await actor.load()
        let state = try #require(await actor.rendererStateSnapshot())
        await actor.recordPresentCompletion(WPEFrameReadinessResult(
            generation: state.currentLoadGeneration, renderCompleted: true, presentCompleted: true
        ))

        let requests = (0 ..< 64).map { _ in Task { await actor.captureLivePoster() } }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var pending = 0
        while clock.now < deadline {
            pending = await actor.run { owner in
                #expect(owner.isOnRenderThread)
                return handoff.renderer.pendingLivePosterCaptures.count
            }
            if pending == requests.count {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(pending == requests.count)
        for request in requests.prefix(32) {
            request.cancel()
        }
        // Teardown races the cancellation jobs; each continuation must still finish once.
        await actor.teardownRenderer()
        for request in requests {
            request.cancel()
            #expect(await request.value == nil)
        }
        #expect(await actor.captureLivePoster() == nil)
        #expect(await actor.shutdown())
    }
}
