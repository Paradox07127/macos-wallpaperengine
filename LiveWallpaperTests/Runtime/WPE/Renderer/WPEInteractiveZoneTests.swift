#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@MainActor
@Suite("WPE interactive zones")
struct WPEInteractiveZoneTests {
    @Test("drawablePointer(fromScenePointer:) inverts scenePointer(fromDrawablePointer:)")
    func presentInverseRoundTrips() throws {
        let presents: [WPEPresentUniforms] = [
            .make(fitMode: .stretch, sourceWidth: 1920, sourceHeight: 1080, targetWidth: 1728, targetHeight: 1117),
            .make(fitMode: .cover, sourceWidth: 1920, sourceHeight: 1080, targetWidth: 1728, targetHeight: 1117),
            .make(fitMode: .cover, sourceWidth: 1080, sourceHeight: 1920, targetWidth: 2560, targetHeight: 1080),
            .make(fitMode: .contain, sourceWidth: 1920, sourceHeight: 1080, targetWidth: 1728, targetHeight: 1117),
            .make(fitMode: .center, sourceWidth: 1280, sourceHeight: 720, targetWidth: 1920, targetHeight: 1200),
            WPEPresentUniforms(ndcScale: SIMD2(1.5, 0.8), uvScale: SIMD2(0.7, 0.9),
                               uvOffset: SIMD2(0.1, 0.05), ndcOffset: SIMD2(0.3, -0.2)),
        ]
        for present in presents {
            for p in [SIMD2<Double>(0.05, 0.05), SIMD2(0.5, 0.5), SIMD2(0.2, 0.9), SIMD2(0.95, 0.95), SIMD2(0.75, 0.1)] {
                let back = try #require(present.scenePointer(fromDrawablePointer: present.drawablePointer(fromScenePointer: p)))
                #expect(abs(back.x - p.x) < 1e-6 && abs(back.y - p.y) < 1e-6, "\(present) maps \(p) to \(back)")
            }
        }
    }

    private func loadedRenderer(script: String, size: String) async throws -> (WPEMetalSceneRenderer, MetalSceneFixture) {
        let fixture = try MetalSceneFixture.solidColorScene()
        let path = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["origin"] = "32 32 0"
        objects[0]["size"] = size
        objects[0]["visible"] = ["value": true, "script": script]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: path)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        try await renderer.load()
        #expect(renderer.sceneRenderSize == CGSize(width: 64, height: 64))
        return (renderer, fixture)
    }

    private func expectZone(_ zones: [CGRect], _ expected: CGRect) {
        #expect(zones.count == 1)
        guard let zone = zones.first else { return }
        for (a, b) in [(zone.minX, expected.minX), (zone.minY, expected.minY),
                       (zone.maxX, expected.maxX), (zone.maxY, expected.maxY)] {
            #expect(abs(a - b) < 1e-4, "zone \(zone) != \(expected)")
        }
    }

    @Test("A cursorClick-only layer yields one zone, published per frame, cropped by a non-matching present, cleared on cleanup")
    func clickLayerYieldsZone() async throws {
        let (renderer, fixture) = try await loadedRenderer(
            script: "export function cursorClick() {}", size: "16 16"
        )
        defer { fixture.cleanup() }
        let pipeline = try #require(renderer.renderPipeline)
        _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        // 16px layer centred in a 64px scene: scene UV 0.375...0.625 on both axes.
        expectZone(renderer.mailbox.interactiveZones, CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25))
        // A 2:1 drawable under cover keeps the middle half of the scene's height.
        renderer.surfaceDrawableSize = CGSize(width: 128, height: 64)
        expectZone(renderer.interactiveZones(pipeline: pipeline), CGRect(x: 0.375, y: 0.25, width: 0.25, height: 0.5))
        renderer.cleanup()
        #expect(renderer.mailbox.interactiveZones.isEmpty)
    }

    @Test("A layer exporting only hover handlers yields no zone")
    func hoverOnlyLayerYieldsNoZone() async throws {
        let (renderer, fixture) = try await loadedRenderer(
            script: "export function cursorEnter() {}\nexport function cursorMove() {}", size: "16 16"
        )
        defer { renderer.cleanup(); fixture.cleanup() }
        let pipeline = try #require(renderer.renderPipeline)
        #expect(renderer.interactiveZones(pipeline: pipeline).isEmpty)
    }

    @Test("A clickable layer covering more than 30% of the view yields no zone")
    func largeLayerYieldsNoZone() async throws {
        let (renderer, fixture) = try await loadedRenderer(
            script: "export function cursorDown() {}", size: "48 48"
        )
        defer { renderer.cleanup(); fixture.cleanup() }
        let pipeline = try #require(renderer.renderPipeline)
        #expect(renderer.interactiveZones(pipeline: pipeline).isEmpty)
    }
}
#endif
