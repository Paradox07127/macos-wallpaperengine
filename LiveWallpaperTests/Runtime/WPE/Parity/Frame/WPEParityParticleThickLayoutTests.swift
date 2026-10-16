#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

/// genericparticle compiled by wpe-shaderc: the 60-byte THICKFORMAT vertex must reach a_Color as the particle colour.
final class WPEParityParticleThickLayoutTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-thick-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testThinSpriteDrawsItsRedColour() async throws {
        try await assertRedParticle(renderer: "sprite", texture: "white", thick: false)
    }

    func testSpriteTrailDrawsItsRedColour() async throws {
        try await assertRedParticle(renderer: "spritetrail", texture: "white", thick: true)
    }

    func testSpriteSheetSpriteDrawsItsRedColour() async throws {
        try await assertRedParticle(renderer: "sprite", texture: "sheet", thick: true)
    }

    private func assertRedParticle(renderer kind: String, texture: String, thick: Bool,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        // A downward velocity read as a_Color would give (0, −100, 0): black, not red.
        let particle: [String: Any] = [
            "maxcount": 1, "material": "materials/particle.json", "renderer": [["name": kind]],
            "emitter": [["name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10],
                            ["name": "sizerandom", "min": 16, "max": 16],
                            ["name": "alpharandom", "min": 1, "max": 1],
                            ["name": "colorrandom", "min": "255 0 0", "max": "255 0 0"],
                            ["name": "velocityrandom", "min": "0 -100 0", "max": "0 -100 0"]],
        ]
        let (renderer, queue) = try await makeRenderer(particle: particle, texture: texture)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)", file: file, line: line)
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.0625) else {
            return XCTFail("skipped", file: file, line: line)
        }
        await buffer.completed()
        XCTAssertNil(buffer.error, file: file, line: line)
        let draws = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
        XCTAssertEqual(draws.count, 1, file: file, line: line)
        let draw = try XCTUnwrap(draws.first?.draw, file: file, line: line)

        let inputs = draw.pipeline.vertex.reflection.vertexInputs.sorted { $0.index < $1.index }
        let expectedNames = thick ? ["POSITION0", "TEXCOORD0", "COLOR0", "TEXCOORD1"]
            : ["POSITION0", "TEXCOORD0", "COLOR0"]
        XCTAssertEqual(inputs.map { $0.name.uppercased() }, expectedNames, file: file, line: line)
        XCTAssertEqual(inputs.map(\.columns), thick ? [3, 4, 4, 4] : [3, 4, 4], file: file, line: line)
        // Stage-in packs inputs tightly in index order, so each semantic's bytes start at the running column sum.
        var offsets: [String: Int] = [:]
        var offset = 0
        for input in inputs {
            offsets[input.name.uppercased()] = offset
            offset += input.columns * 4
        }
        let bytes = draw.vertexBuffer.contents().advanced(by: draw.vertexBufferOffset)
        func vec4(_ name: String) -> [Float]? {
            offsets[name].map { base in (0 ..< 4).map { bytes.load(fromByteOffset: base + $0 * 4, as: Float.self) } }
        }
        XCTAssertEqual(vec4("COLOR0"), [1, 0, 0, 1], file: file, line: line)
        if thick {
            XCTAssertEqual(vec4("TEXCOORD1").map { Array($0[0 ..< 3]) }, [0, -100, 0], file: file, line: line)
        }

        let pixel = try centerPixel(renderer.backbuffer, queue: queue)
        XCTAssertEqual(pixel, [255, 0, 0, 255], file: file, line: line)
    }

    private func makeRenderer(particle: [String: Any], texture: String) async throws
        -> (WPEParityFrameRenderer, MTLCommandQueue) {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        guard FileManager.default.fileExists(atPath: engine.appending(path: "shaders/genericparticle.vert").path) else {
            throw XCTSkip("Needs WPE's assets (or WPE_ASSETS_DIR)")
        }
        let material: [String: Any] = ["passes": [["shader": "genericparticle", "blending": "translucent",
                                                   "textures": [texture], "combos": [String: Int]()]]]
        let files: [String: Data] = try [
            "particles/root.json": JSONSerialization.data(withJSONObject: particle),
            "materials/particle.json": JSONSerialization.data(withJSONObject: material),
            "materials/white.tex": Self.whiteTexture(),
            "materials/sheet.tex": Self.whiteSheet(),
        ]
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { files[$0] }, .directory(engine)])
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "particle": "particles/root.json", "origin": "32 32 0"]],
        ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: .init(bloom: false),
                                          width: 64, height: 64)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "cache")))
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: queue,
            shaders: .init(store: store, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1),
            particleSeed: 7, particleArenaBytes: nil
        )
        return (renderer, queue)
    }

    private func centerPixel(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt8] {
        let data = try XCTUnwrap(queue.device.makeBuffer(length: 256, options: .storageModeShared))
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: texture.width / 2, y: texture.height / 2, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: data, destinationOffset: 0,
                  destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return Array(UnsafeRawBufferPointer(start: data.contents(), count: 4))
    }

    /// TEXV0004 RGBA8888 1×1 white, no sprite flag.
    private static func whiteTexture() -> Data {
        var data = Data("TEXV0004\0".utf8)
        for value: UInt32 in [0, 0, 1, 1, 1, 1, 1, 1, 1, 4] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [255, 255, 255, 255])
        return data
    }

    /// RGBA8888 4×4 white with TEXI flag 0x4 and one whole-image TEXS frame: a one-frame sprite sheet.
    private static func whiteSheet() -> Data {
        var data = Data()
        func magic(_ text: String) {
            data.append(contentsOf: text.utf8)
            data.append(0)
        }
        func int(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let side: Int32 = 4
        let pixels = Data(repeating: 255, count: Int(side * side) * 4)
        magic("TEXV0005")
        magic("TEXI0001")
        int(Int32(WPETexFormat.rgba8888.rawValue))
        int(0x4)
        for value in [side, side, side, side, 0] {
            int(value)
        }
        magic("TEXB0003")
        for value in [1, -1, 1, side, side, 0, Int32(pixels.count), Int32(pixels.count)] {
            int(value)
        }
        data.append(pixels)
        // TEXS3: frame count, gif size, then image, time, x, y, width, widthY, heightX, height.
        magic("TEXS0003")
        for value in [1, side, side, 0] {
            int(value)
        }
        for value: Float in [1, 0, 0, Float(side), 0, 0, Float(side)] {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
