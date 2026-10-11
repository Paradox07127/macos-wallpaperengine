#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import os
import Testing

@Suite("WPE usershortcut icon slots", .serialized)
@MainActor
struct WPEUserShortcutIconStoreTests {
    // MARK: - Slot table

    @Test("Only usershortcut bindings enter the icon slot table, keyed by property name")
    func demandKeepsOnlyUserShortcutSlots() {
        let pipeline = Self.pipeline(id: "1.0", shader: "effects/album", bindings: WPERenderUserTextureBindings(pass: [
            WPESceneUserTextureBinding(name: "$mediaThumbnail", type: "system", slot: 0),
            WPESceneUserTextureBinding(name: "rj2", type: "usershortcut", slot: 1),
        ]))
        #expect(WPEUserShortcutIconDemand.byPassID(in: pipeline) == ["1.0": [1: "rj2"]])
        let mediaOnly = Self.pipeline(id: "1.0", shader: "effects/album", bindings: WPERenderUserTextureBindings(pass: [
            WPESceneUserTextureBinding(name: "$mediaThumbnail", type: "system", slot: 0),
        ]))
        #expect(WPEUserShortcutIconDemand.byPassID(in: mediaOnly).isEmpty)
    }

    @Test("Override beats pass beats material for an icon slot")
    func demandPrecedenceIsOverridePassMaterial() {
        let layered = WPERenderUserTextureBindings(
            material: [WPESceneUserTextureBinding(name: "fromMaterial", type: "usershortcut", slot: 0)],
            pass: [WPESceneUserTextureBinding(name: "fromPass", type: "usershortcut", slot: 0)],
            override: [WPESceneUserTextureBinding(name: "fromOverride", type: "usershortcut", slot: 0)]
        )
        #expect(WPEUserShortcutIconDemand.slots(in: layered) == [0: "fromOverride"])
        let ordinaryOverride = WPERenderUserTextureBindings(
            material: [WPESceneUserTextureBinding(name: "rj1", type: "usershortcut", slot: 0)],
            override: [WPESceneUserTextureBinding(name: "materials/plain.png", slot: 0)]
        )
        #expect(WPEUserShortcutIconDemand.slots(in: ordinaryOverride).isEmpty)
    }

    // MARK: - Store

    @Test("setIcon binds an rgba8Unorm texture, nil restores the authored one, identical bytes change nothing")
    func setIconSubstitutesAndDeduplicates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEUserShortcutIconStore(device: device)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        store.onChange = { changes.withLock { $0 += 1 } }
        let authored = try Self.solidTexture(device, red: 0, green: 0, blue: 255)
        let declarations = [0: "rj1"]
        let icon = Self.icon(red: 255, green: 0, blue: 0)

        #expect(store.setIcon(icon, forKey: "rj1"))
        let bound = try #require(store.substituting(authored, slot: 0, declarations: declarations))
        #expect(bound !== authored)
        #expect(bound.pixelFormat == .rgba8Unorm)
        #expect(store.substituting(authored, slot: 1, declarations: declarations) === authored)

        #expect(!store.setIcon(icon, forKey: "rj1"), "same bytes must not rebuild the texture")
        #expect(store.substituting(authored, slot: 0, declarations: declarations) === bound)
        #expect(changes.withLock { $0 } == 1)

