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
        let running = ClockOverlaySchedule(suspended: false, blinking: true).entries(from: date, mode: .normal)
        #expect(running.next() == date)
        #expect(running.next() == Date(timeIntervalSince1970: 100.5))
        #expect(running.next() == Date(timeIntervalSince1970: 101))
        let stopped = ClockOverlaySchedule(suspended: true, blinking: true).entries(from: date, mode: .normal)
        #expect(stopped.next() == date)
        #expect(stopped.next() == nil)
    }

    @Test func splitFlapSpritesFollowFlipTimeline() {
        typealias Flap = SplitFlapClockView
        #expect(Flap.flipPath(from: 5, to: 0) == [6, 7, 8, 9, 0])
        #expect(Flap.flipPath(from: 9, to: -1) == [-1])
        #expect(Flap.flipPath(from: -1, to: 1) == [0, 1])
        #expect(Flap.flipPath(from: 1, to: -1).count == 9)
        #expect(Flap.flipPath(from: 3, to: 3).isEmpty)

        let chain = [6, 7, 8, 9, 0]
        let expected = [0: "SplitFlapDigit5", 1: "SplitFlapFlip56-01", 9: "SplitFlapFlip56-09",
                        10: "SplitFlapFlip67-05", 25: "SplitFlapFlip90-05", 37: "SplitFlapFlip90-17",
                        38: "SplitFlapDigit0"]
        for (slot, name) in expected {
            #expect(Flap.spriteName(from: 5, path: chain, slot: slot) == name, "slot \(slot)")
        }
        #expect(Flap.spriteName(from: 6, path: [7], slot: 17) == "SplitFlapFlip67-17")
        #expect(Flap.spriteName(from: 6, path: [7], slot: 18) == "SplitFlapDigit7")
        #expect(Flap.spriteName(from: 9, path: [-1], slot: 1) == "SplitFlapFlip9B-01")
        #expect(Flap.spriteName(from: 9, path: [-1], slot: 18) == "SplitFlapDigitBlank")
        #expect(Flap.frameSlot(38.0 / 60) == 38)
    }

    @Test func splitFlapChainsSettleBeforeNextSecond() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var longest = 0
        for uses24HourTime in [true, false] {
            for padsHour in [true, false] {
                for minute in 0 ..< 1440 {
                    let slot = SplitFlapClockView.lastAnimatedSlot(at: Date(timeIntervalSince1970: Double(minute * 60)),
                                                                   calendar: calendar, uses24HourTime: uses24HourTime,
                                                                   padsHour: padsHour)
                    #expect(slot < 60, "minute \(minute)")
                    longest = max(longest, slot)
                }
            }
        }
        #expect(longest == 58)
    }

    @MainActor @Test func splitFlapSpritesShipAtRenderedSize() throws {
        let flips = ["01", "12", "23", "34", "45", "56", "67", "78", "89", "90", "9B", "B0"]
        let names = (0 ... 9).map { "SplitFlapDigit\($0)" } + ["SplitFlapDigitBlank"]
            + flips.flatMap { pair in (1 ... 17).map { "SplitFlapFlip\(pair)-" + String(format: "%02d", $0) } }
        for name in names {
            let image = try #require(NSImage(named: name), "\(name)")
            let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            #expect(cg.width == 324 && cg.height == 537, "\(name)")
        }
        let assembly = try #require(NSImage(named: "SplitFlapAssembly"))
        let cg = try #require(assembly.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width == 2512 && cg.height == 920)
        #expect(NSBitmapImageRep(cgImage: cg).colorAt(x: 0, y: 0)?.alphaComponent == 0)
    }

    @Test func splitFlapScheduleRunsAtSixtyHertzOnlyWhileFlapsMove() {
        let flap = ClockOverlayConfiguration(style: .splitFlap)
        let schedule = ClockOverlaySchedule(suspended: false, blinking: false, splitFlap: flap)
        let oneStep = schedule.entries(from: Date(timeIntervalSince1970: 100), mode: .normal)
        for i in 0 ... 18 {
            #expect(oneStep.next() == Date(timeIntervalSince1970: 100 + Double(i) / 60), "entry \(i)")
        }
        #expect(oneStep.next() == Date(timeIntervalSince1970: 101))

        let chain = schedule.entries(from: Date(timeIntervalSince1970: 120), mode: .normal)
        var previous: Date?
        var current = chain.next()
        while let date = current, date < Date(timeIntervalSince1970: 121), previous.map({ $0 < date }) ?? true {
            previous = date
            current = chain.next()
        }
        #expect(previous == Date(timeIntervalSince1970: 120 + Double(38) / 60))
        #expect(current == Date(timeIntervalSince1970: 121))

        let stopped = ClockOverlaySchedule(suspended: true, blinking: false, splitFlap: flap)
            .entries(from: Date(timeIntervalSince1970: 100), mode: .normal)
        #expect(stopped.next() == Date(timeIntervalSince1970: 100))
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
