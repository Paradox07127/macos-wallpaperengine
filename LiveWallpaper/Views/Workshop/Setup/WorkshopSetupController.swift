#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// The Workshop setup actions and their derived text, in one place.
///
/// The settings page, the onboarding step and the Workshop pane each carried
/// their own copy of `runManagedInstall`, the install-verification window, the
/// SteamCMD detail line and the busy test. Three copies of one state machine
/// is what let them disagree about whether SteamCMD was ready.
///
/// State that belongs to the machine (install status, bindings, probes) stays
/// in the shared singletons this holds; only the transient per-surface things
/// — the error line, the two "we are mid-flight" flags — live here.
@MainActor
@Observable
final class WorkshopSetupController {
    // `@ObservationIgnored` on the references, matching `WorkshopServices`:
    // what a view observes is each singleton's own properties, reached through
    // these, not the (immutable) reference itself.
    @ObservationIgnored let doctor: SteamCMDDoctorService
    @ObservationIgnored let installer = SteamCMDManagedInstallCoordinator.shared
    @ObservationIgnored let engineAssets = WPEEngineAssetsLibrary.shared
    @ObservationIgnored let engineInstaller = WPEEngineAssetsInstaller.shared

    /// Failures from the three Steam connection steps. Scoped, not one string
    /// for the whole controller: the assets section renders its own errors in
    /// its own status line, and a shared slot put a SteamCMD failure there (and
    /// an assets failure under the connection rows).
    var setupError: String?
    var engineAssetsError: String?

    /// Every user-initiated setup action starts here.
    ///
    /// Clears *both* slots on purpose: a scene-resources preflight that failed
    /// for a missing account is answered by signing in, and leaving its warning
    /// on the resources row afterwards covers the state that action just
    /// produced.
    private func beginSetupAction() {
        setupError = nil
        engineAssetsError = nil
    }
    /// The window between "the connector reported installed" and "we confirmed
    /// it launches". Without it the row falls back to `binaryDisplayPath`,
    /// which is still nil, and reads "Not selected" moments after a successful
    /// install.
    private(set) var isVerifyingInstall = false
    private(set) var isDetectingBinary = false
    private(set) var discoveredAccounts: [SteamAccountSummary] = []
    /// Where the connector says Steam already lives. Display only: the sandbox
    /// still needs a user-confirmed panel before it may read anything there.
    private(set) var scannedLibraryPath: String?

    /// Mirrors the connector's manual binding for one purpose: deciding whether
    /// to offer "Forget". The record itself lives in the connector's own root,
    /// which this sandboxed process cannot read — so this is a display hint,
    /// not a source of truth about what will actually be executed.
    ///
    /// On the controller rather than in one view's `@AppStorage`: a binding
    /// made from onboarding has to be forgettable from Settings.
    var hasManualBinding: Bool {
        get {
            _ = manualBindingRevision
            return defaults.bool(forKey: Self.manualBindingKey)
        }
        set {
            defaults.set(newValue, forKey: Self.manualBindingKey)
            manualBindingRevision &+= 1
        }
    }

    /// `@Observable` tracks stored properties only, and the flag above lives in
    /// `UserDefaults`; without this a view reading `hasManualBinding` registers
    /// no dependency and keeps its old answer.
    private var manualBindingRevision: UInt64 = 0
    private static let manualBindingKey = "loomscreen.workshop.doctor.hasManualBinding.v1"
    @ObservationIgnored private let defaults: UserDefaults

    /// Not observed: assigning the handle would invalidate every view that
    /// reads this controller, for a value none of them render.
    @ObservationIgnored private var installTask: Task<Void, Never>?

    init(doctor: SteamCMDDoctorService, defaults: UserDefaults = .appScoped()) {
        self.doctor = doctor
        self.defaults = defaults
    }

    // MARK: - Lifecycle

    func prepare() async {
        // Same flag the manual "Locate automatically" raises: this also runs
        // `autoDetectBinary`, and without it a click landing mid-`prepare`
        // starts a second diagnose whose late "no SteamCMD found" overwrites
        // the binding the first one just made.
        isDetectingBinary = true
        await doctor.autoConfigureIfNeeded()
        isDetectingBinary = false
        engineInstaller.refreshManagedInstallState()
        scanForSteamLibrary()
        await loadAccounts()
    }

    // MARK: - SteamCMD

    var isSteamCMDBusy: Bool {
        if isDetectingBinary || isVerifyingInstall { return true }
        switch installer.status {
        // Removing counts as busy: the command that starts an install is
        // disabled off this, and the coordinator refuses one mid-removal
        // anyway — offering a command that will be declined is worse than
        // greying it out.
        case .installing, .removing: return true
        case .idle, .installed, .failed: return false
        }
    }

