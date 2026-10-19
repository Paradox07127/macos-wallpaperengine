#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

final class WPEParityVolumeSceneTests: XCTestCase {
    func testImportedRawVolumeReachesSamplerThreeDThroughProductionPlanner() async throws {
        let (renderer, queue, scratch) = try await makeRenderer(threeDShader: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("frame skipped")
        }
        await buffer.completed()
        XCTAssertNil(buffer.error)
        let draw = try XCTUnwrap(renderer.lastFrameDraws.first?.draw)
        let volume = try XCTUnwrap(draw.textures["g_Texture0"])
        XCTAssertEqual(volume.textureType, .type3D)
        XCTAssertEqual([volume.width, volume.height, volume.depth, volume.mipmapLevelCount], [4, 2, 2, 3])
        let output = try pixels(renderer.backbuffer, queue: queue)
        for y in 0 ..< 2 {
            for x in 0 ..< 4 {
                let expected: [UInt8] = [UInt8(10 + x * 40), 20, 130, 255]
                for lane in 0 ..< 4 {
                    XCTAssertLessThanOrEqual(abs(Int(output[(y * 4 + x) * 4 + lane]) - Int(expected[lane])), 1)
                }
            }
        }
    }

    func testRawVolumeCannotBecomeAValidTwoDShaderBinding() async throws {
        let (renderer, queue, scratch) = try await makeRenderer(threeDShader: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        XCTAssertEqual(renderer.skipped.count, 1)
        XCTAssertTrue(renderer.skipped.values.allSatisfy { $0.description.contains("textureDimensionMismatch") })
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("frame skipped")
        }
        await buffer.completed()
        XCTAssertNil(buffer.error)
        XCTAssertTrue(renderer.lastFrameDraws.isEmpty)
        let output = try pixels(renderer.backbuffer, queue: queue)
        XCTAssertTrue(stride(from: 0, to: output.count, by: 4).allSatisfy { output[$0 ..< $0 + 3].allSatisfy { $0 == 0 } })
    }

    func testPointTextureBorderWinsOverClampOnAllThreeAxesThroughProductionShader() async throws {
        for flags: UInt32 in [0x41, 0x43, 0x0400_0041, 0x0400_0043] {
            let (renderer, queue, scratch) = try await makeRenderer(threeDShader: true, textureFlags: flags, borderProbe: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
                return XCTFail("frame skipped")
            }
            await buffer.completed()
            XCTAssertNil(buffer.error)
            let draw = try XCTUnwrap(renderer.lastFrameDraws.first?.draw)
            let sampler = try XCTUnwrap(draw.samplers["g_Texture0SamplerState"])
            let hasBorder = flags & 0x0400_0000 != 0
            let address: D3D11TextureAddressMode = hasBorder ? .border : flags == 0x43 ? .clamp : .wrap
            XCTAssertEqual(sampler.addressU, address)
            XCTAssertEqual(sampler.addressV, address)
            XCTAssertEqual(sampler.addressW, address)
            // Six out-of-range samples, two per axis. The control wraps into the authored nonzero texels;
            // zero border must replace both negative and positive coordinates, including when clamp is set.
            let expected = hasBorder ? [0, 0, 0] : flags == 0x43 ? [38, 30, 48] : [68, 45, 73]
            let output = try pixels(renderer.backbuffer, queue: queue)
            for pixel in 0 ..< 8 {
                for lane in 0 ..< 3 {
                    XCTAssertLessThanOrEqual(abs(Int(output[pixel * 4 + lane]) - expected[lane]), 1)
                }
            }
        }
    }

    func testFileTextureAnisotropicFilterInterpolatesAllThreeBordersThroughProductionShader() async throws {
        for flags: UInt32 in [0x40, 0x42, 0x0400_0040, 0x0400_0042] {
            let (renderer, queue, scratch) = try await makeRenderer(threeDShader: true, textureFlags: flags,
                                                                    borderProbe: true, nearBorder: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
                return XCTFail("frame skipped")
            }
            await buffer.completed()
            XCTAssertNil(buffer.error)
            let draw = try XCTUnwrap(renderer.lastFrameDraws.first?.draw)
            let sampler = try XCTUnwrap(draw.samplers["g_Texture0SamplerState"])
            XCTAssertEqual(sampler.filter, .anisotropic)
            XCTAssertEqual(sampler.maxAnisotropy, 8)
            let border = flags & 0x0400_0000 != 0
            let address: D3D11TextureAddressMode = border ? .border : flags == 0x42 ? .clamp : .wrap
            XCTAssertEqual(sampler.addressU, address)
            XCTAssertEqual(sampler.addressV, address)
            XCTAssertEqual(sampler.addressW, address)
            // Constant coordinates give zero derivatives (mip0). At one quarter texel beyond each edge,
            // linear sampling mixes 3/4 outside with 1/4 inside. Border contributes zero, wrap the opposite edge.
            // Weighted negative/positive samples are 1/2 and 1/4; these expectations use authored texels directly.
            let expected: [Float] = border ? [9.375, 7.5, 11.875] : flags == 0x42 ? [37.5, 30, 47.5] : [60, 41.25, 66.25]
            let output = try pixels(renderer.backbuffer, queue: queue)
            for pixel in 0 ..< 8 {
                for lane in 0 ..< 3 {
                    XCTAssertEqual(Float(output[pixel * 4 + lane]), expected[lane], accuracy: 1)
                }
            }
        }
    }

