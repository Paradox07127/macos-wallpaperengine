#if !LITE_BUILD
import CoreGraphics
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import QuartzCore
import Testing

@Suite("Scene span presenter submits each produced frame once", .serialized)
@MainActor
struct WPESceneSpanPresenterTests {
    @MainActor
    private struct Fixture {
        let presenter: WPESceneSpanPresenter
        let frames: WPESceneSpanFrames
        let source: WPEMetalRenderExecutor

        func publish(sequence: UInt64) throws {
            let size = CGSize(width: 16, height: 16)
            let texture = try source.makeOutputTexture(size: size)
            frames.publish(.init(texture: texture, generation: 1, sequence: sequence, sourceSize: size,
                                 fitMode: .stretch, tracker: source.presentTracker),
                           generation: 1, sequence: sequence)
        }

        /// True when this tick acquired a drawable and committed a present pass.
        func tickSubmitted() -> Bool {
            presenter.executor.lastPresentPass = nil
            presenter.present()
            return presenter.executor.lastPresentPass != nil
        }

        func waitUntilIdle() async throws {
            for _ in 0 ..< 200 {
                if presenter.permits.tryAcquire() != nil {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("the presenter's command buffer never completed")
        }
    }

    private static func makeFixture() throws -> Fixture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 32, height: 32)
        let frames = WPESceneSpanFrames()
        frames.reset(generation: 1)
        let canvas = CGRect(x: 0, y: 0, width: 32, height: 32)
        let presenter = try WPESceneSpanPresenter(
            device: device, layer: WPEPresentLayer(layer: layer), frames: frames,
            state: WPESceneSpanPresentationState(), producer: WPEDisplayRenderActor(backing: .main),
            configuration: .init(canvasFrame: canvas, screenFrame: canvas), density: 1
        )
        let source = try WPEMetalRenderExecutor(device: device)
        source.spanOutputTextureLimit = 4
        return Fixture(presenter: presenter, frames: frames, source: source)
    }

    @Test("An unchanged sequence is not presented again; a new sequence is", .timeLimit(.minutes(1)))
    func sameSequenceSubmitsOnce() async throws {
        let fixture = try Self.makeFixture()
        try fixture.publish(sequence: 1)
        #expect(fixture.tickSubmitted())
        try await fixture.waitUntilIdle()
        #expect(fixture.presenter.state.hasPresented(generation: 1))

        #expect(!fixture.tickSubmitted(), "a completed frame was re-presented on an idle tick")

        try fixture.publish(sequence: 2)
        #expect(fixture.tickSubmitted())
        try await fixture.waitUntilIdle()
    }

    @Test("A frame whose present did not complete is retried on the next tick", .timeLimit(.minutes(1)))
    func failedCompletionRetries() async throws {
        let fixture = try Self.makeFixture()
        fixture.presenter.remainingForcedPresentFailuresForTesting = 1
        try fixture.publish(sequence: 1)
        #expect(fixture.tickSubmitted())
        try await fixture.waitUntilIdle()
        #expect(!fixture.presenter.state.hasPresented(generation: 1))

        #expect(fixture.tickSubmitted(), "a failed present must not suppress the retry")
        try await fixture.waitUntilIdle()
        #expect(fixture.presenter.state.hasPresented(generation: 1))
    }
}
#endif
