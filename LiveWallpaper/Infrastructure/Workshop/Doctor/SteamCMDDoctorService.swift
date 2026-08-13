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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .binaryIdentity: return "SteamCMD binary identity"
        case .codeSignature: return "Code signature"
        case .gatekeeperQuarantine: return "Gatekeeper / quarantine"
        case .workingDirectory: return "Steam Library access"
        case .cachedLogin: return "Steam sign-in"
        }
    }

    /// Advisory failures remain visible without blocking Workshop operations.
    var isAdvisory: Bool {
        switch self {
        case .codeSignature: return true
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
        static let binaryPath = "loomscreen.workshop.doctor.binaryPath"
        static let workdirBookmark = "loomscreen.workshop.doctor.workdirBookmark"
        static let binarySHA256 = "loomscreen.workshop.doctor.binarySHA256"
        static let username = "loomscreen.workshop.doctor.username"
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

    /// Bound SteamCMD path (not a capability; connector enforces Valve signature).
    var binaryPath: String? {
        get { defaults.string(forKey: Keys.binaryPath) }
        set {
            setOptional(newValue, forKey: Keys.binaryPath)
            refreshDisplayPaths()
        }
    }

    /// True once a binary path is bound.
    var hasBoundBinary: Bool { binaryPath != nil }

    var workdirBookmarkData: Data? {
        get { defaults.data(forKey: Keys.workdirBookmark) }
        set {
            setOptional(newValue, forKey: Keys.workdirBookmark)
            refreshDisplayPaths()
        }
    }

    var lastBinarySHA256: String? {
        get { defaults.string(forKey: Keys.binarySHA256) }
        set { setOptional(newValue, forKey: Keys.binarySHA256) }
    }

    var username: String? {
        get { defaults.string(forKey: Keys.username) }
        set {
            setOptional(newValue, forKey: Keys.username)
            _ = state  // re-trigger observation chain
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
        refreshDisplayPaths()
    }

    // MARK: - Binding

    /// Bind user pick; connector resolves/hashes wrappers (store path, not bookmark).
    func bindBinary(_ userPickedURL: URL) async throws {
        let pickedAccess = userPickedURL.startAccessingSecurityScopedResource()
        defer { if pickedAccess { userPickedURL.stopAccessingSecurityScopedResource() } }

        let picked = userPickedURL.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        guard let located = await SteamConnectorClient.locateSteamCMDBinary(pickedPath: picked),
              let path = located.canonicalPath else {
            throw SteamCMDDoctorError.binaryResolution(.notMachO)
        }
        let inspection = await SteamConnectorClient.inspectSteamCMDBinary(path: path)
        if let reason = inspection?.unavailableReason {
            // Busy is not "bad binary": refusing the bind with a resolution error
            // would tell the user to pick a different file for no reason.
            throw SteamCMDDoctorError.bookmarkResolution(reason)
        }
        guard let inspection, inspection.exists, let sha256 = inspection.sha256 else {
            throw SteamCMDDoctorError.binaryResolution(.notExecutable)
        }
        binaryPath = path
        lastBinarySHA256 = sha256
        verifiedBinarySHA256 = nil
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

    /// Auto-bind from /opt/homebrew|/usr/local|/opt/local only (no login-shell PATH).
    @discardableResult
    func autoDetectBinary() async -> Bool {
        guard let located = await SteamConnectorClient.locateSteamCMDBinary(pickedPath: nil),
              let path = located.canonicalPath else { return false }
        do {
            try await bindBinary(URL(fileURLWithPath: path))
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
        ) else { return }
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

    func runAll() async {
        state = .probing
        for kind in DoctorProbeKind.allCases {
            await performProbe(kind)
        }
        finishProbeRun()
    }

    func runProbe(_ kind: DoctorProbeKind) async {
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
        }
    }

    private func runBinaryIdentityProbe() async {
        do {
            let binary = try resolveBinaryURL()
            let didStart = binary.startAccessingSecurityScopedResource()
            defer { if didStart { binary.stopAccessingSecurityScopedResource() } }
            guard var executionAuthorization = await trustedExecutionAuthorization(for: binary) else {
                setProbe(.binaryIdentity, status: .red(
                    message: "SteamCMD isn't a verified Valve build, so it wasn't run. Re-select the official SteamCMD.",
                    command: nil
                ))
                return
            }

            var result = await Self.probe(executionAuthorization, args: ["+quit"])
            var retriedAfterSelfUpdate = false
            if !result.timedOut,
               !Self.matches(Self.identityBannerPattern, in: result.stdout),
               Self.matches(Self.selfUpdatePattern, in: result.stdout) {
                // That run may have replaced the binary on disk, so re-establish
                // trust before launching whatever is there now.
                guard let refreshedAuthorization = await trustedExecutionAuthorization(for: binary) else {
                    setProbe(.binaryIdentity, status: .red(
                        message: "SteamCMD isn't a verified Valve build, so it wasn't run. Re-select the official SteamCMD.",
                        command: nil
                    ))
                    return
                }
                executionAuthorization = refreshedAuthorization
                retriedAfterSelfUpdate = true
                result = await Self.probe(executionAuthorization, args: ["+quit"])
            }
            if result.timedOut {
                setProbe(.binaryIdentity, status: .red(
                    message: redacted("SteamCMD identity probe timed out after 30 seconds."),
                    command: redacted(command(binary: binary, args: ["+quit"]))
                ))
                return
            }
            guard Self.matches(Self.identityBannerPattern, in: result.stdout) else {
                setProbe(.binaryIdentity, status: .red(
                    message: retriedAfterSelfUpdate
                        ? "SteamCMD is still updating itself and hasn't printed the Valve identity banner yet. Wait for the update to finish, then run this probe again."
                        : "SteamCMD did not print the expected Valve identity banner. Use Export diagnostics for the raw output.",
                    command: redacted(command(binary: binary, args: ["+quit"]))
                ))
                return
            }

            var detail = "SteamCMD identity verified."
            let rehashPath = binary.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            if let currentSHA = await SteamConnectorClient.inspectSteamCMDBinary(path: rehashPath)?.sha256 {
                if let previous = lastBinarySHA256, previous != currentSHA {
                    detail = "SteamCMD updated itself (SHA-256 changed) — that's normal."
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
            let result = await SteamConnectorClient.inspectSteamCMDBinary(path: path)
            // Distinguish unreachable/busy connector from a missing SteamCMD file.
            guard let result, result.unavailableReason == nil else {
                setProbe(.codeSignature, status: .yellow(
                    message: result?.unavailableReason == nil
                        ? "Loomscreen's Steam connector did not respond, so the signature wasn't checked."
                        : "Loomscreen's Steam connector was busy, so the signature wasn't checked. Try again.",
                    command: nil
                ))
                return
            }
            guard result.exists else {
                setProbe(.codeSignature, status: .red(
                    message: "SteamCMD is no longer at the selected path. Re-select it.",
                    command: nil
                ))
                return
            }
            if result.signatureValid, result.teamIdentifier == Self.valveTeamIdentifier {
                let detail = result.isHardenedRuntime
                    ? "Verified Valve build (TeamIdentifier=MXGJJ98X76, Hardened Runtime)."
                    : "Verified Valve build (TeamIdentifier=MXGJJ98X76)."
                setProbe(.codeSignature, status: .green(detail: redacted(detail)))
            } else {
                let team = result.teamIdentifier ?? "none"
                let reason = result.signatureValid
                    ? "SteamCMD is signed by an unverified team (TeamIdentifier=\(team))."
                    : "SteamCMD signature is missing or could not be verified."
                setProbe(.codeSignature, status: .yellow(
                    message: redacted("Unverified build. \(reason)"),
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
            let quarantineCheck = await SteamConnectorClient.inspectSteamCMDBinary(path: path)
            // Unavailable replies default isQuarantined=false — don't treat as clean.
            guard let quarantineCheck, quarantineCheck.unavailableReason == nil else {
                setProbe(.gatekeeperQuarantine, status: .yellow(
                    message: "Loomscreen's Steam connector didn't answer, so the quarantine attribute wasn't checked. Try again.",
                    command: nil
                ))
                return
            }
            if quarantineCheck.isQuarantined {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: redacted("SteamCMD has the Gatekeeper quarantine attribute. macOS may block it on launch."),
                    command: redacted(xattrCommand(for: binary))
                ))
                return
            }

            // Identity already launched SteamCMD → skip heavier anonymous login probe.
            if isGreen(.binaryIdentity) {
                setProbe(.gatekeeperQuarantine, status: .green(detail: "SteamCMD launches without Gatekeeper interference."))
                return
            }

            guard let executionAuthorization = await trustedExecutionAuthorization(for: binary) else {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: "SteamCMD isn't a verified Valve build, so it wasn't run.",
                    command: nil
                ))
                return
            }
            let result = await Self.probe(executionAuthorization, args: ["+login", "anonymous", "+quit"])
            let combined = "\(result.stdout)\n\(result.stderr)"
            if !result.timedOut,
               !result.killed,
               combined.contains("Steam Console Client") || result.exitCode == 0 {
                setProbe(.gatekeeperQuarantine, status: .green(detail: "SteamCMD launches without Gatekeeper interference."))
            } else {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: "SteamCMD failed the launch sanity check. If macOS blocked it, clear the quarantine attribute.",
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
                    message: redacted("Steam Library folder is missing."),
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
                    message: redacted("Steam Library is not readable."),
                    command: nil
                ))
                return
            }
            setProbe(.workingDirectory, status: .green(detail: redacted("Steam Library is readable.")))
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

        guard let expectedSHA256 = lastBinarySHA256 else {
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

        let result = await SteamConnectorClient.probeCachedLogin(
            accountName: username,
            steamCMDPath: binary.path(percentEncoded: false),
            expectedSHA256: expectedSHA256
        )
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

    private func applyCachedLoginOutcome(
        _ result: SteamCachedLoginResult,
        username: String,
        binary: URL
    ) {
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
        guard hasBoundBinary,
              workdirBookmarkData != nil,
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
                    return .failed(reason: "Workshop download owner was released.")
                }
                return await performDownloadWorkshopItem(
                    itemID,
                    onProgress: onProgress,
                    onContentReady: onContentReady
                )
            }
        } catch is CancellationError {
            return .failed(reason: "Download cancelled.")
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
            return .notConfigured(reason: "Choose your Steam account in the Steam connection sheet first.")
        }
        guard let binary = try? resolveBinaryURL() else {
            return .notConfigured(reason: SteamCMDDoctorError.missingBinaryBinding.errorDescription ?? "No SteamCMD binary is selected.")
        }
        guard let steamRoot = try? resolveWorkdirURL() else {
            return .notConfigured(reason: SteamCMDDoctorError.missingWorkdirBinding.errorDescription ?? "No Steam Library is authorized.")
        }
        guard isGreen(.cachedLogin) else { return .loginRequired }
        // No verified digest → refuse spawn (connector re-hashes expectedSHA256).
        guard let expectedSHA256 = lastBinarySHA256 else { return .untrustedBinary }

        let result = await SteamConnectorClient.downloadWorkshopItem(
            workshopID: String(itemID),
            accountName: username,
            steamCMDPath: binary.path(percentEncoded: false),
            expectedSHA256: expectedSHA256,
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
        switch result.outcome {
        case .downloaded:
            guard let path = result.itemPath else { return .failed(reason: "Download reported no folder.") }
            // The import reads the folder and mints its own per-project bookmark,
            // so the Steam-library scope has to stay open across the handoff.
            let scope = steamRoot.startAccessingSecurityScopedResource()
            defer { if scope { steamRoot.stopAccessingSecurityScopedResource() } }
            return .imported(await onContentReady(URL(fileURLWithPath: path, isDirectory: true)))
        case .loginRequired:
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

    /// Last SHA-256 verified as an intact Valve build. Transient — re-verified
    /// each launch and whenever the SHA changes.
    @ObservationIgnored private var verifiedBinarySHA256: String?

    /// Download progress, as the Workshop UI consumes it. Outlived the retired
    /// `SteamCMDProcessRunner`; the values now originate in the connector.
    typealias SteamCMDProgressHandler = @Sendable (
        _ percent: Double, _ downloadedBytes: UInt64?, _ totalBytes: UInt64?
    ) -> Void

    /// What a Doctor probe came back with.
    ///
    /// Outlived the retired `SteamCMDProcessRunner` because the probe bodies read
    /// these five fields; `killed` now means "the connector never produced a
    /// verdict", not "we signalled a child".
    struct SteamCMDRunResult: Sendable {
        let exitCode: Int32?
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let killed: Bool
    }

    /// A binary the app has decided to trust, plus the digest that decision was
    /// made against. The digest travels to the connector with every probe.
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
    /// connector, or a refusal because the binary changed under us, both surface
    /// as `killed`: neither is a verdict about SteamCMD itself.
    private static func probe(
        _ authorization: SteamCMDBinaryExecutionAuthorization,
        args: [String],
        timeout: TimeInterval = 30
    ) async -> SteamCMDRunResult {
        guard let run = await SteamConnectorClient.runSteamCMDProbe(
            path: authorization.canonicalPath,
            expectedSHA256: authorization.sha256,
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
            killed: false
        )
    }

    /// Trust decision stays here — it is the app that knows what the user
    /// authorized — but every read of the file happens in the connector, so the
    /// sandboxed bundle never needs access to `/opt/homebrew` and friends.
    ///
    /// The returned SHA travels with each probe: the connector re-hashes
    /// immediately before spawning, which is what closes the replace-while-queued
    /// window that a check here alone could not.
    private func trustedExecutionAuthorization(
        for binary: URL
    ) async -> SteamCMDBinaryExecutionAuthorization? {
        let didStart = binary.startAccessingSecurityScopedResource()
        defer { if didStart { binary.stopAccessingSecurityScopedResource() } }
        let path = binary.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let inspection = await SteamConnectorClient.inspectSteamCMDBinary(path: path),
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
            return url
        case .failure(let failure):
            throw SteamCMDDoctorError.bookmarkResolution(failure.localizedDescription)
        }
    }

    private func refreshDisplayPaths() {
        binaryDisplayPath = defaults.string(forKey: Keys.binaryPath)
        workdirDisplayPath = Self.displayPath(for: defaults.data(forKey: Keys.workdirBookmark))
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

    func setProbe(_ kind: DoctorProbeKind, status: DoctorProbeStatus) {
        probes[kind] = DoctorProbeReport(id: kind, status: status, lastRun: Date())
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
