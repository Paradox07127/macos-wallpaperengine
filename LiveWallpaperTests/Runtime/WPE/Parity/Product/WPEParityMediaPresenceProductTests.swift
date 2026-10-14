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

/// Tests only the sealed raw-byte event predicate. No usertexture or GPU decoder qualification is inferred.
extension WPEParitySceneDriverTests {
    @MainActor @objc func testMediaThumbnailInitialRawBytePresenceReachesTheActualScriptAndDraw() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (document, assets, compiler) = try mediaPresenceInputs()
        for (label, artwork, expectedCalls, expectedPresence) in [
            ("nil", nil as Data?, 0, false),
            ("empty", Data(), 0, false),
            ("nonempty invalid", Data("not-an-image-initial".utf8), 1, true),
        ] {
            let source = MediaPresenceSource(initialArtwork: artwork)
            let dispatcher = WPESceneMediaEventDispatcher(source: source)
            let driver = try WPEParitySceneDriver(device: device)
            defer { dispatcher.stop(); driver.cleanup() }
            try await loadMediaPresence(driver, document: document, assets: assets,
                                        compiler: compiler, dispatcher: dispatcher)
            let layer = try mediaPresenceLayer(device: device)
            try await present(driver, layer: layer, label: "initial \(label)")
            try assertMediaPresence(driver, layer: layer, calls: expectedCalls,
                                    presence: expectedPresence, label: "initial \(label)")
            let renderer = try XCTUnwrap(driver.renderer)
            let reason = artwork == nil ? "absent" : artwork?.isEmpty == true ? "empty" : "undecodable"
            XCTAssertTrue(renderer.mediaDiagnostics.contains("media.artwork-\(reason)-native-behavior-unverified"),
                          "Mac decode/fallback uncertainty remains explicit: \(renderer.mediaDiagnostics)")
        }
    }

    @MainActor @objc func testMediaThumbnailChangedRawBytesKeepPresenceIndependentOfDecodeAndPalette() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (document, assets, compiler) = try mediaPresenceInputs()
        let valid = try mediaPresencePNG()
        let invalidA = Data("not-an-image-update-A".utf8)
        let invalidB = Data("not-an-image-update-B".utf8)
        for (label, absentArtwork) in [("nil", nil as Data?), ("empty", Data())] {
            let source = MediaPresenceSource(initialArtwork: valid)
            let dispatcher = WPESceneMediaEventDispatcher(source: source)
            let driver = try WPEParitySceneDriver(device: device)
            defer { dispatcher.stop(); driver.cleanup() }
            try await loadMediaPresence(driver, document: document, assets: assets,
                                        compiler: compiler, dispatcher: dispatcher)
            let layer = try mediaPresenceLayer(device: device)
            try await present(driver, layer: layer, label: "valid initial before \(label)")
            try assertMediaPresence(driver, layer: layer, calls: 1, presence: true, label: "valid initial")

            source.push(artwork: invalidA)
            try await present(driver, layer: layer, label: "valid → invalid A")
            try assertMediaPresence(driver, layer: layer, calls: 2, presence: true, label: "invalid A still has raw bytes")
            XCTAssertTrue(try XCTUnwrap(driver.renderer).mediaDiagnostics.contains(
                "media.artwork-undecodable-native-behavior-unverified"
            ))

            source.push(artwork: invalidA)
            try await present(driver, layer: layer, label: "identical invalid bytes")
            try assertMediaPresence(driver, layer: layer, calls: 2, presence: true,
                                    label: "same source bytes do not manufacture another change")

            source.push(artwork: invalidB)
            try await present(driver, layer: layer, label: "different invalid bytes, unavailable palette")
            try assertMediaPresence(driver, layer: layer, calls: 3, presence: true,
                                    label: "changed nonempty bytes dispatch even with identical unavailable palette")

            source.push(artwork: absentArtwork)
            try await present(driver, layer: layer, label: "nonempty → \(label)")
            try assertMediaPresence(driver, layer: layer, calls: 4, presence: false,
                                    label: "empty range reports false on an actual update")

            source.push(artwork: invalidA)
            try await present(driver, layer: layer, label: "\(label) → nonempty invalid")
            try assertMediaPresence(driver, layer: layer, calls: 5, presence: true,
                                    label: "raw presence can return without a decodable cover")
        }
    }

    private func mediaPresenceInputs() throws -> (WPESceneDocument, WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        let assets: WPEParityProgramAssets
        let compiler: WPEParityHelperShaderCompiler
        do {
            let (_, found) = try sceneInputs()
            assets = found
            compiler = try makeCompiler()
        } catch {
            throw NSError(domain: "WPEParityMediaPresenceProductTests.RequiredInputs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original assets/toolchain unavailable: \(error)"])
        }
        // Original flat really consumes live g_Color/g_Alpha. No replacement shader or synthetic output is used.
        for (path, expected) in [
            ("shaders/flat.frag", "7e0503a1821089475b884e4e8b0fb1987108f7d00c5cb353da7695eac7796477"),
            ("shaders/flat.vert", "3659d0455c48d9c57b329675c42ce0e7f76628865bc2ce7c8452e1b63fdb9805"),
            ("materials/util/solidlayer.json", "2bbc99c15f38041dfb636b4fb8afe975de500c3ad4eb5bd09b616564d46c7b59"),
            ("models/util/solidlayer.json", "a39818343c99fbff21b3a21b962871618c63c0a9257cf944dc09d20d54e3f5ea"),
        ] {
            let data = try XCTUnwrap(assets.data(path), "Required original resource: \(path)")
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            _ = try XCTUnwrap(actual == expected ? true : nil, "Required original identity: \(path)")
        }
        let script = """
        var thumbnailCalls = 0;
        var presence = false;
        var playbackCalls = 0;
        export function mediaPlaybackChanged(event) {
            playbackCalls += 1;
        }
        export function mediaThumbnailChanged(event) {
            thumbnailCalls += 1;
            presence = event.hasThumbnail;
        }
        export function update() {
            thisLayer.color = new Vec3(thumbnailCalls / 8, presence ? 1 : 0, playbackCalls / 8);
            return true;
        }
        """
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 16], "clearcolor": "0 0 0",
                        "clearenabled": true, "bloom": false, "hdr": false, "camerafade": false],
            "objects": [["id": 1, "name": "real media event witness", "image": "models/util/solidlayer.json",
                         "size": "32 16", "origin": "16 8 0", "color": "0 0 0", "alpha": 1,
                         "visible": ["value": true, "script": script]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:])
        return (document, assets, compiler)
    }

    @MainActor private func loadMediaPresence(_ driver: WPEParitySceneDriver, document: WPESceneDocument,
                                              assets: WPEParityProgramAssets, compiler: WPEParityHelperShaderCompiler,
                                              dispatcher: WPESceneMediaEventDispatcher) async throws {
        // Center is the product's native-size path; this event guard does not change process-wide scale defaults.
        driver.setPresentFitMode(.center)
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 32, height: 16), pixelFormat: .rgba8Unorm_srgb,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch),
                              scriptHost: .init(media: dispatcher.mailbox))
        XCTAssertTrue(driver.didLoad)
        XCTAssertTrue(driver.scriptHandlesMedia, "The actual product must have installed the exported handlers")
        XCTAssertFalse(driver.hasMediaTextureDemand, "This tests only events, independently of the unknown factory")
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        XCTAssertTrue(renderer.fallbackTextures.isEmpty, "\(renderer.fallbackTextures)")
        _ = try XCTUnwrap(dispatcher.configureParity(generation: driver.loadGeneration, device: nil,
                                                     textureDemand: driver.hasMediaTextureDemand, onChange: {}) ? true : nil,
                          "The real admitted load must accept its script-only source subscription")
    }

    private func mediaPresenceLayer(device: MTLDevice) throws -> RecordingLayer {
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.colorspace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 32, height: 16)
        return layer
    }

    private func assertMediaPresence(_ driver: WPEParitySceneDriver, layer: RecordingLayer,
                                     calls: Int, presence: Bool, label: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let renderer = try XCTUnwrap(driver.renderer, label, file: file, line: line)
        let color = try XCTUnwrap(renderer.state.value(.color, of: "1"), label, file: file, line: line)
        XCTAssertEqual(color.x, Float(calls) / 8, "real handler delivery count: \(label)", file: file, line: line)
        XCTAssertEqual(color.y, presence ? 1 : 0, "real handler raw presence: \(label)", file: file, line: line)
        XCTAssertEqual(color.z, 0.125, "playback seed proves the source and script are active: \(label)", file: file, line: line)
        let draw = try XCTUnwrap(renderer.lastFrameDraws.first { entry in
            renderer.frames[0].operations[entry.operation].pass.rawValue == "1/albedo"
        }, "The witness must actually draw", file: file, line: line)
        XCTAssertTrue(draw.draw.textures.isEmpty, "Original flat is a script-colour consumer", file: file, line: line)
        let drawable = try XCTUnwrap(layer.lastTexture, label, file: file, line: line)
        XCTAssertEqual([drawable.width, drawable.height], [32, 16], file: file, line: line)
        let bytes = try readBack(drawable, device: drawable.device)
        let offset = (8 * 32 + 16) * 4
        let expected = [Int((Double(calls) * 255 / 8).rounded()), presence ? 255 : 0, 32, 255]
        _ = try XCTUnwrap(bytes.count >= offset + 4 ? true : nil, label, file: file, line: line)
        for channel in 0 ..< 4 {
            XCTAssertLessThanOrEqual(abs(Int(bytes[offset + channel]) - expected[channel]), channel == 3 ? 0 : 1,
                                     "actual original-shader pixel channel \(channel): \(label)", file: file, line: line)
        }
    }

    private func mediaPresencePNG() throws -> Data {
        let data = Data([UInt8(0), 255, 255, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
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
private final class MediaPresenceSource: WPENowPlayingEventSource {
    private var handlers: [UUID: @Sendable (UInt64, MonitorNowPlayingState) -> Void] = [:]
    private var ordinal: UInt64 = 0
    private var state: MonitorNowPlayingState

    init(initialArtwork: Data?) {
        state = MonitorNowPlayingState(phase: .paused, title: "Media presence guard", artwork: initialArtwork)
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
        state = MonitorNowPlayingState(phase: .paused, title: "Media presence guard", artwork: artwork)
        for handler in handlers.values {
            handler(ordinal, state)
        }
    }
}
#endif
