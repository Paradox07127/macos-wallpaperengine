import AppKit
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import os
import Testing

@MainActor
final class DisplaySettingsCoordinatorTests {
    private static let native = DisplayModeKey(width: 3024, height: 1964, pixelWidth: 3024, pixelHeight: 1964, refreshRate: 60)
    private static let looksLike1512 = DisplayModeKey(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refreshRate: 120)
    private static let looksLike1800 = DisplayModeKey(width: 1800, height: 1169, pixelWidth: 3600, pixelHeight: 2338, refreshRate: 120)

    private let displays = FakeDisplays()
    /// Named after the first test function that asks for it; every coordinator in that test shares it.
    private var suite: TestScratch.DefaultsSuite?

    isolated deinit {
        suite?.discard()
    }

    private func makeCoordinator(
        confirmationTimeout: TimeInterval = 15, function: String = #function
    ) throws -> DisplaySettingsCoordinator {
        let suite = try suite ?? TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.DisplaySettingsCoordinator", function: function)
        self.suite = suite
        return DisplaySettingsCoordinator(hardware: displays.hardware, defaults: suite.defaults, confirmationTimeout: confirmationTimeout)
    }

    /// No NSScreenNumber, so the fingerprint is keyed by the name and the ID derives from the frame.
    private static func makeScreen(_ index: Int) -> Screen {
        let nsScreen = FakeNSScreen()
        nsScreen.index = index
        return Screen(nsScreen: nsScreen, displayPixelSize: { _ in nil })
    }

    @Test func turningOffRecordsTheDisplayAndTheRecordSurvivesRelaunch() async throws {
        let coordinator = try makeCoordinator()
        let screen = Self.makeScreen(1)

        try await coordinator.turnOff(screen)

        let expected = DisabledDisplay(
            fingerprint: screen.displayFingerprint,
            lastDisplayID: screen.id,
            name: screen.name,
            frame: screen.frame,
            isBuiltin: false
        )
        #expect(displays.calls == [.setEnabled(false, screen.id)])
        #expect(coordinator.disabledDisplays == [expected])
        #expect(try makeCoordinator().disabledDisplays == [expected])
    }

    @Test func failedTurnOffRecordsNothing() async throws {
        let coordinator = try makeCoordinator()
        let screen = Self.makeScreen(1)
        displays.fail(screen.id)

        await #expect(throws: FakeDisplayFailure.self) { try await coordinator.turnOff(screen) }

        #expect(coordinator.disabledDisplays.isEmpty)
        #expect(try makeCoordinator().disabledDisplays.isEmpty)
    }

    @Test func failedTurnOffThatBlankedTheDisplayKeepsItsRecord() async throws {
        let coordinator = try makeCoordinator()
        let screen = Self.makeScreen(1)
        displays.failAfterBlanking(screen.id)

        await #expect(throws: FakeDisplayFailure.self) { try await coordinator.turnOff(screen) }

        #expect(coordinator.disabledDisplays.map(\.fingerprint) == [screen.displayFingerprint])
        #expect(try makeCoordinator().disabledDisplays.map(\.fingerprint) == [screen.displayFingerprint])
    }

    @Test func turnOnRemovesTheRecordOnlyWhenItSucceeds() async throws {
        let coordinator = try makeCoordinator()
        let succeeding = Self.makeScreen(1)
        let failing = Self.makeScreen(2)
        try await coordinator.turnOff(succeeding)
        try await coordinator.turnOff(failing)
        displays.fail(failing.id)
        let records = coordinator.disabledDisplays

        try await coordinator.turnOn(records[0])
        await #expect(throws: FakeDisplayFailure.self) { try await coordinator.turnOn(records[1]) }

        #expect(coordinator.disabledDisplays.map(\.fingerprint) == [failing.displayFingerprint])
        #expect(try makeCoordinator().disabledDisplays.map(\.fingerprint) == [failing.displayFingerprint])
    }

    @Test func restoreAllSwitchesEveryRecordOnPastAFailure() async throws {
        let coordinator = try makeCoordinator()
        let screens = [Self.makeScreen(1), Self.makeScreen(2), Self.makeScreen(3)]
        for screen in screens {
            try await coordinator.turnOff(screen)
        }
        displays.fail(screens[1].id)

        await coordinator.restoreAll()

        let switchedOn = displays.calls.filter { $0 == .setEnabled(true, $0.displayID) }
        #expect(switchedOn == screens.map { .setEnabled(true, $0.id) })
        #expect(coordinator.disabledDisplays.map(\.fingerprint) == [screens[1].displayFingerprint])
    }

    @Test func aRecordIsDroppedWhenItsDisplayComesBackOnline() async throws {
        let coordinator = try makeCoordinator()
        let returning = Self.makeScreen(1)
        let stillOff = Self.makeScreen(2)
        try await coordinator.turnOff(returning)
        try await coordinator.turnOff(stillOff)

        coordinator.forgetDisplaysBackOnline(in: [returning, Self.makeScreen(3)])

        #expect(coordinator.disabledDisplays.map(\.fingerprint) == [stillOff.displayFingerprint])
        #expect(try makeCoordinator().disabledDisplays.map(\.fingerprint) == [stillOff.displayFingerprint])
    }

