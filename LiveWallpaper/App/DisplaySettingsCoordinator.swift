import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

/// Every call that reads or changes a real display's configuration.
struct DisplayHardware: Sendable {
    /// Blocks until the window server commits; callers keep it off the main thread.
    var applyMode: @Sendable (DisplayModeKey, CGDirectDisplayID) throws -> Void
    /// nil = CoreGraphics does not know the display.
    var currentMode: @Sendable (CGDirectDisplayID) -> DisplayModeKey?
    #if !MAS_BUILD
    var setEnabled: @Sendable (Bool, CGDirectDisplayID) async throws -> Void
    /// Blocks until the window server commits; callers keep it off the main thread.
    var setRotation: @Sendable (DisplayRotation, CGDirectDisplayID) throws -> Void
    /// nil = the display reports an angle outside the four quadrants.
    var currentRotation: @Sendable (CGDirectDisplayID) -> DisplayRotation?
    var isBuiltin: @Sendable (CGDirectDisplayID) -> Bool
    var isOnline: @Sendable (CGDirectDisplayID) -> Bool
    #endif

    #if MAS_BUILD
    static let live = DisplayHardware(
        applyMode: { try DisplayModes.apply($0, to: $1) },
        currentMode: { CGDisplayCopyDisplayMode($0).map(DisplayModeKey.init) }
    )
    #else
    static let live = DisplayHardware(
        applyMode: { try DisplayModes.apply($0, to: $1) },
        currentMode: { CGDisplayCopyDisplayMode($0).map(DisplayModeKey.init) },
        setEnabled: { try await DisplayPower.setEnabled($0, for: $1) },
        setRotation: { try DisplayRotation.set($0, for: $1) },
        currentRotation: { DisplayRotation.current(for: $0) },
        isBuiltin: { CGDisplayIsBuiltin($0) != 0 },
        isOnline: { DisplayPower.onlineDisplayIDs().contains($0) }
    )
    #endif
}

#if !MAS_BUILD
struct DisabledDisplay: Codable, Equatable, Identifiable {
    let fingerprint: String
    let lastDisplayID: CGDirectDisplayID
    let name: String
    /// Global AppKit layout coordinates in points, captured before the display went offline.
    let frame: CGRect
    let isBuiltin: Bool

    var id: String {
        fingerprint
    }
}
#endif

struct PendingDisplayChange {
    let displayID: CGDirectDisplayID
    /// When the change reverts on its own unless it is kept.
    let deadline: Date
    fileprivate let restore: DisplayChangeRestore
}

private enum DisplayChangeRestore {
    case mode(DisplayModeKey)
    #if !MAS_BUILD
    case rotation(DisplayRotation)
    #endif
}

@MainActor @Observable
final class DisplaySettingsCoordinator {
    static let disabledDisplaysDefaultsKey = "loomscreen.display.disabled.v1"

    /// nil = no mode or rotation change is waiting for confirmation.
    private(set) var pendingConfirmation: PendingDisplayChange?
    #if !MAS_BUILD
    /// Displays this app switched off, one per fingerprint.
    private(set) var disabledDisplays: [DisabledDisplay] = []
    #endif

    @ObservationIgnored private let hardware: DisplayHardware
    @ObservationIgnored private let defaults: UserDefaults
    /// Seconds a mode or rotation change waits for `keepPendingChange()` before reverting.
    @ObservationIgnored private let confirmationTimeout: TimeInterval
    @ObservationIgnored private var confirmationTimeoutTask: Task<Void, Never>?

    init(hardware: DisplayHardware = .live, defaults: UserDefaults = .appScoped(), confirmationTimeout: TimeInterval = 15) {
        self.hardware = hardware
        self.defaults = defaults
        self.confirmationTimeout = confirmationTimeout
        #if !MAS_BUILD
        if let data = defaults.data(forKey: Self.disabledDisplaysDefaultsKey) {
            do {
                disabledDisplays = try JSONDecoder().decode([DisabledDisplay].self, from: data)
            } catch {
                Logger.error("Discarding unreadable switched-off display list: \(error)", category: .screenManager)
            }
        }
        #endif
    }

