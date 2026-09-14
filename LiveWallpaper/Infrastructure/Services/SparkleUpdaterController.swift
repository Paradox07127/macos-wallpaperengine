import Foundation
import LiveWallpaperCore
import Sparkle

@MainActor
protocol SparkleUpdateStarting {
    var automaticallyChecksForUpdates: Bool { get }
    func start() throws
    func checkForUpdatesInBackground()
}

extension SPUUpdater: SparkleUpdateStarting {}

/// Keep the launch check in the same runloop turn as Sparkle startup, before
/// its scheduler takes over. Repeated startup calls must not trigger more checks.
@MainActor
struct SparkleUpdateStartup {
    private(set) var hasStarted = false

    mutating func start(updater: any SparkleUpdateStarting) throws {
        guard !hasStarted else { return }
        try updater.start()
        hasStarted = true
        if updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }
}

@MainActor
@Observable
final class SparkleUpdaterController {
    static let shared = SparkleUpdaterController()

    /// Version string of an update Sparkle has found and is holding back, or `nil` when there is nothing to show.
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var driverDelegate: GentleReminderDelegate!
    @ObservationIgnored private var updaterDelegate: UpdateAvailabilityDelegate!
    @ObservationIgnored private var startup = SparkleUpdateStartup()

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
        // Also from the user driver, not just `didFindValidUpdate`: an already-downloaded update is shown on next launch by resuming the session, so the updater-side callback never fires.
        driverDelegate.onUpdateFound = { [weak self] version in
            self?.noteUpdateFound(version: version)
        }
        driverDelegate.onSessionFinished = { [weak self] in
            self?.noteUpdateSessionFinished()
        }
    }

    func noteUpdateFound(version: String) {
        availableVersion = version
    }

    /// A completed check that turned up nothing — the only thing that withdraws a pending update.
    func noteNoUpdateFound() {
        availableVersion = nil
    }

    /// Deliberately leaves `availableVersion` alone. Clearing it here would make dismissing the alert look like already current.
    func noteUpdateSessionFinished() {}

    /// Kept out of `init` so construction never reaches the network.
    func start() {
        guard !startup.hasStarted else { return }
        if let carried = Self.legacyOptOutToCarryOver(
            defaults: .appScoped(),
            sparkleChoiceIsStored: UserDefaults.standard.object(forKey: Self.sparkleAutomaticChecksKey) != nil
        ) {
            controller.updater.automaticallyChecksForUpdates = carried
        }
        do {
            try startup.start(updater: controller.updater)
        } catch {
            Logger.error("Sparkle updater failed to start: \(String(describing: error))", category: .updates)
        }
    }

    nonisolated static let legacyCheckAtLaunchKey = "loomscreen.update.checkAtLaunch.v1"
    /// Read from the user-defaults layer alone. `SUEnableAutomaticChecks` is also in both Info.plists, so Sparkle's merged value is never unset.
    nonisolated static let sparkleAutomaticChecksKey = "SUEnableAutomaticChecks"

    nonisolated static func legacyOptOutToCarryOver(
        defaults: UserDefaults,
        sparkleChoiceIsStored: Bool
    ) -> Bool? {
        guard let legacy = defaults.object(forKey: legacyCheckAtLaunchKey) as? Bool else { return nil }
        defaults.removeObject(forKey: legacyCheckAtLaunchKey)
        return sparkleChoiceIsStored ? nil : legacy
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}

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

    /// Sparkle 2.9.6 calls the delegate on the main thread, but that assert is compiled out of release builds and absent from the protocol header, so a version bump could move a callback off-thread, where `assumeIsolated` traps.
    private nonisolated func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    /// Still true — the menu bar badge is a gentle reminder layered on Sparkle's alert, not replacing it. Returning false would log a false 'background app with no gentle reminder' warning.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// `true` = Sparkle's default: it puts the update alert on screen for a scheduled check.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    /// Fires on both paths — Sparkle calls it before showing the alert itself as well as when the delegate would have shown it.
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
