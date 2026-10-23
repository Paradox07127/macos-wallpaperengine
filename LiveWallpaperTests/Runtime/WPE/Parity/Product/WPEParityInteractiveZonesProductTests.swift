#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

/// Hot zones open only over visible, non-transparent solid layers whose scripts take the left button.
extension WPEParitySceneDriverTests {
    @objc func testInteractiveZonesCoverOnlyVisibleSolidClickableLayers() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let (_, assets) = try sceneInputs()
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(value): compiler = value
        case let .failure(reason): throw XCTSkip("\(reason)")
        }
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParityInteractiveZonesProductTests.Isolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required isolated product defaults"])
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
        let click = "export function cursorClick(event) {}"
        func panel(id: Int, origin: String, solid: Bool = true, visible: Bool = true, alpha: Float = 1,
                   script: String?) -> [String: Any] {
            var object: [String: Any] = ["id": id, "name": "panel \(id)", "image": "models/util/solidlayer.json",
                                         "origin": origin, "size": "32 32", "solid": solid, "visible": visible,
                                         "color": "1 1 1", "alpha": alpha]
            if let script {
                object["alpha"] = ["value": alpha, "script": script]
            }
            return object
        }
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 160, "height": 96], "clearenabled": true,
                        "clearcolor": "0 0 0", "camerashake": false, "cameraparallax": false],
            "objects": [
                panel(id: 10, origin: "40 72 0", script: click),
                panel(id: 20, origin: "120 72 0", script: "export function cursorMove(event) {}"),
                panel(id: 30, origin: "40 24 0", solid: false, script: click),
                panel(id: 40, origin: "120 24 0", alpha: 0, script: click),
                panel(id: 50, origin: "80 48 0", visible: false, script: click),
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 160, height: 96), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        let script = try XCTUnwrap(driver.renderer?.instance.script, "actual product load must attach SceneScript")
        XCTAssertEqual(script.engine.bindings.filter(\.compiled).count, 5)
        XCTAssertEqual(driver.interactiveZones(), [], "no cursor pass has run yet")

        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.drawableSize = CGSize(width: 160, height: 96)
        let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(),
                                                                 pointer: SIMD2(0.5, 0.5)))
        try await settle(driver, label: "interactive zones frame")
        XCTAssertNil(command.error)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))

        // Panel 10 spans x 24...56 and y 8...40 of the 160x96 canvas, top-left origin.
        let zones = driver.interactiveZones()
        XCTAssertEqual(zones.count, 1, "\(zones)")
        let zone = try XCTUnwrap(zones.first)
        XCTAssertEqual(zone.minX, 24.0 / 160, accuracy: 1e-4)
        XCTAssertEqual(zone.maxX, 56.0 / 160, accuracy: 1e-4)
        XCTAssertEqual(zone.minY, 8.0 / 96, accuracy: 1e-4)
        XCTAssertEqual(zone.maxY, 40.0 / 96, accuracy: 1e-4)
    }
}
#endif
