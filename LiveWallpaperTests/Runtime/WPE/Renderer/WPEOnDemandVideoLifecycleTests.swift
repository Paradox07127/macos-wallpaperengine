#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import Metal
import Testing

@MainActor
@Suite("On-demand video retirement", .serialized)
struct WPEOnDemandVideoLifecycleTests {
    @Test("Pinned still admission does not schedule a live upgrade")
    func pinnedStill() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        let actor = WPEDisplayRenderActor(backing: .main)
        await actor.adopt(WPERendererHandoff(renderer: renderer).renderer)
        let admission = WPEVideoDecoderAdmission(limit: 0)
        renderer.oracleVideoDecoderAdmission = admission
        let url = fixture.root.appendingPathComponent("still.mp4")
        try Data().write(to: url)
        let source = try WPEVideoTextureSource(
            device: renderer.executor.textureSourceDevice, videoURL: url,
            commandQueue: renderer.executor.commandQueue, decoderAdmission: admission
        )
        renderer.dynamicTextureSources["still.mp4"] = source
        #expect(!source.isLiveDecoder)
        #expect(renderer.videoDecoderAdmission === admission)
        for _ in 0 ..< 4 {
            renderer.lazyLoadVideo(key: "still.mp4")
        }
        #expect(renderer.onDemandVideoTasks.isEmpty)
        #expect(admission.activeCount == 0)
        await actor.teardownRenderer()
        #expect(await actor.shutdown())
    }

    @Test("Queued video loads are cancelled before reading assets", arguments: [false, true])
    func queuedLoad(useMainExecutor: Bool) async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let handoff = try WPERendererHandoff(renderer: makeRenderer(fixture))
        let actor = WPEDisplayRenderActor(backing: useMainExecutor ? .main : .renderThread)
        await actor.adopt(handoff.renderer)
        let task = try await actor.run { _ in
            handoff.renderer.lazyLoadVideo(key: "must-not-read-missing.mp4")
            let task = try #require(handoff.renderer.onDemandVideoTasks.values.first)
            handoff.renderer.cleanup()
            return task
        }
        await task.value
        #expect(task.isCancelled)
        await actor.teardownRenderer()
        #expect(await actor.shutdown())
    }

    @Test("Teardown waits for a suspended load and rejects its publication", .timeLimit(.minutes(1)), arguments: [false, true])
    func inFlightLoad(useMainExecutor: Bool) async throws {
        let fixture = try MetalSceneFixture.materialTextureScene(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        defer { fixture.cleanup() }
        let handoff = try WPERendererHandoff(renderer: makeRenderer(fixture))
        let actor = WPEDisplayRenderActor(backing: useMainExecutor ? .main : .renderThread)
        await actor.adopt(handoff.renderer)
        let gate = VideoLoadPublicationGate()
        await actor.run { _ in
            handoff.renderer.onDemandVideoTasks["materials/base.png"] = Task {
                await actor.loadAtPublicationGate(handoff: handoff, gate: gate)
            }
        }
        for await _ in gate.started.stream {
            break
        }
        var finished = false
        let teardown = Task {
            await actor.teardownRenderer()
            finished = true
        }
        for await _ in gate.cancelled.stream {
            break
        }
        #expect(!finished, "teardown returned while the load could still access its files")
        await gate.release()
        await teardown.value
        #expect(finished)
        await actor.run { _ in
            #expect(handoff.renderer.loadedTextures["materials/base.png"] == nil)
            #expect(handoff.renderer.onDemandVideoTasks.isEmpty)
        }
        #expect(await actor.shutdown())
    }

    private func makeRenderer(_ fixture: MetalSceneFixture) throws -> WPEMetalSceneRenderer {
        try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
    }
}

private actor VideoLoadPublicationGate {
    nonisolated let started = AsyncStream<Void>.makeStream()
    nonisolated let cancelled = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation = $0
                started.continuation.yield(())
            }
        } onCancel: {
            cancelled.continuation.yield(())
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private extension WPEDisplayRenderActor {
    func loadAtPublicationGate(handoff: WPERendererHandoff, gate: VideoLoadPublicationGate) async {
        do {
            try await handoff.renderer.loadDynamicTextureOnActor(
                path: "materials/base.png", layerName: "probe",
                publicationAllowed: { await gate.wait(); return true }, on: self
            )
            Issue.record("A cancelled load published after teardown")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected load error: \(error)")
        }
    }
}
#endif
