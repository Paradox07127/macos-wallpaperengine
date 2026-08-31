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
    @ObservationIgnored private var updaterDelegate: UpdateAvailabilityDelegate!

    private init() {
        driverDelegate = GentleReminderDelegate()
        updaterDelegate = UpdateAvailabilityDelegate()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: driverDelegate
        )
        updaterDelegate.onUpdateFound = { [weak self] version in
            self?.noteUpdateFound(version: version)
        }
        updaterDelegate.onNoUpdateFound = { [weak self] in
            self?.noteNoUpdateFound()
        }
        // Also from the user driver, not just `didFindValidUpdate`: an update that
        // was already downloaded is shown again on the next launch by resuming the
        // session, and no new check runs, so the updater-side callback never fires.
        driverDelegate.onUpdateFound = { [weak self] version in
            self?.noteUpdateFound(version: version)
        }
        driverDelegate.onSessionFinished = { [weak self] in
            self?.noteUpdateSessionFinished()
        }
    }

    /// Sparkle found a release newer than this build.
    func noteUpdateFound(version: String) {
        availableVersion = version
    }

    /// A completed check that turned up nothing — the only thing that withdraws
    /// a pending update. Also covers "the newest release needs a newer macOS"
    /// and "you already have it", which are the same fact to every surface here.
    func noteNoUpdateFound() {
        availableVersion = nil
    }

    /// Sparkle's update-alert session ended: installed, skipped, or dismissed
    /// with "Remind Me Later". Deliberately leaves `availableVersion` alone.
    /// Clearing it here is what made dismissing the alert flip the About line to
    /// a checkmark and drop the menu bar Update button, telling a user on 0.6.1
    /// that 0.6.1 was current. Availability belongs to `SPUUpdaterDelegate`;
    /// this callback only reports that the UI session is over. An install ends
    /// with a relaunch, so the new process starts with no pending update anyway.
    func noteUpdateSessionFinished() {}

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
/// Availability, as opposed to UI-session lifetime. Sparkle reports the two
/// through different delegates and only this one means "there is / is not an
/// update".
@MainActor
final class UpdateAvailabilityDelegate: NSObject, SPUUpdaterDelegate {
    var onUpdateFound: ((String) -> Void)?
    var onNoUpdateFound: (() -> Void)?

    /// Same reasoning as `GentleReminderDelegate.onMain`: the protocol header
    /// does not promise a thread, so hop rather than assume.
    private nonisolated func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    nonisolated func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        onMain { [weak self] in self?.onUpdateFound?(version) }
    }

    /// The plain variant, not `updaterDidNotFindUpdate(_:error:)`: the reason a
    /// check came back empty does not change what these surfaces show.
    nonisolated func updaterDidNotFindUpdate(_: SPUUpdater) {
        onMain { [weak self] in self?.onNoUpdateFound?() }
    }
}

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
