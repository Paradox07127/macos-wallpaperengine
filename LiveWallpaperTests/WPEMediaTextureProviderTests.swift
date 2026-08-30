import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing
import UniformTypeIdentifiers

/// `$mediaThumbnail` / `$mediaPreviousThumbnail`: the album-art bitmap that
/// reaches a Scene wallpaper as a system texture bound into a shader slot, never
/// through JavaScript. Twelve of the 54 installed scenes declare one.
///
/// Structure asserted here comes from the installed corpus, not from our own
/// code: `usertextures` is positional against the sibling `textures` array with
/// `null` in every slot the author did not override (2955378002
/// `objects[201]/effects[0]/passes[0]` is `[null, {$mediaPreviousThumbnail},
/// {$mediaThumbnail}]` against three `textures` entries).
///
/// Nothing in this file may reach `NowPlayingMonitor.shared` — it observes the
/// user's real Spotify/Music. The injected `WPENowPlayingEventSource` seam
/// (`FakeNowPlayingSource`, declared in WPESceneMediaEventDispatchTests) is the
/// only source used.
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

    /// Mirrors the load path in WPEMetalSceneRenderer+Load.swift: it scans the
    /// pipeline, and only builds a store and subscribes when the scan is
    /// non-empty. Asserted through the injected source so nothing here reaches
    /// `NowPlayingMonitor.shared`.
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
        // A leaked subscription would outlive the wallpaper: the monitor holds
        // the handler, which holds this scene's store.
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

        // Asserting identity, not just non-nil: binding a blank or black texture
        // here is exactly the bug this guards — "no music playing" must render
        // the author's cover art, not a hole.
        #expect(store.substituting(placeholder, slot: 2, declarations: declarations) === placeholder)
    }

    /// A → player stops (nil) → B: the previous slot must still serve A at B.
    /// Clearing previous together with current on a nil push wiped that memory,
    /// so `$mediaPreviousThumbnail` fell back to the placeholder instead of the
    /// cover the scene was crossfading from.
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

    /// The renderer's frame loop can be parked (static scene, nothing else
    /// animating); an ingest that changed a texture reports it so the caller
    /// can wake one frame — otherwise the desktop keeps the old song's cover.
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

        // First artwork ever: there is no previous, so that slot must still be
        // the author's placeholder rather than a copy of the current cover.
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

    /// A solid PNG, distinct per `red` so two covers differ byte-for-byte.
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

/// The `usertextures` array position IS the overridden texture slot. Both
/// parsers used to `compactMap` the `null` holes away, which silently shifted
/// every declaration down — `[null, {$mediaPreviousThumbnail}, {$mediaThumbnail}]`
/// bound slots 0 and 1 instead of 1 and 2.
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
