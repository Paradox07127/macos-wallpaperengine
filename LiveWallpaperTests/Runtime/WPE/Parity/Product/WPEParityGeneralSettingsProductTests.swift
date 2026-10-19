#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

extension WPEParitySceneDriverTests {
    func testLanguageReachesInitialAndChangedScriptsWithoutRepeatingOnResize() async throws {
        let (_, assets) = try sceneInputs()
        let data = try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 160, "height": 96], "bloom": false],
            "objects": [["id": 20, "name": "solid", "image": "models/util/solidlayer.json", "origin": "80 48 0",
                         "size": "12 12", "alpha": ["value": 1, "script": """
                         let calls = 0;
                         export function applyGeneralSettings(settings) {
                             if (!settings.hasOwnProperty('language')) throw Error('missing language');
                             thisLayer.alpha = ++calls / 10;
                             thisLayer.brightness = settings.language === 'german' ? 0.5 : 1;
                         }
                         """]]],
        ])
        let document = try WPESceneDocumentParser.parse(data: data, userValues: [:])
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { driver.cleanup() }
        let compiler = try makeCompiler()
        driver.setSceneScriptLanguage("english")
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 160, height: 96), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: .init(cachesURL: scratch))
        XCTAssertEqual(try XCTUnwrap(driver.renderer?.state.object("20")?.alpha), 0.1, accuracy: 0.001)
        driver.setSceneScriptLanguage("german")
        driver.setSceneScriptLanguage("german")
        XCTAssertEqual(try XCTUnwrap(driver.renderer?.state.object("20")?.alpha), 0.2, accuracy: 0.001)
        XCTAssertEqual(driver.renderer?.state.object("20")?.brightness, 0.5)
        driver.updateSurfaceGeometry(drawableSize: CGSize(width: 320, height: 192))
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        XCTAssertEqual(try XCTUnwrap(driver.renderer?.state.object("20")?.alpha), 0.2, accuracy: 0.001)
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 160, height: 96), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: .init(cachesURL: scratch))
        XCTAssertEqual(try XCTUnwrap(driver.renderer?.state.object("20")?.alpha), 0.1, accuracy: 0.001)
        XCTAssertEqual(driver.renderer?.state.object("20")?.brightness, 0.5)
        XCTAssertNil(driver.runtimeFailure)
    }
}
#endif