    var steamCMDState: WorkshopStepState {
        isSteamCMDBusy ? .working : doctor.binaryStepState
    }

    var steamCMDDetail: String {
        switch installer.status {
        case .installing:
            return String(localized: "Setting up SteamCMD…", comment: "SteamCMD step detail while the connector unpacks and verifies the install.")
        case .removing:
            return String(localized: "Removing SteamCMD…", comment: "SteamCMD step detail while the connector deletes the managed install.")
        case .idle, .installed, .failed:
            if isVerifyingInstall {
                return String(
                    localized: "Checking that SteamCMD runs…",
                    comment: "SteamCMD step detail while the connector launches the freshly installed binary to confirm it works."
                )
            }
            // Execution receipt wins over the stored binding: the connector
            // re-resolves per operation, so what actually ran is the truth.
            return doctor.lastExecutedBinaryPath
                ?? doctor.binaryDisplayPath
                ?? String(localized: "Not selected", comment: "SteamCMD step detail when no binary is bound.")
        }
    }

    /// The defaults record is not the only way a managed install can be the one
    /// in use: auto-detect deliberately rebinds a copy the connector rediscovers
    /// even when the record is gone (cleared defaults, a restored container).
    var hasManagedInstall: Bool {
        if installer.managedInstall != nil { return true }
        guard let bound = doctor.binaryPath else { return false }
        return bound.hasPrefix(Self.managedInstallRoot + "/")
    }

    static var managedInstallRoot: String {
        SteamCMDManagedInstaller.canonicalInstallRoot(
            home: AppleAerialsLibrary.realHomeDirectory()
        ).path(percentEncoded: false)
    }

    /// Installs, then binds through the normal auto-detect path rather than the
    /// returned path: binding is what makes the rest of the Doctor consider
    /// SteamCMD set up, and auto-detect asks the connector to launch the binary
    /// instead of inferring from the install having reported success.
    func runManagedInstall() {
        beginSetupAction()
        installTask = Task {
            switch await installer.install() {
            case .installed:
                isVerifyingInstall = true
                let bound = await doctor.autoDetectBinary()
                isVerifyingInstall = false
                if !bound {
                    setupError = String(
                        localized: "SteamCMD was installed but could not be started.",
                        comment: "Workshop setup error after a managed SteamCMD install that will not launch."
                    )
                }
            case .failed(let reason):
                setupError = reason
            case .idle, .installing, .removing:
                // Either a second install was already running and owns the
                // outcome, or this one was cancelled — neither is an error.
                break
            }
            installTask = nil
        }
    }

    func autoDetectBinary() {
        beginSetupAction()
        isDetectingBinary = true
        Task {
            let found = await doctor.autoDetectBinary()
            isDetectingBinary = false
            if !found {
                // The connector's own reason when it reached one — it names the
                // copy it tried and what went wrong. The generic sentence is
                // only right when nothing was found at all.
                setupError = doctor.lastAutoDetectDiagnosis?.remedy ?? String(
                    localized: "No SteamCMD found in the usual places. Use Install SteamCMD for Loomscreen's own copy, or Choose SteamCMD to point at one yourself.",
                    comment: "Workshop setup error when auto-detection finds no SteamCMD."
                )
            }
        }
    }

