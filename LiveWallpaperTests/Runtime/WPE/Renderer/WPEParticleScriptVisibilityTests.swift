import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import os
import Testing

#if !LITE_BUILD
@MainActor
@Suite("WPE particle script visibility", .serialized)
struct WPEParticleScriptVisibilityTests {
    private struct Sample {
        var time: Double
        var alive: Int
        var encoded: Int
    }

    @Test("A hidden emitter shown by another layer's init emits like a visible one")
    func initRevealEmitsLikeControl() async throws {
        let revealed = try await samples(
            particleVisible: false,
            script: "export function init() { thisScene.getLayer('Sparks').visible = true; }"
        )
        let control = try await samples(particleVisible: true, script: nil)
        let revealedEnd = try #require(revealed.last)
        let controlEnd = try #require(control.last)
        #expect(revealedEnd.encoded == 1, "init-revealed emitter is never handed to the executor")
        #expect(revealedEnd.alive > 30, "init-revealed emitter did not emit: \(revealedEnd.alive)")
        #expect(abs(revealedEnd.alive - controlEnd.alive) <= 3,
                "init-revealed \(revealedEnd.alive) vs control \(controlEnd.alive)")
    }

    @Test("A hidden emitter shown by a 2.5 s timeout starts emitting only then")
    func delayedRevealStartsFromZero() async throws {
        let delayed = try await samples(
            particleVisible: false,
            script: """
            export function init() {
              engine.setTimeout(function () { thisScene.getLayer('Sparks').visible = true; }, 2500);
            }
            """
        )
        let control = try await samples(particleVisible: true, script: nil)
        for sample in delayed where sample.time < 2.45 {
            #expect(sample.alive == 0 && sample.encoded == 0,
                    "hidden emitter simulated or drew at t=\(sample.time): alive=\(sample.alive) encoded=\(sample.encoded)")
        }
        let firstLive = try #require(delayed.first { $0.alive > 0 }, "emitter never started")
        #expect(firstLive.time >= 2.45 && firstLive.alive <= 2,
                "emission did not start from zero at reveal: t=\(firstLive.time) alive=\(firstLive.alive)")
        let delayedEnd = try #require(delayed.last)
        let controlEnd = try #require(control.last)
        #expect(delayedEnd.encoded == 1)
        #expect(delayedEnd.alive > 10 && delayedEnd.alive < controlEnd.alive - 15,
                "delayed \(delayedEnd.alive) vs control \(controlEnd.alive): history accumulated while hidden")
    }

    @Test("A hidden emitter no script touches never simulates or draws")
    func untouchedHiddenEmitterStaysDormant() async throws {
        let hidden = try await samples(particleVisible: false, script: nil, startTime: 2)
        for sample in hidden {
            #expect(sample.alive == 0 && sample.encoded == 0,
                    "hidden emitter alive=\(sample.alive) encoded=\(sample.encoded) at t=\(sample.time)")
        }
    }

    @Test("A visible emitter emits from load")
    func visibleControlEmitsFromLoad() async throws {
        let control = try await samples(particleVisible: true, script: nil)
        let atOne = try #require(control.first { $0.time >= 1 })
        #expect(atOne.alive >= 8 && atOne.encoded == 1)
        let end = try #require(control.last)
        #expect(end.alive > 40)
    }

    /// Renders 0…4.4 s at 30 fps on a driven clock and records the emitter's live count and executor hand-off per frame.
    private func samples(
        particleVisible: Bool,
        script: String?,
        startTime: Double? = nil
    ) async throws -> [Sample] {
        let fixture = try Self.scene(particleVisible: particleVisible, script: script, startTime: startTime)
        defer { fixture.cleanup() }
        let now = OSAllocatedUnfairLock(initialState: 0.0)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: #require(MTLCreateSystemDefaultDevice()),
            frameClock: WPEMetalFrameClock(loadTime: 0, currentMediaTime: { now.withLock { $0 } })
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        try #require(renderer.particleSystems.count == 1, "emitter was not registered")
        let system = try #require(renderer.particleSystems.first)
        renderer.executor.synchronizeFrameCompletion = true
        var result: [Sample] = []
        for frame in 1 ... 132 {
            let time = Double(frame) / 30
            now.withLock { $0 = time }
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
            result.append(Sample(
                time: time,
                alive: system.liveInstanceCount,
                encoded: renderer.executor.lastDiagnosticFrameStats.particleSystemsEncoded
            ))
        }
        return result
    }

    private static func scene(particleVisible: Bool, script: String?, startTime: Double?) throws -> MetalSceneFixture {
        let fixture = try MetalSceneFixture.audioResponsiveParticleScene(audioFields: false)
        let start = startTime.map { #""starttime": \#($0),"# } ?? ""
        let particle = """
        {
          "material": "materials/spark.json",
          "maxcount": 200,
          \(start)
          "emitter": [{ "name": "sphererandom", "rate": 10, "origin": "0 0 0" }],
          "initializer": [
            { "name": "lifetimerandom", "min": 10, "max": 10 },
            { "name": "sizerandom", "min": 4, "max": 4 }
          ]
        }
        """
        try Data(particle.utf8).write(to: fixture.root.appendingPathComponent("particles/audio.json"))
        var solid: [String: Any] = [
            "id": "solid", "name": "Solid", "type": "image",
            "image": "models/util/solidlayer.json", "color": "1 0 0", "alpha": 1,
        ]
        if let script {
            solid["visible"] = ["value": true, "script": script + "\nexport function update(value) { return value; }"]
        }
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64, "auto": true]],
            "objects": [
                solid,
                ["id": "pfx", "name": "Sparks", "particle": "particles/audio.json",
                 "origin": "32 32 0", "visible": particleVisible],
            ],
        ]
        try JSONSerialization.data(withJSONObject: scene).write(to: fixture.root.appendingPathComponent("scene.json"))
        return fixture
    }
}
#endif
