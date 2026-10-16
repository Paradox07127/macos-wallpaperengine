#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

extension WPEParitySceneDriverTests {
    /// A plain image layer samples only the TEXI image part of a padded albedo (140209360.c:53-59); the effect and
    /// encoded-TEX cases cover the composite step and the already-unpadded upload.
    @MainActor @objc func testPaddedAlbedoDrawsOnlyItsImagePart() async throws {
        XCTAssertEqual(WPEMetalFXSpatialUpscaler.renderScale, 1, "Required isolated native-size product gate")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (original, compiler) = try missingTextureInputs()
        for (label, effect, encoded) in [("plain", false, false), ("effect", true, false), ("encoded", false, true)] {
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            let (sceneJSON, assets) = try paddedScene(original: original, effect: effect, encoded: encoded)
            let document = try WPESceneDocumentParser.parse(data: sceneJSON, userValues: [:])
            try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                                  drawableSize: CGSize(width: 64, height: 32), pixelFormat: .rgba8Unorm,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            XCTAssertTrue(driver.didLoad, label)
            let layer = RecordingLayer()
            layer.device = device
            layer.pixelFormat = .rgba8Unorm
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.drawableSize = CGSize(width: 64, height: 32)
            layer.framebufferOnly = false
            try await present(driver, layer: layer, label: label)
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(label): \(renderer.skipped)")
            let raw = try readBack(renderer.backbuffer, device: renderer.backbuffer.device)
            let (width, height) = (renderer.backbuffer.width, renderer.backbuffer.height)
            XCTAssertEqual([width, height], [64, 32], label)
            func pixel(_ x: Int, _ y: Int) -> [Int] {
                let at = (y * width + x) * 4
                return Array(raw[at ..< at + 4]).map(Int.init)
            }
            var (minX, minY, maxX, maxY) = (Int.max, Int.max, Int.min, Int.min)
            var green: [[Int]] = []
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let value = pixel(x, y)
                    if value[1] > 128, value[0] < 128 {
                        green.append([x, y])
                    }
                    guard value[0] > 128, value[1] < 128 else { continue }
                    (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                }
            }
            XCTAssertEqual(green.count, 0, "\(label): padding texels drawn at \(green.prefix(8))")
            // Quad centred at (32, 16) with size 48×24 covers pixels 8–55 × 4–27.
            XCTAssertEqual([minX, minY, maxX, maxY], [8, 4, 55, 27], "\(label) red region")
            for (x, y) in [(54, 16), (32, 26)] {
                let value = pixel(x, y)
                XCTAssertTrue(value[0] > 128 && value[1] < 128, "\(label) pixel (\(x), \(y)): \(value)")
            }
        }
    }

    /// One 48×24 image layer whose albedo is a 64×32 TEX with a 48×24 image part (red) and green padding;
    /// `encoded` replaces the raw payload with a 48×24 red PNG, `effect` adds a passthrough effect.
    private func paddedScene(original: WPEParityProgramAssets, effect: Bool,
                             encoded: Bool) throws -> (Data, WPEParityProgramAssets) {
        let pass: [String: Any] = ["shader": "passthrough", "textures": ["padded-product"],
                                   "combos": ["TRANSFORM": 1], "blending": "normal"]
        var tex = Data("TEXV0005\0TEXI0001\0".utf8)
        func word(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { tex.append(contentsOf: $0) }
        }
        for value: UInt32 in [UInt32(WPETexFormat.rgba8888.rawValue), 3, 64, 32, 48, 24, 0] {
            word(value)
        }
        tex.append(contentsOf: "TEXB0003\0".utf8)
        if encoded {
            let png = try redPNG(width: 48, height: 24)
            for value: UInt32 in [1, 13, 1, 48, 24, 0, UInt32(png.count), UInt32(png.count)] {
                word(value)
            }
            tex.append(png)
        } else {
            for value: UInt32 in [1, .max, 1, 64, 32, 0, 64 * 32 * 4, 64 * 32 * 4] {
                word(value)
            }
            for y in 0 ..< 32 {
                for x in 0 ..< 64 {
                    tex.append(contentsOf: x < 48 && y < 24 ? [255, 0, 0, 255] : [0, 255, 0, 255])
                }
            }
        }
        let files: [String: Data] = try [
            "models/padded-product.json": JSONSerialization.data(withJSONObject: [
                "material": "materials/padded-product.json",
            ]),
            "materials/padded-product.json": JSONSerialization.data(withJSONObject: ["passes": [pass]]),
            "materials/padded-pass.json": JSONSerialization.data(withJSONObject: [
                "passes": [["shader": "passthrough", "combos": ["TRANSFORM": 1], "blending": "normal"]],
            ]),
            "effects/padded-product.json": JSONSerialization.data(withJSONObject: [
                "passes": [["material": "materials/padded-pass.json"]],
            ]),
            "materials/padded-product.tex": tex,
        ]
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { files[$0] }] + original.sources)
        var object: [String: Any] = ["id": 1, "name": "padded", "image": "models/padded-product.json",
                                     "origin": "32 16 0", "size": "48 24", "alpha": 1]
        if effect {
            object["effects"] = [["id": 4, "file": "effects/padded-product.json"]]
        }
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 32], "clearcolor": "0 0 1",
                        "clearenabled": true, "bloom": false, "hdr": false, "camerafade": false],
            "objects": [object],
        ]
        return try (JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), assets)
    }

    private func redPNG(width: Int, height: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
#endif
