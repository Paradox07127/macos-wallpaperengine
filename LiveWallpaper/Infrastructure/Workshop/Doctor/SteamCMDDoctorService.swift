#if !LITE_BUILD
import AppKit
import Foundation
import LiveWallpaperCore
import Observation

enum DoctorProbeKind: String, Sendable, CaseIterable, Identifiable {
    case binaryIdentity
    case codeSignature
    case gatekeeperQuarantine
    case workingDirectory
    case cachedLogin
    case workshopContent
    case sceneResources
    case connector

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .binaryIdentity: return String(localized: "SteamCMD binary identity", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .codeSignature: return String(localized: "Code signature", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .gatekeeperQuarantine: return String(localized: "Gatekeeper / quarantine", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .workingDirectory: return String(localized: "Steam Library access", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .cachedLogin: return String(localized: "Steam sign-in", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .workshopContent: return String(localized: "Workshop content folder", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .sceneResources: return String(localized: "Scene resources", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .connector: return String(localized: "Background Steam connector", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        }
    }

    var isAdvisory: Bool {
        switch self {
        case .codeSignature, .workshopContent, .sceneResources, .connector: return true
        default: return false
        }
    }
}

enum DoctorProbeStatus: Equatable, Sendable {
    case notRun
    case running
    case green(detail: String?)
    case yellow(message: String, command: String?)
    case red(message: String, command: String?)
}

struct DoctorProbeReport: Identifiable, Sendable {
    let id: DoctorProbeKind
    let status: DoctorProbeStatus
    let lastRun: Date
}

struct DoctorGreenFingerprint: Codable, Equatable, Sendable {
    let binaryPath: String
    let sha256: String
    let isHardenedRuntime: Bool
    /// When the probes that earned this actually ran. Carried into the restored
    /// reports so exported diagnostics never claim a check that did not happen.
    let recordedAt: Date
}

enum DoctorState: Sendable, Equatable {
    case idle
    case probing
    case done(allGreen: Bool, blockingFailures: Int)
}

enum SteamCMDDoctorError: Error, Equatable, Sendable, LocalizedError {
    case binaryResolution(SteamCMDBinaryError)
    case bookmarkCreation(String)
    case missingBinaryBinding
    case missingWorkdirBinding
    case bookmarkResolution(String)
    case invalidUsername
    case steamLibraryMissingConfig(URL)
    case steamLibraryInsideContainer(URL)
    case untrustedBinary
    case connectorBusy
    case connectorUnavailable

    var errorDescription: String? {
        switch self {
        case .binaryResolution:
            return String(localized: "Loomscreen couldn't use that file as SteamCMD.", bundle: .appLanguage, comment: "Workshop setup error when a manually chosen SteamCMD is refused.")
        case .bookmarkCreation(let reason):
            return String(localized: "Couldn't keep access to the chosen folder: \(reason)", bundle: .appLanguage, comment: "Workshop diagnostics error; %@ is the failure reason.")
        case .missingBinaryBinding:
            return String(localized: "No SteamCMD binary is selected.", bundle: .appLanguage, comment: "Workshop diagnostics error.")
        case .missingWorkdirBinding:
            return String(localized: "No Steam Library is authorized.", bundle: .appLanguage, comment: "Workshop diagnostics error.")
        case .bookmarkResolution(let reason):
            return String(localized: "Access to the chosen folder has expired. Choose it again: \(reason)", bundle: .appLanguage, comment: "Workshop diagnostics error; %@ is the failure reason.")
        case .invalidUsername:
            return String(localized: "Steam username must match ^[A-Za-z0-9_]{1,32}$.", bundle: .appLanguage, comment: "Workshop diagnostics error for an invalid Steam username.")
        case .steamLibraryMissingConfig(let url):
            let path = url.path(percentEncoded: false)
            return String(localized: "Steam Library must contain config/config.vdf: \(path)", bundle: .appLanguage, comment: "Workshop diagnostics error; %@ is the offending path.")
        case .steamLibraryInsideContainer(let url):
            let path = url.path(percentEncoded: false)
            return String(localized: "That folder is inside Loomscreen's own sandbox container, not your Steam installation: \(path)", bundle: .appLanguage, comment: "Workshop diagnostics error when the picked Steam Library is the app's private container copy; %@ is the offending path.")
        case .untrustedBinary:
            return String(localized: "SteamCMD is not a verified Valve build.", bundle: .appLanguage, comment: "Workshop diagnostics error when the SteamCMD binary is not trusted.")
        case .connectorBusy:
            return String(localized: "Loomscreen's Steam connector is busy with another SteamCMD task. Try again in a moment.", bundle: .appLanguage, comment: "Workshop setup error when binding SteamCMD while the connector is busy with another SteamCMD operation.")
        case .connectorUnavailable:
            return String(localized: "Loomscreen's Steam connector did not respond.", bundle: .appLanguage, comment: "Steam sign-in diagnostic when the XPC connector could not be reached.")
        }
    }
}

enum WorkshopItemDownloadResult<Imported: Sendable>: Sendable {
    case imported(Imported)
    case notConfigured(reason: String)
    case loginRequired
    case untrustedBinary
    case steamUnreachable
    case removedFromSteam
    case timedOut
    case failed(reason: String)
}

@MainActor
@Observable
final class SteamCMDDoctorService {

    private enum Keys {
        /// `.v2` because `.v1` could be any path the user picked, and those are no longer executed.
        static let binaryPath = "loomscreen.workshop.doctor.binaryPath.v2"
        static let legacyPickedBinaryPath = "loomscreen.workshop.doctor.binaryPath"
        static let workdirBookmark = "loomscreen.workshop.doctor.workdirBookmark"
        static let binarySHA256 = "loomscreen.workshop.doctor.binarySHA256"
        static let username = "loomscreen.workshop.doctor.username"
        static let greenFingerprint = "loomscreen.workshop.doctor.greenFingerprint.v1"
    }

    @MainActor
    static func relocatedWorkshopSourceBookmark(
        workshopID: String,
        resolver: SecurityScopedBookmarkResolver = .shared,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .appScoped()
    ) -> Data? {
        // The connector's digits-only rule, not the looser path-component one:
        // this id is about to become a path under the user's Steam library.
        guard SteamLibraryPaths.isSafeWorkshopID(workshopID),
              let workdirData = defaults.data(forKey: Keys.workdirBookmark),
              case .success(let root) = resolver.resolve(workdirData, target: .transient) else {
            return nil
        }
        return SecurityScopedBookmarkResolver.withScopedAccess(root.url) { didStart in
            guard didStart else { return nil }
            var folder = root.url
            for component in SteamLibraryPaths.workshopContentComponents {
                folder.appendPathComponent(component, isDirectory: true)
            }
            folder.appendPathComponent(workshopID, isDirectory: true)
            guard fileManager.fileExists(atPath: folder.path(percentEncoded: false)) else { return nil }
            return try? folder.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    nonisolated static let valveTeamIdentifier = "MXGJJ98X76"
    private static let identityBannerPattern = #"Steam Console Client \(c\) Valve Corporation - version \d+"#
    /// Self-update output is transient and must not be classified as an identity failure.
    private static let selfUpdatePattern =
        #"(Checking for available updates|Downloading update|Verifying installation)"#

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static let identityFailureExplainers: [DoctorProbeKind] =
        [.codeSignature, .gatekeeperQuarantine]
    nonisolated static let wallpaperEngineAppID: UInt32 = 431960
    @ObservationIgnored let operationCoordinator: SteamCMDDoctorOperationCoordinator
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let fileManager: FileManager
    @ObservationIgnored private let workshopFileInventory: any SteamCMDWorkshopFileInventoryServing

    var probes: [DoctorProbeKind: DoctorProbeReport]
    var state: DoctorState = .idle
    var binaryDisplayPath: String?
    var workdirDisplayPath: String?
    /// Stored fact that the bookmark exists but last resolution failed. `downloadBlocker` must stay IO-free.
    var workdirResolutionFailed = false
    private(set) var cachedLoginDiagnosticTail = ""
    private(set) var cachedLoginExitCode: Int32?
    /// Bumped whenever `username` changes so a download begun as account A cannot colour account B's probe.
    private(set) var accountGeneration = 0
    /// What Steam last said about the selected account's session. Only the
    /// credential verdicts gate downloads; network trouble does not.
    private(set) var cachedLoginVerdict: SteamCachedLoginOutcome?

    /// Execution receipt from the connector, not the app-side binding. nil until an operation that ran SteamCMD reports back.
    private(set) var lastExecutedBinaryPath: String?

    /// `@Observable` only tracks stored properties; these three live in `UserDefaults`, so this bump is what makes views that read only `binaryPath`/`workdirBookmarkData` update.
    private var defaultsRevision: UInt64 = 0

    var binaryPath: String? {
        get {
            _ = defaultsRevision
            return defaults.string(forKey: Keys.binaryPath)
        }
        set {
            setOptional(newValue, forKey: Keys.binaryPath)
            defaultsRevision &+= 1
            refreshDisplayPaths()
        }
    }

    var hasBoundBinary: Bool { binaryPath != nil }

    var workdirBookmarkData: Data? {
        get {
            _ = defaultsRevision
            return defaults.data(forKey: Keys.workdirBookmark)
        }
        set {
            setOptional(newValue, forKey: Keys.workdirBookmark)
            defaultsRevision &+= 1
            refreshDisplayPaths()
        }
    }

    var lastBinarySHA256: String? {
        get { defaults.string(forKey: Keys.binarySHA256) }
        set { setOptional(newValue, forKey: Keys.binarySHA256) }
    }

    var username: String? {
        get {
            _ = defaultsRevision
            return defaults.string(forKey: Keys.username)
        }
        set {
            setOptional(newValue, forKey: Keys.username)
            defaultsRevision &+= 1
        }
    }

    init(
        defaults: UserDefaults = .appScoped(),
        fileManager: FileManager = .default,
        workshopFileInventory: (any SteamCMDWorkshopFileInventoryServing)? = nil,
        operationCoordinator: SteamCMDDoctorOperationCoordinator = .shared
    ) {
        self.operationCoordinator = operationCoordinator
        self.defaults = defaults
        self.fileManager = fileManager
        self.workshopFileInventory = workshopFileInventory
            ?? SteamCMDWorkshopFileInventory(fileManager: fileManager)
        self.probes = Dictionary(uniqueKeysWithValues: DoctorProbeKind.allCases.map { kind in
            (kind, DoctorProbeReport(id: kind, status: .notRun, lastRun: .distantPast))
        })
        retireLegacyPickedBinaryBinding()
        refreshDisplayPaths()
    }

    private func retireLegacyPickedBinaryBinding() {
        guard defaults.object(forKey: Keys.legacyPickedBinaryPath) != nil else { return }
        defaults.removeObject(forKey: Keys.legacyPickedBinaryPath)
        if defaults.string(forKey: Keys.binaryPath) == nil {
            defaults.removeObject(forKey: Keys.binarySHA256)
        }
        Logger.info(
            "Retired a pre-managed SteamCMD binding; auto-detect will re-bind",
            category: .workshop
        )
    }

    // MARK: - Binding

    func bindResolvedBinary(_ path: String) async throws {
        beginProbeRun()
        let inspection = await inspect(path: path)
        if let refusal = Self.bindRefusal(for: inspection) {
            if let reason = inspection?.unavailableReason {
                Logger.notice("SteamCMD bind refused, connector busy: \(reason)", category: .workshop)
            }
            throw refusal
        }
        binaryPath = path
        // A receipt from before the rebind describes a binary the user just
        // replaced; showing it would undo the rebind on screen.
        lastExecutedBinaryPath = nil
        lastBinarySHA256 = inspection?.sha256
        verifiedBinarySHA256 = nil
        greenFingerprint = nil
        for kind in DoctorProbeKind.allCases where kind != .workingDirectory {
            setProbe(kind, status: .notRun)
        }
        Logger.info("Bound SteamCMD binary", category: .workshop)
        await runProbe(.binaryIdentity)
        if !isGreen(.binaryIdentity) {
            for kind in Self.identityFailureExplainers {
                await runProbe(kind)
            }
        }
    }

    nonisolated static func bindRefusal(for inspection: SteamCMDBinaryInspection?) -> SteamCMDDoctorError? {
        guard let inspection else { return .connectorUnavailable }
        if inspection.unavailableReason != nil {
            // Busy is not "bad binary": refusing the bind with a resolution error
            // would tell the user to pick a different file for no reason.
            return .connectorBusy
        }
        guard inspection.exists, inspection.sha256 != nil else {
            return .binaryResolution(.notExecutable)
        }
        return nil
    }

    func unbindBinary() {
        binaryPath = nil
        lastExecutedBinaryPath = nil
        lastBinarySHA256 = nil
        verifiedBinarySHA256 = nil
        greenFingerprint = nil
        for kind in DoctorProbeKind.allCases where kind != .workingDirectory {
            setProbe(kind, status: .notRun)
        }
    }

    private(set) var lastAutoDetectDiagnosis: SteamCMDDiagnosis?

    @discardableResult
    func autoDetectBinary() async -> Bool {
        lastAutoDetectDiagnosis = nil
        if let diagnosis = await SteamConnectorClient.diagnoseSteamCMD() {
            lastAutoDetectDiagnosis = diagnosis
            if diagnosis.launch != nil, let executed = diagnosis.canonicalPath {
                noteExecutionReceipt(executed)
            }
            // A reached verdict is the answer. Falling through to locate/bind on a negative one would bind a path just proved unable to launch.
            guard diagnosis.isUsable, let resolved = diagnosis.canonicalPath else { return false }
            return (try? await bindResolvedBinary(resolved)) != nil
        }
        // Only an unreachable connector falls through.
        guard let located = await SteamConnectorClient.locateSteamCMDBinary(),
              let path = located.canonicalPath else { return false }
        do {
            try await bindResolvedBinary(path)
            return true
        } catch {
            return false
        }
    }

    func autoConfigureIfNeeded() async {
        if !hasBoundBinary {
            await autoDetectBinary()
        } else if case .notRun? = probes[.binaryIdentity]?.status {
            // The binding survives relaunch; the probe result does not. Without this, an already-configured SteamCMD stays "unverified" for the whole session.
            await runProbe(.binaryIdentity)
        }
        await autoConfigureWorkdirIfNeeded()
    }

    func autoConfirmDownloadReadinessIfNeeded() async {
        await autoConfigureIfNeeded()
    }

    private func autoConfigureWorkdirIfNeeded() async {
        guard let data = workdirBookmarkData else { return }
        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            data,
            target: .transient
        ) else {
            workdirResolutionFailed = true
            return
        }
        workdirResolutionFailed = false
        let didStart = resolved.url.startAccessingSecurityScopedResource()
        defer { if didStart { resolved.url.stopAccessingSecurityScopedResource() } }
        guard !WPEEngineAssetsLibrary.isContainerInternal(resolved.url) else {
            forgetWorkdirBinding(reason: "binding pointed inside the app container, not the shared Steam profile")
            return
        }
        guard Self.isLibraryRoot(resolved.url) else {
            forgetWorkdirBinding(reason: "retired non-Steam Workshop repository binding")
            return
        }
    }

    private func forgetWorkdirBinding(reason: String) {
        workdirBookmarkData = nil
        workdirDisplayPath = nil
        workdirResolutionFailed = false
        setProbe(.workingDirectory, status: .notRun)
        setProbe(.cachedLogin, status: .notRun)
        Logger.notice("Forgot Steam library binding — \(reason)", category: .workshop)
    }

    func bindSteamLibrary(_ url: URL) async throws {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(atPath: canonicalURL.path(percentEncoded: false), isDirectory: &isDirectory)

        let configURL = canonicalURL
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("config.vdf", isDirectory: false)
        guard exists,
              isDirectory.boolValue,
              Self.isLibraryRoot(canonicalURL)
        else {
            throw SteamCMDDoctorError.steamLibraryMissingConfig(configURL)
        }
        guard !WPEEngineAssetsLibrary.isContainerInternal(canonicalURL) else {
            throw SteamCMDDoctorError.steamLibraryInsideContainer(canonicalURL)
        }

        let bookmark = try Self.makeBookmark(for: canonicalURL, readOnly: false)
        workdirBookmarkData = bookmark
        workdirDisplayPath = canonicalURL.path(percentEncoded: false)
        workdirResolutionFailed = false
        Logger.info("Bound official Steam library", category: .workshop)
        await runProbe(.workingDirectory)
    }

    func setUsername(_ name: String) throws {
        guard SteamCMDScriptWriter.validateUsername(name) else {
            throw SteamCMDDoctorError.invalidUsername
        }
        let changed = username != name
        username = name
        // A different account name means cached-login green is no longer about
        // this user.
        if changed {
            accountGeneration += 1
            cachedLoginVerdict = nil
            cachedLoginDiagnosticTail = ""
            cachedLoginExitCode = nil
            setProbe(.cachedLogin, status: .notRun)
        }
    }

    @discardableResult
    func removeSignedInSession() async -> Bool {
        guard let username else { return false }
        let generation = accountGeneration
        let result = await SteamConnectorClient.removeAccountSession(accountName: username)
        // The account can change while the connector works; a removal that
        // finished for the previous one must not clear this one's verdict.
        guard generation == accountGeneration else { return false }
        switch result?.outcome {
        case .removed, .notFound:
            forgetSignedInSession()
            return true
        case .refused, nil:
            // Leaving the probe untouched is accurate: the session is still there.
            Logger.warning(
                "Removing the saved Steam session was refused: \(result?.failureReason ?? "connector did not respond")",
                category: .workshop
            )
            return false
        }
    }

    func forgetSignedInSession() {
        // Bumping the generation is the point: an in-flight operation must not colour the probe green against a session that no longer exists.
        accountGeneration += 1
        cachedLoginVerdict = nil
        cachedLoginDiagnosticTail = ""
        cachedLoginExitCode = nil
        setProbe(.cachedLogin, status: .notRun)
    }

    // MARK: - Probes

    nonisolated static let binaryProbeKinds: [DoctorProbeKind] =
        [.binaryIdentity, .codeSignature, .gatekeeperQuarantine]

    private static func identityVerifiedDetail() -> String {
        String(localized: "SteamCMD identity verified.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
    }

    private static func verifiedValveBuildDetail(isHardenedRuntime: Bool) -> String {
        isHardenedRuntime
            ? String(localized: "Verified Valve build (TeamIdentifier=MXGJJ98X76, Hardened Runtime).", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
            : String(localized: "Verified Valve build (TeamIdentifier=MXGJJ98X76).", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
    }

    private static func gatekeeperClearDetail() -> String {
        String(localized: "SteamCMD launches without Gatekeeper interference.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
    }

    /// Not time-based: an unchanged fingerprint is an unchanged verdict, and a TTL would only burn a SteamCMD launch on a schedule.
    nonisolated static func canRestoreGreen(
        fingerprint: DoctorGreenFingerprint?,
        boundBinaryPath: String?,
        inspection: SteamCMDBinaryInspection?
    ) -> Bool {
        guard let fingerprint,
              boundBinaryPath == fingerprint.binaryPath,
              // No verdict is not a green light. A busy or unreachable connector
              // falls through to the probes, which say so in their own words.
              let inspection,
              inspection.unavailableReason == nil,
              inspection.exists,
              inspection.sha256 == fingerprint.sha256,
              inspection.signatureValid,
              inspection.teamIdentifier == valveTeamIdentifier,
              !inspection.isQuarantined
        else { return false }
        return true
    }

    func prepareAtLaunch() async {
        beginProbeRun()
        state = .probing
        var restored = false
        if let binary = try? resolveBinaryURL() {
            let didStart = binary.startAccessingSecurityScopedResource()
            defer { if didStart { binary.stopAccessingSecurityScopedResource() } }
            let path = binary.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            let inspection = await inspect(path: path)
            if let fingerprint = greenFingerprint,
               Self.canRestoreGreen(
                   fingerprint: fingerprint, boundBinaryPath: binaryPath, inspection: inspection
               ) {
                restoreGreen(from: fingerprint)
                restored = true
            }
        }
        if !restored {
            for kind in Self.binaryProbeKinds {
                await performProbe(kind)
            }
        }
        // After the restore, so that its own `.notRun` identity re-probe does not
        // re-run what we just settled.
        await autoConfigureIfNeeded()
        await performProbe(.workingDirectory)
        finishProbeRun()
    }

    private func restoreGreen(from fingerprint: DoctorGreenFingerprint) {
        setProbe(
            .binaryIdentity,
            status: .green(detail: redacted(Self.identityVerifiedDetail())),
            lastRun: fingerprint.recordedAt
        )
        setProbe(
            .codeSignature,
            status: .green(detail: redacted(
                Self.verifiedValveBuildDetail(isHardenedRuntime: fingerprint.isHardenedRuntime)
            )),
            lastRun: fingerprint.recordedAt
        )
        setProbe(
            .gatekeeperQuarantine,
            status: .green(detail: Self.gatekeeperClearDetail()),
            lastRun: fingerprint.recordedAt
        )
        verifiedBinarySHA256 = fingerprint.sha256
        // Nothing was probed, so nothing may re-date the record.
        lastInspection = nil
    }

    func runAll() async {
        beginProbeRun()
        state = .probing
        for kind in DoctorProbeKind.allCases {
            await performProbe(kind)
        }
        finishProbeRun()
    }

    func runProbe(_ kind: DoctorProbeKind) async {
        beginProbeRun()
        state = .probing
        await performProbe(kind)
        finishProbeRun()
    }

    private func performProbe(_ kind: DoctorProbeKind) async {
        setProbe(kind, status: .running)
        switch kind {
        case .binaryIdentity: await runBinaryIdentityProbe()
        case .codeSignature: await runCodeSignatureProbe()
        case .gatekeeperQuarantine: await runGatekeeperProbe()
        case .workingDirectory: runWorkingDirectoryProbe()
        case .cachedLogin: await runCachedLoginProbe()
        case .workshopContent: runWorkshopContentProbe()
        case .sceneResources: runSceneResourcesProbe()
        case .connector: await runConnectorProbe()
        }
    }

    private func runBinaryIdentityProbe() async {
        do {
            let binary = try resolveBinaryURL()
            let didStart = binary.startAccessingSecurityScopedResource()
            defer { if didStart { binary.stopAccessingSecurityScopedResource() } }
            guard var executionAuthorization = await trustedExecutionAuthorization(for: binary) else {
                setProbe(.binaryIdentity, status: .red(
                    message: String(localized: "SteamCMD isn't a verified Valve build, so it wasn't run. Re-select the official SteamCMD.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: nil
                ))
                return
            }

            var result = await launchSteamCMD(executionAuthorization, args: ["+quit"])
            var retriedAfterSelfUpdate = false
            if !result.timedOut,
               !Self.matches(Self.identityBannerPattern, in: result.stdout),
               Self.matches(Self.selfUpdatePattern, in: result.stdout) {
                // That run may have replaced the binary on disk, so re-establish
                // trust before launching whatever is there now.
                guard let refreshedAuthorization = await trustedExecutionAuthorization(for: binary) else {
                    setProbe(.binaryIdentity, status: .red(
                        message: String(localized: "SteamCMD isn't a verified Valve build, so it wasn't run. Re-select the official SteamCMD.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                        command: nil
                    ))
                    return
                }
                executionAuthorization = refreshedAuthorization
                retriedAfterSelfUpdate = true
                result = await launchSteamCMD(executionAuthorization, args: ["+quit"])
            }
            if result.timedOut {
                setProbe(.binaryIdentity, status: .red(
                    message: redacted(String(localized: "SteamCMD identity probe timed out after \(Int(Self.probeLaunchTimeout)) seconds.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message; %lld is the timeout in seconds.")),
                    command: redacted(command(binary: binary, args: ["+quit"]))
                ))
                return
            }
            guard Self.matches(Self.identityBannerPattern, in: result.stdout) else {
                setProbe(.binaryIdentity, status: .red(
                    message: retriedAfterSelfUpdate
                        ? String(localized: "SteamCMD is still updating itself and hasn't printed the Valve identity banner yet. Wait for the update to finish, then run this probe again.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
                        : String(localized: "SteamCMD did not print the expected Valve identity banner. Use Export diagnostics for the raw output.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: redacted(command(binary: binary, args: ["+quit"]))
                ))
                return
            }

            var detail = Self.identityVerifiedDetail()
            let rehashPath = binary.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            if let currentSHA = await inspect(path: rehashPath)?.sha256 {
                if let previous = lastBinarySHA256, previous != currentSHA {
                    detail = String(localized: "SteamCMD updated itself (SHA-256 changed) — that's normal.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
                }
                lastBinarySHA256 = currentSHA
            }
            setProbe(.binaryIdentity, status: .green(detail: redacted(detail)))
        } catch {
            setProbe(.binaryIdentity, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    private func runCodeSignatureProbe() async {
        do {
            let binary = try resolveBinaryURL()
            let didStart = binary.startAccessingSecurityScopedResource()
            defer { if didStart { binary.stopAccessingSecurityScopedResource() } }
            let path = binary.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            let result = await inspect(path: path)
            guard let result, result.unavailableReason == nil else {
                setProbe(.codeSignature, status: .yellow(
                    message: result?.unavailableReason == nil
                        ? String(localized: "Loomscreen's Steam connector did not respond, so the signature wasn't checked.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
                        : String(localized: "Loomscreen's Steam connector was busy, so the signature wasn't checked. Try again.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: nil
                ))
                return
            }
            guard result.exists else {
                setProbe(.codeSignature, status: .red(
                    message: String(localized: "SteamCMD is no longer where Loomscreen found it. Run Locate automatically again.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: nil
                ))
                return
            }
            if result.signatureValid, result.teamIdentifier == Self.valveTeamIdentifier {
                let detail = Self.verifiedValveBuildDetail(isHardenedRuntime: result.isHardenedRuntime)
                setProbe(.codeSignature, status: .green(detail: redacted(detail)))
            } else {
                let team = result.teamIdentifier ?? "none"
                let reason = result.signatureValid
                    ? String(localized: "SteamCMD is signed by an unverified team (TeamIdentifier=\(team)).", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
                    : String(localized: "SteamCMD signature is missing or could not be verified.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
                setProbe(.codeSignature, status: .yellow(
                    message: redacted(String(localized: "Unverified build. \(reason)", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")),
                    command: redacted(command(
                        binary: URL(fileURLWithPath: "/usr/bin/codesign"),
                        args: ["-dv", "--verbose=4", binary.path(percentEncoded: false)]
                    ))
                ))
            }
        } catch {
            setProbe(.codeSignature, status: .yellow(message: redacted(error.localizedDescription), command: nil))
        }
    }

    private func runGatekeeperProbe() async {
        do {
            let binary = try resolveBinaryURL()
            let didStart = binary.startAccessingSecurityScopedResource()
            defer { if didStart { binary.stopAccessingSecurityScopedResource() } }
            let path = binary.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            let quarantineCheck = await inspect(path: path)
            // Unavailable replies default isQuarantined=false — don't treat as clean.
            guard let quarantineCheck, quarantineCheck.unavailableReason == nil else {
                setProbe(.gatekeeperQuarantine, status: .yellow(
                    message: String(localized: "Loomscreen's Steam connector didn't answer, so the quarantine attribute wasn't checked. Try again.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: nil
                ))
                return
            }
            if quarantineCheck.isQuarantined {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: redacted(String(localized: "SteamCMD has the Gatekeeper quarantine attribute. macOS may block it on launch.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")),
                    command: redacted(xattrCommand(for: binary))
                ))
                return
            }

            if isGreen(.binaryIdentity) {
                setProbe(.gatekeeperQuarantine, status: .green(detail: Self.gatekeeperClearDetail()))
                return
            }

            guard let executionAuthorization = await trustedExecutionAuthorization(for: binary) else {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: String(localized: "SteamCMD isn't a verified Valve build, so it wasn't run.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: nil
                ))
                return
            }
            let result = await launchSteamCMD(
                executionAuthorization, args: ["+login", "anonymous", "+quit"]
            )
            let combined = "\(result.stdout)\n\(result.stderr)"
            if !result.timedOut,
               !result.killed,
               combined.contains("Steam Console Client") || result.exitCode == 0 {
                setProbe(.gatekeeperQuarantine, status: .green(detail: Self.gatekeeperClearDetail()))
            } else {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: String(localized: "SteamCMD failed the launch sanity check. If macOS blocked it, clear the quarantine attribute.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: redacted(xattrCommand(for: binary))
                ))
            }
        } catch {
            setProbe(.gatekeeperQuarantine, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    private func runWorkingDirectoryProbe() {
        do {
            let workdir = try resolveWorkdirURL()
            let didStart = workdir.startAccessingSecurityScopedResource()
            defer { if didStart { workdir.stopAccessingSecurityScopedResource() } }

            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: workdir.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                setProbe(.workingDirectory, status: .red(
                    message: redacted(String(localized: "Steam Library folder is missing.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")),
                    command: nil
                ))
                return
            }
            // Read-only library probe; a write probe would leave litter on green.
            guard Self.isLibraryRoot(workdir), fileManager.isReadableFile(atPath: workdir.path(percentEncoded: false)) else {
                setProbe(.workingDirectory, status: .red(
                    message: redacted(String(localized: "Steam Library is not readable.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")),
                    command: nil
                ))
                return
            }
            setProbe(.workingDirectory, status: .green(detail: redacted(String(localized: "Steam Library is readable.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."))))
        } catch {
            setProbe(.workingDirectory, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    private func runCachedLoginProbe() async {
        guard let username, SteamCMDScriptWriter.validateUsername(username) else {
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Choose which Steam account to use before checking the connection.",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic when no account has been selected yet."
                ),
                command: nil
            ))
            return
        }
        guard let binary = try? resolveBinaryURL() else {
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Select SteamCMD before checking the connection.",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic when no SteamCMD binary is bound."
                ),
                command: nil
            ))
            return
        }

        guard lastBinarySHA256 != nil else {
            // A bound binary always records its digest at bind time; missing
            // digest means the binding is incomplete — same remedy as unbound.
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Select SteamCMD before checking the connection.",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic when no SteamCMD binary is bound."
                ),
                command: nil
            ))
            return
        }

        let generation = accountGeneration
        let result = await SteamConnectorClient.probeCachedLogin(accountName: username)
        guard generation == accountGeneration else { return }
        guard let result else {
            setProbe(.cachedLogin, status: .red(
                message: String(
                    localized: "Loomscreen's Steam connector did not respond.",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic when the XPC connector could not be reached."
                ),
                command: nil
            ))
            return
        }
        applyCachedLoginOutcome(result, username: username, binary: binary, generation: generation)
    }

    static var steamUnreachableMessage: String {
        String(
            localized: "Steam reported that it couldn't connect. If you use a VPN or proxy: SteamCMD reaches Steam directly rather than through the system proxy, so try TUN (enhanced) mode or a direct connection.",
            bundle: .appLanguage, comment: "Steam sign-in failure when SteamCMD reported it could not open a connection to Steam."
        )
    }

    func applyCachedLoginOutcome(
        _ result: SteamCachedLoginResult,
        username: String,
        binary: URL,
        generation: Int
    ) {
        guard generation == accountGeneration, username == self.username else { return }
        noteExecutionReceipt(result.executedBinaryPath)
        cachedLoginVerdict = result.outcome
        cachedLoginDiagnosticTail = redacted(String(result.diagnosticTail.suffix(500)))
        cachedLoginExitCode = result.exitCode
        // Terminal recovery must authenticate the same private profile as XPC.
        // +quit ends the interactive run; that is what persists the session.
        let signIn = command(binary: binary, args: ["+login", username, "+quit"])

        switch result.outcome {
        case .sessionValid:
            setProbe(.cachedLogin, status: .green(
                detail: redacted(String(
                    localized: "Signed in to Steam as \(username).",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic detail; %@ is the Steam account name."
                ))
            ))
        case .noCachedSession:
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Connect this account to Loomscreen once. Its download session is saved separately from the Steam app.",
                    bundle: .appLanguage, comment: "SteamCMD private profile needs authentication; Steam client login is separate."
                ),
                command: signIn
            ))
        case .sessionExpired:
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Loomscreen's download session is unavailable. Reconnect this account; your Steam app sign-in is separate.",
                    bundle: .appLanguage, comment: "SteamCMD download needs renewed private-profile authentication."
                ),
                command: signIn
            ))
        case .noConnection:
            setProbe(.cachedLogin, status: .red(message: Self.steamUnreachableMessage, command: nil))
        case .rateLimited:
            // No sign-in command: running it again is what caused this, and
            // the throttle lifts on its own.
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Steam is rate-limiting sign-ins from this Mac. Wait a few minutes, then check again.",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic when Steam is throttling sign-in attempts."
                ),
                command: nil
            ))
        case .loginFailed:
            // A payload with no reason rendered "…the sign-in ()."; an older
            // connector, or a refusal line we could not parse, both land here.
            let reason = result.failureReason.map(redacted) ?? ""
            setProbe(.cachedLogin, status: .red(
                message: reason.isEmpty
                    ? String(
                        localized: "Steam refused the sign-in. Sign in to this account again, then check again.",
                        bundle: .appLanguage, comment: "Steam sign-in diagnostic when Steam refused without giving a reason."
                    )
                    : String(
                        localized: "Steam refused the sign-in (\(reason)). Sign in to this account again, then check again.",
                        bundle: .appLanguage, comment: "Steam sign-in diagnostic when Steam answered with a refusal; %@ is Steam's own reason text."
                    ),
                command: signIn
            ))
        case .timedOut:
            setProbe(.cachedLogin, status: .red(
                message: String(
                    localized: "The Steam sign-in check timed out. Steam's servers may be unreachable from this network.",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic when SteamCMD did not finish in time."
                ),
                command: nil
            ))
        case .steamCMDUnavailable:
            setProbe(.cachedLogin, status: .red(
                message: String(
                    localized: "SteamCMD could not be launched. Re-select it in the setup list.",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic when the bound SteamCMD binary could not run."
                ),
                command: nil
            ))
        case .unrecognized:
            // Never green on output nobody has seen before — that is how the old
            // Doctor produced confident-but-wrong results.
            let tail = redacted(result.diagnosticTail).replacingOccurrences(of: "\n", with: " ⏎ ")
            setProbe(.cachedLogin, status: .red(
                message: String(
                    localized: "Steam returned an unrecognized response. Raw tail: \(tail)",
                    bundle: .appLanguage, comment: "Steam sign-in diagnostic for unparsed SteamCMD output; %@ is the redacted output tail."
                ),
                command: nil
            ))
        }
    }

    // MARK: - Workshop download

    var isDownloadReady: Bool { downloadBlocker == nil }

    /// Stricter than `isDownloadReady`: the session must have been proven this launch, not merely not refuted.
    var isDownloadConfirmed: Bool {
        downloadBlocker == nil && isGreen(.cachedLogin)
    }

    /// The first setup step a download still lacks.
    enum DownloadBlocker: Equatable {
        case steamCMD
        case library
        case account
        case session
    }

    var downloadBlocker: DownloadBlocker? {
        // Only an actual red identity verdict blocks; `.notRun` stays allowed
        // because probe results are not persisted across launches.
        if case .red? = probes[.binaryIdentity]?.status {
            return .steamCMD
        }
        guard hasBoundBinary else { return .steamCMD }
        guard workdirBookmarkData != nil, !workdirResolutionFailed else { return .library }
        guard username.map(SteamCMDScriptWriter.validateUsername) ?? false else { return .account }
        // Unknown after launch is not logged out, and a network failure is not a missing account. Only a credential verdict blocks.
        switch cachedLoginVerdict {
        case .noCachedSession?, .sessionExpired?, .loginFailed?:
            return .session
        default:
            return nil
        }
    }

    var downloadBlockerMessage: String? {
        switch downloadBlocker {
        case .none:
            nil
        case .steamCMD:
            String(
                localized: "Set up SteamCMD first — Steam downloads run through it.",
                bundle: .appLanguage, comment: "Reason the automatic scene-resources download is unavailable: no SteamCMD."
            )
        case .library:
            String(
                localized: "Authorize your Steam library folder first.",
                bundle: .appLanguage, comment: "Reason the automatic scene-resources download is unavailable: the Steam library is not authorized."
            )
        case .account:
            String(
                localized: "Sign in to Steam first — the download runs as your own account.",
                bundle: .appLanguage, comment: "Reason the automatic scene-resources download is unavailable: no Steam account."
            )
        case .session:
            String(
                localized: "Loomscreen's download session is unavailable. Reconnect this account; your Steam app sign-in is separate.",
                bundle: .appLanguage, comment: "SteamCMD download needs renewed private-profile authentication."
            )
        }
    }

    /// Invoke onContentReady while workdir security scope is still held.
    func downloadWorkshopItem<Imported: Sendable>(
        _ itemID: UInt64,
        onProgress: SteamCMDProgressHandler? = nil,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        do {
            return try await operationCoordinator.withOperation(.workshopDownload) { [weak self] _ in
                guard let self else {
                    return .failed(reason: String(localized: "Workshop download owner was released.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."))
                }
                return await performDownloadWorkshopItem(
                    itemID,
                    onProgress: onProgress,
                    onContentReady: onContentReady
                )
            }
        } catch is CancellationError {
            return .failed(reason: String(localized: "Download cancelled.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."))
        } catch {
            return .failed(reason: redacted(error.localizedDescription))
        }
    }

    private func performDownloadWorkshopItem<Imported: Sendable>(
        _ itemID: UInt64,
        onProgress: SteamCMDProgressHandler?,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        guard let username, SteamCMDScriptWriter.validateUsername(username) else {
            return .notConfigured(reason: String(localized: "Choose your Steam account in the Steam connection sheet first.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message."))
        }
        guard (try? resolveBinaryURL()) != nil else {
            return .notConfigured(reason: SteamCMDDoctorError.missingBinaryBinding.errorDescription ?? "No SteamCMD binary is selected.")
        }
        guard let steamRoot = try? resolveWorkdirURL() else {
            return .notConfigured(reason: SteamCMDDoctorError.missingWorkdirBinding.errorDescription ?? "No Steam Library is authorized.")
        }
        // No digest means the binding never completed its identity probe. This is a readiness check, not an authorization one.
        guard lastBinarySHA256 != nil else { return .untrustedBinary }

        let generation = accountGeneration
        let result = await SteamConnectorClient.downloadWorkshopItem(
            workshopID: String(itemID),
            accountName: username,
            libraryPath: steamRoot.path(percentEncoded: false),
            onProgress: { update in
                guard let fraction = update.fraction else { return }
                onProgress?(fraction * 100, update.downloadedBytes, update.totalBytes)
            }
        )
        guard let result else {
            return .failed(reason: String(
                localized: "Loomscreen's Steam connector did not respond.",
                bundle: .appLanguage, comment: "Steam sign-in diagnostic when the XPC connector could not be reached."
            ))
        }
        noteExecutionReceipt(result.executedBinaryPath)
        switch result.outcome {
        case .downloaded:
            noteSuccessfulSteamOperation(generation: generation)
            guard result.itemPath != nil else { return .failed(reason: String(localized: "Download reported no folder.", bundle: .appLanguage, comment: "SteamCMD diagnostic (Doctor) probe label or result message.")) }
            // The import reads the folder and mints its own per-project bookmark,
            // so the Steam-library scope has to stay open across the handoff.
            let scope = steamRoot.startAccessingSecurityScopedResource()
            defer {
                if scope {
                    steamRoot.stopAccessingSecurityScopedResource()
                }
            }
            guard let folder = authorizedDownloadedItemDirectory(
                workshopID: String(itemID),
                steamRoot: steamRoot
            ) else {
                return .failed(reason: String(
                    localized: "The download didn't land in your authorized Steam library, so it wasn't imported.",
                    bundle: .appLanguage, comment: "Workshop download refused: the item directory failed containment revalidation under the authorized Steam library."
                ))
            }
            return await .imported(onContentReady(folder))
        case .loginRequired:
            noteOperationReportedLoginRequired(generation: generation)
            return .loginRequired
        case .steamUnreachable:
            return .steamUnreachable
        case .removedFromSteam:
            return .removedFromSteam
        case .timedOut:
            return .timedOut
        case .steamCMDUnavailable:
            return .notConfigured(reason: String(
                localized: "SteamCMD could not be launched. Re-select it in the setup list.",
                bundle: .appLanguage, comment: "Steam sign-in diagnostic when the bound SteamCMD binary could not run."
            ))
        case .unrecognized:
            return .failed(reason: redacted(result.diagnosticTail))
        }
    }

    /// `result.itemPath` is a claim from the connector's JSON, not an authorization; revalidate among the library's own items before the importer sees a URL.
    func authorizedDownloadedItemDirectory(workshopID: String, steamRoot: URL) -> URL? {
        guard let candidate = workshopFileInventory.projectFolders(
            under: steamRoot,
            anchoredTo: steamRoot,
            skipping: []
        ).first(where: { $0.url.lastPathComponent == workshopID })
        else { return nil }
        return workshopFileInventory.revalidatedURL(for: candidate, requiringProjectJSON: true)
    }

    func enumerateDownloadedItemFolders(_ body: @MainActor (URL) async -> Void) async {
        var seen = Set<String>()
        let inventory = workshopFileInventory

        if let workdir = try? resolveWorkdirURL() {
            let scope = workdir.startAccessingSecurityScopedResource()
            defer { if scope { workdir.stopAccessingSecurityScopedResource() } }
            let snapshotSeen = seen
            let projects = await Task.detached(priority: .utility) {
                inventory.projectFolders(
                    under: workdir,
                    anchoredTo: workdir,
                    skipping: snapshotSeen
                )
            }.value
            var consumedIDs: [String] = []
            for candidate in projects {
                let project = await Task.detached(priority: .utility) {
                    inventory.revalidatedURL(
                        for: candidate,
                        requiringProjectJSON: true
                    )
                }.value
                guard let project else { continue }
                consumedIDs.append(project.lastPathComponent)
                await body(project)
            }
            seen.formUnion(consumedIDs)
        }
    }

    // MARK: - Helpers

    /// A result with no receipt ran nothing; it must not erase the last one.
    func noteExecutionReceipt(_ path: String?) {
        guard let path else { return }
        lastExecutedBinaryPath = path
    }

    /// Last SHA-256 verified as an intact Valve build. Transient — re-verified
    /// each launch and whenever the SHA changes.
    @ObservationIgnored private var verifiedBinarySHA256: String?

    /// The most recent inspection that reached a verdict. Cleared by a restore, which judged nothing.
    @ObservationIgnored private var lastInspection: SteamCMDBinaryInspection?

    /// Valid only from a run's start until the next SteamCMD launch: SteamCMD rewrites its own executable, so `launchSteamCMD` drops it.
    @ObservationIgnored var runScopedInspections: [String: SteamCMDBinaryInspection] = [:]

    func beginProbeRun() {
        runScopedInspections.removeAll()
    }

    func launchSteamCMD(
        _ authorization: SteamCMDBinaryExecutionAuthorization,
        args: [String]
    ) async -> SteamCMDRunResult {
        let result = await Self.probe(authorization, args: args)
        noteExecutionReceipt(result.executedBinaryPath)
        runScopedInspections.removeAll()
        return result
    }

    var greenFingerprint: DoctorGreenFingerprint? {
        get {
            guard let data = defaults.data(forKey: Keys.greenFingerprint) else { return nil }
            return try? JSONDecoder().decode(DoctorGreenFingerprint.self, from: data)
        }
        set {
            setOptional(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.greenFingerprint)
        }
    }

    func inspect(path: String) async -> SteamCMDBinaryInspection? {
        if let reused = runScopedInspections[path] { return reused }
        let inspection = await SteamConnectorClient.inspectSteamCMDBinary(path: path)
        if let inspection, inspection.unavailableReason == nil, inspection.exists {
            lastInspection = inspection
            runScopedInspections[path] = inspection
        }
        return inspection
    }

    typealias SteamCMDProgressHandler = @Sendable (
        _ percent: Double, _ downloadedBytes: UInt64?, _ totalBytes: UInt64?
    ) -> Void

    /// `killed` means the connector never produced a verdict, not that a child was signalled.
    struct SteamCMDRunResult: Sendable {
        let exitCode: Int32?
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let killed: Bool
        var executedBinaryPath: String? = nil
    }

    struct SteamCMDBinaryExecutionAuthorization: Equatable, Sendable {
        let canonicalPath: String
        let sha256: String
    }

    /// 120, not 30: a fresh SteamCMD bootstrap self-updates with up to two exit-42 restarts inside one probe, and slow networks need the headroom.
    static let probeLaunchTimeout: TimeInterval = 120

    private static func probe(
        _ authorization: SteamCMDBinaryExecutionAuthorization,
        args: [String],
        timeout: TimeInterval = SteamCMDDoctorService.probeLaunchTimeout
    ) async -> SteamCMDRunResult {
        guard let run = await SteamConnectorClient.runSteamCMDProbe(
            arguments: args,
            timeout: timeout
        ) else {
            return SteamCMDRunResult(
                exitCode: nil,
                stdout: "",
                stderr: "Loomscreen's Steam connector did not respond.",
                timedOut: false,
                killed: true
            )
        }
        if let refusal = run.refusalReason {
            return SteamCMDRunResult(
                exitCode: nil, stdout: "", stderr: refusal, timedOut: false, killed: true
            )
        }
        return SteamCMDRunResult(
            exitCode: run.exitCode,
            stdout: run.output,
            stderr: "",
            timedOut: run.timedOut,
            killed: false,
            executedBinaryPath: run.executedBinaryPath
        )
    }

    private func trustedExecutionAuthorization(
        for binary: URL
    ) async -> SteamCMDBinaryExecutionAuthorization? {
        let didStart = binary.startAccessingSecurityScopedResource()
        defer { if didStart { binary.stopAccessingSecurityScopedResource() } }
        let path = binary.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let inspection = await inspect(path: path),
              inspection.exists,
              let currentSHA = inspection.sha256 else {
            verifiedBinarySHA256 = nil
            return nil
        }
        let decision = Self.evaluateTrust(inspection: inspection, cachedSHA256: verifiedBinarySHA256)
        verifiedBinarySHA256 = decision.verifiedSHA256
        guard decision.isTrusted else { return nil }
        return SteamCMDBinaryExecutionAuthorization(canonicalPath: path, sha256: currentSHA)
    }

    /// An unchanged SHA must skip re-verification; a changed SHA must be re-verified against Valve's team identifier before it is trusted again.
    struct TrustDecision: Equatable {
        let isTrusted: Bool
        let verifiedSHA256: String?
        /// True when the signature had to be re-examined rather than cached.
        let didReverify: Bool
    }

    nonisolated static func evaluateTrust(
        inspection: SteamCMDBinaryInspection,
        cachedSHA256: String?
    ) -> TrustDecision {
        // No verdict is not a negative verdict. Dropping the cached digest here would make the next run re-spawn codesign for a binary nothing has said is bad.
        guard inspection.unavailableReason == nil else {
            return TrustDecision(isTrusted: false, verifiedSHA256: cachedSHA256, didReverify: false)
        }
        guard inspection.exists, let currentSHA = inspection.sha256 else {
            return TrustDecision(isTrusted: false, verifiedSHA256: nil, didReverify: false)
        }
        guard currentSHA != cachedSHA256 else {
            return TrustDecision(isTrusted: true, verifiedSHA256: cachedSHA256, didReverify: false)
        }
        guard inspection.signatureValid,
              inspection.teamIdentifier == valveTeamIdentifier else {
            return TrustDecision(isTrusted: false, verifiedSHA256: nil, didReverify: true)
        }
        return TrustDecision(isTrusted: true, verifiedSHA256: currentSHA, didReverify: true)
    }


    func resolveBinaryURL() throws -> URL {
        guard let path = binaryPath else { throw SteamCMDDoctorError.missingBinaryBinding }
        return URL(fileURLWithPath: path)
    }

    func resolveWorkdirURL() throws -> URL {
        guard let data = workdirBookmarkData else { throw SteamCMDDoctorError.missingWorkdirBinding }
        switch SecurityScopedBookmarkResolver.shared.resolve(data, target: .transient) {
        case .success(let resolved):
            let url = resolved.url.resolvingSymlinksInPath().standardizedFileURL
            if resolved.didRefresh {
                // The shared resolver refreshes with read-only scope, but workdir needs write access — recreate the bookmark with write scope and persist.
                if let refreshed = try? Self.makeBookmark(for: url, readOnly: false) {
                    workdirBookmarkData = refreshed
                }
            }
            workdirDisplayPath = url.path(percentEncoded: false)
            workdirResolutionFailed = false
            return url
        case .failure(let failure):
            workdirResolutionFailed = true
            throw SteamCMDDoctorError.bookmarkResolution(failure.localizedDescription)
        }
    }

    private func refreshDisplayPaths() {
        binaryDisplayPath = defaults.string(forKey: Keys.binaryPath)
        workdirDisplayPath = Self.displayPath(for: defaults.data(forKey: Keys.workdirBookmark))
        // Bytes that no longer resolve are a broken grant from the first frame,
        // not only after some later probe happens to notice.
        if workdirDisplayPath == nil, defaults.data(forKey: Keys.workdirBookmark) != nil {
            workdirResolutionFailed = true
        }
    }

    private static func displayPath(for bookmarkData: Data?) -> String? {
        guard let bookmarkData,
              case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient)
        else { return nil }
        return resolved.url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }

    private static func makeBookmark(for url: URL, readOnly: Bool) throws -> Data {
        do {
            let options: URL.BookmarkCreationOptions = readOnly
                ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                : [.withSecurityScope]
            return try SecurityScopedBookmarkResolver.withScopedAccess(url) { _ in
                try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
        } catch {
            throw SteamCMDDoctorError.bookmarkCreation(error.localizedDescription)
        }
    }

    private func setOptional(_ value: Data?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func setOptional(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    func setProbe(_ kind: DoctorProbeKind, status: DoctorProbeStatus, lastRun: Date = Date()) {
        probes[kind] = DoctorProbeReport(id: kind, status: status, lastRun: lastRun)
    }

    private func finishProbeRun() {
        let blockingFailures = probes.values.reduce(0) { partial, report in
            guard case .red = report.status, !report.id.isAdvisory else { return partial }
            return partial + 1
        }
        let allGreen = DoctorProbeKind.allCases.allSatisfy { kind in
            guard let report = probes[kind], case .green = report.status else { return false }
            return true
        }
        state = .done(allGreen: allGreen, blockingFailures: blockingFailures)
        updateGreenFingerprint()
    }

    func updateGreenFingerprint() {
        let contradicted = Self.binaryProbeKinds.contains { kind in
            switch probes[kind]?.status {
            case .yellow, .red: return true
            default: return false
            }
        }
        guard !contradicted else {
            greenFingerprint = nil
            return
        }
        guard Self.binaryProbeKinds.allSatisfy(isGreen),
              let path = binaryPath,
              let inspection = lastInspection,
              let sha256 = inspection.sha256
        else { return }
        greenFingerprint = DoctorGreenFingerprint(
            binaryPath: path,
            sha256: sha256,
            isHardenedRuntime: inspection.isHardenedRuntime,
            recordedAt: Date()
        )
    }

    /// Demote the probe when a live operation reports login required so `isDownloadReady` stops saying yes.
    func noteOperationReportedLoginRequired(generation: Int) {
        guard generation == accountGeneration else { return }
        cachedLoginVerdict = .sessionExpired
        // Prefer the receipt: the Terminal command should name the binary that
        // actually failed, not the one the UI happens to have bound.
        let binary = lastExecutedBinaryPath.map { URL(fileURLWithPath: $0) } ?? (try? resolveBinaryURL())
        let signIn = binary.flatMap { binary in
            username.map { command(binary: binary, args: ["+login", $0, "+quit"]) }
        }
        setProbe(.cachedLogin, status: .yellow(
            message: String(
                localized: "Loomscreen's download session is unavailable. Reconnect this account; your Steam app sign-in is separate.",
                bundle: .appLanguage, comment: "SteamCMD download needs renewed private-profile authentication."
            ),
            command: signIn
        ))
    }

    func noteSuccessfulSteamOperation(generation: Int) {
        guard generation == accountGeneration, let username else { return }
        cachedLoginVerdict = .sessionValid
        setProbe(.cachedLogin, status: .green(detail: redacted(String(
            localized: "Signed in to Steam as \(username).",
            bundle: .appLanguage, comment: "Steam sign-in diagnostic detail; %@ is the Steam account name."
        ))))
    }

    func isGreen(_ kind: DoctorProbeKind) -> Bool {
        guard let report = probes[kind], case .green = report.status else { return false }
        return true
    }

    func redacted(_ raw: String) -> String {
        var prepared = raw
        if let workdirDisplayPath, !workdirDisplayPath.isEmpty {
            prepared = prepared.replacingOccurrences(of: workdirDisplayPath, with: "<workdir>")
        }
        var output = WorkshopDiagnosticRedactor.redact(prepared)
        if let username, !username.isEmpty {
            output = output.replacingOccurrences(of: username, with: "<steam_username>")
        }
        return output
    }

    private func command(binary: URL, args: [String]) -> String {
        var words = [binary.path(percentEncoded: false)] + args
        if let account = SteamCMDProfile.account(in: args), let home = try? SteamCMDProfile.home(accountName: account) {
            words = ["/usr/bin/env", "HOME=\(home.path(percentEncoded: false))"] + words
        }
        return words.map(Self.shellEscaped).joined(separator: " ")
    }

    /// A SteamCMD-only installation has no client config in the content library.
    /// Its canonical library folder is still valid; SteamCMD credentials live elsewhere.
    static func isLibraryRoot(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL == SteamLibraryPaths.steamRoot().resolvingSymlinksInPath().standardizedFileURL
            || FileManager.default.isReadableFile(atPath: url.appendingPathComponent("config/config.vdf").path(percentEncoded: false))
    }

    private func xattrCommand(for binary: URL) -> String {
        "xattr -dr com.apple.quarantine \(Self.shellEscaped(binary.path(percentEncoded: false)))"
    }

    private static func shellEscaped(_ value: String) -> String {
        if value.range(of: #"[^A-Za-z0-9_@%+=:,./-]"#, options: .regularExpression) == nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
#endif