    func testComparisonFileTextureReportsUnsupportedInsteadOfUsingAnOrdinarySampler() async throws {
        let (renderer, queue, scratch) = try await makeRenderer(threeDShader: true, textureFlags: 0x0800_0040)
        defer { try? FileManager.default.removeItem(at: scratch) }
        XCTAssertEqual(renderer.skipped.count, 1)
        XCTAssertTrue(renderer.skipped.values.allSatisfy { $0.description.contains("unsupported file texture sampler flags") })
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else { return XCTFail("frame skipped") }
        await buffer.completed()
        XCTAssertNil(buffer.error)
        XCTAssertTrue(renderer.lastFrameDraws.isEmpty)
        let output = try pixels(renderer.backbuffer, queue: queue)
        XCTAssertTrue(stride(from: 0, to: output.count, by: 4).allSatisfy { output[$0 ..< $0 + 3].allSatisfy { $0 == 0 } })
    }

    private func makeRenderer(threeDShader: Bool, textureFlags: UInt32 = 0x40, borderProbe: Bool = false,
                              nearBorder: Bool = false) async throws
        -> (WPEParityFrameRenderer, MTLCommandQueue, URL) {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "parity-volume-\(UUID().uuidString)")
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let outsideX = nearBorder ? 0.0625 : 0.125
        let outsideYZ = nearBorder ? 0.125 : 0.25
        let fragment = borderProbe ? """
        uniform sampler3D g_Texture0;
        varying vec2 v_TexCoord;
        void main() {
            float r = 0.5 * texSample3D(g_Texture0, vec3(-\(outsideX), 0.25, 0.25)).r
                    + 0.25 * texSample3D(g_Texture0, vec3(\(1 + outsideX), 0.25, 0.25)).r;
            float g = 0.5 * texSample3D(g_Texture0, vec3(0.125, -\(outsideYZ), 0.25)).g
                    + 0.25 * texSample3D(g_Texture0, vec3(0.125, \(1 + outsideYZ), 0.25)).g;
            float b = 0.5 * texSample3D(g_Texture0, vec3(0.125, 0.25, -\(outsideYZ))).b
                    + 0.25 * texSample3D(g_Texture0, vec3(0.125, 0.25, \(1 + outsideYZ))).b;
            gl_FragColor = vec4(r, g, b, 1.0);
        }
        """ : threeDShader ? """
        uniform sampler3D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = texSample3D(g_Texture0, vec3(v_TexCoord.x, 0.25, 0.75)); }
        """ : """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        let files: [String: Data] = try [
            "models/volume.json": Data(#"{"material":"materials/volume.json"}"#.utf8),
            "materials/volume.json": Data(#"{"passes":[{"shader":"volume","combos":{"TRANSFORM":1},"textures":["volume"],"blending":"normal"}]}"#.utf8),
            "materials/volume.tex": Self.rawVolume(flags: textureFlags),
            "shaders/volume.vert": Data(contentsOf: engine.appending(path: "shaders/passthrough.vert")),
            "shaders/volume.frag": Data(fragment.utf8),
        ]
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { files[$0] }, .directory(engine)])
        let scene = Data(#"{"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},"general":{"orthogonalprojection":{"width":4,"height":2},"clearcolor":"0 0 0"},"objects":[{"id":1,"image":"models/volume.json","size":"4 2","origin":"2 1 0"}]}"#.utf8)
        let document = try WPESceneDocumentParser.parse(data: scene, userValues: [:])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: .init(bloom: false), width: 4, height: 2)
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "cache")))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try await WPEParityFrameRenderer(plan: plan, device: device, queue: queue,
                                                        shaders: .init(store: store, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1))
        return (renderer, queue, scratch)
    }

    /// Native TEXV5/TEXI1 and TEXB3 raw records, xyz in dense row/slice order, with explicit depth per mip.
    private static func rawVolume(flags: UInt32 = 0x40) -> Data {
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) {
            var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        for value: UInt32 in [0, flags, 4, 2, 4, 2, 2, 0] {
            word(value)
        }
        data.append(contentsOf: "TEXB0003\0".utf8)
        for value: UInt32 in [1, .max, 3] {
            word(value)
        }
        for (width, height, depth) in [(4, 2, 2), (2, 1, 1), (1, 1, 1)] {
            var texels: [UInt8] = []
            for z in 0 ..< depth {
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        texels += [UInt8(10 + x * 40), UInt8(20 + y * 60), UInt8(30 + z * 100), 255]
                    }
                }
            }
            for value in [UInt32(width), UInt32(height), UInt32(depth), 0, UInt32(texels.count), UInt32(texels.count)] {
                word(value)
            }
            data.append(contentsOf: texels)
        }
        return data
    }

    private func pixels(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt8] {
        let output = try XCTUnwrap(queue.device.makeBuffer(length: 512, options: .storageModeShared))
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 4, height: 2, depth: 1), to: output, destinationOffset: 0,
                  destinationBytesPerRow: 256, destinationBytesPerImage: 512)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return (0 ..< 2).flatMap { y in Array(UnsafeRawBufferPointer(start: output.contents() + y * 256, count: 16)) }
    }
}

#endif
