import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import XCTest

@MainActor
final class NixieClockWidgetTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func context() -> MonitorWidgetContext {
        MonitorWidgetContext(
            snapshot: MonitorSnapshot(), history: MonitorHistorySnapshot(),
            placement: MonitorWidgetPlacement(kind: .nixieClock, size: .medium),
            isEditing: false, reduceMotion: true, now: Date(timeIntervalSince1970: 75636)
        )
    }

    func testClockWorksWithoutReadingsOrSamplers() {
        XCTAssertNil(context().readingsNotice)
        XCTAssertFalse(MonitorRuntimeOptions.requiresSystemMetrics(for: [.nixieClock]))
        XCTAssertEqual(MonitorSampleDemand.of([context().placement]), MonitorSampleDemand())
        let options = Runtime.systemOptions(for: [.nixieClock])
        XCTAssertFalse(options.cpu || options.memory || options.gpu || options.network || options.disk || options.power)
        XCTAssertFalse(options.sensors || options.topProcesses || options.processIO || options.ane || options.accessories)
    }

    func testTimeRollsOverWithoutLosingLeadingZeroes() {
        XCTAssertEqual(NixieClockView.digits(at: Date(timeIntervalSince1970: 0), calendar: calendar), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(NixieClockView.digits(at: Date(timeIntervalSince1970: 86399), calendar: calendar), [2, 3, 5, 9, 5, 9])
        XCTAssertEqual(NixieClockView.digits(at: Date(timeIntervalSince1970: 86400), calendar: calendar), [0, 0, 0, 0, 0, 0])
    }

    func testEveryDigitPreservesTransparentExteriorAndTranslucentGlass() throws {
        for digit in 0 ... 9 {
            let image = try XCTUnwrap(NSImage(named: "NixieDigit\(digit)"))
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
            XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.001)
            let glass = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 5))
            XCTAssertGreaterThan(glass.alphaComponent, 0.01)
            XCTAssertLessThan(glass.alphaComponent, 0.8, "Glass must transmit the desktop, not the old black studio background")
        }
        let assembly = try XCTUnwrap(NSImage(named: "NixieAssembly"))
        let cgAssembly = try XCTUnwrap(assembly.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgAssembly)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 1256, y: 200)).alphaComponent, 0, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 1256, y: 816)).alphaComponent, 0.99)
        for x in [828, 1684] {
            let discharge = try XCTUnwrap(bitmap.colorAt(x: x, y: 339)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(discharge.redComponent, 0.8)
            XCTAssertGreaterThan(discharge.alphaComponent, 0.8)
        }
    }

    func testFitsBothBoardSizesWithoutStretchingTubes() {
        for bounds in [CGSize(width: 356, height: 170), CGSize(width: 356, height: 356)] {
            let fitted = NixieClockView.fittedSize(in: bounds)
            XCTAssertLessThanOrEqual(fitted.width, bounds.width)
            XCTAssertLessThanOrEqual(fitted.height, bounds.height)
            XCTAssertEqual(fitted.width / fitted.height, 1256 / 460, accuracy: 0.001)
        }
    }

    func testNativeTransparentCompositionAndCapture() throws {
        let dimensions = NSSize(width: 900, height: 300)
        let root = NixieClockView(now: context().now).frame(width: dimensions.width, height: dimensions.height)
        let host = NSHostingView(rootView: root)
        let window = OverlayWindow(screenFrame: NSRect(origin: .zero, size: dimensions), level: .desktop)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)).alphaComponent, 0.01)
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.hasShadow)
        XCTAssertGreaterThan(window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)))
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nixie-native-transparent.png")
        try png.write(to: url)
        print("NIXIE_NATIVE_CAPTURE: \(url.path)")
    }

    func testClockSettingsPanelLayoutAndCapture() throws {
        let screen = try Screen(nsScreen: XCTUnwrap(NSScreen.main))
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: []),
            featureCatalog: FeatureCatalog(capabilities: .pro), originReconciler: PreservingOriginReconciler()
        ))
        let root = ClockOverlaySection(screen: screen, screenManager: manager, backdropAvailable: false)
            .padding(16).frame(width: 380, height: 560, alignment: .top)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clock-settings-native.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertGreaterThan(host.fittingSize.height, 300)
        print("CLOCK_SETTINGS_CAPTURE: \(url.path)")
    }
}
