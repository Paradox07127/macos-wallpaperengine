#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

/// Native 171440 publishes raw identities before 1731d0 observers and media events. Decode remains Mac policy.
extension WPEParitySceneDriverTests {
    @MainActor @objc func testMediaRawIdentityAndObserversPrecedeEventsAcrossInvalidAndEmptyArtwork() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try mediaIdentityInputs(projection: false)
        let valid = try mediaIdentityPNG()
        let invalidB = Data("media-identity-invalid-B".utf8)
        let invalidC = Data("media-identity-invalid-C".utf8)
        let invalidD = Data("media-identity-invalid-D".utf8)
        // Start from a real nonempty seed. Native admission of an initially absent observation is a separate gate.
        for (label, noArtwork) in [("nil", nil as Data?), ("empty", Data())] {
            let source = MediaIdentitySource(artwork: valid)
            let dispatcher = WPESceneMediaEventDispatcher(source: source)
            let driver = try WPEParitySceneDriver(device: device)
            defer { dispatcher.stop(); driver.cleanup() }
            try await loadMediaIdentity(driver, fixture: fixture, dispatcher: dispatcher)
            let layer = try mediaIdentityLayer(device: device)
            try await present(driver, layer: layer, label: "raw identity valid seed before \(label)")
            try assertMediaIdentityPixel(driver, layer: layer, rgb: SIMD3(0.125, 1, 1), label: "valid seed")

            let steps: [(String, Data?, Int, String)] = [
                ("invalid B", invalidB, 2, "undecodable"),
                ("same invalid B", invalidB, 2, "undecodable"),
                ("invalid C", invalidC, 3, "undecodable"),
                (label, noArtwork, 4, label == "nil" ? "absent" : "empty"),
                ("same \(label)", noArtwork, 4, label == "nil" ? "absent" : "empty"),
                ("invalid D after \(label)", invalidD, 5, "undecodable"),
            ]
            for (step, artwork, deliveries, diagnostic) in steps {
                source.push(artwork: artwork)
                try await present(driver, layer: layer, label: step)
                // G witnesses nonempty/new current and previous == the last delivered current, without parsing names.
                // B witnesses the actual bound scriptproperties and event4 before the media callback.
                try assertMediaIdentityPixel(driver, layer: layer, rgb: SIMD3(Float(deliveries) / 8, 1, 1), label: step)
                XCTAssertTrue(try XCTUnwrap(driver.renderer).mediaDiagnostics.contains(
                    "media.artwork-\(diagnostic)-native-behavior-unverified"
                ), "Raw identity must not qualify the Mac GPU decoder: \(step)")
            }
        }
    }

    @MainActor @objc func testMediaEvent4FiltersUntypedKeysAndPreservesTheTypedLivePropertyConsumer() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try mediaIdentityInputs(projection: true)
        let source = try MediaIdentitySource(artwork: mediaIdentityPNG())
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let driver = try WPEParitySceneDriver(device: device)
        defer { dispatcher.stop(); driver.cleanup() }
        try await loadMediaIdentity(driver, fixture: fixture, dispatcher: dispatcher)
        let layer = try mediaIdentityLayer(device: device)
        try await present(driver, layer: layer, label: "event4 media seed")
        try assertMediaIdentityPixel(driver, layer: layer, rgb: SIMD3(0, 1, 0.125), label: "media keys excluded")

        // Use the product's real prepare/commit path; neither a direct engine dispatch nor a mailbox injection.
        let generation = driver.loadGeneration
        let rendererIdentity = try ObjectIdentifier(XCTUnwrap(driver.renderer))
        let patch = WPEScenePropertyPatch(bindingsByProperty: driver.userPropertyBindings,
                                          oldValues: ["ordinary": .number(0.125)],
                                          newValues: ["ordinary": .number(0.75)])
        let updated = try WPESceneDocumentParser.parse(data: fixture.sceneJSON,
                                                       userValues: ["ordinary": .number(0.75)])
        _ = try XCTUnwrap(driver.canApplyUserPropertiesLive(patch) ? true : nil, "Real incremental binding required")
        _ = try XCTUnwrap(driver.prepareUserProperties(patch, document: updated) ? true : nil, "Real prepare required")
        _ = try XCTUnwrap(driver.commitUserProperties(patch) ? true : nil, "Real commit required")
        try await present(driver, layer: layer, label: "ordinary typed event4")
        // R increments only when the typed event4 value is .75 and the real control layer already received .75.
        try assertMediaIdentityPixel(driver, layer: layer, rgb: SIMD3(0.125, 1, 0.125), label: "typed entry retained")
        XCTAssertEqual(driver.loadGeneration, generation)
        XCTAssertEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer)), rendererIdentity)
        let controlAlpha = try XCTUnwrap(XCTUnwrap(driver.renderer).state.value(.alpha, of: "2"))
        XCTAssertEqual(controlAlpha.x, 0.75)

        source.push(artwork: Data("event4-invalid-next-artwork".utf8))
        try await present(driver, layer: layer, label: "media after typed project commit")
        try assertMediaIdentityPixel(driver, layer: layer, rgb: SIMD3(0.125, 1, 0.25),
                                     label: "media keys excluded while merged state and observers advance")
        XCTAssertTrue(try XCTUnwrap(driver.renderer).mediaDiagnostics.contains(
            "media.artwork-undecodable-native-behavior-unverified"
        ))
    }

    private struct MediaIdentityInputs {
        let sceneJSON: Data
        let document: WPESceneDocument
        let assets: WPEParityProgramAssets
        let compiler: WPEParityHelperShaderCompiler
    }

    private func mediaIdentityInputs(projection: Bool) throws -> MediaIdentityInputs {
        let assets: WPEParityProgramAssets
        let compiler: WPEParityHelperShaderCompiler
        do {
            let (_, found) = try sceneInputs()
            assets = found
            compiler = try makeCompiler()
        } catch {
            throw NSError(domain: "WPEParityMediaIdentityProductTests.RequiredInputs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original assets/toolchain unavailable: \(error)"])
        }
        for (path, expected) in [
            ("shaders/flat.frag", "7e0503a1821089475b884e4e8b0fb1987108f7d00c5cb353da7695eac7796477"),
            ("shaders/flat.vert", "3659d0455c48d9c57b329675c42ce0e7f76628865bc2ce7c8452e1b63fdb9805"),
            ("materials/util/solidlayer.json", "2bbc99c15f38041dfb636b4fb8afe975de500c3ad4eb5bd09b616564d46c7b59"),
            ("models/util/solidlayer.json", "a39818343c99fbff21b3a21b962871618c63c0a9257cf944dc09d20d54e3f5ea"),
            ("scripts/jsclasses/baseclasses.js", "708e6636167f0456eebf3ba05274d7b7763d17dfbd44c2711dc3d6d98f0cb294"),
        ] {
            let bytes = try XCTUnwrap(assets.data(path), "Required original resource: \(path)")
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            _ = try XCTUnwrap(actual == expected ? true : nil, "Required original identity: \(path)")
        }
        let script = "var projectionMode = \(projection ? "true" : "false");\n" + Self.mediaIdentityScript
        let scene: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 16], "clearcolor": "0 0 0",
                        "clearenabled": true, "bloom": false, "hdr": false, "camerafade": false],
            "objects": [
                ["id": 1, "name": "media-identity-witness", "image": "models/util/solidlayer.json",
                 "size": "32 16", "origin": "16 8 0", "color": "0 0 0", "alpha": 1,
                 "visible": ["value": true, "script": script, "scriptproperties": [
                     "currentName": ["user": "$mediaThumbnail", "value": "unseeded-current"],
                     "previousName": ["user": "$mediaPreviousThumbnail", "value": "unseeded-previous"],
                 ]]],
                ["id": 2, "name": "ordinary-control", "image": "models/util/solidlayer.json",
                 "size": "1 1", "origin": "-100 -100 0", "visible": false,
                 "alpha": ["user": "ordinary", "value": 0.125]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys])
        let document = try WPESceneDocumentParser.parse(data: data, userValues: [:])
        return MediaIdentityInputs(sceneJSON: data, document: document, assets: assets, compiler: compiler)
    }

    /// The oracle inspects real script inputs and relationships; it never derives a name from the production revision.
    private static let mediaIdentityScript = """
    export var scriptProperties = createScriptProperties()
        .addText({name: 'currentName', label: 'Current', value: 'unseeded-current'})
        .addText({name: 'previousName', label: 'Previous', value: 'unseeded-previous'})
        .finish();
    var mediaCalls = 0;
    var ordinaryCalls = 0;
    var identityErrors = 0;
    var observerErrors = 0;
    var payloadErrors = 0;
    var ordinaryErrors = 0;
    var propertyStage = 0;
    var lastCurrent;
    function own(object, key) { return Object.prototype.hasOwnProperty.call(object, key); }
    export function applyUserProperties(properties) {
        if (own(properties, '$mediaThumbnail') || own(properties, '$mediaPreviousThumbnail')) payloadErrors += 1;
        var current = engine.userProperties['$mediaThumbnail'];
        if (typeof current === 'string' && scriptProperties.currentName !== current) observerErrors += 1;
        if (own(properties, 'ordinary')) {
            if (properties.ordinary === 0.75) {
                ordinaryCalls += 1;
                if (engine.userProperties.ordinary !== 0.75 || thisScene.getLayer('ordinary-control').alpha !== 0.75)
                    ordinaryErrors += 1;
            } else if (properties.ordinary !== 0.125) ordinaryErrors += 1;
        }
        propertyStage = 1;
    }
    export function mediaThumbnailChanged(event) {
        var current = engine.userProperties['$mediaThumbnail'];
        var previous = engine.userProperties['$mediaPreviousThumbnail'];
        if (typeof current !== 'string' || current.length === 0) identityErrors += 1;
        if (mediaCalls > 0 && (current === lastCurrent || previous !== lastCurrent)) identityErrors += 1;
        if (mediaCalls === 0 && previous !== undefined && previous !== '') identityErrors += 1;
        if (propertyStage !== 1 || scriptProperties.currentName !== current) observerErrors += 1;
        if (mediaCalls > 0 && scriptProperties.previousName !== previous) observerErrors += 1;
        lastCurrent = current;
        mediaCalls += 1;
        propertyStage = 2;
    }
    export function update() {
        if (projectionMode) {
            var good = payloadErrors === 0 && ordinaryErrors === 0 && observerErrors === 0 && identityErrors === 0;
            thisLayer.color = new Vec3(ordinaryCalls / 8, good ? 1 : 0, mediaCalls / 8);
        } else {
            thisLayer.color = new Vec3(mediaCalls / 8, identityErrors === 0 ? 1 : 0,
                                      observerErrors === 0 && propertyStage === 2 ? 1 : 0);
        }
        return true;
    }
    """

    @MainActor private func loadMediaIdentity(_ driver: WPEParitySceneDriver, fixture: MediaIdentityInputs,
                                              dispatcher: WPESceneMediaEventDispatcher) async throws {
        driver.setPresentFitMode(.center)
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 32, height: 16), pixelFormat: .rgba8Unorm_srgb,
                              compiler: fixture.compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch),
                              scriptHost: .init(userPropertiesJSON: "{\"ordinary\":{\"type\":\"slider\",\"value\":0.125,\"text\":\"ordinary typed control\"}}",
                                                media: dispatcher.mailbox))
        XCTAssertTrue(driver.didLoad)
        XCTAssertTrue(driver.scriptHandlesMedia)
        XCTAssertFalse(driver.hasMediaTextureDemand, "Raw identities/observers do not imply a qualified GPU decoder")
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        XCTAssertTrue(renderer.fallbackTextures.isEmpty, "\(renderer.fallbackTextures)")
        _ = try XCTUnwrap(dispatcher.configureParity(generation: driver.loadGeneration, device: nil,
                                                     textureDemand: driver.hasMediaTextureDemand, onChange: {}) ? true : nil,
                          "The admitted real load must accept its source subscription")
    }

    private func mediaIdentityLayer(device: MTLDevice) throws -> RecordingLayer {
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.colorspace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 32, height: 16)
        return layer
    }

    private func assertMediaIdentityPixel(_ driver: WPEParitySceneDriver, layer: RecordingLayer,
                                          rgb: SIMD3<Float>, label: String,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let renderer = try XCTUnwrap(driver.renderer, label, file: file, line: line)
        let color = try XCTUnwrap(renderer.state.value(.color, of: "1"), label, file: file, line: line)
        for channel in 0 ..< 3 {
            XCTAssertEqual(color[channel], rgb[channel], label, file: file, line: line)
        }
        let draw = try XCTUnwrap(renderer.lastFrameDraws.first { entry in
            renderer.frames[0].operations[entry.operation].pass.rawValue == "1/albedo"
        }, "The script witness must really draw", file: file, line: line)
        XCTAssertTrue(draw.draw.textures.isEmpty, "Original flat reads real script colour", file: file, line: line)
        let texture = try XCTUnwrap(layer.lastTexture, label, file: file, line: line)
        XCTAssertEqual([texture.width, texture.height], [32, 16], file: file, line: line)
        let bytes = try readBack(texture, device: texture.device)
        let offset = (8 * 32 + 16) * 4
        _ = try XCTUnwrap(bytes.count >= offset + 4 ? true : nil, label, file: file, line: line)
        let expected = (0 ..< 3).map { Int((Double(rgb[$0]) * 255).rounded()) } + [255]
        for channel in 0 ..< 4 {
            XCTAssertLessThanOrEqual(abs(Int(bytes[offset + channel]) - expected[channel]), channel == 3 ? 0 : 1,
                                     "Real original-shader pixel channel \(channel): \(label)", file: file, line: line)
        }
    }

    private func mediaIdentityPNG() throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data([UInt8(0), 255, 255, 255]) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                          space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        _ = try XCTUnwrap(CGImageDestinationFinalize(destination) ? true : nil)
        return output as Data
    }
}

@MainActor
private final class MediaIdentitySource: WPENowPlayingEventSource {
    private var handlers: [UUID: @Sendable (UInt64, MonitorNowPlayingState) -> Void] = [:]
    private var ordinal: UInt64 = 0
    private var state: MonitorNowPlayingState

    init(artwork: Data?) {
        state = MonitorNowPlayingState(phase: .paused, title: "Media raw identity guard", artwork: artwork)
    }

    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        handlers[id] = handler
        handler(ordinal, state)
    }

    func unsubscribe(id: UUID) {
        handlers[id] = nil
    }

    func push(artwork: Data?) {
        ordinal &+= 1
        state = MonitorNowPlayingState(phase: .paused, title: "Media raw identity guard", artwork: artwork)
        for handler in handlers.values {
            handler(ordinal, state)
        }
    }
}
#endif