    /// The recourse when SteamCMD is installed somewhere auto-detection has
    /// never heard of.
    ///
    /// The path only travels as far as the connector, which resolves it, gates
    /// it, and records it on its own side; the app never gets to say what runs
    /// on any subsequent download. See `SteamCMDManualBinding`.
    ///
    /// Returns true when a manual binding was recorded, so the caller can
    /// update its own `@AppStorage` display hint.
    func pickBinaryManually() async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        // Homebrew's cask lives under a dot-directory on newer versions.
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true)
        panel.message = String(localized: "Choose the steamcmd binary, or the steamcmd.sh that launches it.", comment: "Open-panel message when pointing Loomscreen at an existing SteamCMD.")
        panel.prompt = String(localized: "Use SteamCMD", comment: "Open-panel confirm button when pointing Loomscreen at an existing SteamCMD.")
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        beginSetupAction()
        isDetectingBinary = true
        defer { isDetectingBinary = false }
        let result = await SteamConnectorClient.bindManualSteamCMDBinary(
            path: url.path(percentEncoded: false)
        )
        guard let result, result.isBound, let canonical = result.canonicalPath else {
            setupError = result?.failureReason ?? String(
                localized: "Loomscreen couldn't use that file as SteamCMD.",
                comment: "Workshop setup error when a manually chosen SteamCMD is refused."
            )
            return false
        }
        // Bind through the service so the identity probe re-runs against the
        // new binary rather than leaving the previous one's verdict on screen.
        do {
            try await doctor.bindResolvedBinary(canonical)
            hasManualBinding = true
            return true
        } catch {
            setupError = error.localizedDescription
            return false
        }
    }

    func forgetManualBinary() async {
        beginSetupAction()
        isDetectingBinary = true
        await SteamConnectorClient.clearManualSteamCMDBinary()
        hasManualBinding = false
        let found = await doctor.autoDetectBinary()
        isDetectingBinary = false
        if !found { doctor.unbindBinary() }
    }

    func removeManagedInstall() {
        beginSetupAction()
        let installRoot = Self.managedInstallRoot
        Task {
            let removed = await installer.forget()
            guard removed else {
                // The files are still there and still work. Unbinding here would
                // take a working SteamCMD away from the user as the visible
                // result of a delete that did not happen. `forget()` keeps the
                // install record on failure, so the Remove command stays in the
                // menu and this is retryable.
                setupError = String(
                    localized: "Couldn't remove the SteamCMD copy Loomscreen installed.",
                    comment: "Workshop setup error when removing a managed SteamCMD install fails."
                )
                return
            }
            // The bound path is the Mach-O inside the payload, not the root, so
            // compare by containment.
            if doctor.binaryPath?.hasPrefix(installRoot + "/") == true {
                doctor.unbindBinary()
                await doctor.autoDetectBinary()
            }
        }
    }

    // MARK: - Steam library

    var libraryDetail: String {
        doctor.workdirDisplayPath
            ?? scannedLibraryPath
            ?? String(localized: "Not authorized", comment: "Steam library step detail when no folder has been picked.")
    }

    /// Where Steam keeps its profile, if it is in the standard place.
    ///
    /// This is the whole of what "scan" can do: the sandbox needs a
    /// security-scoped bookmark to read anything under it, and only a panel the
    /// user confirms can produce one. Knowing the path in advance is still
    /// worth it — it turns the panel into a single click on a folder the user
    /// can see named on screen first.
    private func scanForSteamLibrary() {
        let candidate = AppleAerialsLibrary.realHomeDirectory()
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        let config = candidate
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("config.vdf", isDirectory: false)
        scannedLibraryPath = FileManager.default.fileExists(atPath: config.path(percentEncoded: false))
            ? candidate.path(percentEncoded: false)
            : nil
    }

    var hasScannedLibrary: Bool { scannedLibraryPath != nil }

    /// Opens the authorization panel already standing on `directory`.
    ///
    /// The sandbox cannot grant itself this folder — a user-initiated pick is
    /// the only way to get the bookmark — but it can open the panel already
    /// standing on it, which turns the common case into one click.
    func authorizeSteamLibrary(startingAtScannedPath useScanned: Bool) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // Not `homeDirectoryForCurrentUser` — sandbox maps that to the container, which also has a `Steam` folder we must not bind.
        let applicationSupport = AppleAerialsLibrary.realHomeDirectory()
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        if useScanned, let scannedLibraryPath {
            panel.directoryURL = URL(fileURLWithPath: scannedLibraryPath, isDirectory: true)
        } else {
            panel.directoryURL = applicationSupport
        }
        panel.message = String(localized: "Choose Steam's main folder containing config/config.vdf.", comment: "Open-panel message when authorizing the official Steam Library.")
        panel.prompt = String(localized: "Use Steam Library", comment: "Open-panel confirm button when authorizing the official Steam Library.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginSetupAction()
        do {
            try await doctor.bindSteamLibrary(url)
        } catch {
            setupError = error.localizedDescription
        }
    }

    // MARK: - Steam account

    var accountDetail: String {
        guard let username = doctor.username else {
            return discoveredAccounts.isEmpty
                ? String(localized: "No Steam sign-in found on this Mac", comment: "Steam account step detail when config.vdf lists no accounts.")
                : String(localized: "No account selected", comment: "Steam account step detail when no account is chosen.")
        }
        return username
    }

    /// Accounts from Steam `config.vdf` via the connector (sandbox cannot read that file).
    func loadAccounts() async {
        discoveredAccounts = await SteamConnectorClient.discoverAccounts()
        // Auto-select the only discovered account so setup finishes without a menu click.
        if doctor.username == nil, discoveredAccounts.count == 1 {
            selectAccount(discoveredAccounts[0])
        }
    }

    func selectAccount(_ account: SteamAccountSummary) {
        beginSetupAction()
        do {
            try doctor.adoptAccount(account)
        } catch {
            setupError = error.localizedDescription
        }
    }

    /// Through `setUsername`, never by assigning `username` directly: a changed
    /// account name has to knock `cachedLogin` back to `.notRun`, or the green
    /// earned by the previous account keeps `isDownloadReady` true while
    /// downloads already run as the new one.
    func adoptSignedInAccount(_ accountName: String) {
        beginSetupAction()
        do {
            try doctor.setUsername(accountName)
        } catch {
            setupError = error.localizedDescription
            return
        }
        Task {
            await loadAccounts()
            await doctor.runProbe(.cachedLogin)
        }
    }

    // MARK: - Scene resources

    var engineAssetsState: WorkshopStepState {
        .engineAssets(library: engineAssets, installer: engineInstaller)
    }

    var hasEngineAssets: Bool {
        WorkshopStepState.hasEngineAssets(library: engineAssets, installer: engineInstaller)
    }

    /// Clears the failure slot only once a folder was actually granted:
    /// clearing up front meant cancelling the panel erased the reason the user
    /// opened it for.
    func linkEngineAssetsFolder() async {
        guard await engineAssets.requestAccess() else { return }
        engineAssetsError = nil
        engineInstaller.refreshManagedInstallState()
        engineInstaller.clearTransientStatus()
    }

    /// Why the automatic download route is unavailable, or nil when it can be
    /// attempted.
    ///
    /// Deliberately reads the *bindings* and not `isDownloadReady`. Probe
    /// results are not persisted, so on a fresh launch `cachedLogin` is
    /// `.notRun` and `isDownloadReady` is false for a perfectly set-up Mac.
    /// Disabling the button on that would be a deadlock: the click is what
    /// runs the probes that would clear it. So the button stays live whenever
    /// the pieces exist, and `downloadEngineAssets()` re-probes first.
    ///
    /// `downloadBlockerMessage` is one generic sentence; a tooltip on a
    /// disabled button has to name the missing piece instead.
    var engineAssetsDownloadBlockReason: String? {
        if !doctor.hasBoundBinary {
            return String(
                localized: "Set up SteamCMD first — Steam downloads run through it.",
                comment: "Reason the automatic scene-resources download is unavailable: no SteamCMD."
            )
        }
        if doctor.workdirBookmarkData == nil || doctor.workdirResolutionFailed {
            return String(
                localized: "Authorize your Steam library folder first.",
                comment: "Reason the automatic scene-resources download is unavailable: the Steam library is not authorized."
            )
        }
        if doctor.username == nil {
            return String(
                localized: "Sign in to Steam first — the download runs as your own account.",
                comment: "Reason the automatic scene-resources download is unavailable: no Steam account."
            )
        }
        return nil
    }

    /// Confirms readiness, then downloads.
    ///
    /// The probe run is what makes a freshly launched, fully configured Mac
    /// work on the first click: `cachedLogin` starts every launch at `.notRun`.
    private(set) var isPreflightingDownload = false

    func downloadEngineAssets() {
        runWithPreflight { [self] in engineInstaller.download(using: doctor) }
    }

    /// Same preflight, for the version check — it runs SteamCMD too.
    func checkEngineAssetsUpdate() {
        runWithPreflight { [self] in engineInstaller.checkForUpdate(using: doctor) }
    }

    /// Both Steam-side asset actions: refuse with a reason when a prerequisite
    /// is missing, run immediately when readiness is already proven, otherwise
    /// prove it first.
    ///
    /// Saying why out loud matters here: "Check for updates" is not disabled
    /// when a prerequisite is missing, so a silent return reads as a dead button.
    private func runWithPreflight(_ action: @escaping () -> Void) {
        engineAssetsError = nil
        if let reason = engineAssetsDownloadBlockReason {
            engineAssetsError = reason
            return
        }
        if doctor.isDownloadReady {
            action()
            return
        }
        // Set before the `Task`, not inside it: two clicks land two bodies on
        // the main actor before either suspends, so a flag raised inside the
        // task leaves the button live for the second one — and the first to
        // finish then clears it while the other probe run is still going.
        guard !isPreflightingDownload else { return }
        isPreflightingDownload = true
        Task {
            await doctor.runAll()
            isPreflightingDownload = false
            if doctor.isDownloadReady {
                action()
            } else {
                engineAssetsError = doctor.downloadBlockerMessage
            }
        }
    }
}
#endif
