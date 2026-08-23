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
        do {
            try controller.updater.start()
        } catch {
            Logger.error("Sparkle updater failed to start: \(String(describing: error))", category: .updates)
        }
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
private final class GentleReminderDelegate: NSObject, SPUStandardUserDriverDelegate {
    var onUpdateFound: ((String) -> Void)?
    var onSessionFinished: (() -> Void)?

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
        MainActor.assumeIsolated { onUpdateFound?(version) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { onSessionFinished?() }
    }
}
