#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Unlimited FPS cap")
struct WPEUnlimitedFPSCapTests {
    @Test("Unlimited locks to the display setting's ceiling, with a 60 fallback")
    func capSemantics() {
        #expect(WPEMetalSceneRenderer.unlimitedPreferredFPS(fastestDisplayFPS: 136) == 136)
        #expect(WPEMetalSceneRenderer.unlimitedPreferredFPS(fastestDisplayFPS: 120) == 120)
        #expect(WPEMetalSceneRenderer.unlimitedPreferredFPS(fastestDisplayFPS: 60) == 60)
        #expect(WPEMetalSceneRenderer.unlimitedPreferredFPS(fastestDisplayFPS: 50) == 50)
        // No display reports a rate (headless / between reconfigurations): vsync default.
        #expect(WPEMetalSceneRenderer.unlimitedPreferredFPS(fastestDisplayFPS: 0) == 60)
    }
}

@Suite("Shader error sink")
struct WPEShaderErrorSinkTests {
    @Test("Reset drops the previous scene's failures")
    func resetClearsFailures() {
        let sink = WPEShaderErrorSink()
        sink.record(shader: "effects/blur", reason: "translation failed")
        sink.record(shader: "effects/pulse", reason: "MSL rejected")
        #expect(sink.summary.count == 2)

        sink.reset()
        #expect(sink.summary.count == 0)
        #expect(sink.summary.entries.isEmpty)

        // Still usable afterwards — reset is a scope boundary, not a teardown.
        sink.record(shader: "effects/blend", reason: "translation failed")
        #expect(sink.summary.entries.map(\.shader) == ["effects/blend"])
    }

    @Test("Same shader failing twice stays one entry")
    func dedupesByShaderName() {
        let sink = WPEShaderErrorSink()
        sink.record(shader: "effects/blur", reason: "first")
        sink.record(shader: "effects/blur", reason: "second")
        #expect(sink.summary.count == 1)
        #expect(sink.summary.entries.first?.reason == "second")
    }
}
#endif
