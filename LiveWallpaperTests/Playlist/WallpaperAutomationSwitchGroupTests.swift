import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

private final class SwitchGroupTestNSScreen: NSScreen {
    var displayID: UInt32 = 1
    override var frame: NSRect {
        NSRect(x: CGFloat(displayID) * 800, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "Switch Group Test"
    }
}

@Suite("Wallpaper automation switch group")
@MainActor
struct WallpaperAutomationSwitchGroupTests {
    private func makeScreen(id: UInt32) -> Screen {
        let nsScreen = SwitchGroupTestNSScreen()
        nsScreen.displayID = id
        return Screen(nsScreen: nsScreen)
    }

    @Test("Each tick runs its handlers inside one automatic switch group that their tasks inherit", .timeLimit(.minutes(1)))
    func handlersRunInsideOneAutomaticGroup() async throws {
        let screens = [makeScreen(id: 41), makeScreen(id: 42)]
        let ticks = AsyncStream<Date>.makeStream()
        let coordinator = WallpaperAutomationCoordinator(tickStreamFactory: { ticks.stream })
        var scheduleGroups: [WallpaperSwitchGroup?] = []
        var playlistGroups: [WallpaperSwitchGroup?] = []
        var childTasks: [Task<WallpaperSwitchGroup?, Never>] = []
        coordinator.start(
            screenProvider: { screens },
            configurationProvider: { id in
                ScreenConfiguration(
                    screenID: id,
                    videoBookmarkData: Data([0x01]),
                    playlistBookmarks: [Data([0x02])],
                    playlistRotationMinutes: 30
                )
            },
            scheduleHandler: { _ in scheduleGroups.append(WallpaperSwitchGroup.current) },
            playlistHandler: { _ in
                playlistGroups.append(WallpaperSwitchGroup.current)
                childTasks.append(Task { WallpaperSwitchGroup.current })
            },
            runInitialScheduleCheck: true
        )
        defer { coordinator.stop() }

        #expect(scheduleGroups.count == 2)
        #expect(scheduleGroups.allSatisfy { $0?.pace == .automatic })
        #expect((scheduleGroups.first ?? nil) === (scheduleGroups.last ?? nil))

        let t0 = Date(timeIntervalSince1970: 1000)
        for minute in [0.0, 31] {
            let now = t0.addingTimeInterval(minute * 60)
            ticks.continuation.yield(now)
            while coordinator.currentTime != now {
                await Task.yield()
            }
        }

        #expect(playlistGroups.count == 2)
        let group = try #require(playlistGroups.first ?? nil)
        #expect(group.pace == .automatic)
        #expect(playlistGroups.allSatisfy { $0 === group })
        for task in childTasks {
            #expect(await task.value === group)
        }
    }
}
