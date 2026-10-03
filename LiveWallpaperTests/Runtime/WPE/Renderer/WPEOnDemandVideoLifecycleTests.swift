#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperProWPE
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

    @Test("A rate committed before release is restored on the rebuilt source")
    func rateBeforeReleaseSurvivesRebuild() async throws {
        let rebuilt = try await rebuiltSourceSnapshot(afterRelease: [])
        #expect(rebuilt.rate == 0.5)
        #expect(rebuilt.loop == false)
        #expect(rebuilt.isPlaying)
    }

    @Test("Commands committed while the source is released apply to the rebuilt source")
    func commandsDuringReleaseSurviveRebuild() async throws {
        let rebuilt = try await rebuiltSourceSnapshot(afterRelease: [.setRate(2), .pause, .seek(0.5)])
        #expect(rebuilt.rate == 2)
        #expect(rebuilt.loop == false)
        #expect(!rebuilt.isPlaying)
    }

    private func rebuiltSourceSnapshot(
        afterRelease: [WPELayerVideoCommand]
    ) async throws -> WPEVideoPlaybackSnapshot {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let key = "materials/clip.tex"
        let url = fixture.root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.videoTex().write(to: url)
        let renderer = try makeRenderer(fixture)
        let actor = WPEDisplayRenderActor(backing: .main)
        await actor.adopt(WPERendererHandoff(renderer: renderer).renderer)
        renderer.oracleVideoDecoderAdmission = WPEVideoDecoderAdmission(limit: 4)
        renderer.layerVideoSourceKey["video"] = key
        _ = renderer.sceneScriptLoadState.begin(generation: renderer.loadGeneration)
        func commit(_ commands: [WPELayerVideoCommand]) {
            renderer.beginSceneScriptVideoCommands()
            renderer.sceneScriptVideoCommandBuffer.enqueue(commands, objectID: "video")
            #expect(renderer.finishCurrentSceneScriptVideoCommands())
        }
        await actor.rebuildOnDemandVideo(key: key, generation: renderer.loadGeneration)
        let first = try #require(renderer.dynamicTextureSources[key] as? WPEVideoTextureSource)
        commit([.setRate(0.5), .setLoop(false)])
        #expect(first.scriptPlaybackSnapshot?.rate == 0.5)
        // Same release reconcileVideoResidency performs for a hidden consumer.
        first.invalidate()
        renderer.dynamicTextureSources.removeValue(forKey: key)
        commit(afterRelease)
        await actor.rebuildOnDemandVideo(key: key, generation: renderer.loadGeneration)
        let rebuilt = try #require(renderer.dynamicTextureSources[key] as? WPEVideoTextureSource)
        #expect(rebuilt !== first)
        let snapshot = try #require(rebuilt.scriptPlaybackSnapshot)
        await actor.teardownRenderer()
        #expect(await actor.shutdown())
        return snapshot
    }

    /// A video `.tex` whose MP4 payload is only an `ftyp` box: enough for a live player, no frames needed.
    private static func videoTex() -> Data {
        var data = Data()
        func magic(_ value: String) {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        func int32(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        // ISO BMFF `ftyp` box: size 24, major brand mp42, minor 0, compatible mp42/isom.
        let mp4 = Data("\u{0}\u{0}\u{0}\u{18}ftypmp42\u{0}\u{0}\u{0}\u{0}mp42isom".utf8)
        magic("TEXV0005")
        magic("TEXI0001")
        for value in [Int32(WPETexFormat.rgba8888.rawValue), 0, 4, 4, 4, 4, 0] {
            int32(value)
        }
        magic("TEXB0003")
        for value: Int32 in [1, -1, 1, 4, 4, 0, Int32(mp4.count), Int32(mp4.count)] {
            int32(value)
        }
        data.append(mp4)
        return data
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
