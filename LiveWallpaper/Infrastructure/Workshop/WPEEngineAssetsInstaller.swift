#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

/// Download/update WPE assets via SteamCMD into the shared Steam library and bind the library.
@MainActor
@Observable
final class WPEEngineAssetsInstaller {
    enum Phase: Equatable, Sendable {
        case idle
        case downloading
        case pruning
        case checking
        case failed(String)
    }

    struct ProgressBytes: Equatable, Sendable {
        let downloaded: UInt64?
        let total: UInt64?
    }

    enum UpdateCheckOutcome: Equatable, Sendable {
        case notChecked
        case checking
        case available(latestBuildID: String)
        case upToDate(buildID: String?)
        case unableToCompare
        case checkFailed
        /// Steam refused the cached session. Separate from `checkFailed`
        /// because it is the only one of these with an obvious next step, and
        /// because it is the one the user actually hits.
        case loginRequired

        static func resolve(
            installedBuildID: String?,
            lookup: SteamEngineBuildLookup?
        ) -> UpdateCheckOutcome {
            guard let lookup else { return .checkFailed }
            switch lookup.outcome {
            case .loginRequired: return .loginRequired
            case .timedOut, .steamCMDUnavailable, .unrecognized: return .checkFailed
            case .found: break
            }
            guard let latestBuildID = lookup.buildID else { return .checkFailed }
            guard let installedBuildID else { return .unableToCompare }
            return latestBuildID == installedBuildID
                ? .upToDate(buildID: installedBuildID)
                : .available(latestBuildID: latestBuildID)
        }
    }

    static let shared = WPEEngineAssetsInstaller()

    private(set) var phase: Phase = .idle
    private(set) var progress: Double?
    private(set) var progressBytes: ProgressBytes?
    /// nil when no managed install (or its build couldn't be read).
    private(set) var installedBuildID: String?
    private(set) var latestBuildID: String?
    private(set) var updateAvailable = false
    private(set) var updateCheckOutcome: UpdateCheckOutcome = .notChecked

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Per-run token. Guards a cancel-then-retry race where a superseded run's
    /// late return or progress callback would otherwise mutate the newer run.
    @ObservationIgnored private var currentAttempt: UUID?
    @ObservationIgnored private let operationCoordinator: SteamCMDDoctorOperationCoordinator

    /// Unknown-buildid marker; stored so SwiftUI observes download completion.
    private(set) var hasManagedInstall: Bool

