import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
private final class AvailabilityGate {
    private(set) var pending: [(id: String, continuation: CheckedContinuation<Bool, Never>)] = []

    func check(_ entry: WallpaperQueueEntry) async -> Bool {
        await withCheckedContinuation { pending.append((entry.id, $0)) }
    }

    func waitForPending(_ count: Int) async {
        for _ in 0 ..< 200 where pending.count < count {
            await Task.yield()
        }
    }

    func resumeOldest(_ available: Bool) -> String? {
        guard !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        next.continuation.resume(returning: available)
        return next.id
    }
}

private func settle() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }
}

@Suite("Queue edits during an automatic selection")
@MainActor
struct AutomationQueueEditRaceTests {
    private let rows = ["A", "B", "C"].map { WallpaperQueueEntry(id: $0, title: $0, content: .html(source: .inline($0), config: .default)) }

    private func makeRig(screen: Screen) -> (WallpaperAutomationOrchestrator, WallpaperConfigurationStore, AvailabilityGate, () -> [WallpaperContent]) {
        var config = ScreenConfiguration(screenID: screen.id, wallpaper: rows[0].content)
        config.wallpaperMode = .playlist
        config.wallpaperQueue = rows
        config.playlistCursorIndex = 0
        let persistence = ScreenManagerFixtureState()
        persistence.saveConfiguration(config)
        let store = WallpaperConfigurationStore(persistence: persistence)
        _ = store.loadAll()
        let gate = AvailabilityGate()
        var landed: [WallpaperContent] = []
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, _, intended in
                guard intended() else { return .cancelled }
                landed.append(proposed.activeWallpaper)
                store.save(proposed)
                return .ready
            },
            libraryEntryAvailable: { await gate.check($0) }
        )
        return (orchestrator, store, gate, { landed })
    }

    @Test("Saving a queue without the row being checked stops that row from landing", .timeLimit(.minutes(1)))
    func savedQueueWithoutCandidateCancelsIt() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let (orchestrator, store, gate, landed) = makeRig(screen: screen)

        orchestrator.advancePlaylist(for: screen)
        await gate.waitForPending(1)
        #expect(gate.pending.map(\.id) == ["B"])

        orchestrator.updateAutomation(queue: [rows[0], rows[2]], slots: [], mode: .playlist, rotationMinutes: nil, shuffle: false, for: screen)
        _ = gate.resumeOldest(true)
        await settle()
        while gate.resumeOldest(true) != nil {
            await settle()
        }

        #expect(!landed().contains(rows[1].content), "a row removed from the queue was still shown")
        let saved = try #require(store.get(for: screen.id))
        #expect(saved.activeWallpaper == rows[0].content)
        #expect(saved.playlistCursorIndex == 0)
    }

    @Test("A row removed behind the selection's back is skipped and the next row lands at its own index", .timeLimit(.minutes(1)))
    func removedCandidateIsSkippedAfterTheCheck() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let (orchestrator, store, gate, landed) = makeRig(screen: screen)

        orchestrator.advancePlaylist(for: screen)
        await gate.waitForPending(1)
        var edited = try #require(store.get(for: screen.id))
        edited.wallpaperQueue = [rows[0], rows[2]]
        store.save(edited)
        _ = gate.resumeOldest(true)
        await gate.waitForPending(1)
        #expect(gate.pending.map(\.id) == ["C"], "the selection did not move on past the removed row")
        _ = gate.resumeOldest(true)
        await settle()

        #expect(landed() == [rows[2].content], "a row removed from the queue was still shown")
        #expect(store.get(for: screen.id)?.playlistCursorIndex == 1, "the cursor kept the index from the old queue")
    }

    @Test("A row inserted ahead of the candidate moves the cursor with the candidate", .timeLimit(.minutes(1)))
    func cursorFollowsCandidateID() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let (orchestrator, store, gate, landed) = makeRig(screen: screen)
        let inserted = WallpaperQueueEntry(id: "X", title: "X", content: .html(source: .inline("X"), config: .default))

        orchestrator.advancePlaylist(for: screen)
        await gate.waitForPending(1)
        var edited = try #require(store.get(for: screen.id))
        edited.wallpaperQueue = [rows[0], inserted, rows[1], rows[2]]
        store.save(edited)
        _ = gate.resumeOldest(true)
        await settle()

        #expect(landed() == [rows[1].content])
        #expect(store.get(for: screen.id)?.playlistCursorIndex == 2, "the cursor points at a different row than the one shown")
    }
}

