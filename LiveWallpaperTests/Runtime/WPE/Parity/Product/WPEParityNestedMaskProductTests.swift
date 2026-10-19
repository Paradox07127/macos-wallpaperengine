#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import MetalFX
import QuartzCore
import simd
import XCTest

extension WPEParitySceneDriverTests {
    /// Native14020d6a0 draws ancestor A, draws child B into Intermediate, then multiplies B into A.
    /// The controlled MDL input uses original shaders; fixed samples distinguish intersection from either mask.
    @objc func testNestedPuppetMasksMultiplyAncestorsAtEveryRenderScale() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        _ = try XCTUnwrap(MTLFXSpatialScalerDescriptor.supportsDevice(device) ? device : nil,
                          "required nested-mask product gate needs the registered MetalFX GPU")
        let (original, compiler) = try nestedMaskRequiredInputs()
        let (document, assets) = try nestedMaskDocument(original: original)
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParityNestedMaskProductTests.Isolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required isolated XCTest defaults are absent"])
        }
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let saved = defaults.object(forKey: key)
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        // Literal physical dimensions; do not call the production size converter to make this oracle.
        for (scale, physical) in [(1.0, SIMD2(384, 256)), (0.5, SIMD2(192, 128)), (0.75, SIMD2(288, 192))] {
            defaults.set(scale, forKey: key)
            XCTAssertEqual(WPEMetalFXSpatialUpscaler.renderScale, scale)
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                                  drawableSize: CGSize(width: 384, height: 256), pixelFormat: .rgba8Unorm,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertEqual(renderer.skipped, [:])
            let layer = RecordingLayer()
            layer.device = device
            layer.pixelFormat = .rgba8Unorm
            layer.drawableSize = CGSize(width: 384, height: 256)
            layer.framebufferOnly = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            try await present(driver, layer: layer, label: "nested masks q\(scale)")
            XCTAssertEqual(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX, scale < 1)
            XCTAssertEqual(renderer.skipped, [:])
            XCTAssertEqual(renderer.pathCamera.renderTargetSize, SIMD2(384, 256))
            XCTAssertEqual(renderer.pathCamera.projection.columns.0.x, 2 / 384, accuracy: 0.000001)
            XCTAssertEqual(renderer.pathCamera.projection.columns.1.y, 2 / 256, accuracy: 0.000001)

            let frame = try XCTUnwrap(renderer.frames.first)
            let intermediate = try XCTUnwrap(renderer.renderTarget("_rt_FullAlphaMaskIntermediate"))
            let mask = try XCTUnwrap(renderer.renderTarget("_rt_FullAlphaMask"))
            for texture in [intermediate, mask] {
                XCTAssertEqual(SIMD2(texture.width, texture.height), physical)
                XCTAssertEqual(texture.pixelFormat, .r8Unorm)
                XCTAssertEqual(texture.sampleCount, 1)
            }
            XCTAssertFalse(intermediate === mask)
            let maskDraws = frame.draws.compactMap { index, value -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(draw) = value, draw.shader == "clippingmaskimage4" else { return nil }
                return (index, draw)
            }
            XCTAssertEqual(maskDraws.count, 3, "ancestor A once for its target, then ancestor A and child B")
            XCTAssertEqual(maskDraws.filter { $0.1.target == "_rt_FullAlphaMaskIntermediate" }.count, 1)
            for (index, description) in maskDraws {
                XCTAssertEqual(description.source?.materialPath, "materials/util/clippingmaskimage4.json")
                let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == index }?.draw)
                XCTAssertGreaterThan(draw.indexCount, 0)
                _ = try XCTUnwrap(draw.textures["g_Texture0"])
                _ = try XCTUnwrap(draw.textures["g_Texture1"])
                guard case let .vector(rv)? = draw.constants[.fragment]?["g_RenderVar0"], !rv.isEmpty else {
                    return XCTFail("the actual original mask draw must consume RV0")
                }
                XCTAssertEqual(rv[0], 0, "both controlled masks are non-inverted")
            }
            // These named resources are pooled and no later R8 allocation reuses them in this fixture.
            // Their post-completion readback observes the final child B and ancestor intersection, respectively.
            for id: WPEResourceID in ["_rt_FullAlphaMaskIntermediate", "_rt_FullAlphaMask"] {
                XCTAssertEqual(try XCTUnwrap(frame.resources.first { $0.id == id }).lifetime, .pooled)
            }
            let merges = frame.draws.compactMap { index, value -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(draw) = value, draw.multipliesDestination else { return nil }
                return (index, draw)
            }
            XCTAssertEqual(merges.count, 1, "the child has exactly one real ancestor merge")
            let (mergeIndex, merge) = try XCTUnwrap(merges.first)
            XCTAssertEqual(merge.objectID, "42")
            XCTAssertEqual(merge.shader, "minimalalpha")
            XCTAssertEqual(merge.source?.materialPath, "materials/util/flattexture.json")
            XCTAssertEqual(merge.geometry, .fullscreenQuad)
            XCTAssertEqual(merge.target, "_rt_FullAlphaMask")
            XCTAssertEqual(merge.reads, ["_rt_FullAlphaMaskIntermediate"])
            let encodedMerge = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == mergeIndex }?.draw)
            XCTAssertGreaterThan(encodedMerge.indexCount + encodedMerge.vertexCount, 0)
            XCTAssertTrue(try XCTUnwrap(encodedMerge.textures["g_Texture0"]) === intermediate)
            guard case let .float(alpha)? = encodedMerge.constants[.fragment]?["g_Alpha"] else {
                return XCTFail("the actual original flattexture draw must receive g_Alpha")
            }
            XCTAssertEqual(alpha, 1)

            // Native14020d6a0.c:99–145 writes I to M, copies it to V, then to P. Preserve all 16 fields,
            // including Z; a generic effect-pass ortho is not this native merge role.
            let matrices = try XCTUnwrap(renderer.uniforms(mergeIndex)).matrices
            let identity: [SIMD4<Float>] = [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                            SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)]
            for (name, matrix) in [("M", matrices.model), ("V", matrices.view), ("P", matrices.projection)] {
                for column in 0 ..< 4 {
                    XCTAssertEqual(matrix[column], identity[column], "native merge \(name), q\(scale)")
                }
            }
            guard case let .matrix(mvp)? = encodedMerge.values(for: .vertex)["g_ModelViewProjectionMatrix"] else {
                return XCTFail("the encoded merge must consume its original MVP uniform")
            }
            XCTAssertEqual(mvp.columns, [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])

            let clipped = frame.draws.compactMap { index, value -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(draw) = value, draw.source?.combos["CLIPPINGTARGET"] == 1 else { return nil }
                return (index, draw)
            }.sorted { $0.0 < $1.0 }
            XCTAssertEqual(clipped.count, 2)
            let (targetIndex, target) = try XCTUnwrap(clipped.last)
            XCTAssertEqual(target.shader, "genericimage4")
            XCTAssertTrue(target.reads.contains("_rt_FullAlphaMask"))
            let encodedTarget = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == targetIndex }?.draw)
            XCTAssertGreaterThan(encodedTarget.indexCount, 0)
            XCTAssertTrue(try XCTUnwrap(encodedTarget.textures["g_Texture8"]) === mask)

            let intermediatePixels = try nestedMaskR8Pixels(intermediate, device: device)
            let maskPixels = try nestedMaskR8Pixels(mask, device: device)
            let backbuffer = renderer.backbuffer
            XCTAssertEqual(SIMD2(backbuffer.width, backbuffer.height), physical)
            let backbufferPixels = try readBack(backbuffer, device: device)
            let drawable = try XCTUnwrap(layer.lastTexture)
            XCTAssertEqual([drawable.width, drawable.height], [384, 256])
            let shown = try readBack(drawable, device: device)
            _ = try XCTUnwrap(intermediatePixels.count == physical.x * physical.y ? true : nil)
            _ = try XCTUnwrap(maskPixels.count == physical.x * physical.y ? true : nil)
            _ = try XCTUnwrap(backbufferPixels.count == physical.x * physical.y * 4 ? true : nil)
            _ = try XCTUnwrap(shown.count == 384 * 256 * 4 ? true : nil)

            // A=[64,192]×[48,144], B=[128,256]×[96,208]; C covers the canvas.
            // Native mask shader with opaque original white inputs gives indicator functions, and DEST_COLOR
            // gives A*B. Samples are >=16 logical pixels from edges, so filtering cannot justify a missing mask.
            for (point, childB, intersection): (SIMD2<Int>, UInt8, UInt8) in [
                (SIMD2(144, 112), 255, 255), // A and B
                (SIMD2(80, 112), 0, 0), // A only: missing child multiplication must fail
                (SIMD2(224, 112), 255, 0), // B only: replacing A by B must fail
                (SIMD2(144, 176), 255, 0), // B only, below A: catches Y/extent mistakes
                (SIMD2(288, 224), 0, 0), // neither
            ] {
                let physicalPoint = SIMD2(point.x * physical.x / 384, point.y * physical.y / 256)
                let offset = physicalPoint.y * physical.x + physicalPoint.x
                XCTAssertEqual(intermediatePixels[offset], childB, "Intermediate B at \(point), q\(scale)")
                XCTAssertEqual(maskPixels[offset], intersection, "A*B mask at \(point), q\(scale)")
                for channel in 0 ..< 3 {
                    XCTAssertLessThanOrEqual(abs(Int(backbufferPixels[offset * 4 + channel]) - Int(intersection)), 1,
                                             "logical intersection BB \(point), q\(scale)")
                    let screen = (point.y * 384 + point.x) * 4
                    XCTAssertLessThanOrEqual(abs(Int(shown[screen + channel]) - Int(intersection)), 2,
                                             "logical intersection actual drawable \(point), q\(scale)")
                }
                XCTAssertEqual(shown[(point.y * 384 + point.x) * 4 + 3], 255)
            }
        }
    }

    private func nestedMaskRequiredInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        do {
            let (_, original) = try sceneInputs()
            for path in ["materials/util/clippingmaskimage4.json", "materials/util/flattexture.json",
                         "materials/util/white.tex", "shaders/clippingmaskimage4.vert", "shaders/clippingmaskimage4.frag",
                         "shaders/minimalalpha.vert", "shaders/minimalalpha.frag",
                         "shaders/genericimage4.vert", "shaders/genericimage4.frag"] {
                _ = try XCTUnwrap(original.data(path), "required original input \(path)")
            }
            // Require the real app bundle before asking its production resolver. Debug environment fallback
            // cannot make an absent shipping helper/toolchain appear to satisfy this product gate.
            let contents = Bundle.main.bundleURL.appending(path: "Contents")
            for path in ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"] {
                _ = try XCTUnwrap(FileManager.default.fileExists(atPath: contents.appending(path: path).path)
                    ? path : nil, "required bundled shader toolchain \(path)")
            }
            switch WPEParityShaderToolchain.makeCompiler() {
            case let .success(compiler): return (original, compiler)
            case let .failure(reason): throw reason
            }
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityNestedMaskProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required original assets/bundled helper unavailable: \(error)"]
            ))
        }
    }

    private func nestedMaskDocument(original: WPEParityProgramAssets) throws
        -> (WPESceneDocument, WPEParityProgramAssets) {
        let mdl = Self.nestedMaskMDL()
        let parsed = try WPEMdlParser.parse(data: mdl)
        let mesh = try XCTUnwrap(parsed.meshes.first)
        XCTAssertEqual(mesh.vertices.count, 12)
        XCTAssertEqual(mesh.indices.count, 18)
        XCTAssertEqual(mesh.parts.count, 3)
        XCTAssertEqual(mesh.clipGroups.map(\.targetPartIndices), [[1], [2]])
        XCTAssertEqual(mesh.clipGroups.map(\.sourcePartIndices), [[0], [1]])
        XCTAssertEqual(mesh.clipGroups.map(\.flags), [4, 4])
        XCTAssertEqual(parsed.bones.count, 1)
        let resolvedGroups = WPEParityPuppetClipGroup.groups(of: mesh)
        let groups = try XCTUnwrap(resolvedGroups.count == 2 ? resolvedGroups : nil)
        XCTAssertNil(groups[0].parent)
        XCTAssertEqual(groups[1].parent, 0, "every child mask part is clipped by the ancestor group")
        let modelURL = scratch.appending(path: "models/nested-mask.mdl")
        try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try mdl.write(to: modelURL)
        try nestedMaskWriteJSON(["material": "materials/nested-mask.json", "puppet": "models/nested-mask.mdl"],
                                path: "models/nested-mask.json")
        try nestedMaskWriteJSON(["passes": [["shader": "genericimage4", "textures": ["util/white"],
                                             "combos": ["LIGHTING": 0, "FOG": 0, "REFLECTION": 0],
                                             "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled",
                                             "blending": "translucent"]]], path: "materials/nested-mask.json")
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 384, "height": 256], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "camerashake": false, "cameraparallax": false],
            "objects": [["id": 42, "image": "models/nested-mask.json", "size": "384 256",
                         "origin": "192 128 0", "scale": "1 1 1", "angles": "0 0 0", "perspective": false,
                         "color": "1 1 1", "alpha": 1, "colorBlendMode": 0, "copybackground": false]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        return (document, WPEParityProgramAssets(sources: [.directory(scratch)] + original.sources))
    }

    private func nestedMaskWriteJSON(_ json: Any, path: String) throws {
        let url = scratch.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func nestedMaskR8Pixels(_ texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        XCTAssertEqual(texture.pixelFormat, .r8Unorm)
        let rowBytes = (texture.width + 255) & ~255
        let buffer = try XCTUnwrap(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes,
                  destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return (0 ..< texture.height).flatMap { row in
            Array(UnsafeBufferPointer(start: bytes + row * rowBytes, count: texture.width))
        }
    }

    /// Binary input only: MDLV23 three rectangle parts, two independent clip sets, MDLS1 identity bind.
    /// Target/source tables and flags follow the original MDLV grammar, not a replacement clip implementation.
    private static func nestedMaskMDL() -> Data {
        var mdl = NestedMaskMDLWriter()
        mdl.string("MDLV0023")
        mdl.uint32(0x0180_000B) // float3 position/normal, uint4 indices, float4 weights, float2 UV
        mdl.uint32(1) // one skin/material
        mdl.uint32(1) // one mesh
        mdl.string("materials/nested-mask.json")
        mdl.uint32(8) // segmented mesh
        for value: Float in [-192, -128, 0, 192, 128, 0] {
            mdl.float(value)
        }
        mdl.uint32(0x0180_000B)
        var vertices = NestedMaskMDLWriter()
        // Top-left, top-right, bottom-left, bottom-right. y-up local positions map through origin(192,128).
        for (left, top, right, bottom): (Float, Float, Float, Float) in [
            (64, 48, 192, 144), (128, 96, 256, 208), (0, 0, 384, 256),
        ] {
            for (x, y, u, v): (Float, Float, Float, Float) in [
                (left, top, 0, 0), (right, top, 1, 0), (left, bottom, 0, 1), (right, bottom, 1, 1),
            ] {
                for value in [x - 192, 128 - y, 0] {
                    vertices.float(value)
                }
                for value: Float in [0, 0, 1] {
                    vertices.float(value)
                }
                for _ in 0 ..< 4 {
                    vertices.uint32(0)
                }
                for value: Float in [1, 0, 0, 0] {
                    vertices.float(value)
                }
                vertices.float(u)
                vertices.float(v)
            }
        }
        mdl.uint32(UInt32(vertices.data.count))
        mdl.data.append(vertices.data)
        mdl.uint32(36) // 18 R16 indices
        for part in 0 ..< 3 {
            for index: UInt16 in [0, 2, 1, 1, 2, 3] {
                mdl.uint16(UInt16(part * 4) + index)
            }
        }
        mdl.data.append(0) // no companion UV payload
        mdl.data.append(1) // part table present
        mdl.uint32(48)
        for part in 0 ..< 3 {
            mdl.uint32(UInt32(part))
            mdl.uint32(0)
            mdl.uint32(UInt32(part * 6))
            mdl.uint32(6)
        }
        mdl.uint32(2) // two group records: targets first, then mask sources
        for (target, source): (UInt32, UInt32) in [(1, 0), (2, 1)] {
            mdl.uint32(0)
            mdl.uint32(0)
            mdl.string("util/white")
            mdl.uint32(4) // hide mask parts in the ordinary segment; still draw them in the mask prepass
            mdl.uint32(1)
            mdl.uint32(target)
            mdl.uint32(1)
            mdl.uint32(source)
        }
        mdl.string("MDLS0001")
        mdl.uint32(0) // section end absent; bounded reader uses the supplied input end
        mdl.uint32(1) // u16 bone count + u16 padding
        mdl.string("root")
        mdl.uint32(0)
        mdl.uint32(.max)
        mdl.uint32(64)
        for value: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] {
            mdl.float(value)
        }
        mdl.string("")
        return mdl.data
    }
}

private struct NestedMaskMDLWriter {
    var data = Data()

    mutating func string(_ value: String) {
        data.append(contentsOf: value.utf8)
        data.append(0)
    }

    mutating func uint32(_ value: UInt32) {
        var word = value.littleEndian
        Swift.withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }

    mutating func uint16(_ value: UInt16) {
        var word = value.littleEndian
        Swift.withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }

    mutating func float(_ value: Float) {
        uint32(value.bitPattern)
    }
}
#endif