    init(
        operationCoordinator: SteamCMDDoctorOperationCoordinator = .shared,
        managedStateForTesting: (hasManagedInstall: Bool, installedBuildID: String?)? = nil
    ) {
        self.operationCoordinator = operationCoordinator
        let state = managedStateForTesting ?? Self.managedStateFromDefaults()
        hasManagedInstall = state.hasManagedInstall
        installedBuildID = state.installedBuildID
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .pruning, .checking: true
        default: false
        }
    }

    /// Refresh linked state from disk (settings appearance / self-heal).
    func refreshManagedInstallState() {
        let state = Self.managedStateFromDefaults()
        hasManagedInstall = state.hasManagedInstall
        installedBuildID = state.installedBuildID
        if !hasManagedInstall {
            latestBuildID = nil
            updateAvailable = false
            updateCheckOutcome = .notChecked
        }
    }

    // MARK: - Download / update

    func download(using doctor: SteamCMDDoctorService) {
        guard !isBusy else { return }
        let attempt = UUID()
        currentAttempt = attempt
        phase = .downloading
        progress = nil
        progressBytes = nil
        updateCheckOutcome = .notChecked
        task = Task { [weak self] in await self?.run(using: doctor, attempt: attempt) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        // The Task cancel above only stops the app-side wait; the SteamCMD
        // child in the connector keeps running (timeout up to 5400s) and holds
        // its serial queue, so a retry would look wedged behind it. Scoped to
        // this attempt's id: a cancel that lands after the retry has started
        // must not kill the retry. Fire-and-forget — the interrupted run
        // reports failure through its own reply, which the cleared attempt
        // token already ignores.
        if let cancelled = currentAttempt {
            Task { await SteamConnectorClient.cancelActiveSteamCMD(operationID: cancelled.uuidString) }
        }
        currentAttempt = nil
        progress = nil
        progressBytes = nil
        if isBusy {
            phase = .idle
        }
        // A cancelled check would otherwise keep the "Checking Steam…" status
        // line on screen forever.
        if updateCheckOutcome == .checking {
            updateCheckOutcome = .notChecked
        }
    }

    func clearTransientStatus() {
        if case .failed = phase {
            phase = .idle
        }
        if !hasManagedInstall {
            latestBuildID = nil
            updateAvailable = false
            updateCheckOutcome = .notChecked
        }
    }

    /// Install via connector (real $HOME / shared Steam library; app has no write duty).
    private func run(using doctor: SteamCMDDoctorService, attempt: UUID) async {
        // Prefer adopting an existing install over re-downloading.
        if adoptExistingInstallIfPresent(doctor: doctor, attempt: attempt) { return }
        guard let account = doctor.username, (try? doctor.resolveBinaryURL()) != nil else {
            fail(String(
                localized: "Choose your Steam account and SteamCMD in Settings → Workshop → Steam connection first.",
                comment: "Engine-assets install blocked because the Steam connection is not configured."
            ))
            return
        }
        let result = await SteamConnectorClient.installWallpaperEngineAssets(
            accountName: account,
            operationID: attempt.uuidString,
            onProgress: { [weak self] update in
                Task { @MainActor [weak self] in
                    guard let self, currentAttempt == attempt else { return }
                    switch update.phase {
                    case .pruning:
                        phase = .pruning
                        progress = nil
                        progressBytes = nil
                    case .connecting, .downloading, .verifying:
                        guard case .downloading = phase else { return }
                        progress = update.fraction
                        progressBytes = ProgressBytes(
                            downloaded: update.downloadedBytes,
                            total: (update.totalBytes ?? 0) > 0 ? update.totalBytes : nil
                        )
                    }
                }
            }
        )
        guard currentAttempt == attempt else { return }
        task = nil
        guard !Task.isCancelled else { phase = .idle; progress = nil; currentAttempt = nil; return }

        guard let result else {
            fail(String(
                localized: "Loomscreen's Steam connector did not respond.",
                comment: "Steam sign-in diagnostic when the XPC connector could not be reached."
            ))
            return
        }
        doctor.noteExecutionReceipt(result.executedBinaryPath)
        switch result.outcome {
        case .installed:
            await adoptInstall(result, doctor: doctor, attempt: attempt)
        case .loginRequired:
            // Steam itself said the session is gone — demote the green probe so
            // download readiness stops disagreeing with reality.
            doctor.noteOperationReportedLoginRequired()
            fail(String(localized: "Sign in to Steam in Terminal, then re-check the connection.", comment: "Engine-assets install blocked: no cached Steam session."))
        case .notEntitled:
            fail(String(localized: "This Steam account doesn't own Wallpaper Engine, so its assets can't be downloaded.", comment: "Engine-assets download blocked: account doesn't own Wallpaper Engine."))
        case .pruneRefused:
            fail(String(localized: "Downloaded Wallpaper Engine, but trimming it to the assets folder failed.", comment: "Engine-assets download succeeded but pruning failed."))
        case .timedOut:
            fail(String(localized: "The download timed out. Try again.", comment: "Engine-assets download timed out."))
        case .steamCMDUnavailable:
            fail(String(localized: "SteamCMD could not be launched. Re-select it in the setup list.", comment: "Steam sign-in diagnostic when the bound SteamCMD binary could not run."))
        case .steamUnreachable, .unrecognized:
            fail(String(localized: "Steam returned an unrecognized response while installing Wallpaper Engine.", comment: "Engine-assets install failed with unparsed SteamCMD output."))
        }
    }

    /// Links an install that is already on disk instead of downloading one.
    /// Returns true when it took over the run.
    private func adoptExistingInstallIfPresent(
        doctor: SteamCMDDoctorService,
        attempt: UUID
    ) -> Bool {
        guard let steamRoot = try? doctor.resolveWorkdirURL() else { return false }
        let scope = steamRoot.startAccessingSecurityScopedResource()
        defer { if scope { steamRoot.stopAccessingSecurityScopedResource() } }
        let installRoot = WPEEngineAssetsLibrary.sharedLibraryInstallRoot(steamRoot: steamRoot)
        let assets = installRoot.appendingPathComponent("assets", isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: assets.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: assets.path(percentEncoded: false)),
              !contents.isEmpty,
              // Build id stays unknown here: nothing was downloaded, so there is
              // no `app_info` answer to trust yet. The update check fills it in.
              WPEEngineAssetsLibrary.adoptManagedInstall(at: installRoot, buildID: nil)
        else { return false }
        hasManagedInstall = true
        installedBuildID = nil
        updateAvailable = false
        updateCheckOutcome = .notChecked
        WPEEngineAssetsLibrary.shared.refresh()
        guard currentAttempt == attempt else { return true }
        task = nil
        currentAttempt = nil
        phase = .idle
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Wallpaper Engine assets ready", comment: "Engine-assets download success toast headline."),
            title: "",
            message: String(localized: "Linked the install already in your Steam library.", comment: "Toast when an existing Wallpaper Engine install was linked instead of downloaded."),
            isSuccess: true
        )
        return true
    }

    /// Bind install as assets root while Steam-library scope is held.
    private func adoptInstall(
        _ result: SteamEngineAssetsResult,
        doctor: SteamCMDDoctorService,
        attempt: UUID
    ) async {
        guard let assetsPath = result.assetsPath else {
            fail(String(localized: "Downloaded Wallpaper Engine, but trimming it to the assets folder failed.", comment: "Engine-assets download succeeded but pruning failed."))
            return
        }
        // Bookmark the install root (parent of `assets/`), matching what a
        // manual link stores.
        let installRoot = URL(fileURLWithPath: assetsPath, isDirectory: true).deletingLastPathComponent()
        guard let steamRoot = try? doctor.resolveWorkdirURL() else {
            fail(String(localized: "No Steam Library is authorized.", comment: "Workshop diagnostics error."))
            return
        }
        let scope = steamRoot.startAccessingSecurityScopedResource()
        defer { if scope { steamRoot.stopAccessingSecurityScopedResource() } }
        if !scope {
            // Bookmarking below needs this scope; without it the failure surfaces
            // as an opaque "Operation not permitted" from bookmarkData.
            Logger.warning(
                "Steam library scope did not start; bookmarking the install is likely to fail",
                category: .fileAccess
            )
        }
        guard WPEEngineAssetsLibrary.adoptManagedInstall(at: installRoot, buildID: result.buildID) else {
            fail(String(localized: "Installed Wallpaper Engine, but Loomscreen could not keep access to it.", comment: "Engine-assets install succeeded but the bookmark could not be created."))
            return
        }
        hasManagedInstall = true
        installedBuildID = result.buildID
        latestBuildID = result.buildID
        updateAvailable = false
        updateCheckOutcome = .upToDate(buildID: result.buildID)
        WPEEngineAssetsLibrary.shared.refresh()
        guard currentAttempt == attempt else { return }
        currentAttempt = nil
        phase = .idle
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Wallpaper Engine assets ready", comment: "Engine-assets download success toast headline."),
            title: "",
            message: String(localized: "Linked for extra scene coverage.", comment: "Engine-assets download success toast subtitle."),
            isSuccess: true
        )
    }

    // MARK: - Update check

    func checkForUpdate(using doctor: SteamCMDDoctorService) {
        checkForUpdate(
            account: doctor.username,
            binaryResolvable: (try? doctor.resolveBinaryURL()) != nil,
            // Demoting the probe is the point: without it the account row keeps
            // its green while every Steam operation is failing to log in.
            onLoginRequired: { doctor.noteOperationReportedLoginRequired() }
        )
    }

    /// Seam for tests: doctor fields and the connector lookup are injectable.
    /// `fetchLatestBuildID` stays ahead of `onLoginRequired`: Swift's forward
    /// scan binds an unlabelled trailing closure to the first closure
    /// parameter, and every existing caller passes the fetch that way.
    func checkForUpdate(
        account: String?,
        binaryResolvable: Bool,
        fetchLatestBuildID: @escaping @Sendable (String, String) async -> SteamEngineBuildLookup? = {
            await SteamConnectorClient.latestWallpaperEngineBuildID(accountName: $0, operationID: $1)
        },
        onLoginRequired: @escaping @MainActor () -> Void = {}
    ) {
        guard !isBusy, hasManagedInstall else { return }
        // Checked before any state is set: an early exit after `.checking` would
        // leave `isBusy` true forever and dead-lock download/check/remove.
        guard let account, binaryResolvable else { return }
        let attempt = UUID()
        currentAttempt = attempt
        phase = .checking
        updateCheckOutcome = .checking
        task = Task { [weak self] in
            let lookup = await fetchLatestBuildID(account, attempt.uuidString)
            guard let self, currentAttempt == attempt else { return }
            task = nil
            currentAttempt = nil
            phase = .idle
            latestBuildID = lookup?.buildID
            let outcome = UpdateCheckOutcome.resolve(
                installedBuildID: installedBuildID,
                lookup: lookup
            )
            if outcome == .loginRequired { onLoginRequired() }
            updateCheckOutcome = outcome
            updateAvailable = {
                if case .available = outcome {
                    return true
                }
                return false
            }()
            postUpdateCheckToast(outcome)
        }
    }

    // MARK: - Removal

    func remove() {
        guard !isBusy else { return }
        let attempt = UUID()
        currentAttempt = attempt
        phase = .pruning
        task = Task { [weak self] in await self?.performRemove(attempt: attempt) }
    }

    private func performRemove(attempt: UUID) async {
        do {
            try await operationCoordinator.withOperation(.assetsMutation) { [weak self] lease in
                guard let self else { return }
                try await commitRemove(attempt: attempt, operationLease: lease)
            }
        } catch {
            guard currentAttempt == attempt else { return }
            task = nil
            currentAttempt = nil
            phase = .idle
        }
    }

    // The coordinator's closure is @Sendable and runs off the main actor; hop back in one
    // call instead of touching main-actor state piecemeal, same as performRun.
    private func commitRemove(
        attempt: UUID,
        operationLease lease: SteamCMDDoctorOperationLease
    ) async throws {
        guard currentAttempt == attempt else { return }
        // Unlink bookmark/marker only; Steam owns the install files.
        _ = lease
        SettingsManager.shared.clearWPEEngineAssetsBookmark()
        SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
        hasManagedInstall = false
        installedBuildID = nil
        latestBuildID = nil
        updateAvailable = false
        updateCheckOutcome = .notChecked
        WPEEngineAssetsLibrary.shared.refresh()
        guard currentAttempt == attempt else { return }
        task = nil
        currentAttempt = nil
        phase = .idle
    }

    private func fail(_ message: String) {
        currentAttempt = nil
        progress = nil
        progressBytes = nil
        phase = .failed(message)
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Download failed", comment: "Engine-assets download failure toast headline."),
            title: "",
            message: message,
            isSuccess: false
        )
    }

    private static func managedStateFromDefaults() -> (hasManagedInstall: Bool, installedBuildID: String?) {
        let hasManagedInstall = WPEEngineAssetsLibrary.hasManagedInstall
        guard hasManagedInstall else { return (false, nil) }
        let stored = SettingsManager.shared.wpeEngineAssetsManagedBuildID
        return (
            true,
            stored == WPEEngineAssetsLibrary.unknownManagedBuildMarker ? nil : stored
        )
    }

    private func postUpdateCheckToast(_ outcome: UpdateCheckOutcome) {
        switch outcome {
        case .available:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Wallpaper Engine update available", comment: "Engine-assets update check found an update."),
                title: "",
                message: String(localized: "Click Update to download and relink the latest assets.", comment: "Engine-assets update available toast subtitle."),
                isSuccess: true
            )
        case .upToDate:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Wallpaper Engine assets are up to date", comment: "Engine-assets update check success headline."),
                title: "",
                message: String(localized: "No download is needed.", comment: "Engine-assets update check up-to-date subtitle."),
                isSuccess: true
            )
        case .unableToCompare:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Couldn't compare versions", comment: "Engine-assets update check version-unknown headline."),
                title: "",
                message: String(localized: "Download again to refresh the managed assets.", comment: "Engine-assets update check version-unknown subtitle."),
                isSuccess: false
            )
        case .loginRequired:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Steam sign-in expired", comment: "Engine-assets update check failure headline when Steam refused the cached session."),
                title: "",
                message: String(localized: "Sign in to your Steam account again, then check for updates.", comment: "Engine-assets update check failure subtitle when Steam refused the cached session."),
                isSuccess: false
            )
        case .checkFailed:
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Couldn't check for updates", comment: "Engine-assets update check failure headline."),
                title: "",
                message: String(localized: "SteamCMD did not return the latest Wallpaper Engine build.", comment: "Engine-assets update check failure subtitle."),
                isSuccess: false
            )
        case .notChecked, .checking:
            break
        }
    }
}

#endif
