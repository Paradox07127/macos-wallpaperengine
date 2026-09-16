#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

@MainActor
@Observable
final class WorkshopSetupController {
    // `@ObservationIgnored`: views observe each singleton's own properties, not these immutable references.
    @ObservationIgnored let doctor: SteamCMDDoctorService
    @ObservationIgnored let installer = SteamCMDManagedInstallCoordinator.shared
    @ObservationIgnored let engineAssets = WPEEngineAssetsLibrary.shared
    @ObservationIgnored let engineInstaller = WPEEngineAssetsInstaller.shared

    /// Failures from the three Steam connection steps; scene-resources failures
    /// belong in `engineAssetsError`, not here.
    var setupError: String?
    var engineAssetsError: String?

    /// Clears *both* error slots on purpose: the action that fixes one step often
    /// invalidates the other's warning.
    private func beginSetupAction() {
        setupError = nil
        engineAssetsError = nil
    }
    /// True between "the connector reported installed" and "we confirmed it launches";
    /// without it the row would read "Not selected" right after a successful install.
    private(set) var isVerifyingInstall = false
    /// Counter, not a Bool: three surfaces share this controller, so detections overlap
    /// and a Bool would be cleared by whichever finishes first.
    private var detectionsInFlight = 0
    var isDetectingBinary: Bool { detectionsInFlight > 0 }
    private func beginBinaryDetection() { detectionsInFlight += 1 }
    private func endBinaryDetection() { detectionsInFlight = max(0, detectionsInFlight - 1) }
    private(set) var discoveredAccounts: [SteamAccountSummary] = []
    /// Where the connector says Steam already lives. Display only: the sandbox
    /// still needs a user-confirmed panel before it may read anything there.
    private(set) var scannedLibraryPath: String?

    /// Display hint only: the binding record lives in the connector's root, unreadable
    /// here, so this never decides what actually runs.
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

    /// `@Observable` tracks stored properties only; bumping this is what makes the
    /// `UserDefaults`-backed `hasManualBinding` invalidate views.
    private var manualBindingRevision: UInt64 = 0
    private static let manualBindingKey = "loomscreen.workshop.doctor.hasManualBinding.v1"
    @ObservationIgnored private let defaults: UserDefaults

    init(doctor: SteamCMDDoctorService, defaults: UserDefaults = .appScoped()) {
        self.doctor = doctor
        self.defaults = defaults
    }

    // MARK: - Lifecycle

    func prepare() async {
        // Raise the same flag "Locate automatically" does: a click landing mid-`prepare`
        // would start a second diagnose whose late "not found" overwrites this binding.
        beginBinaryDetection()
        await doctor.autoConfigureIfNeeded()
        endBinaryDetection()
        engineInstaller.refreshManagedInstallState()
        scanForSteamLibrary()
        await loadAccounts()
    }

    // MARK: - SteamCMD

    var isSteamCMDBusy: Bool {
        if isDetectingBinary || isVerifyingInstall { return true }
        switch installer.status {
        // Removing counts as busy: the coordinator refuses an install mid-removal anyway.
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
            return String(localized: "Setting up SteamCMD…", bundle: .appLanguage, comment: "SteamCMD step detail while the connector unpacks and verifies the install.")
        case .removing:
            return String(localized: "Removing SteamCMD…", bundle: .appLanguage, comment: "SteamCMD step detail while the connector deletes the managed install.")
        case .idle, .installed, .failed:
            if isVerifyingInstall {
                return String(
                    localized: "Checking that SteamCMD runs…",
                    bundle: .appLanguage, comment: "SteamCMD step detail while the connector launches the freshly installed binary to confirm it works."
                )
            }
            // Execution receipt wins over the stored binding: the connector
            // re-resolves per operation, so what actually ran is the truth.
            return doctor.lastExecutedBinaryPath
                ?? doctor.binaryDisplayPath
                ?? String(localized: "Not selected", bundle: .appLanguage, comment: "SteamCMD step detail when no binary is bound.")
        }
    }

    /// The defaults record alone is not the test: auto-detect rebinds a rediscovered
    /// managed copy even when the record is gone.
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

