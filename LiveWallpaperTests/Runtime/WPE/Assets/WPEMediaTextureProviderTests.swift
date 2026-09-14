import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing
import UniformTypeIdentifiers

/// 本文件不许触到 `NowPlayingMonitor.shared`(用户真实播放器):
/// 只走注入的 `FakeNowPlayingSource`(在 WPESceneMediaEventDispatchTests)。
@Suite("WPE $mediaThumbnail system texture", .serialized)
@MainActor
struct WPEMediaTextureProviderTests {
    // MARK: - Demand gate

    @Test("A pipeline with no $media user texture declares no demand")
    func pipelineWithoutMediaBindingsDeclaresNoDemand() {
        let pipeline = Self.pipeline(bindings: .empty)
        #expect(WPEMediaTextureDemand.byPassID(in: pipeline).isEmpty)
    }

    @Test("A pass declaring $mediaThumbnail declares demand at the authored slot")
    func passDeclaringThumbnailDeclaresDemandAtItsSlot() {
        let pipeline = Self.pipeline(bindings: WPERenderUserTextureBindings(pass: [
            WPESceneUserTextureBinding(name: "$mediaPreviousThumbnail", type: "system", slot: 1),
            WPESceneUserTextureBinding(name: "$mediaThumbnail", type: "system", slot: 2)
        ]))
        let demand = WPEMediaTextureDemand.byPassID(in: pipeline)
        #expect(demand.count == 1)
        #expect(demand["1.0"]?[1] == .previousThumbnail)
        #expect(demand["1.0"]?[2] == .thumbnail)
        #expect(demand["1.0"]?[0] == nil)
    }

    @Test("An unhandled type:system name declares no demand for its slot")
    func unhandledSystemNameDeclaresNoDemand() {
        let pipeline = Self.pipeline(bindings: WPERenderUserTextureBindings(pass: [
            WPESceneUserTextureBinding(name: "$mediaSomethingElse", type: "system", slot: 1)
        ]))
        #expect(WPEMediaTextureDemand.byPassID(in: pipeline).isEmpty)
    }

    @Test("No $media binding creates neither a subscription nor a texture store")
    func demandGateCreatesNoSubscriptionWithoutBindings() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = FakeNowPlayingSource()
        let demand = WPEMediaTextureDemand.byPassID(in: Self.pipeline(bindings: .empty))

