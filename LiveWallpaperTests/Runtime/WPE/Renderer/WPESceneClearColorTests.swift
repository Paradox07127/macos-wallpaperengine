import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import Testing

@MainActor
@Suite("WPE scene clear color (general.clearcolor / clearenabled)")
struct WPESceneClearColorTests {
    private struct Pixel: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }

    @Test("clearcolor is the raw UNORM scene backdrop with alpha 1", arguments: [
        ("0.7 0.7 0.7", [UInt8(178), 178, 178]),
        ("0.2 0.4 0.6", [UInt8(51), 102, 153]),
    ])
    func clearColorIsRawUnorm(clearColor: String, expected: [UInt8]) async throws {
        let (renderer, fixture) = try makeRenderer(general: ["clearcolor": clearColor])
        defer { renderer.cleanup(); fixture.cleanup() }
        try await renderer.load()
        let output = try #require(renderer.outputTexture)
        #expect(try pixel(output, x: 2, y: 2) == Pixel(r: expected[0], g: expected[1], b: expected[2], a: 255))
        #expect(try pixel(output, x: 128, y: 64) == Pixel(r: 255, g: 0, b: 0, a: 255))
    }

    @Test("A scene without clearcolor keeps the opaque black backdrop")
    func missingClearColorStaysBlack() async throws {
        let (renderer, fixture) = try makeRenderer(general: [:])
        defer { renderer.cleanup(); fixture.cleanup() }
        try await renderer.load()
        let output = try #require(renderer.outputTexture)
        #expect(try pixel(output, x: 2, y: 2) == Pixel(r: 0, g: 0, b: 0, a: 255))
        #expect(try pixel(output, x: 128, y: 64) == Pixel(r: 255, g: 0, b: 0, a: 255))
    }

    @Test("clearenabled false keeps the previous frame instead of clearing")
    func clearDisabledPreservesPreviousFrame() async throws {
        let (renderer, fixture) = try makeRenderer(general: ["clearcolor": "0.7 0.7 0.7", "clearenabled": false])
        defer { renderer.cleanup(); fixture.cleanup() }
        try await renderer.load()
        let first = try #require(renderer.outputTexture)
        #expect(try pixel(first, x: 2, y: 2) == Pixel(r: 178, g: 178, b: 178, a: 255),
                "the first frame has no previous content and must fall back to clearcolor")

        try paint(first, red: 0, green: 1, blue: 0, alpha: 1)
        renderer.executor.synchronizeFrameCompletion = true
        let second = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        #expect(second !== first)
        #expect(try pixel(second, x: 2, y: 2) == Pixel(r: 0, g: 255, b: 0, a: 255),
                "the second frame cleared the scene instead of keeping the previous frame")
        #expect(try pixel(second, x: 128, y: 64) == Pixel(r: 255, g: 0, b: 0, a: 255))
    }

    private func makeRenderer(general extra: [String: Any]) throws -> (WPEMetalSceneRenderer, MetalSceneFixture) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESceneClearColor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var general: [String: Any] = ["orthogonalprojection": ["width": 256, "height": 128]]
        general.merge(extra) { _, new in new }
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": general,
            "objects": [[
                "id": "red", "name": "Red", "type": "image", "image": "models/util/solidlayer.json",
                "origin": "128 64 0", "size": "32 32", "color": "1 0 0", "alpha": 1,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: scene).write(to: root.appendingPathComponent("scene.json"))
        let fixture = MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 256, height: 128), device: device
        )
        return (renderer, fixture)
    }

    private func paint(_ texture: MTLTexture, red: Double, green: Double, blue: Double, alpha: Double) throws {
        let queue = try #require(texture.device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: red, green: green, blue: blue, alpha: alpha)
        try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func pixel(_ texture: MTLTexture, x: Int, y: Int) throws -> Pixel {
        try #require(texture.pixelFormat == .rgba8Unorm)
        let staged = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(texture))
        var bytes = [UInt8](repeating: 0, count: 4)
        staged.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return Pixel(r: bytes[0], g: bytes[1], b: bytes[2], a: bytes[3])
    }
}