    @Test(.timeLimit(.minutes(1)))
    func anUnconfirmedModeChangeRevertsAfterTheTimeout() async throws {
        let coordinator = try makeCoordinator(confirmationTimeout: 0.05)
        let screen = Self.makeScreen(1)
        displays.setMode(Self.native, for: screen.id)

        try await coordinator.applyMode(Self.looksLike1512, to: screen)
        #expect(coordinator.pendingConfirmation?.displayID == screen.id)

        while displays.mode(of: screen.id) != Self.native {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.pendingConfirmation == nil)
        #expect(displays.calls == [.applyMode(Self.looksLike1512, screen.id), .applyMode(Self.native, screen.id)])
    }

    @Test(.timeLimit(.minutes(1)))
    func aKeptModeChangeIsNotReverted() async throws {
        let coordinator = try makeCoordinator(confirmationTimeout: 0.05)
        let screen = Self.makeScreen(1)
        displays.setMode(Self.native, for: screen.id)

        try await coordinator.applyMode(Self.looksLike1512, to: screen)
        coordinator.keepPendingChange()
        try await Task.sleep(for: .milliseconds(300))

        #expect(coordinator.pendingConfirmation == nil)
        #expect(displays.mode(of: screen.id) == Self.looksLike1512)
        #expect(displays.calls == [.applyMode(Self.looksLike1512, screen.id)])
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondChangeKeepsTheFirst() async throws {
        let coordinator = try makeCoordinator(confirmationTimeout: 0.1)
        let screen = Self.makeScreen(1)
        displays.setMode(Self.native, for: screen.id)

        try await coordinator.applyMode(Self.looksLike1512, to: screen)
        try await coordinator.applyMode(Self.looksLike1800, to: screen)

        while displays.mode(of: screen.id) != Self.looksLike1512 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(displays.mode(of: screen.id) == Self.looksLike1512)
        #expect(displays.calls == [
            .applyMode(Self.looksLike1512, screen.id),
            .applyMode(Self.looksLike1800, screen.id),
            .applyMode(Self.looksLike1512, screen.id),
        ])
    }
}

private struct FakeDisplayFailure: Error {}

private enum FakeDisplayCall: Equatable {
    case setEnabled(Bool, CGDirectDisplayID)
    case applyMode(DisplayModeKey, CGDirectDisplayID)
    case setRotation(DisplayRotation, CGDirectDisplayID)

    var displayID: CGDirectDisplayID {
        switch self {
        case let .setEnabled(_, id), let .applyMode(_, id), let .setRotation(_, id): id
        }
    }
}

/// Stands in for the window server; every call is recorded and none reaches a real display.
private final class FakeDisplays: Sendable {
    private struct State {
        var calls: [FakeDisplayCall] = []
        var modes: [CGDirectDisplayID: DisplayModeKey] = [:]
        var failingIDs: Set<CGDirectDisplayID> = []
        var offlineIDs: Set<CGDirectDisplayID> = []
    }

    /// The display goes dark even though the call reports failure.
    func failAfterBlanking(_ displayID: CGDirectDisplayID) {
        state.withLock {
            _ = $0.failingIDs.insert(displayID)
            _ = $0.offlineIDs.insert(displayID)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [FakeDisplayCall] {
        state.withLock { $0.calls }
    }

    func mode(of displayID: CGDirectDisplayID) -> DisplayModeKey? {
        state.withLock { $0.modes[displayID] }
    }

    func setMode(_ key: DisplayModeKey, for displayID: CGDirectDisplayID) {
        state.withLock { $0.modes[displayID] = key }
    }

    func fail(_ displayID: CGDirectDisplayID) {
        state.withLock { _ = $0.failingIDs.insert(displayID) }
    }

    var hardware: DisplayHardware {
        DisplayHardware(
            applyMode: { key, displayID in
                try self.record(.applyMode(key, displayID))
                self.setMode(key, for: displayID)
            },
            currentMode: { self.mode(of: $0) },
            setEnabled: { try self.record(.setEnabled($0, $1)) },
            setRotation: { try self.record(.setRotation($0, $1)) },
            currentRotation: { _ in .degrees0 },
            isBuiltin: { _ in false },
            isOnline: { id in self.state.withLock { !$0.offlineIDs.contains(id) } }
        )
    }

    private func record(_ call: FakeDisplayCall) throws {
        try state.withLock {
            $0.calls.append(call)
            if $0.failingIDs.contains(call.displayID) {
                throw FakeDisplayFailure()
            }
        }
    }
}

private final class FakeNSScreen: NSScreen {
    var index = 0

    override var frame: NSRect {
        NSRect(x: CGFloat(index) * 1000, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [:]
    }

    override var localizedName: String {
        "Display Settings Test \(index)"
    }
}
