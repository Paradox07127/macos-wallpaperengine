#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

/// The shipping driver must propagate the JSC watchdog failure instead of publishing a scriptless or partial frame.
extension WPEParitySceneDriverTests {
    func testScriptInitializationTimeoutFailsTheLoad() async throws {
        let (document, assets) = try watchdogScene(script: """
        export function init(value) { while (true) {} }
        """)
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { driver.cleanup() }
        let compiler = try makeCompiler()
        do {
            try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                                  drawableSize: CGSize(width: 160, height: 96), pixelFormat: .rgba8Unorm,
                                  compiler: compiler, diskCache: .init(cachesURL: scratch))
            XCTFail("A terminated initializer must fail the scene load")
        } catch let failure as WPEParityScriptEngine.Failure {
            XCTAssertEqual(failure, .executionTimedOut(operation: .initialize, seconds: 5))
        }
        XCTAssertFalse(driver.didLoad)
        XCTAssertNil(driver.renderer)
        XCTAssertNotNil(driver.loadDiagnostics)
    }

    func testScriptUpdateTimeoutLatchesFailureAndStopsSubmittingFrames() async throws {
        let (document, assets) = try watchdogScene(script: """
        let frame = 0;
        export function update(value) { if (++frame > 1) { while (true) {} } return value; }
        """)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 160, height: 96), pixelFormat: .rgba8Unorm,
                              compiler: makeCompiler(), diskCache: .init(cachesURL: scratch))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.drawableSize = CGSize(width: 160, height: 96)
        try await present(driver, layer: layer, label: "healthy frame before script timeout")
        XCTAssertTrue(driver.hasPresentedFrame)
        XCTAssertNil(driver.runtimeFailure)
        let renderer = try XCTUnwrap(driver.renderer)
        let script = try XCTUnwrap(renderer.script)

        XCTAssertNil(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(), pointer: SIMD2(0.5, 0.5)))
        let failure = try XCTUnwrap(driver.runtimeFailure)
        XCTAssertEqual(script.engine.executionFailure, .executionTimedOut(operation: .update, seconds: 0.25))
        XCTAssertFalse(driver.needsContinuousFrames)
        let stoppedTime = renderer.clock.time
        let exceptionCount = script.engine.exceptionCount
        for _ in 0 ..< 3 {
            XCTAssertNil(driver.renderAndPresentFrame(layer: layer, timestamp: nextTimestamp(), pointer: SIMD2(0.5, 0.5)))
        }
        XCTAssertEqual(driver.runtimeFailure, failure)
        XCTAssertEqual(renderer.clock.time, stoppedTime, "A disabled scene must not step its clock or execute more JS")
        XCTAssertEqual(script.engine.exceptionCount, exceptionCount)
        XCTAssertEqual(driver.inFlightCount, 0, "The terminated update must not submit GPU work")
    }

    private func watchdogScene(script: String) throws -> (WPESceneDocument, WPEParityProgramAssets) {
        let (_, assets) = try sceneInputs()
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 160, "height": 96], "clearcolor": "0 0 0"],
            "objects": [["id": 20, "name": "solid", "image": "models/util/solidlayer.json", "origin": "80 48 0",
                         "size": "12 12", "alpha": ["value": 1, "script": script]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        return (document, assets)
    }
}
#endif
