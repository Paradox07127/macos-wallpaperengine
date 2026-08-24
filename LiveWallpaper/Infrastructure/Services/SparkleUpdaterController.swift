import Foundation
import LiveWallpaperCore
import Sparkle

/// Owns the one Sparkle updater for the app.
///
/// Sparkle would normally throw its own alert on screen the moment a scheduled
/// check finds something. This app deliberately opts into "gentle reminders"
/// instead: the scheduled check stays silent and only lights up the menu bar
/// button, so a wallpaper that is running full-screen is never interrupted by a
/// dialog the user did not ask for. Clicking that button hands control back to
/// Sparkle's standard UI.
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
    /// asserts `NSThread.isMainThread` at each call site — but that `assert` is
    /// compiled out of its release build and the guarantee is not written into
    /// the protocol header, so a version bump could move a callback off. A late
    /// banner is recoverable; `assumeIsolated` off the main thread traps. The
    /// failed-check path reaches `standardUserDriverWillFinishUpdateSession`.
    private nonisolated func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// `false` = do not put Sparkle's alert on screen for a scheduled check.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

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
