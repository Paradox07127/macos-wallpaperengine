#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore
import simd
import XCTest

extension WPEParitySceneDriverTests {
    /// Only a static child's base material requests mip history. Its real original VS/GS must still produce
    /// the sprite and its actual fragment must read the previous frame's LOD2, before this frame's tail refresh.
    @objc func testChildOnlyMipMaterialReachesOriginalParticleGeometryShaderAndSamplesHistory() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (original, compiler) = try childMipRequiredInputs()
        let (document, assets) = try childMipDocument(original: original)
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParityMipMappedParticleProductTests.Isolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required isolated XCTest defaults are absent"])
        }
        let scaleKey = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let savedScale = defaults.object(forKey: scaleKey)
        defaults.set(1.0, forKey: scaleKey)
        defer {
            if let savedScale {
                defaults.set(savedScale, forKey: scaleKey)
            } else {
                defaults.removeObject(forKey: scaleKey)
            }
        }
        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityChildOnlyMip")
        defer { suite.discard() }
        suite.defaults.set(true, forKey: WPEParityProductSettings.mipMappedFrameBufferDefaultsKey)
        let descriptor = SceneDescriptor(workshopID: "child-only-mip", cacheRelativePath: "wpe-cache/child-only-mip",
                                         entryFile: "scene.json", capabilityTier: .degraded,
                                         presetID: "child-only-mip", presetSnapshot: [:])
        let settings = try WPEParityProductSettings.make(descriptor: descriptor, device: device,
                                                         defaults: suite.defaults, bloomEnabled: false)
        XCTAssertTrue(settings.mipMappedFrameBufferEnabled)
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: settings,
                              drawableSize: CGSize(width: 64, height: 64), pixelFormat: .rgba8Unorm_srgb,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertEqual(renderer.skipped, [:], "request discovery alone must not hide a rejected child texture read")
        XCTAssertEqual(renderer.particleMaterialSkips, [:])
        XCTAssertTrue(renderer.fallbackTextures.isEmpty)
        let history = try XCTUnwrap(renderer.renderTarget("_rt_MipMappedFrameBuffer"))
        XCTAssertEqual([history.width, history.height, history.sampleCount], [64, 64, 1])
        XCTAssertEqual(history.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(history.mipmapLevelCount, 3, "Native count includes the base level")
        let queue = driver.executor.textureSourceCommandQueue
        let fresh = try childMipBytes(history, level: 2, queue: queue)
        XCTAssertTrue(stride(from: 0, to: fresh.count, by: 4).allSatisfy {
            fresh[$0] == 0 && fresh[$0 + 1] == 0 && fresh[$0 + 2] == 0
        }, "the real LOD2 must be safe black before any frame, including a child-only request")

        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = CGSize(width: 64, height: 64)
        layer.framebufferOnly = false
        layer.colorspace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let colors: [SIMD4<Float>] = [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                      SIMD4(0, 0, 1, 0), SIMD4(1, 0, 0, 0)]
        let rgb = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 0, 0]]
        for frame in colors.indices {
            XCTAssertTrue(renderer.state.set(.color, of: "1", to: colors[frame]))
            try await present(driver, layer: layer, label: "child-only mip frame\(frame)")
            XCTAssertEqual(renderer.skipped, [:])
            XCTAssertEqual(renderer.particleMaterialSkips, [:])
            XCTAssertTrue(renderer.fallbackTextures.isEmpty)
            XCTAssertEqual(renderer.droppedParticleBatches, 0)
            XCTAssertFalse(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
            XCTAssertEqual(try XCTUnwrap(renderer.particleLiveCount("2")), 1)
            let particles = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
            // WPE clamps the first simulation step to1e-4; the zero-delay instantaneous child is already born.
            XCTAssertEqual(particles.count, 1)
            let entry = try XCTUnwrap(particles.first)
            guard case let .scene(description)? = renderer.frames[0].draws[entry.operation],
                  case let .particles(key) = description.geometry else {
                return XCTFail("the actual point draw must belong to the child particle prototype")
            }
            XCTAssertEqual(key.objectID, "2")
            XCTAssertEqual(key.path, [.staticChild(0)])
            XCTAssertEqual(key.renderer, 0)
            XCTAssertEqual(description.shader, "child-only-mip-particle")
            let draw = entry.draw
            XCTAssertNotNil(draw.pipeline.geometry, "the pinned original GS must actually execute")
            XCTAssertEqual(draw.primitiveType, .point)
            XCTAssertEqual(draw.vertexCount, 1)
            let birth = draw.vertexBuffer.contents().advanced(by: draw.vertexBufferOffset)
            for lane in 0 ..< 3 {
                XCTAssertEqual(birth.load(fromByteOffset: lane * 4, as: Float.self), 0)
            }
            XCTAssertEqual(birth.load(fromByteOffset: 40, as: Float.self), 1, "the original vertex colour alpha is opaque")
            XCTAssertTrue(try XCTUnwrap(draw.textures["g_Texture1"]) === history,
                          "the real child slot must sample the actual pooled mip history, not a transparent fallback")
            _ = try XCTUnwrap(draw.textures["g_Texture0"])
            guard case let .float(mips)? = draw.constants[.fragment]?["g_Texture1MipMapInfo"] else {
                return XCTFail("the original uniform bridge must reach the controlled LOD fragment")
            }
            XCTAssertEqual(mips, 3)
            let expectedChild = frame == 0 ? [0, 0, 0] : rgb[frame - 1]
            // The actual child is centred at(16,32), size16. UV(.75,.5) samples a footprint around(48,32),
            // wholly outside that child. These fixed literals do not come from renderer matrices or source pixels.
            try childMipAssertPixel(readBack(renderer.backbuffer, device: device), width: 64, x: 16, y: 32,
                                    rgb: expectedChild, label: "raw child previous color frame\(frame)")
            let shown = try readBack(XCTUnwrap(layer.lastTexture), device: device)
            try childMipAssertPixel(shown, width: 64, x: 16, y: 32, rgb: expectedChild,
                                    label: "actual displayed child frame\(frame)")
            try childMipAssertPixel(shown, width: 64, x: 48, y: 32, rgb: rgb[frame],
                                    label: "actual displayed current background frame\(frame)")
            try childMipAssertPixel(childMipBytes(history, level: 2, queue: queue), width: 16,
                                    x: 12, y: 8, rgb: rgb[frame], alpha: nil,
                                    label: "tail copy and real generated high mip frame\(frame)")
        }
    }

    private func childMipRequiredInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        do {
            let (_, assets) = try sceneInputs()
            for (path, expected) in [
                ("shaders/genericparticle.vert", "43fd60ac760a57072b5e57ce93f46142c22b2f19aa0942bcf47cfd58752f6224"),
                ("shaders/genericparticle.geom", "b0047bfbbff1da70654681a06885ea4893ca7ccd7b7647bbbe6b04ec7fd4ba13"),
                ("shaders/genericparticle.frag", "aed28ef81a5d870c07bc6cfa6bd17b6adf388efb352bd1fd8d1fd3fc0dbf7cd5"),
                ("shaders/common_particles.h", "a8a73e28ea5e72c7628d032a11e5f223a996f89fbe9e8318d71b483f0e5078be"),
            ] {
                let bytes = try XCTUnwrap(assets.data(path), "required original particle source \(path)")
                XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected)
            }
            for path in ["materials/util/white.tex", "materials/util/solidlayer.json", "models/util/solidlayer.json"] {
                _ = try XCTUnwrap(assets.data(path), "required original producer/input \(path)")
            }
            let contents = Bundle.main.bundleURL.appending(path: "Contents")
            for path in ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"] {
                _ = try XCTUnwrap(FileManager.default.fileExists(atPath: contents.appending(path: path).path)
                    ? path : nil, "required bundled shader toolchain \(path)")
            }
            switch WPEParityShaderToolchain.makeCompiler() {
            case let .success(compiler): return (assets, compiler)
            case let .failure(reason): throw reason
            }
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityMipMappedParticleProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required original assets/bundled helper unavailable: \(error)"]
            ))
        }
    }

    private func childMipDocument(original: WPEParityProgramAssets) throws
        -> (WPESceneDocument, WPEParityProgramAssets) {
        let fragment = """
        uniform sampler2D g_Texture0; // {"default":"util/white"}
        uniform sampler2D g_Texture1; // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
        uniform float g_Texture1MipMapInfo;
        varying vec2 v_TexCoord;
        varying vec4 v_Color;
        void main() {
            // The original white texture has alpha252 in higher mips; use its opaque LOD0 to isolate history.
            float alpha = texSample2DLod(g_Texture0, v_TexCoord, 0.0).a * v_Color.a;
            float lod = min(2.0, max(0.0, g_Texture1MipMapInfo - 1.0));
            gl_FragColor = vec4(texSample2DLod(g_Texture1, vec2(0.75, 0.5), lod).rgb, alpha);
        }
        """
        let parent: [String: Any] = ["maxcount": 1, "material": "materials/child-mip-parent.json",
                                     "renderer": [], "emitter": [],
                                     "children": [["name": "particles/child-mip-leaf.json"]]]
        let child: [String: Any] = [
            "maxcount": 1, "material": "materials/child-mip-leaf.json", "renderer": [["name": "sprite"]],
            "emitter": [["name": "sphererandom", "origin": "0 0 0", "distancemax": 0, "rate": 0, "instantaneous": 1]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10],
                            ["name": "sizerandom", "min": 16, "max": 16],
                            ["name": "alpharandom", "min": 1, "max": 1],
                            ["name": "colorrandom", "min": "255 255 255", "max": "255 255 255"]],
        ]
        func material(_ shader: String) -> [String: Any] {
            ["passes": [["shader": shader, "textures": ["util/white"],
                         "combos": ["FOG": 0, "LIGHTING": 0, "REFRACT": 0], "blending": "translucent",
                         "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled"]]]
        }
        let files: [String: Data] = try [
            "particles/child-mip-root.json": JSONSerialization.data(withJSONObject: parent),
            "particles/child-mip-leaf.json": JSONSerialization.data(withJSONObject: child),
            "materials/child-mip-parent.json": JSONSerialization.data(withJSONObject: material("genericparticle")),
            "materials/child-mip-leaf.json": JSONSerialization.data(withJSONObject: material("child-only-mip-particle")),
            "shaders/child-only-mip-particle.vert": XCTUnwrap(original.data("shaders/genericparticle.vert")),
            "shaders/child-only-mip-particle.geom": XCTUnwrap(original.data("shaders/genericparticle.geom")),
            "shaders/child-only-mip-particle.frag": Data(fragment.utf8),
        ]
        // The parent remains the untouched original shader; only the child alias selects the controlled sampler.
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "camerafade": false],
            "objects": [
                ["id": 1, "image": "models/util/solidlayer.json", "size": "64 64", "origin": "32 32 0",
                 "color": "1 0 0", "solid": true],
                ["id": 2, "particle": "particles/child-mip-root.json", "origin": "16 32 0"],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        var flags = WPEEngineComboFlags()
        flags.orthographicProjection = true
        let probes = WPEParityParticleScene.materialProbes(document: document, assets: assets, engineFlags: flags)
        XCTAssertEqual(probes.count, 2)
        guard let root = probes.first(where: { $0.path.isEmpty }),
              let leaf = probes.first(where: { $0.path == [.staticChild(0)] }),
              case let .ready(rootProgram, rootNames) = root.material,
              case let .ready(childProgram, childNames) = leaf.material else {
            throw NSError(domain: "WPEParityMipMappedParticleProductTests.RequiredProbes", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Both independent base material probes must resolve"])
        }
        XCTAssertEqual(rootProgram.shader, "genericparticle")
        XCTAssertFalse(rootNames.values.contains("_rt_MipMappedFrameBuffer"), "root must not accidentally qualify the scene")
        XCTAssertEqual(childProgram.shader, "child-only-mip-particle")
        XCTAssertEqual(childNames[1], "_rt_MipMappedFrameBuffer")
        XCTAssertNotNil(childProgram.hlsl.geometry)
        return (document, assets)
    }

    private func childMipAssertPixel(_ bytes: [UInt8], width: Int, x: Int, y: Int, rgb: [Int], alpha: Int? = 255,
                                     label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let offset = (y * width + x) * 4
        _ = try XCTUnwrap(offset >= 0 && offset + 3 < bytes.count ? true : nil, label, file: file, line: line)
        for channel in 0 ..< 3 {
            XCTAssertLessThanOrEqual(abs(Int(bytes[offset + channel]) - rgb[channel]), 1,
                                     "\(label), channel\(channel)", file: file, line: line)
        }
        if let alpha {
            XCTAssertEqual(Int(bytes[offset + 3]), alpha, label, file: file, line: line)
        }
    }

    /// Read actual generated LOD2 on the producer queue; no direct writes or prefilled history output.
    private func childMipBytes(_ texture: MTLTexture, level: Int, queue: MTLCommandQueue) throws -> [UInt8] {
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
        let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
        let row = (width * 4 + 255) & ~255
        let buffer = try XCTUnwrap(texture.device.makeBuffer(length: row * height, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: row, destinationBytesPerImage: row * height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        let bytes = UnsafeRawBufferPointer(start: buffer.contents(), count: row * height)
        return (0 ..< height).flatMap { Array(bytes[($0 * row) ..< ($0 * row + width * 4)]) }
    }
}
#endif