    /// Binds through `autoDetectBinary`, not the returned path: that is what launches
    /// the binary instead of trusting the install's success report.
    func runManagedInstall() {
        beginSetupAction()
        Task {
            switch await installer.install() {
            case .installed:
                isVerifyingInstall = true
                let bound = await doctor.autoDetectBinary()
                isVerifyingInstall = false
                if !bound {
                    setupError = String(
                        localized: "SteamCMD was installed but could not be started.",
                        bundle: .appLanguage, comment: "Workshop setup error after a managed SteamCMD install that will not launch."
                    )
                }
            case .failed(let reason):
                setupError = reason
            case .idle, .installing, .removing:
                // Either a second install was already running and owns the
                // outcome, or this one was cancelled — neither is an error.
                break
            }
        }
    }

    func autoDetectBinary() {
        beginSetupAction()
        beginBinaryDetection()
        Task {
            let found = await doctor.autoDetectBinary()
            endBinaryDetection()
            // `!doctor.hasBoundBinary`, not just `!found`: a parallel detect can bind while
            // this one is out, and its late "not found" would overwrite that.
            if !found, !doctor.hasBoundBinary {
                // The connector's own reason names the copy it tried; the generic sentence is
                // only right when nothing was found at all.
                setupError = doctor.lastAutoDetectDiagnosis?.remedy ?? String(
                    localized: "No SteamCMD found in the usual places. Use Install SteamCMD for Loomscreen's own copy, or Choose SteamCMD to point at one yourself.",
                    bundle: .appLanguage, comment: "Workshop setup error when auto-detection finds no SteamCMD."
                )
            }
        }
    }

