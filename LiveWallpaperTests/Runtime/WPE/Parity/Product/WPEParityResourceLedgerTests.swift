#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Metal
import QuartzCore
import XCTest

final class WPEParityResourceLedgerTests: XCTestCase {
    func testTransitionsMoveBytesBetweenStates() {
        let ledger = WPEParityResourceLedger()
        let first = NSObject()
        let second = NSObject()
        ledger.record(first, .candidate, bytes: 100)
        XCTAssertEqual(ledger.totals(), .init(candidate: 100, live: 0, retiring: 0, peak: 100))
        ledger.record(first, .live, bytes: 120)
        ledger.record(second, .candidate, bytes: 50)
        XCTAssertEqual(ledger.totals(), .init(candidate: 50, live: 120, retiring: 0, peak: 170))
        ledger.record(first, .retiring, bytes: 120)
        ledger.record(second, .live, bytes: 60)
        XCTAssertEqual(ledger.totals(), .init(candidate: 0, live: 60, retiring: 120, peak: 180))
        withExtendedLifetime((first, second)) {}
    }

    func testReleasedOwnerLeavesTheTotals() {
        let ledger = WPEParityResourceLedger()
        let kept = NSObject()
        ledger.record(kept, .live, bytes: 10)
        autoreleasepool {
            let retired = NSObject()
            ledger.record(retired, .retiring, bytes: 30)
            XCTAssertEqual(ledger.totals().retiring, 30)
            withExtendedLifetime(retired) {}
        }
        XCTAssertEqual(ledger.totals(), .init(candidate: 0, live: 10, retiring: 0, peak: 40))
        withExtendedLifetime(kept) {}
    }

    func testPeakKeepsTheHighestSumUntilReset() {
        let ledger = WPEParityResourceLedger()
        let old = NSObject()
        let new = NSObject()
        ledger.record(old, .live, bytes: 100)
        ledger.record(new, .candidate, bytes: 80)
        ledger.record(old, .retiring, bytes: 100)
        ledger.record(new, .live, bytes: 80)
        ledger.record(old, .retiring, bytes: 10)
        XCTAssertEqual(ledger.totals(), .init(candidate: 0, live: 80, retiring: 10, peak: 180))
        ledger.resetPeak()
        XCTAssertEqual(ledger.totals().peak, 90)
        ledger.record(new, .live, bytes: 70)
        XCTAssertEqual(ledger.totals(), .init(candidate: 0, live: 70, retiring: 10, peak: 90))
        withExtendedLifetime((old, new)) {}
    }
}

extension WPEParitySceneDriverTests {
    /// Repeated resize replans leave only the current renderer in the ledger, all of it live.
    func testRepeatedReplansLeaveOnlyTheLiveRendererInTheResourceLedger() async throws {
        let (document, assets) = try sceneInputs()
        let compiler = try makeCompiler()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        let ledger = WPEParityResourceLedger()
        driver.resourceLedger = ledger
        defer { driver.cleanup() }
        let sizes = [CGSize(width: 320, height: 180), CGSize(width: 400, height: 224)]
        try await driver.load(document: document, assets: assets, settings: .init(), drawableSize: sizes[0],
                              pixelFormat: .bgra8Unorm_srgb, compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "ledger-cache")),
                              renderScaleOverride: 1)
        XCTAssertNil(driver.loadDiagnostics)
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = sizes[0]
        layer.framebufferOnly = false
        try await present(driver, layer: layer, label: "loaded frame")
        func bytes(_ renderer: WPEParityFrameRenderer) -> Int {
            renderer.arenaBytes + renderer.heapBytes + renderer.dedicatedTextureBytes
        }
        var held: WPEParityFrameRenderer?
        for index in 1 ... 20 {
            let size = sizes[index % 2]
            layer.drawableSize = size
            driver.updateSurfaceGeometry(drawableSize: size)
            if index == 20 {
                held = driver.renderer
            }
            let replanned = await driver.replan()
            XCTAssertTrue(replanned, "replan \(index)")
            if let held {
                let current = try XCTUnwrap(driver.renderer)
                XCTAssertEqual(ledger.totals().retiring, bytes(held), "a held replaced renderer counts as retiring")
                XCTAssertEqual(ledger.totals().live, bytes(current))
            }
            try await present(driver, layer: layer, label: "frame after replan \(index)")
        }
        held = nil
        try await settle(driver, label: "after replans")
        let renderer = try XCTUnwrap(driver.renderer)
        let totals = ledger.totals()
        XCTAssertEqual(totals.candidate, 0)
        XCTAssertEqual(totals.retiring, 0)
        XCTAssertEqual(totals.live, bytes(renderer))
        XCTAssertGreaterThanOrEqual(totals.peak, totals.live)
        print("Parity resource ledger after 20 replans: peak \(totals.peak) B, live \(totals.live) B")
    }
}
#endif
