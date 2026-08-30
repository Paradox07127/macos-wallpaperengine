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
        case .binaryIdentity: return String(localized: "SteamCMD binary identity", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .codeSignature: return String(localized: "Code signature", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .gatekeeperQuarantine: return String(localized: "Gatekeeper / quarantine", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .workingDirectory: return String(localized: "Steam Library access", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .cachedLogin: return String(localized: "Steam sign-in", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .workshopContent: return String(localized: "Workshop content folder", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .sceneResources: return String(localized: "Scene resources", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        case .connector: return String(localized: "Background Steam connector", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
        }
    }

    /// Advisory failures remain visible without blocking Workshop operations.
    ///
    /// The three Workshop-wide checks are all advisory by construction:
    /// `downloadBlocker` never reads them, so a red row here reports a problem
    /// without taking any command away from the user.
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

/// The SteamCMD that last passed all three binary probes, kept across launches.
///
/// Only facts, never rendered probe text: the details are rebuilt at restore
/// time so a language change between launches cannot resurrect the old
/// locale's strings.
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
    case workdirNotDirectory(URL)
    case steamLibraryMissingConfig(URL)
    case steamLibraryInsideContainer(URL)
    case untrustedBinary

    var errorDescription: String? {
        switch self {
        case .binaryResolution(let error):
            let detail = String(describing: error)
            return String(localized: "SteamCMD binary could not be resolved: \(detail)", comment: "Workshop diagnostics error; %@ is the underlying binary-resolution failure.")
        case .bookmarkCreation(let reason):
            return String(localized: "Could not create a security-scoped bookmark: \(reason)", comment: "Workshop diagnostics error; %@ is the failure reason.")
        case .missingBinaryBinding:
            return String(localized: "No SteamCMD binary is selected.", comment: "Workshop diagnostics error.")
        case .missingWorkdirBinding:
            return String(localized: "No Steam Library is authorized.", comment: "Workshop diagnostics error.")
        case .bookmarkResolution(let reason):
            return String(localized: "Stored security-scoped bookmark could not be resolved: \(reason)", comment: "Workshop diagnostics error; %@ is the failure reason.")
        case .invalidUsername:
            return String(localized: "Steam username must match ^[A-Za-z0-9_]{1,32}$.", comment: "Workshop diagnostics error for an invalid Steam username.")
        case .workdirNotDirectory(let url):
            let path = url.path(percentEncoded: false)
            return String(localized: "Steam Library path is not a folder: \(path)", comment: "Workshop diagnostics error; %@ is the offending path.")
        case .steamLibraryMissingConfig(let url):
            let path = url.path(percentEncoded: false)
            return String(localized: "Steam Library must contain config/config.vdf: \(path)", comment: "Workshop diagnostics error; %@ is the offending path.")
        case .steamLibraryInsideContainer(let url):
            let path = url.path(percentEncoded: false)
            return String(localized: "That folder is inside Loomscreen's own sandbox container, not your Steam installation: \(path)", comment: "Workshop diagnostics error when the picked Steam Library is the app's private container copy; %@ is the offending path.")
        case .untrustedBinary:
            return String(localized: "SteamCMD is not a verified Valve build.", comment: "Workshop diagnostics error when the SteamCMD binary is not trusted.")
        }
    }
}

/// Download result independent of the concrete imported-item model.
enum WorkshopItemDownloadResult<Imported: Sendable>: Sendable {
    case imported(Imported)
    case notConfigured(reason: String)
    case loginRequired
    case untrustedBinary
    case notEntitled
    case removedFromSteam
    case timedOut
    case failed(reason: String)
}

@MainActor
@Observable
final class SteamCMDDoctorService {

    private enum Keys {
        /// `.v2` because the `.v1` value could be any path the user picked in an
        /// open panel, and those are exactly the paths we no longer execute.
        /// Re-keying retires them without needing a rule for telling one apart;
        /// auto-detect re-binds on the next use, silently for anyone whose
        /// SteamCMD is a managed or package-manager install.
        static let binaryPath = "loomscreen.workshop.doctor.binaryPath.v2"
        static let legacyPickedBinaryPath = "loomscreen.workshop.doctor.binaryPath"
        static let workdirBookmark = "loomscreen.workshop.doctor.workdirBookmark"
        static let binarySHA256 = "loomscreen.workshop.doctor.binarySHA256"
        static let username = "loomscreen.workshop.doctor.username"
        static let greenFingerprint = "loomscreen.workshop.doctor.greenFingerprint.v1"
    }

    /// Re-bookmark a workshop item under the authorized Steam library (layout moves).
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

    /// Probes that can diagnose identity failure without executing authenticated operations.
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
    /// True while the stored Steam-library bookmark exists but its most recent
    /// resolution failed (folder moved/deleted, grant revoked). A stored fact,
    /// not a live check: `downloadBlocker` must stay IO-free (rule R2).
    var workdirResolutionFailed = false

    /// The binary the connector most recently reported actually executing — its
    /// execution receipt, not the app-side binding. The connector re-resolves
    /// its candidate list on every operation, so this can differ from
    /// `binaryPath`; the app consumes the receipt, it never vetoes it. nil until
    /// an operation that ran SteamCMD reports back.
    private(set) var lastExecutedBinaryPath: String?

    /// Bumped by every defaults-backed setter below, and read by their getters.
    ///
    /// `@Observable` only tracks stored properties, and these three live in
    /// `UserDefaults`. Without this, a view whose body reads only `binaryPath`
    /// or `workdirBookmarkData` — including the step-state properties that
    /// `guard` on them and return before touching `probes` — registers no
    /// dependency at all, and keeps showing "not set up" after the user sets it
    /// up. Refreshing the display paths is not enough: it only notifies views
    /// that happen to read those.
    private var defaultsRevision: UInt64 = 0

    /// Bound SteamCMD path (not a capability; connector enforces Valve signature).
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

    /// True once a binary path is bound.
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

    /// SteamCMD read/spawn lives in the connector; doctor only stores the path.
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

    /// Drops a binding made when the user could still point us at any file. The
    /// stored digest goes with it — it describes a binary we will not run.
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

    /// Records the binary the connector resolved from its own candidate list.
    ///
    /// There is no "bind what the user picked" any more: an app-named path is
    /// one the app can rewrite between our checks and the connector's spawn,
    /// and nothing on macOS binds a signature verdict to the inode that ends up
    /// executed. Every path stored here came back from the connector.
    func bindResolvedBinary(_ path: String) async throws {
        beginProbeRun()
        let inspection = await inspect(path: path)
        if let reason = inspection?.unavailableReason {
            // Busy is not "bad binary": refusing the bind with a resolution error
            // would tell the user to pick a different file for no reason.
            throw SteamCMDDoctorError.bookmarkResolution(reason)
        }
        guard let inspection, inspection.exists, let sha256 = inspection.sha256 else {
            throw SteamCMDDoctorError.binaryResolution(.notExecutable)
        }
        binaryPath = path
        // A receipt from before the rebind describes a binary the user just
        // replaced; showing it would undo the rebind on screen.
        lastExecutedBinaryPath = nil
        lastBinarySHA256 = sha256
        verifiedBinarySHA256 = nil
        greenFingerprint = nil
        // Invalidate every probe whose green-ness depends on which binary
        // we run — re-binding to a different SteamCMD must force a re-run.
        for kind in DoctorProbeKind.allCases where kind != .workingDirectory {
            setProbe(kind, status: .notRun)
        }
        Logger.info("Bound SteamCMD binary", category: .workshop)
        await runProbe(.binaryIdentity)
        // Identity failed: still run probes that explain why; skip ones needing a binary.
        if !isGreen(.binaryIdentity) {
            for kind in Self.identityFailureExplainers {
                await runProbe(kind)
            }
        }
    }

    /// Drops the current binding. Only for when the binary it names is known to
    /// be gone — removing a managed install leaves the stored path pointing at
    /// nothing, and the Doctor would keep displaying it as the chosen SteamCMD.
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

    /// Auto-bind, managed install first and then the three package-manager
    /// locations. This is now the only way a binary ever gets bound.
    ///
    /// Why the last auto-detect ended where it did. nil before the first run,
    /// and after one that bound a binary there is nothing left to explain.
    private(set) var lastAutoDetectDiagnosis: SteamCMDDiagnosis?

    /// The managed install wins over a package-manager one because we installed
    /// it: its provenance was digest-checked and its signature verified against
    /// Valve's team id, which is more than we know about an arbitrary
    /// `/usr/local/bin/steamcmd`.
    @discardableResult
    func autoDetectBinary() async -> Bool {
        lastAutoDetectDiagnosis = nil
        // Ask the connector for the whole verdict rather than assembling one
        // here: it is the only process that can actually launch the binary, and
        // this app's previous path-existence inference reported green while
        // SteamCMD could not start at all.
        // No managed path is sent: the connector derives its own install root,
        // so auto-detect also finds a managed copy whose app-side record was
        // lost — which is exactly the state a failed removal leaves behind.
        if let diagnosis = await SteamConnectorClient.diagnoseSteamCMD() {
            // Kept, not discarded: a failed auto-detect used to collapse into a
            // bare `false`, so "found it, but its first run timed out — run
            // `steamcmd +quit` once in Terminal" reached the user as "no
            // SteamCMD found in the usual places". The reason is the whole
            // difference between a dead end and a next step.
            lastAutoDetectDiagnosis = diagnosis
            // The diagnosis needs no extra receipt field: `canonicalPath` with a
            // non-nil `launch` already names the binary the connector ran.
            if diagnosis.launch != nil, let executed = diagnosis.canonicalPath {
                noteExecutionReceipt(executed)
            }
            // A reached verdict is the answer, either way. Falling through to
            // the old locate/bind on a negative one would bind a path we just
            // proved cannot launch and report success for having stored it.
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

    /// Auto-detects the binary and validates any previously authorized official
    /// Steam profile. A fresh sandbox install requires an explicit folder pick.
    func autoConfigureIfNeeded() async {
        if !hasBoundBinary {
            await autoDetectBinary()
        } else if case .notRun? = probes[.binaryIdentity]?.status {
            // The binding survives relaunch; the probe result does not. Without
            // this, an already-configured SteamCMD spends the whole session
            // "unverified" and never earns its green.
            await runProbe(.binaryIdentity)
        }
        await autoConfigureWorkdirIfNeeded()
    }

    /// Re-run cached-login probe on Workshop appear (read-only; never prompts password).
    func autoConfirmDownloadReadinessIfNeeded() async {
        await autoConfigureIfNeeded()
        guard hasBoundBinary,
              workdirBookmarkData != nil,
              username.map(SteamCMDScriptWriter.validateUsername) ?? false,
              !isGreen(.cachedLogin)
        else { return }
        if case .running? = probes[.cachedLogin]?.status { return }
        await runProbe(.cachedLogin)
    }

    /// Drop retired container/custom-workdir Steam library grants (files untouched).
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
        // Forget container-local Steam binds that look valid via their own config.vdf.
        guard !WPEEngineAssetsLibrary.isContainerInternal(resolved.url) else {
            forgetWorkdirBinding(reason: "binding pointed inside the app container, not the shared Steam profile")
            return
        }
        let config = resolved.url
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("config.vdf", isDirectory: false)
        guard fileManager.fileExists(atPath: config.path(percentEncoded: false)) else {
            forgetWorkdirBinding(reason: "retired non-Steam Workshop repository binding")
            return
        }
    }

    /// Drop Steam-library grant only (never deletes library files).
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
              fileManager.fileExists(atPath: configURL.path(percentEncoded: false))
        else {
            throw SteamCMDDoctorError.steamLibraryMissingConfig(configURL)
        }
        // Reject container Steam/config.vdf as if it were the shared profile.
        guard !WPEEngineAssetsLibrary.isContainerInternal(canonicalURL) else {
            throw SteamCMDDoctorError.steamLibraryInsideContainer(canonicalURL)
        }

        let bookmark = try Self.makeBookmark(for: canonicalURL, readOnly: false)
        workdirBookmarkData = bookmark
        workdirDisplayPath = canonicalURL.path(percentEncoded: false)
        workdirResolutionFailed = false
        // The Steam profile holds cached login and Workshop content, so changing
        // it invalidates the account-dependent probe.
        setProbe(.cachedLogin, status: .notRun)
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
            setProbe(.cachedLogin, status: .notRun)
        }
    }

    // MARK: - Probes

    nonisolated static let binaryProbeKinds: [DoctorProbeKind] =
        [.binaryIdentity, .codeSignature, .gatekeeperQuarantine]

    private static func identityVerifiedDetail() -> String {
        String(localized: "SteamCMD identity verified.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
    }

    private static func verifiedValveBuildDetail(isHardenedRuntime: Bool) -> String {
        isHardenedRuntime
            ? String(localized: "Verified Valve build (TeamIdentifier=MXGJJ98X76, Hardened Runtime).", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
            : String(localized: "Verified Valve build (TeamIdentifier=MXGJJ98X76).", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
    }

    private static func gatekeeperClearDetail() -> String {
        String(localized: "SteamCMD launches without Gatekeeper interference.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
    }

    /// Whether a launch may restore the stored green instead of re-running the
    /// three binary probes.
    ///
    /// Deliberately not time-based: all three are a function of the bytes on
    /// disk and their signature, so an unchanged fingerprint is an unchanged
    /// verdict, and a TTL would only burn a SteamCMD launch on a schedule.
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

    /// Launch path.
    ///
    /// A relaunch on the same SteamCMD costs one inspection here, against the
    /// four inspections (eight `codesign` spawns) and two SteamCMD launches that
    /// `autoConfigureIfNeeded()` + `runAll()` cost between them: the three
    /// binary probes are restored from the fingerprint the last passing run
    /// recorded, and re-run only when the bytes, signature or quarantine state
    /// no longer match it.
    ///
    /// `cachedLogin` is deliberately absent. A Steam session expires
    /// server-side while the app is closed, so a launch-time verdict is already
    /// stale by the time the user reaches for a download;
    /// `autoConfirmDownloadReadinessIfNeeded()` runs it when the Workshop pane
    /// appears.
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
        // The digest, signature and team id were just confirmed against the
        // fingerprint, so an in-session probe need not re-spawn codesign.
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
                    message: String(localized: "SteamCMD isn't a verified Valve build, so it wasn't run. Re-select the official SteamCMD.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
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
                        message: String(localized: "SteamCMD isn't a verified Valve build, so it wasn't run. Re-select the official SteamCMD.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
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
                    message: redacted(String(localized: "SteamCMD identity probe timed out after \(Int(Self.probeLaunchTimeout)) seconds.", comment: "SteamCMD diagnostic (Doctor) probe label or result message; %lld is the timeout in seconds.")),
                    command: redacted(command(binary: binary, args: ["+quit"]))
                ))
                return
            }
            guard Self.matches(Self.identityBannerPattern, in: result.stdout) else {
                setProbe(.binaryIdentity, status: .red(
                    message: retriedAfterSelfUpdate
                        ? String(localized: "SteamCMD is still updating itself and hasn't printed the Valve identity banner yet. Wait for the update to finish, then run this probe again.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
                        : String(localized: "SteamCMD did not print the expected Valve identity banner. Use Export diagnostics for the raw output.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: redacted(command(binary: binary, args: ["+quit"]))
                ))
                return
            }

            var detail = Self.identityVerifiedDetail()
            let rehashPath = binary.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            if let currentSHA = await inspect(path: rehashPath)?.sha256 {
                if let previous = lastBinarySHA256, previous != currentSHA {
                    detail = String(localized: "SteamCMD updated itself (SHA-256 changed) — that's normal.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
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
            // Distinguish unreachable/busy connector from a missing SteamCMD file.
            guard let result, result.unavailableReason == nil else {
                setProbe(.codeSignature, status: .yellow(
                    message: result?.unavailableReason == nil
                        ? String(localized: "Loomscreen's Steam connector did not respond, so the signature wasn't checked.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
                        : String(localized: "Loomscreen's Steam connector was busy, so the signature wasn't checked. Try again.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: nil
                ))
                return
            }
            guard result.exists else {
                setProbe(.codeSignature, status: .red(
                    message: String(localized: "SteamCMD is no longer where Loomscreen found it. Run Locate automatically again.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
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
                    ? String(localized: "SteamCMD is signed by an unverified team (TeamIdentifier=\(team)).", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
                    : String(localized: "SteamCMD signature is missing or could not be verified.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")
                setProbe(.codeSignature, status: .yellow(
                    message: redacted(String(localized: "Unverified build. \(reason)", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")),
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
                    message: String(localized: "Loomscreen's Steam connector didn't answer, so the quarantine attribute wasn't checked. Try again.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
                    command: nil
                ))
                return
            }
            if quarantineCheck.isQuarantined {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: redacted(String(localized: "SteamCMD has the Gatekeeper quarantine attribute. macOS may block it on launch.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")),
                    command: redacted(xattrCommand(for: binary))
                ))
                return
            }

            // Identity already launched SteamCMD → skip heavier anonymous login probe.
            if isGreen(.binaryIdentity) {
                setProbe(.gatekeeperQuarantine, status: .green(detail: Self.gatekeeperClearDetail()))
                return
            }

            guard let executionAuthorization = await trustedExecutionAuthorization(for: binary) else {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: String(localized: "SteamCMD isn't a verified Valve build, so it wasn't run.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
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
                    message: String(localized: "SteamCMD failed the launch sanity check. If macOS blocked it, clear the quarantine attribute.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."),
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
                    message: redacted(String(localized: "Steam Library folder is missing.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")),
                    command: nil
                ))
                return
            }
            // Read-only library probe (old write probe left litter on green).
            let config = workdir
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("config.vdf", isDirectory: false)
            guard fileManager.isReadableFile(atPath: config.path(percentEncoded: false)) else {
                setProbe(.workingDirectory, status: .red(
                    message: redacted(String(localized: "Steam Library is not readable.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")),
                    command: nil
                ))
                return
            }
            setProbe(.workingDirectory, status: .green(detail: redacted(String(localized: "Steam Library is readable.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."))))
        } catch {
            setProbe(.workingDirectory, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    /// Cached-login check via connector (app STEAMROOT ≠ shared Terminal profile).
    private func runCachedLoginProbe() async {
        guard let username, SteamCMDScriptWriter.validateUsername(username) else {
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Choose which Steam account to use before checking the connection.",
                    comment: "Steam sign-in diagnostic when no account has been selected yet."
                ),
                command: nil
            ))
            return
        }
        guard let binary = try? resolveBinaryURL() else {
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Select SteamCMD before checking the connection.",
                    comment: "Steam sign-in diagnostic when no SteamCMD binary is bound."
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
                    comment: "Steam sign-in diagnostic when no SteamCMD binary is bound."
                ),
                command: nil
            ))
            return
        }

        let result = await SteamConnectorClient.probeCachedLogin(accountName: username)
        guard let result else {
            setProbe(.cachedLogin, status: .red(
                message: String(
                    localized: "Loomscreen's Steam connector did not respond.",
                    comment: "Steam sign-in diagnostic when the XPC connector could not be reached."
                ),
                command: nil
            ))
            return
        }
        applyCachedLoginOutcome(result, username: username, binary: binary)
    }

    /// Internal, not private, so tests can drive the receipt path without XPC.
    func applyCachedLoginOutcome(
        _ result: SteamCachedLoginResult,
        username: String,
        binary: URL
    ) {
        noteExecutionReceipt(result.executedBinaryPath)
        // Shared STEAMROOT: plain +login (do not re-pin home like container era).
        let signIn = command(binary: binary, args: ["+login", username])

        switch result.outcome {
        case .sessionValid:
            setProbe(.cachedLogin, status: .green(
                detail: redacted(String(
                    localized: "Signed in to Steam as \(username).",
                    comment: "Steam sign-in diagnostic detail; %@ is the Steam account name."
                ))
            ))
        case .noCachedSession:
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Sign in once in Terminal so Steam caches the session, then check again.",
                    comment: "Steam sign-in diagnostic when the shared profile has never signed in."
                ),
                command: signIn
            ))
        case .sessionExpired:
            setProbe(.cachedLogin, status: .yellow(
                message: String(
                    localized: "Your Steam session expired. Sign in again in Terminal, then check again.",
                    comment: "Steam sign-in diagnostic when the cached session is no longer valid."
                ),
                command: signIn
            ))
        case .timedOut:
            setProbe(.cachedLogin, status: .red(
                message: String(
                    localized: "The Steam sign-in check timed out.",
                    comment: "Steam sign-in diagnostic when SteamCMD did not finish in time."
                ),
                command: nil
            ))
        case .steamCMDUnavailable:
            setProbe(.cachedLogin, status: .red(
                message: String(
                    localized: "SteamCMD could not be launched. Re-select it in the setup list.",
                    comment: "Steam sign-in diagnostic when the bound SteamCMD binary could not run."
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
                    comment: "Steam sign-in diagnostic for unparsed SteamCMD output; %@ is the redacted output tail."
                ),
                command: nil
            ))
        }
    }

    // MARK: - Workshop download

    var isDownloadReady: Bool { downloadBlocker == nil }

    /// Download block reason, or nil if ready (`setupIncomplete` → open Doctor).
    enum DownloadBlocker: Equatable {
        case setupIncomplete

        var isFixableInDoctor: Bool { self == .setupIncomplete }
    }

    var downloadBlocker: DownloadBlocker? {
        // Only an actual red identity verdict blocks; `.notRun` stays allowed
        // because probe results are not persisted across launches.
        if case .red? = probes[.binaryIdentity]?.status { return .setupIncomplete }
        guard hasBoundBinary,
              workdirBookmarkData != nil,
              !workdirResolutionFailed,
              username.map(SteamCMDScriptWriter.validateUsername) ?? false,
              isGreen(.cachedLogin)
        else { return .setupIncomplete }
        return nil
    }

    var downloadBlockerMessage: String? {
        switch downloadBlocker {
        case .none:
            return nil
        case .setupIncomplete:
            return String(
                localized: "Finish connecting Steam before downloading.",
                comment: "Reason downloads are unavailable because setup is incomplete."
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
                    return .failed(reason: String(localized: "Workshop download owner was released.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."))
                }
                return await performDownloadWorkshopItem(
                    itemID,
                    onProgress: onProgress,
                    onContentReady: onContentReady
                )
            }
        } catch is CancellationError {
            return .failed(reason: String(localized: "Download cancelled.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."))
        } catch {
            return .failed(reason: redacted(error.localizedDescription))
        }
    }

    /// Download via connector (real $HOME → shared Steam repo, not container).
    private func performDownloadWorkshopItem<Imported: Sendable>(
        _ itemID: UInt64,
        onProgress: SteamCMDProgressHandler?,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        guard let username, SteamCMDScriptWriter.validateUsername(username) else {
            return .notConfigured(reason: String(localized: "Choose your Steam account in the Steam connection sheet first.", comment: "SteamCMD diagnostic (Doctor) probe label or result message."))
        }
        guard (try? resolveBinaryURL()) != nil else {
            return .notConfigured(reason: SteamCMDDoctorError.missingBinaryBinding.errorDescription ?? "No SteamCMD binary is selected.")
        }
        guard let steamRoot = try? resolveWorkdirURL() else {
            return .notConfigured(reason: SteamCMDDoctorError.missingWorkdirBinding.errorDescription ?? "No Steam Library is authorized.")
        }
        guard isGreen(.cachedLogin) else { return .loginRequired }
        // No digest on file means the binding never completed its identity
        // probe. The connector picks the binary now, so this is a readiness
        // check, not an authorization one.
        guard lastBinarySHA256 != nil else { return .untrustedBinary }

        let result = await SteamConnectorClient.downloadWorkshopItem(
            workshopID: String(itemID),
            accountName: username,
            onProgress: { update in
                guard let fraction = update.fraction else { return }
                onProgress?(fraction * 100, update.downloadedBytes, update.totalBytes)
            }
        )
        guard let result else {
            return .failed(reason: String(
                localized: "Loomscreen's Steam connector did not respond.",
                comment: "Steam sign-in diagnostic when the XPC connector could not be reached."
            ))
        }
        noteExecutionReceipt(result.executedBinaryPath)
        switch result.outcome {
        case .downloaded:
            guard let path = result.itemPath else { return .failed(reason: String(localized: "Download reported no folder.", comment: "SteamCMD diagnostic (Doctor) probe label or result message.")) }
            // The import reads the folder and mints its own per-project bookmark,
            // so the Steam-library scope has to stay open across the handoff.
            let scope = steamRoot.startAccessingSecurityScopedResource()
            defer { if scope { steamRoot.stopAccessingSecurityScopedResource() } }
            return .imported(await onContentReady(URL(fileURLWithPath: path, isDirectory: true)))
        case .loginRequired:
            noteOperationReportedLoginRequired()
            return .loginRequired
        case .notEntitled:
            return .notEntitled
        case .removedFromSteam:
            return .removedFromSteam
        case .timedOut:
            return .timedOut
        case .steamCMDUnavailable:
            return .notConfigured(reason: String(
                localized: "SteamCMD could not be launched. Re-select it in the setup list.",
                comment: "Steam sign-in diagnostic when the bound SteamCMD binary could not run."
            ))
        case .unrecognized:
            return .failed(reason: redacted(result.diagnosticTail))
        }
    }
    /// Enumerate workshop content folders while workdir scope is held. Lets the library ingest
    /// items SteamCMD wrote outside the in-app download button (a manual `steamcmd`
    /// run, a prior launch, a download whose import didn't record).
    func enumerateDownloadedItemFolders(_ body: @MainActor (URL) async -> Void) async {
        var seen = Set<String>()
        let inventory = workshopFileInventory

        // The bound official Steam profile is the only content tree. Hold its
        // security scope across import and per-project bookmark creation.
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
    /// Internal, not private: the assets installer receives receipts on its own
    /// payload and has no other way to hand them to the Doctor.
    func noteExecutionReceipt(_ path: String?) {
        guard let path else { return }
        lastExecutedBinaryPath = path
    }

    /// Last SHA-256 verified as an intact Valve build. Transient — re-verified
    /// each launch and whenever the SHA changes.
    @ObservationIgnored private var verifiedBinarySHA256: String?

    /// The most recent inspection that actually reached a verdict, so the
    /// fingerprint is recorded from the same facts the probes just judged.
    /// Cleared by a restore, which judged nothing.
    @ObservationIgnored private var lastInspection: SteamCMDBinaryInspection?

    /// Inspections already paid for during the current probe run, by canonical
    /// path.
    ///
    /// One inspection costs a full-file SHA-256 plus two `codesign` children in
    /// the connector, serialized behind every other SteamCMD operation, and
    /// identity, signature and Gatekeeper all ask it about the same bytes.
    ///
    /// Valid only from a run's start until the next SteamCMD launch: SteamCMD
    /// rewrites its own executable, so `launchSteamCMD(_:args:)` drops it.
    @ObservationIgnored var runScopedInspections: [String: SteamCMDBinaryInspection] = [:]

    /// Opens a probe run: whatever the last one learned about the binary is no
    /// longer this run's evidence.
    func beginProbeRun() {
        runScopedInspections.removeAll()
    }

    /// The only place a Doctor probe launches SteamCMD, so the only place the
    /// run cache has to be dropped.
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

    /// Every inspection this service asks for goes through here, so no probe
    /// can record a verdict the fingerprint did not see.
    func inspect(path: String) async -> SteamCMDBinaryInspection? {
        if let reused = runScopedInspections[path] { return reused }
        let inspection = await SteamConnectorClient.inspectSteamCMDBinary(path: path)
        if let inspection, inspection.unavailableReason == nil, inspection.exists {
            lastInspection = inspection
            runScopedInspections[path] = inspection
        }
        return inspection
    }

    /// Download progress, as the Workshop UI consumes it.
    typealias SteamCMDProgressHandler = @Sendable (
        _ percent: Double, _ downloadedBytes: UInt64?, _ totalBytes: UInt64?
    ) -> Void

    /// What a Doctor probe came back with.
    ///
    /// `killed` now means "the connector never produced a verdict", not "we
    /// signalled a child".
    struct SteamCMDRunResult: Sendable {
        let exitCode: Int32?
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let killed: Bool
        /// Execution receipt forwarded from the connector's probe run.
        var executedBinaryPath: String? = nil
    }

    /// Proof that the Doctor evaluated the binary and found it trustworthy.
    ///
    /// A token, not an instruction: it no longer travels to the connector,
    /// which picks and runs its own binary. Holding one is what makes a probe
    /// body allowed to probe, and the fields are what the report renders.
    struct SteamCMDBinaryExecutionAuthorization: Equatable, Sendable {
        let canonicalPath: String
        let sha256: String
    }

    /// Runs a Doctor probe through the connector and reshapes the reply into the
    /// result type the probe bodies already read.
    ///
    /// The connector merges the child's stdout and stderr into one stream — they
    /// share a pipe there so interleaving stays faithful — so `stderr` is empty
    /// and callers that concatenate the two are unaffected. An unreachable
    /// connector, or a refusal because no binary resolved, both surface as
    /// `killed`: neither is a verdict about SteamCMD itself.
    ///
    /// The authorization is required but not forwarded — see its own doc.
    /// 120, not 30: a fresh SteamCMD bootstrap self-updates with up to two
    /// exit-42 restarts inside one probe (~9s measured on a fast network),
    /// and slow networks need the headroom before the probe is a verdict.
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

    /// Whether the Doctor considers the bound binary usable. Every read of the
    /// file happens in the connector, so the sandboxed bundle never needs access
    /// to `/opt/homebrew` and friends.
    ///
    /// This is a readiness verdict for the UI, not an execution authorization:
    /// what the connector runs is what the connector resolves. An app-side check
    /// could never have authorized a spawn anyway — the file can change between
    /// the check and the exec, and nothing on macOS binds the two.
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

    /// The trust rule, as a pure function of one inspection plus what we last
    /// verified.
    ///
    /// Pulled out of the flow above so both of its properties stay testable now
    /// that the inspection itself happens over XPC and can no longer be faked by
    /// injecting a checker: an unchanged SHA must skip re-verification (one
    /// "Run all" would otherwise re-spawn codesign per executing probe), and a
    /// changed SHA must be re-verified against Valve's team identifier before it
    /// is trusted again — a self-updating binary is normal, an attacker-signed
    /// replacement is not.
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
        // No verdict is not a negative verdict. Dropping the cached digest here
        // would make the next run re-spawn codesign for a binary nothing has
        // said anything bad about.
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
                // The shared resolver refreshes with read-only scope, but
                // workdir needs write access for SteamCMD scripts + downloads
                // — recreate the bookmark with write scope and persist.
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

    /// Keeps the launch fast path's ledger honest, in three rules.
    ///
    /// A binary probe that came back yellow or red retires the fingerprint.
    /// Three greens plus a fresh inspection record a new one. A restored green
    /// carries no fresh inspection, so it leaves the existing record — and the
    /// date it was actually earned — alone.
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

    /// A live operation (download / assets) got "login required" from Steam even
    /// though the cached-login probe was green: the session died after the probe
    /// ran. Demote the probe now so `isDownloadReady` stops saying yes and the
    /// user is not invited to retry a download that must fail.
    func noteOperationReportedLoginRequired() {
        // Prefer the receipt: the Terminal command should name the binary that
        // actually failed, not the one the UI happens to have bound.
        let binary = lastExecutedBinaryPath.map { URL(fileURLWithPath: $0) } ?? (try? resolveBinaryURL())
        let signIn = binary.flatMap { binary in
            username.map { command(binary: binary, args: ["+login", $0]) }
        }
        setProbe(.cachedLogin, status: .yellow(
            message: String(
                localized: "Your Steam session expired. Sign in again in Terminal, then check again.",
                comment: "Steam sign-in diagnostic when the cached session is no longer valid."
            ),
            command: signIn
        ))
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
        ([binary.path(percentEncoded: false)] + args).map(Self.shellEscaped).joined(separator: " ")
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