@Suite("Schedule after a time zone change")
@MainActor
struct ScheduleTimeZoneChangeTests {
    private static let morning = WallpaperQueueEntry(id: "morning", title: "Morning", content: .html(source: .inline("morning"), config: .default))
    private static let afternoon = WallpaperQueueEntry(id: "afternoon", title: "Afternoon", content: .html(source: .inline("afternoon"), config: .default))
    private static let fallback = WallpaperQueueEntry(id: "fallback", title: "Fallback", content: .video(bookmarkData: Data([9])))

    private static func utc(_ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: hour))!
    }

    @MainActor
    private final class Rig {
        var calendar: Calendar
        var landed: [WallpaperContent] = []
        let store: WallpaperConfigurationStore
        var orchestrator: WallpaperAutomationOrchestrator!

        init(screen: Screen, clock: Date) {
            calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            var config = ScreenConfiguration(screenID: screen.id, wallpaper: ScheduleTimeZoneChangeTests.fallback.content)
            config.wallpaperMode = .schedule
            config.scheduleFallback = ScheduleTimeZoneChangeTests.fallback
            config.scheduleSlots = [
                ScheduleSlot(startHour: 6, endHour: 12, label: "Morning", wallpaper: ScheduleTimeZoneChangeTests.morning),
                ScheduleSlot(startHour: 12, endHour: 18, label: "Afternoon", wallpaper: ScheduleTimeZoneChangeTests.afternoon),
            ]
            let persistence = ScreenManagerFixtureState()
            persistence.saveConfiguration(config)
            let store = WallpaperConfigurationStore(persistence: persistence)
            _ = store.loadAll()
            self.store = store
            let idle = AsyncStream<Date>.makeStream().stream
            orchestrator = WallpaperAutomationOrchestrator(
                configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(tickStreamFactory: { idle }),
                screensProvider: { [screen] }, saveConfiguration: { store.save($0) }, restoreProposedConfiguration: { _, _ in },
                bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true }, now: { clock },
                calendar: { [weak self] in self?.calendar ?? .current },
                prepareAutomation: { [weak self] _, proposed, _, intended in
                    guard intended() else { return .cancelled }
                    self?.landed.append(proposed.activeWallpaper)
                    store.save(proposed)
                    return .ready
                },
                libraryEntryAvailable: { _ in true }
            )
        }
    }

    @Test("A zone change re-plans the slot at once, or on return when it happens while the user is away", .timeLimit(.minutes(1)), arguments: [false, true])
    func zoneChangeReplansTheSlot(whileAway: Bool) async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let rig = Rig(screen: screen, clock: Self.utc(9))
        rig.orchestrator.startMonitoring()
        defer { rig.orchestrator.stopMonitoring() }
        await settle()
        #expect(rig.landed == [Self.morning.content])
        #expect(rig.store.get(for: screen.id)?.scheduleSettledUntil == Self.utc(12))

        if whileAway {
            rig.orchestrator.suspendForUserAbsence()
        }
        rig.calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3 * 3600))
        rig.orchestrator.handleTimeZoneChange()
        if whileAway {
            rig.orchestrator.resumeAfterUserAbsence()
        }
        await settle()

        #expect(rig.landed.last == Self.afternoon.content, "the slot settled under the old zone kept the display on the wrong wallpaper")
        #expect(rig.store.get(for: screen.id)?.scheduleSettledUntil == Self.utc(15), "the next boundary was not recomputed in the new zone")
    }

    @Test("A hand-picked wallpaper keeps holding across a zone change, until the next slot edge of the new zone", .timeLimit(.minutes(1)))
    func manualHoldIsRebasedToTheNewZone() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let rig = Rig(screen: screen, clock: Self.utc(9))
        rig.orchestrator.startMonitoring()
        defer { rig.orchestrator.stopMonitoring() }
        await settle()
        var picked = try #require(rig.store.get(for: screen.id))
        picked.activeWallpaper = .html(source: .inline("picked"), config: .default)
        rig.store.save(picked)

        rig.calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3 * 3600))
        rig.orchestrator.handleTimeZoneChange()
        await settle()

        let saved = try #require(rig.store.get(for: screen.id))
        #expect(rig.landed == [Self.morning.content], "a zone change overrode the hand-picked wallpaper")
        #expect(saved.activeWallpaper == picked.activeWallpaper)
        #expect(saved.scheduleSettledUntil == Self.utc(15), "the hold still ends at the old zone's slot edge")
    }
}