        #expect(store.setIcon(nil, forKey: "rj1"))
        #expect(store.substituting(authored, slot: 0, declarations: declarations) === authored)
        #expect(changes.withLock { $0 } == 2)
        #expect(!store.setIcon(nil, forKey: "rj1"))
    }

    // MARK: - Builtin dispatch

    @Test("A builtin image pass declaring a usershortcut slot samples the icon, else the fallback", arguments: ["genericimage2", "genericimage4"])
    func builtinImagePassBindsIcon(shader: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let store = WPEUserShortcutIconStore(device: device)
        store.setDeclarations(["cover.0": [0: "rj1"]])
        executor.userShortcutIconStore = store
        let placeholder = try Self.solidTexture(device, red: 0, green: 0, blue: 255)
        func center() throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let output = try executor.render(
                pipeline: Self.coverPipeline(shader: shader),
                size: CGSize(width: 4, height: 4),
                textures: ["materials/cover.png": placeholder]
            )
            return try Self.readPixel(output, x: 2, y: 2)
        }

        let fallback = try center()
        #expect(fallback.b > 150 && fallback.r < 100, "no icon: the author's fallback texture must show, got \(fallback)")

        store.setIcon(Self.icon(red: 230, green: 0, blue: 0), forKey: "rj1")
        let withIcon = try center()
        #expect(withIcon.r > 150, "the usershortcut slot must carry the icon, not the blue fallback")
        #expect(withIcon.b < 100)

        store.setIcon(nil, forKey: "rj1")
        let cleared = try center()
        #expect(cleared.b > 150 && cleared.r < 100, "a cleared icon must restore the fallback, got \(cleared)")
    }

    #if DEBUG
    @Test("A transparent icon samples on the GPU as straight RGBA")
    func transparentIconPreservesStraightAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        // Premultiplied source pixels: straight RGB is (192,128,64) at alpha 128.
        let pixel: [UInt8] = [96, 64, 32, 128]
        let source = try Self.premultipliedImage(rgba: (0 ..< 8 * 8).flatMap { _ in pixel }, edge: 8)
        let image = try #require(UserShortcutIconRenderer.rasterize(source))
        let store = WPEUserShortcutIconStore(device: device)
        store.setIcon(image, forKey: "rj1")
        let texture = try #require(store.substituting(nil, slot: 0, declarations: [0: "rj1"]))

        let center = image.width / 2
        let probe = try WPEOraclePixelProbe.sample(
            texture: texture, coordinates: [[center, center]], commandQueue: executor.commandQueue
        )
        let samples = try #require(probe["samples"] as? [[String: Any]])
        let sample = try #require(samples.first?["storageRGBA"] as? [Double])
        let expected = [192.0, 128, 64, 128].map { $0 / 255 }
        #expect(zip(sample, expected).allSatisfy { abs($0 - $1) <= 2.0 / 255 },
                "icon must not publish premultiplied RGB as a straight image: \(sample)")
    }
    #endif

    // MARK: - Preflight

    @Test("An effect-override usershortcut binding is consumed; an untyped unknown name is still unsupported")
    func preflightTreatsUserShortcutAsConsumed() throws {
        func entries(_ binding: [String: Any]) throws -> [WPEShaderImplementationInventoryEntry] {
            let payload: [String: Any] = [
                "camera": ["center": "0 0 0"],
                "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
                "objects": [[
                    "id": 7,
                    "name": "Shortcut",
                    "image": "models/rj.json",
                    "effects": [[
                        "id": 9,
                        "name": "Icon",
                        "file": "effects/icon/effect.json",
                        "passes": [["usertextures": [binding]]],
                    ]],
                ]],
            ]
            let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: payload))
            return WPEShaderImplementationInventory.preflightEntries(document: document)
        }

        #expect(try entries(["name": "rj1", "type": "usershortcut"]).isEmpty)
        #expect(try entries(["name": "$effectMask"]).count == 1)
    }

    // MARK: - Fixtures

    static func icon(red: UInt8, green: UInt8, blue: UInt8) -> WPEUserShortcutIconImage {
        WPEUserShortcutIconImage(rgba: (0 ..< 4 * 4).flatMap { _ in [red, green, blue, 255] }, width: 4, height: 4)
    }

    private static func pipeline(id: String, shader: String, bindings: WPERenderUserTextureBindings) -> WPEPreparedRenderPipeline {
        let pass = WPERenderPass(
            id: id, phase: .effect(file: "effects/album/effect.json"), shader: shader, source: .previous, target: .scene,
            textures: [:], binds: [:], constants: [:], combos: [:], userTextureBindings: bindings,
            blending: "normal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "1", objectName: "Album", imagePath: "materials/album.png", materialPath: nil, geometry: .identity,
            compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass]
        )
        return WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(graphLayer: layer, passes: [
            WPEPreparedRenderPass(pass: pass, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:]),
        ])])
    }

    private static func coverPipeline(shader: String) -> WPEPreparedRenderPipeline {
        let material = WPERenderPass(
            id: "cover.0", phase: .material, shader: shader, source: .image("materials/cover.png"),
            target: .scene, textures: [0: .image("materials/cover.png")], binds: [:], constants: [:], combos: [:],
            userTextureBindings: WPERenderUserTextureBindings(
                override: [WPESceneUserTextureBinding(name: "rj1", type: "usershortcut", slot: 0)]
            ),
            blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "1080", objectName: "Cover", imagePath: "materials/cover.png", materialPath: nil,
            geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [material]
        )
        return WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(graphLayer: layer, passes: [
            WPEPreparedRenderPass(pass: material, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:]),
        ])])
    }

    private static func solidTexture(_ device: MTLDevice, red: UInt8, green: UInt8, blue: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: 4, height: 4, mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = (0 ..< 4 * 4).flatMap { _ in [red, green, blue, 255] }
        texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 4 * 4)
        return texture
    }

    private static func premultipliedImage(rgba: [UInt8], edge: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        return try #require(CGImage(
            width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: edge * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private static func readPixel(_ texture: MTLTexture, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let staged = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(texture))
        var bytes = [UInt8](repeating: 0, count: staged.width * staged.height * 4)
        staged.getBytes(
            &bytes, bytesPerRow: staged.width * 4, from: MTLRegionMake2D(0, 0, staged.width, staged.height), mipmapLevel: 0
        )
        let index = (y * staged.width + x) * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }
}
#endif
