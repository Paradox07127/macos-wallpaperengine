import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Independent clock overlay")
struct ClockOverlayTests {
    @Test func freeSizePreservesAspectAndSafeArea() {
        let canvas = CGSize(width: 800, height: 600)
        let safe = MonitorSafeAreaInsets(top: 0.05, leading: 0.1, bottom: 0.1)
        let clock = ClockOverlayConfiguration(x: 1, y: 1, width: 1600)
        let rect = ClockOverlayLayout.renderRect(configuration: clock, canvas: canvas, safeArea: safe)
        #expect(rect.minX >= 80 && rect.maxX <= 800)
        #expect(rect.minY >= 30 && rect.maxY <= 540)
        #expect(abs(rect.width / rect.height - ClockOverlayConfiguration.aspectRatio) < 0.001)
    }

    @Test func previewMatchesDesktopAtArbitraryWidth() {
        let clock = ClockOverlayConfiguration(x: 0.81, y: 0.83, width: 731.5)
        let safe = MonitorSafeAreaInsets(top: 0.03, bottom: 0.07, trailing: 0.08)
        let desktop = ClockOverlayLayout.renderRect(configuration: clock, canvas: CGSize(width: 1920, height: 1080), safeArea: safe)
        let preview = ClockOverlayLayout.renderRect(configuration: clock, canvas: CGSize(width: 480, height: 270),
                                                    referenceWidth: 1920, safeArea: safe)
        #expect(abs(preview.width * 4 - desktop.width) < 0.001)
        #expect(abs(preview.minX * 4 - desktop.minX) < 0.001)
        #expect(abs(preview.minY * 4 - desktop.minY) < 0.001)
    }

    @Test func dropCommitsClampedPosition() {
        let canvas = CGSize(width: 960, height: 540)
        let clock = ClockOverlayConfiguration(width: 600)
        let next = ClockOverlayLayout.placing(clock, origin: CGPoint(x: 930, y: 530), canvas: canvas,
                                              referenceWidth: 1920, safeArea: .none)
        #expect(abs(next.x - 660 / 960.0) < 0.001)
        let rect = ClockOverlayLayout.renderRect(configuration: next, canvas: canvas, referenceWidth: 1920)
        #expect(abs(rect.maxX - 960) < 0.001 && abs(rect.maxY - 540) < 0.001)
        #expect(next.width == 600)
    }

    @Test func twelveHourMidnightNoonAndUnlitLeadingTube() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(NixieClockView.digits(at: Date(timeIntervalSince1970: 0), calendar: calendar,
                                      uses24HourTime: false) == [1, 2, 0, 0, 0, 0])
        #expect(NixieClockView.digits(at: Date(timeIntervalSince1970: 43200), calendar: calendar,
                                      uses24HourTime: false) == [1, 2, 0, 0, 0, 0])
        #expect(NixieClockView.digits(at: Date(timeIntervalSince1970: 46800), calendar: calendar,
                                      uses24HourTime: false, padsHour: false) == [-1, 1, 0, 0, 0, 0])
    }

    @Test func blinkChangesOnlyOnHalfSecondBoundary() {
        #expect(NixieClockView.separatorsLit(at: Date(timeIntervalSince1970: 100.499), blinking: true))
        #expect(!NixieClockView.separatorsLit(at: Date(timeIntervalSince1970: 100.5), blinking: true))
        #expect(NixieClockView.separatorsLit(at: Date(timeIntervalSince1970: 101), blinking: true))
        #expect(NixieClockView.separatorsLit(at: Date(timeIntervalSince1970: 100.7), blinking: false))
    }

    @Test func scheduleAlignsToWallClockAndStopsWhenSuspended() {
        let date = Date(timeIntervalSince1970: 100.2)
        var running = ClockOverlaySchedule(suspended: false, blinking: true).entries(from: date, mode: .normal)
        #expect(running.next() == date)
        #expect(running.next() == Date(timeIntervalSince1970: 100.5))
        #expect(running.next() == Date(timeIntervalSince1970: 101))
        var stopped = ClockOverlaySchedule(suspended: true, blinking: true).entries(from: date, mode: .normal)
        #expect(stopped.next() == date)
        #expect(stopped.next() == nil)
    }

    @Test func clockVisibilityNeverRequestsSampling() {
        let key = MonitorOverlayHostKey(screenID: 1, module: .clock)
        let input = MonitorOverlayVisibilityInput(key: key, level: .desktop, isDesktopOccluded: false)
        let visible = MonitorOverlayVisibilityPolicy.resolve(hosts: [input], isUserAbsent: false)
        #expect(visible.visibleHostKeys == [key])
        #expect(visible.runtimeDisposition == .released && !visible.pumpShouldRun)
        let absent = MonitorOverlayVisibilityPolicy.resolve(hosts: [input], isUserAbsent: true)
        #expect(absent.suspendedHostKeys == [key] && absent.visibleHostKeys.isEmpty)
        #expect(absent.runtimeDisposition == .released)
        var covered = input
        covered.isDesktopOccluded = true
        #expect(MonitorOverlayVisibilityPolicy.resolve(hosts: [covered], isUserAbsent: false).visibleHostKeys.isEmpty)
    }

    @MainActor @Test func realClockHostRunsWithoutWidgetBoard() async {
        let runtime = Runtime()
        let controller = OverlayController(runtime: runtime)
        controller.apply(overlay: MonitorOverlayConfiguration(clock: ClockOverlayConfiguration(enabled: true)),
                         screenID: 601, screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600))
        await controller.waitUntilRuntimeSettled()
        #expect(controller.activeHostKeys == [MonitorOverlayHostKey(screenID: 601, module: .clock)])
        #expect(controller.board(screenID: 601, module: .monitor) == nil)
        #expect(OverlayController.stackingOrder([.music, .clock, .monitor]) == [.monitor, .clock, .music])
        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    @MainActor @Test func offAssetsPreservePhysicalGlass() throws {
        for name in ["NixieAssemblyOff", "NixieDigitOff"] {
            let image = try #require(NSImage(named: name))
            let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cg)
            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
            if name == "NixieAssemblyOff" {
                #expect((bitmap.colorAt(x: 828, y: 339)?.alphaComponent ?? 0) > 0.1)
                #expect((bitmap.colorAt(x: 1256, y: 816)?.alphaComponent ?? 0) > 0.99)
            }
        }
    }
}
