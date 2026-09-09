import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import XCTest

@MainActor
final class SystemOverviewWidgetTests: XCTestCase {
    private func context(size: MonitorWidgetSize = .large) -> MonitorWidgetContext {
        let fixture = MonitorBoardPreviewFixture.sample()
        return MonitorWidgetContext(
            snapshot: fixture.snapshot, history: fixture.history,
            placement: MonitorWidgetPlacement(kind: .systemOverview, size: size),
            isEditing: false, reduceMotion: true, now: fixture.capturedAt
        )
    }

    func testOneOverviewSamplesSixGroupsWithoutProcessOrAccessoryScans() {
        XCTAssertTrue(MonitorRuntimeOptions.requiresSystemMetrics(for: [.systemOverview]))
        let options = Runtime.systemOptions(for: [.systemOverview])
        XCTAssertTrue(options.cpu && options.memory && options.gpu && options.network && options.disk && options.power)
        XCTAssertFalse(options.topProcesses || options.processIO || options.ane || options.accessories)
        XCTAssertEqual(InteractionModel.defaultSize(for: .systemOverview), .medium)
    }

    func testSensorsFollowVisibleSizeAndStoredToggle() {
        var widget = context(size: .medium).placement
        XCTAssertFalse(MonitorSampleDemand.of([widget]).sensors)
        widget.size = .large
        XCTAssertTrue(MonitorSampleDemand.of([widget]).sensors)
        widget.options[MonitorWidgetDraft.showSensorsKey] = .bool(false)
        XCTAssertFalse(MonitorSampleDemand.of([widget]).sensors)
        let narrowed = Runtime.narrowed(Runtime.systemOptions(for: [.systemOverview]), to: .of([widget]))
        XCTAssertFalse(narrowed.sensors)
        XCTAssertTrue(narrowed.cpu && narrowed.gpu && narrowed.memory)
    }

    func testOverviewParticipatesInSharedGPUCadence() {
        var overview = context().placement
        overview = MonitorWidgetDraft.settingGPUSampleSeconds(10, on: overview)
        XCTAssertEqual(MonitorWidgetDraft.gpuSampleSeconds(in: [overview]), 10)
        let standalone = MonitorWidgetPlacement(kind: .gpu)
        XCTAssertEqual(MonitorWidgetDraft.gpuSampleSeconds(in: [overview, standalone]), 6)
        overview = MonitorWidgetDraft.settingGPUSampleSeconds(2, on: overview)
        XCTAssertEqual(MonitorWidgetDraft.gpuSampleSeconds(in: [overview, standalone]), 2)
    }

    func testMissingAndStaleSourcesDoNotBlankHealthyInstruments() {
        var ctx = context()
        ctx.snapshot.system?.metricSamples?["gpu"]?.available = false
        ctx.snapshot.system?.metricSamples?["disk"]?.sampledAt = ctx.now.timeIntervalSince1970 - 120
        // There is deliberately no made-up aggregate metric from the sampler.
        ctx.snapshot.system?.metricSamples?.removeValue(forKey: "systemOverview")
        XCTAssertNil(ctx.readingsNotice)
        let readings = SystemOverviewReadings(context: ctx)
        XCTAssertEqual(readings.cpu, 0.42)
        XCTAssertNotNil(readings.memory)
        XCTAssertNil(readings.gpu)
        XCTAssertNil(readings.diskRead)
        XCTAssertNil(readings.diskWrite)
        XCTAssertEqual(readings.download, 8_400_000)
    }

    func testFreshZeroIsAReadingAndInvalidNumbersAreNot() {
        var ctx = context()
        ctx.snapshot.system?.cpuTotal = 0
        ctx.snapshot.system?.netRxBytesPerSec = 0
        ctx.snapshot.system?.gpuUsage = .nan
        ctx.snapshot.system?.diskReadBytesPerSec = .infinity
        ctx.snapshot.system?.memTotalBytes = 0
        let readings = SystemOverviewReadings(context: ctx)
        XCTAssertEqual(readings.cpu, 0)
        XCTAssertEqual(readings.download, 0)
        XCTAssertNil(readings.gpu)
        XCTAssertNil(readings.diskRead)
        XCTAssertNil(readings.memory)
    }

    func testDesktopPowerAndMissingSnapshotNeverInventBatteryLevel() {
        var ctx = context()
        ctx.snapshot.system?.batteryLevel = nil
        ctx.snapshot.system?.powerSource = "ac"
        let desktop = SystemOverviewReadings(context: ctx)
        XCTAssertNil(desktop.battery)
        XCTAssertEqual(desktop.powerSource, "ac")
        ctx.snapshot.system = nil
        XCTAssertNotNil(ctx.readingsNotice)
        let absent = SystemOverviewReadings(context: ctx)
        XCTAssertNil(absent.cpu)
        XCTAssertNil(absent.memory)
        XCTAssertNil(absent.download)
        XCTAssertNil(absent.battery)
    }

    func testLargeOptionsPersistWhileMediumKeepsItsCompactLayout() {
        var placement = context().placement
        XCTAssertTrue(SystemOverviewOptions.showsHistory(placement))
        placement = MonitorWidgetDraft.settingHistoryWindow(tag: 120, clearValue: 60, on: placement)
        XCTAssertEqual(SystemOverviewOptions.historyWindow(placement), 120)
        placement.size = .medium
        XCTAssertFalse(SystemOverviewOptions.showsHistory(placement))
        XCTAssertFalse(SystemOverviewOptions.showsSensors(placement))
        placement.size = .large
        XCTAssertEqual(SystemOverviewOptions.historyWindow(placement), 120)
        XCTAssertTrue(SystemOverviewOptions.showsSensors(placement))
    }

    /// Capture the production SwiftUI view in an AppKit host at actual board
    /// dimensions. These images are visual QA artifacts, not pixel baselines.
    func testNativeLayoutsAndCapture() throws {
        for size in [MonitorWidgetSize.medium, .large] {
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "es", "stress"] {
                let dimensions = NSSize(width: 356, height: size == .large ? 356 : 170)
                var fixture = context(size: size)
                if language == "stress" {
                    fixture.snapshot.system?.cpuTotal = 1
                    fixture.snapshot.system?.gpuUsage = 1
                    fixture.snapshot.system?.memUsedBytes = 512 * 1_073_741_824
                    fixture.snapshot.system?.memTotalBytes = 512 * 1_073_741_824
                    fixture.snapshot.system?.memPressure = "critical"
                    fixture.snapshot.system?.netRxBytesPerSec = 99.9 * 1_073_741_824
                    fixture.snapshot.system?.netTxBytesPerSec = 99.9 * 1_073_741_824
                    fixture.snapshot.system?.diskReadBytesPerSec = 99.9 * 1_073_741_824
                    fixture.snapshot.system?.diskWriteBytesPerSec = 99.9 * 1_073_741_824
                    fixture.snapshot.system?.batteryLevel = nil
                    fixture.snapshot.system?.powerSource = "ac"
                }
                let view = WidgetFactory.tile(context: fixture)
                    .environment(\.locale, Locale(identifier: language == "stress" ? "es" : language))
                    .frame(width: dimensions.width, height: dimensions.height)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: dimensions),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderBack(nil)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                XCTAssertLessThanOrEqual(host.fittingSize.width, dimensions.width + 1)
                XCTAssertLessThanOrEqual(host.fittingSize.height, dimensions.height + 1)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("system-overview-\(size.rawValue)-\(language).png")
                try png.write(to: url)
                print("SYSTEM_OVERVIEW_CAPTURE: \(url.path)")
            }
        }
    }
}