        #expect(demand.isEmpty)
        if !demand.isEmpty {
            let store = WPEMediaTextureStore(device: device, slotsByPassID: demand)
            WPEMediaTextureSubscription(store: store, source: source).start()
        }
        #expect(source.subscriberCount == 0)
    }

    @Test("A $media binding does create a subscription, and stopping releases it")
    func demandGateCreatesSubscriptionWithBindings() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = FakeNowPlayingSource()
        let demand = WPEMediaTextureDemand.byPassID(in: Self.pipeline(
            bindings: WPERenderUserTextureBindings(pass: [
                WPESceneUserTextureBinding(name: "$mediaThumbnail", type: "system", slot: 2)
            ])
        ))
        #expect(!demand.isEmpty)

        let store = WPEMediaTextureStore(device: device, slotsByPassID: demand)
        #expect(store.declarations(forPassID: "1.0") == [2: .thumbnail])
        #expect(store.declarations(forPassID: "9.9") == nil)

        let subscription = WPEMediaTextureSubscription(store: store, source: source)
        subscription.start()
        #expect(source.subscriberCount == 1)
        subscription.stop()
        #expect(source.subscriberCount == 0)
    }

    @Test("Subscribing replays current state, so a scene loaded mid-song has its cover")
    func subscribingReplaysCurrentArtwork() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = FakeNowPlayingSource()
        source.push(MonitorNowPlayingState(
            phase: .playing,
            title: "Track",
            artwork: try Self.artwork(red: 0.9)
        ))

        let store = WPEMediaTextureStore(device: device, slotsByPassID: ["1.0": [2: .thumbnail]])
        WPEMediaTextureSubscription(store: store, source: source).start()

        #expect(store.uploadCount == 1)
        #expect(store.texture(for: .thumbnail) != nil)
    }

    // MARK: - Slot substitution

    @Test("A slot declaring $mediaThumbnail binds the artwork texture once artwork exists")
    func thumbnailSlotBindsArtworkTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [2: .thumbnail]

        store.ingest(artwork: try Self.artwork(red: 0.9))

        let bound = try #require(store.substituting(placeholder, slot: 2, declarations: declarations))
        #expect(bound !== placeholder, "the artwork must replace the authored placeholder")
        #expect(bound === store.texture(for: .thumbnail))
    }

    @Test("With no artwork the declared slot keeps the authored placeholder")
    func noArtworkKeepsAuthoredPlaceholder() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [2: .thumbnail]

        store.ingest(artwork: nil)

        // 断言 identity 而非仅 non-nil:这里换成空白/黑纹理会渲成一个洞,
        // 而不是作者的封面图。
        #expect(store.substituting(placeholder, slot: 2, declarations: declarations) === placeholder)
    }

    @Test("A no-artwork gap does not erase the previous cover")
    func nilArtworkKeepsPreviousCoverAcrossTheGap() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [1: .previousThumbnail, 2: .thumbnail]

        store.ingest(artwork: try Self.artwork(red: 0.9))
        let coverA = try #require(store.texture(for: .thumbnail))

        store.ingest(artwork: nil)
        #expect(store.substituting(placeholder, slot: 2, declarations: declarations) === placeholder,
                "no track playing → the authored placeholder")
        #expect(store.substituting(placeholder, slot: 1, declarations: declarations) === coverA,
                "the gap must not erase the cover that came before it")

        store.ingest(artwork: try Self.artwork(red: 0.2))
        #expect(store.substituting(placeholder, slot: 1, declarations: declarations) === coverA,
                "at B the previous slot still serves A, not the placeholder")
    }

    @Test("Ingest reports whether it changed anything")
    func ingestReportsChanges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)

        #expect(!store.ingest(artwork: nil), "empty store, nil push: nothing changed")
        let a = try Self.artwork(red: 0.9)
        #expect(store.ingest(artwork: a))
        #expect(!store.ingest(artwork: a), "same bytes, same key: no change, no wake")
        #expect(store.ingest(artwork: nil), "clearing a live cover is a visible change")
    }

    @Test("A slot nobody declared is untouched even while artwork exists")
    func undeclaredSlotIsUntouched() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)

        store.ingest(artwork: try Self.artwork(red: 0.9))

        #expect(store.substituting(placeholder, slot: 0, declarations: [2: .thumbnail]) === placeholder)
    }

    @Test("$mediaPreviousThumbnail holds the placeholder until artwork changes, then the prior art")
    func previousThumbnailServesPriorArtworkOnlyAfterAChange() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [1: .previousThumbnail, 2: .thumbnail]

        let first = try Self.artwork(red: 0.9)
        store.ingest(artwork: first)

        #expect(store.substituting(placeholder, slot: 1, declarations: declarations) === placeholder)
        let current = try #require(store.substituting(placeholder, slot: 2, declarations: declarations))

        store.ingest(artwork: try Self.artwork(red: 0.1))

        let previous = try #require(store.substituting(placeholder, slot: 1, declarations: declarations))
        #expect(previous === current, "the previous slot must serve the artwork that was just replaced")
        #expect(store.substituting(placeholder, slot: 2, declarations: declarations) !== current)
    }

    // MARK: - Upload cache

    @Test("Re-ingesting identical artwork bytes uploads exactly once")
    func identicalArtworkUploadsOnce() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let artwork = try Self.artwork(red: 0.9)

        store.ingest(artwork: artwork)
        #expect(store.uploadCount == 1)

        store.ingest(artwork: artwork)
        #expect(store.uploadCount == 1, "a re-delivered unchanged cover must not decode again")

        store.ingest(artwork: try Self.artwork(red: 0.1))
        #expect(store.uploadCount == 2, "different bytes must upload — a frozen cache is not a cache")
    }

    @Test("Two draws with unchanged artwork upload nothing at all")
    func drawingTwiceUploadsNothing() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [2: .thumbnail]
        store.ingest(artwork: try Self.artwork(red: 0.9))

        let first = store.substituting(placeholder, slot: 2, declarations: declarations)
        let second = store.substituting(placeholder, slot: 2, declarations: declarations)

        #expect(store.uploadCount == 1, "a frame must never decode an image")
        #expect(first === second)
    }

    @Test("Artwork is downsampled to the system-texture cap")
    func artworkIsDownsampledOnUpload() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)

        store.ingest(artwork: try Self.artwork(red: 0.9, size: 1024))

        let texture = try #require(store.texture(for: .thumbnail))
        #expect(texture.width <= WPEMediaTextureStore.maximumEdge)
        #expect(texture.height <= WPEMediaTextureStore.maximumEdge)
    }

    @Test("Undecodable artwork bytes leave the placeholder in place")
    func undecodableArtworkKeepsPlaceholder() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)

        store.ingest(artwork: Data("not an image".utf8))

        #expect(store.substituting(placeholder, slot: 2, declarations: [2: .thumbnail]) === placeholder)
    }

    // MARK: - Name mapping

    @Test("Only the two corpus names map to a system texture")
    func onlyTheTwoCorpusNamesMap() {
        #expect(WPEMediaSystemTexture(bindingName: "$mediaThumbnail") == .thumbnail)
        #expect(WPEMediaSystemTexture(bindingName: "$mediaPreviousThumbnail") == .previousThumbnail)
        // WPE resolves these case-insensitively, as it does every other authored name.
        #expect(WPEMediaSystemTexture(bindingName: "$MEDIATHUMBNAIL") == .thumbnail)
        #expect(WPEMediaSystemTexture(bindingName: "$mediaStatus") == nil)
        #expect(WPEMediaSystemTexture(bindingName: "$instanceSource") == nil)
    }

    // MARK: - Builtin dispatch

    @Test("A builtin genericimage2 pass declaring $mediaThumbnail renders with the artwork bound")
    func builtinImagePassBindsArtworkAndKeepsItsComposite() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let store = WPEMediaTextureStore(device: device, slotsByPassID: ["cover.0": [0: .thumbnail]])
        try store.ingest(artwork: Self.artwork(red: 0.9))
        executor.mediaTextureStore = store

        let output = try executor.render(
            pipeline: Self.coverPipeline(),
            size: CGSize(width: 4, height: 4),
            textures: ["materials/cover.png": Self.solidTexture(device, red: 0, green: 0, blue: 255)]
        )
        let pixel = try Self.readPixel(output, x: 2, y: 2)

        #expect(pixel.r > 150, "the cover slot must carry the artwork, not the blue placeholder")
        #expect(pixel.b < 100)
    }

    @Test("A pass whose shader cannot translate leaves its cleared composite readable")
    func skippedShaderPassStillPublishesItsClearedComposite() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let output = try executor.render(
            pipeline: Self.untranslatablePipeline(),
            size: CGSize(width: 4, height: 4),
            textures: [:]
        )

        // Both halves matter: the pass really was skipped (otherwise this asserts nothing),
        // and the scene still rendered instead of dying on the downstream `_a` read.
        #expect(executor.untranslatableShaderReasonByPassID["broken.0"] != nil)
        let pixel = try Self.readPixel(output, x: 2, y: 2)
        #expect(pixel.a < 10, "a skipped pass publishes its cleared (transparent) target")
    }

    // MARK: - Fixtures

    private static func pipeline(bindings: WPERenderUserTextureBindings) -> WPEPreparedRenderPipeline {
        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/album/effect.json"),
            shader: "effects/album",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            userTextureBindings: bindings,
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: nil,
            textureBindings: [:],
            comboValues: [:],
            uniformValues: [:]
        )
        let layer = WPERenderLayer(
            objectID: "1",
            objectName: "Album",
            imagePath: "materials/album.png",
            materialPath: nil,
            geometry: .identity,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass]
        )
        return WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [prepared])
        ])
    }

    /// 第二个 pass 读第一个写的 composite —— 这个读才是夹具的要害。
    private static func coverPipeline() -> WPEPreparedRenderPipeline {
        func prepared(_ pass: WPERenderPass) -> WPEPreparedRenderPass {
            WPEPreparedRenderPass(pass: pass, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:])
        }
        let material = WPERenderPass(
            id: "cover.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/cover.png"),
            target: .layerComposite(name: "a"),
            textures: [0: .image("materials/cover.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            userTextureBindings: WPERenderUserTextureBindings(
                material: [WPESceneUserTextureBinding(name: "$mediaThumbnail", type: "system", slot: 0)]
            ),
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let toScene = WPERenderPass(
            id: "cover.1",
            phase: .material,
            shader: "genericimage2",
            source: .fbo("a"),
            target: .scene,
            textures: [0: .fbo("a")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "1080",
            objectName: "Cover",
            imagePath: "materials/cover.png",
            materialPath: nil,
            geometry: .identity,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [material, toScene]
        )
        return WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [prepared(material), prepared(toScene)]),
        ])
    }

    private static func untranslatablePipeline() -> WPEPreparedRenderPipeline {
        let broken = WPERenderPass(
            id: "broken.0",
            phase: .effect(file: "effects/broken/effect.json"),
            shader: "effects/broken",
            source: .image("materials/cover.png"),
            target: .layerComposite(name: "a"),
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let toScene = WPERenderPass(
            id: "broken.1",
            phase: .material,
            shader: "genericimage2",
            source: .fbo("a"),
            target: .scene,
            textures: [0: .fbo("a")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "1",
            objectName: "Broken",
            imagePath: "materials/cover.png",
            materialPath: nil,
            geometry: .identity,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [broken, toScene]
        )
        return WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    WPEPreparedRenderPass(
                        pass: broken,
                        shader: WPEShaderProgram(
                            name: "effects/broken",
                            vertexSource: "",
                            fragmentSource: "void main() { this is not glsl }",
                            isBuiltin: false
                        ),
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: [:]
                    ),
                    WPEPreparedRenderPass(
                        pass: toScene, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:]
                    ),
                ]
            ),
        ])
    }

    private static func solidTexture(_ device: MTLDevice, red: UInt8, green: UInt8, blue: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: 4, height: 4, mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8]()
        for _ in 0 ..< (4 * 4) {
            bytes.append(contentsOf: [red, green, blue, 255])
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 4 * 4
        )
        return texture
    }

    private static func readPixel(_ texture: MTLTexture, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let staged = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(texture))
        var bytes = [UInt8](repeating: 0, count: staged.width * staged.height * 4)
        staged.getBytes(
            &bytes,
            bytesPerRow: staged.width * 4,
            from: MTLRegionMake2D(0, 0, staged.width, staged.height),
            mipmapLevel: 0
        )
        let index = (y * staged.width + x) * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
    }

    private static func placeholderTexture(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: 8,
            height: 8,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// 按 `red` 取值不同,使两张封面字节级不相同。
    private static func artwork(red: Double, size: Int = 64) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = UInt8((red * 255).rounded())
            bytes[index + 1] = 40
            bytes[index + 2] = 40
            bytes[index + 3] = 255
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

/// `usertextures` 的数组下标就是被覆盖的纹理槽位:把 `null` 空洞
/// compactMap 掉会让每条声明整体下移。
@Suite("WPE usertextures slot alignment")
struct WPEUserTextureSlotAlignmentTests {
    @Test("Document parser keeps instance usertextures aligned across null holes")
    func documentParserKeepsInstanceSlotAlignment() throws {
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": 201,
                "name": "Album",
                "image": "models/album.json",
                "instance": [
                    "id": 2258,
                    "textures": ["cover", "cover", "cover"],
                    "usertextures": [
                        NSNull(),
                        ["name": "$mediaPreviousThumbnail", "type": "system"],
                        ["name": "$mediaThumbnail", "type": "system"]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: scene)
        let document = try WPESceneDocumentParser.parse(data: data)
        let instance = try #require(document.imageObjects.first?.materialInstance)

        #expect(instance.userTextures.count == 2)
        #expect(instance.userTextures[0].name == "$mediaPreviousThumbnail")
        #expect(instance.userTextures[0].slot == 1)
        #expect(instance.userTextures[1].name == "$mediaThumbnail")
        #expect(instance.userTextures[1].slot == 2)
    }

    @Test("Graph builder keeps material-pass usertextures aligned across null holes")
    func graphBuilderKeepsPassSlotAlignment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMediaSlotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try Self.writeJSON(["material": "materials/album.json"], to: root.appendingPathComponent("models/album.json"))
        try Self.writeJSON([
            "passes": [[
                "shader": "genericimage3",
                "textures": ["album2", "album2", "album2"],
                "usertextures": [
                    NSNull(),
                    ["name": "$mediaPreviousThumbnail", "type": "system"],
                    ["name": "$mediaThumbnail", "type": "system"]
                ]
            ]]
        ], to: root.appendingPathComponent("materials/album.json"))

        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [["id": 47, "name": "Album", "image": "models/album.json"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: scene)
        let document = try WPESceneDocumentParser.parse(data: data)
        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let pass = try #require(graph.layers.first?.passes.first)

        #expect(pass.userTextureBindings.pass.count == 2)
        #expect(pass.userTextureBindings.pass[0].slot == 1)
        #expect(pass.userTextureBindings.pass[1].slot == 2)
        #expect(WPEMediaTextureDemand.slots(in: pass.userTextureBindings) == [
            1: .previousThumbnail,
            2: .thumbnail
        ])
    }

    private static func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: url)
    }
}