    /// Returns true when a binding was recorded, so the caller can update its hint.
    /// The chosen path only reaches the connector (see `SteamCMDManualBinding`).
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
        panel.message = String(localized: "Choose the steamcmd binary, or the steamcmd.sh that launches it.", bundle: .appLanguage, comment: "Open-panel message when pointing Loomscreen at an existing SteamCMD.")
        panel.prompt = String(localized: "Use SteamCMD", bundle: .appLanguage, comment: "Open-panel confirm button when pointing Loomscreen at an existing SteamCMD.")
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        beginSetupAction()
        beginBinaryDetection()
        defer { endBinaryDetection() }
        let result = await SteamConnectorClient.bindManualSteamCMDBinary(
            path: url.path(percentEncoded: false)
        )
        guard let result, result.isBound, let canonical = result.canonicalPath else {
            setupError = result?.localizedFailureReason ?? String(
                localized: "Loomscreen couldn't use that file as SteamCMD.",
                bundle: .appLanguage, comment: "Workshop setup error when a manually chosen SteamCMD is refused."
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
        beginBinaryDetection()
        await SteamConnectorClient.clearManualSteamCMDBinary()
        hasManualBinding = false
        let found = await doctor.autoDetectBinary()
        endBinaryDetection()
        if !found { doctor.unbindBinary() }
    }

    func removeManagedInstall() {
        beginSetupAction()
        let installRoot = Self.managedInstallRoot
        Task {
            switch await installer.forget() {
            case .removed:
                break
            case .superseded:
                // Another operation owns the outcome; reporting a failure here would put an error
                // on screen for a removal that is still running.
                return
            case .connectorUnavailable:
                setupError = String(
                    localized: "Loomscreen's Steam connector did not respond.",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic when the XPC connector could not be reached."
                )
                return
            case .refused:
                // Don't unbind here: the files still work, and `forget()` keeps the install record
                // on failure so Remove stays retryable.
                setupError = String(
                    localized: "Couldn't remove the SteamCMD copy Loomscreen installed.",
                    bundle: .appLanguage, comment: "Workshop setup error when removing a managed SteamCMD install fails."
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
            ?? String(localized: "Not authorized", bundle: .appLanguage, comment: "Steam library step detail when no folder has been picked.")
    }

    /// Where Steam keeps its profile if it is in the standard place. Reading anything
    /// under it still needs a user-confirmed panel for the bookmark.
    private func scanForSteamLibrary() {
        let candidate = AppleAerialsLibrary.realHomeDirectory()
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        scannedLibraryPath = FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
            ? candidate.path(percentEncoded: false)
            : nil
    }

    var hasScannedLibrary: Bool { scannedLibraryPath != nil }

    /// The sandbox cannot grant itself this folder: only a user-initiated pick produces
    /// the bookmark.
    func authorizeSteamLibrary(startingAtScannedPath useScanned: Bool) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        // Not `homeDirectoryForCurrentUser` — sandbox maps that to the container, which also has a `Steam` folder we must not bind.
        let applicationSupport = AppleAerialsLibrary.realHomeDirectory()
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        if useScanned, let scannedLibraryPath {
            panel.directoryURL = URL(fileURLWithPath: scannedLibraryPath, isDirectory: true)
        } else {
            panel.directoryURL = applicationSupport
        }
        panel.message = String(localized: "Choose the Steam library folder for wallpaper files. Download sign-in is stored separately.", bundle: .appLanguage, comment: "Open-panel message for the content library; credentials use a private profile.")
        panel.prompt = String(localized: "Use Steam Library", bundle: .appLanguage, comment: "Open-panel confirm button when authorizing the official Steam Library.")
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
                ? String(localized: "No Steam sign-in found on this Mac", bundle: .appLanguage, comment: "Steam account step detail when config.vdf lists no accounts.")
                : String(localized: "No account selected", bundle: .appLanguage, comment: "Steam account step detail when no account is chosen.")
        }
        return username
    }

    /// Accounts from Steam `config.vdf` via the connector (sandbox cannot read that file).
    func loadAccounts() async {
        discoveredAccounts = await SteamConnectorClient.discoverAccounts()
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

    func adoptSignedInAccount(_ accountName: String) {
        beginSetupAction()
        do {
            try doctor.setUsername(accountName)
        } catch {
            setupError = error.localizedDescription
            return
        }
        doctor.noteSuccessfulSteamOperation(generation: doctor.accountGeneration)
        Task { await loadAccounts() }
    }

    // MARK: - Scene resources

    var engineAssetsState: WorkshopStepState {
        .engineAssets(library: engineAssets, installer: engineInstaller)
    }

    var hasEngineAssets: Bool {
        WorkshopStepState.hasEngineAssets(library: engineAssets, installer: engineInstaller)
    }

    /// Clear the failure slot only after a folder is granted: clearing up front would
    /// erase the reason the user opened the panel.
    func linkEngineAssetsFolder() async {
        guard await engineAssets.requestAccess() else { return }
        engineAssetsError = nil
        engineInstaller.refreshManagedInstallState()
        engineInstaller.clearTransientStatus()
    }

    /// nil when the download can be attempted. Reads the *bindings*, not `isDownloadReady`:
    /// `cachedLogin` is `.notRun` on a fresh launch, so gating on it would deadlock the
    /// click that runs the probes.
    var engineAssetsDownloadBlockReason: String? {
        if !doctor.hasBoundBinary {
            return String(
                localized: "Set up SteamCMD first — Steam downloads run through it.",
                bundle: .appLanguage, comment: "Reason the automatic scene-resources download is unavailable: no SteamCMD."
            )
        }
        if doctor.workdirBookmarkData == nil || doctor.workdirResolutionFailed {
            return String(
                localized: "Authorize your Steam library folder first.",
                bundle: .appLanguage, comment: "Reason the automatic scene-resources download is unavailable: the Steam library is not authorized."
            )
        }
        if doctor.username == nil {
            return String(
                localized: "Sign in to Steam first — the download runs as your own account.",
                bundle: .appLanguage, comment: "Reason the automatic scene-resources download is unavailable: no Steam account."
            )
        }
        return nil
    }

    /// True while the pre-download readiness probes run; `cachedLogin` starts every
    /// launch at `.notRun`, so the first click always has to probe.
    private(set) var isPreflightingDownload = false

    func downloadEngineAssets() {
        runWithPreflight { [self] in engineInstaller.download(using: doctor) }
    }

    /// No preflight: the version check logs in anonymously, so it needs SteamCMD
    /// and nothing about the account or library.
    func checkEngineAssetsUpdate() {
        engineAssetsError = nil
        guard doctor.hasBoundBinary else {
            engineAssetsError = String(
                localized: "Set up SteamCMD first — Steam downloads run through it.",
                bundle: .appLanguage, comment: "Reason the automatic scene-resources download is unavailable: no SteamCMD."
            )
            return
        }
        engineInstaller.checkForUpdate(using: doctor)
    }

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
        // Set before the `Task`, not inside it: two clicks land on the main actor before
        // either suspends, so a flag raised inside would leave the button live.
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