    func applyMode(_ key: DisplayModeKey, to screen: Screen) async throws {
        let displayID = screen.id
        guard let original = hardware.currentMode(displayID) else { throw DisplayControlError.displayNotFound }
        keepPendingChange()
        try await Task.detached { [applyMode = hardware.applyMode] in try applyMode(key, displayID) }.value
        awaitConfirmation(restoring: .mode(original), on: displayID)
    }

    func keepPendingChange() {
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        pendingConfirmation = nil
    }

    func revertPendingChange() async {
        guard let pending = pendingConfirmation else { return }
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        pendingConfirmation = nil
        let displayID = pending.displayID
        do {
            switch pending.restore {
            case let .mode(key):
                try await Task.detached { [applyMode = hardware.applyMode] in try applyMode(key, displayID) }.value
            #if !MAS_BUILD
            case let .rotation(rotation):
                try await Task.detached { [setRotation = hardware.setRotation] in try setRotation(rotation, displayID) }.value
            #endif
            }
        } catch {
            Logger.error("Could not revert the configuration change on display \(displayID): \(error)", category: .screenManager)
        }
    }

    private func awaitConfirmation(restoring restore: DisplayChangeRestore, on displayID: CGDirectDisplayID) {
        pendingConfirmation = PendingDisplayChange(
            displayID: displayID,
            deadline: Date.now.addingTimeInterval(confirmationTimeout),
            restore: restore
        )
        confirmationTimeoutTask = Task { [weak self, confirmationTimeout] in
            try? await Task.sleep(for: .seconds(confirmationTimeout))
            // A sleep that already finished does not throw when the change is kept or replaced afterwards.
            guard !Task.isCancelled else { return }
            await self?.revertPendingChange()
        }
    }

    #if !MAS_BUILD
    func applyRotation(_ rotation: DisplayRotation, to screen: Screen) async throws {
        let displayID = screen.id
        guard let original = hardware.currentRotation(displayID) else { throw DisplayControlError.unavailable }
        keepPendingChange()
        try await Task.detached { [setRotation = hardware.setRotation] in try setRotation(rotation, displayID) }.value
        awaitConfirmation(restoring: .rotation(original), on: displayID)
    }

    func turnOff(_ screen: Screen) async throws {
        // Captured first: once the display is off it is gone from NSScreen.screens.
        let record = DisabledDisplay(
            fingerprint: screen.displayFingerprint,
            lastDisplayID: screen.id,
            name: screen.name,
            frame: screen.frame,
            isBuiltin: hardware.isBuiltin(screen.id)
        )
        // Saved before the call: a commit that blanks the display yet reports failure must still be restored.
        disabledDisplays.removeAll { $0.fingerprint == record.fingerprint }
        disabledDisplays.append(record)
        saveDisabledDisplays()
        do {
            try await hardware.setEnabled(false, screen.id)
        } catch {
            if hardware.isOnline(screen.id) {
                disabledDisplays.removeAll { $0.fingerprint == record.fingerprint }
                saveDisabledDisplays()
            }
            throw error
        }
    }

    func turnOn(_ display: DisabledDisplay) async throws {
        try await hardware.setEnabled(true, display.lastDisplayID)
        disabledDisplays.removeAll { $0.fingerprint == display.fingerprint }
        saveDisabledDisplays()
    }

    /// A failed display keeps its record so the next launch tries again.
    func restoreAll() async {
        for display in disabledDisplays {
            do {
                try await turnOn(display)
            } catch {
                Logger.error("Could not switch display \(display.lastDisplayID) back on: \(error)", category: .screenManager)
            }
        }
    }

    /// Drops records of displays the system brought back without this app, e.g. after a replug.
    func forgetDisplaysBackOnline(in screens: [Screen]) {
        let onlineFingerprints = Set(screens.map(\.displayFingerprint))
        guard disabledDisplays.contains(where: { onlineFingerprints.contains($0.fingerprint) }) else { return }
        disabledDisplays.removeAll { onlineFingerprints.contains($0.fingerprint) }
        saveDisabledDisplays()
    }

    private func saveDisabledDisplays() {
        do {
            try defaults.set(JSONEncoder().encode(disabledDisplays), forKey: Self.disabledDisplaysDefaultsKey)
        } catch {
            Logger.error("Could not save the switched-off display list; the next launch cannot switch them back on: \(error)", category: .screenManager)
        }
    }
    #endif
}
