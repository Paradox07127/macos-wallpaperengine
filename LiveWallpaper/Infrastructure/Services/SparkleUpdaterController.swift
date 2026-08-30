import Foundation
import LiveWallpaperCore
import Sparkle

/// Owns the one Sparkle updater for the app. A scheduled check that finds
/// something gets Sparkle's own alert (default behaviour, since the menu bar
/// badge alone is easy to miss) — the badge still lights too, because
/// `standardUserDriverWillHandleShowingUpdate` fires either way, keeping it and the About page in sync.
@MainActor
@Observable
final class SparkleUpdaterController {
    static let shared = SparkleUpdaterController()

    /// Version string of an update Sparkle has found and is holding back, or
    /// `nil` when there is nothing to show. Drives the menu bar button.
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var driverDelegate: GentleReminderDelegate!

    private init() {
        driverDelegate = GentleReminderDelegate()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
        )
        driverDelegate.onUpdateFound = { [weak self] version in
            self?.availableVersion = version
        }
        driverDelegate.onSessionFinished = { [weak self] in
            self?.availableVersion = nil
        }
    }

    /// Starts the scheduled-check machinery. Kept out of `init` so tests can
    /// touch the type without it reaching the network.
    func start() {
        if let carried = Self.legacyOptOutToCarryOver(
            defaults: .appScoped(),
            sparkleChoiceIsStored: UserDefaults.standard.object(forKey: Self.sparkleAutomaticChecksKey) != nil
        ) {
            controller.updater.automaticallyChecksForUpdates = carried
        }
        do {
            try controller.updater.start()
        } catch {
            Logger.error("Sparkle updater failed to start: \(String(describing: error))", category: .updates)
        }
    }

    nonisolated static let legacyCheckAtLaunchKey = "loomscreen.update.checkAtLaunch.v1"
    /// Read from the user-defaults layer alone. `SUEnableAutomaticChecks` is also
    /// in both Info.plists, so Sparkle's merged value is never unset and cannot
    /// tell us whether the user has chosen anything.
    nonisolated static let sparkleAutomaticChecksKey = "SUEnableAutomaticChecks"

    /// 0.5.7 kept the launch-check opt-out in its own key, and Sparkle defaults
    /// to on, so an upgrade would re-enable network checks for someone who had
    /// turned them off. Consumes the old key either way: a choice already made in
    /// Sparkle's settings wins, and this must not reapply on the next launch.
    nonisolated static func legacyOptOutToCarryOver(
        defaults: UserDefaults,
        sparkleChoiceIsStored: Bool
    ) -> Bool? {
        guard let legacy = defaults.object(forKey: legacyCheckAtLaunchKey) as? Bool else { return nil }
        defaults.removeObject(forKey: legacyCheckAtLaunchKey)
        return sparkleChoiceIsStored ? nil : legacy
    }

    /// Shows Sparkle's own update UI — used by the menu bar button and the
    /// About page's manual check.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// Sparkle persists this itself (`SUEnableAutomaticChecks`), so the General
    /// settings toggle reads and writes it rather than keeping a parallel key.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}

/// Separate object because `SPUStandardUserDriverDelegate` requires NSObject
/// conformance, which does not mix with `@Observable`'s generated storage.
@MainActor
final class GentleReminderDelegate: NSObject, SPUStandardUserDriverDelegate {
    var onUpdateFound: ((String) -> Void)?
    var onSessionFinished: (() -> Void)?

    /// Sparkle 2.9.6 calls the delegate on the main thread — `SPUStandardUserDriver.m`
    /// asserts `NSThread.isMainThread` per call site, but that assert is compiled
    /// out of release builds and absent from the protocol header, so a version bump
    /// could move a callback off-thread, where `assumeIsolated` traps (unlike a merely-late banner); the failed-check path reaches `standardUserDriverWillFinishUpdateSession`.
    private nonisolated func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    /// Still true — the menu bar badge is a gentle reminder layered on top of
    /// Sparkle's alert, not replacing it. Sparkle reads this flag only to decide
    /// whether to log its "background app with no gentle reminder" warning
    /// (`SPUStandardUserDriver.logGentleScheduledUpdateReminderWarningIfNeeded`), which would be a false alarm here.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// `true` = Sparkle's own default: it puts the update alert on screen for a
    /// scheduled check. 0.6.0 and earlier returned `false` and left the menu bar
    /// badge as the only signal, which users missed.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    /// Fires on both paths — Sparkle calls it before showing the alert itself as
    /// well as when the delegate would have shown it — so the badge tracks the
    /// found version either way.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        onMain { [weak self] in self?.onUpdateFound?(version) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        onMain { [weak self] in self?.onSessionFinished?() }
    }
}
