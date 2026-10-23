import Foundation

/// The connector's argv gate for Doctor probes: only the exact directive
/// shapes Doctor sends are executable, `+quit` and `+login anonymous`.
/// Everything else — `+force_install_dir`, `+runscript`, a real account
/// name, any bare word — is refused at the connector, the side of the trust
/// boundary a compromised app process can't edit. Lives in the shared
/// contract so the app's tests exercise the exact rule the connector enforces.
enum SteamCMDProbeArgumentPolicy {
    static func isAllowed(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "+quit":
                index += 1
            case "+login":
                guard index + 1 < arguments.count, arguments[index + 1] == "anonymous" else {
                    return false
                }
                index += 2
            default:
                return false
            }
        }
        return true
    }
}

// MARK: - SteamCMD diagnosis

/// The run at the centre of the diagnosis.
enum SteamCMDDiagnosisProbe {
    /// The only argv the diagnosis ever spawns. `+quit` takes SteamCMD through
    /// its first-run self-update and exits, which is the cheapest run that still
    /// proves this machine can execute this binary.
    static let arguments = ["+quit"]

    static let defaultLaunchTimeout: TimeInterval = 180

    /// A caller-supplied budget of 0 would make every launch "time out" before
    /// the child got to run — the diagnosis reporting on nothing. Clamped rather
    /// than refused so a bad number degrades to a slow answer, not to no answer.
    static func clampedLaunchTimeout(_ requested: TimeInterval) -> TimeInterval {
        guard requested.isFinite else { return defaultLaunchTimeout }
        return min(max(requested, 30), 900)
    }
}

/// Where the binary under test came from.
enum SteamCMDBinarySource: String, Codable, Sendable {
    /// A location the user pointed at themselves. See `SteamCMDManualBinding`
    /// for what accepting one does and does not promise.
    case manual
    case managedInstall
    case homebrew
    case usrLocal
    case macPorts
    case notFound
}

/// A SteamCMD location the user pointed at, remembered on this side of the
/// XPC boundary — deliberately reopens a hole closed 2026-08-13 at the
/// user's 2026-08-14 direction (`autoDetectCandidates` only covers package
/// managers, so closing it left no recourse). Given up: a path isn't an
/// inode, so a file swapped between our checks and `posix_spawn` runs
/// unchecked (no `fexecve`). Kept: the record lives under the connector's
/// own root in the real home, write-once via XPC; it re-enters
/// `resolvedExecutablePath` and re-clears every gate — signature,
/// quarantine, execution fence — on **every** run; and it's a candidate, not
/// an override, going first with a fall-through on failure.
enum SteamCMDManualBinding {
    static func recordURL(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Loomscreen", isDirectory: true)
            .appendingPathComponent("manual-steamcmd-path", isDirectory: false)
            .standardizedFileURL
    }

    static func load(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL? {
        guard let raw = try? String(contentsOf: recordURL(home: home), encoding: .utf8) else {
            return nil
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Relative paths would resolve against this process's working directory,
        // which the app does not know and we do not control.
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func store(_ path: String, home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws {
        let record = recordURL(home: home)
        try FileManager.default.createDirectory(
            at: record.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(path.utf8).write(to: record, options: .atomic)
    }

    static func clear(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        try? FileManager.default.removeItem(at: recordURL(home: home))
    }
}

/// What the connector made of a path the user pointed at. Why a SteamCMD
/// operation failed, as a code the app renders — the helper can't localize
/// (`SteamConnector.xpc` ships no `.lproj`, so `Bundle.main` has no catalog
/// and `String(localized:)` would silently return English); the reason
/// crosses the wire as a code plus arguments and renders app-side, where the
/// catalog is. Raw values are wire format — renaming a case breaks old
/// payloads.
enum SteamCMDFailureCode: String, Codable, Sendable {
    // MARK: Manual bind

    case pathNotAbsolute
    case bindExpiredInQueue
    case notSteamCMDBinary
    case refusesOwnContainer
    case signatureNotValve
    case binaryQuarantined
    /// Argument 0: the underlying error description.
    case couldNotRecordChoice

    // MARK: Managed install

    case installExpiredInQueue
    case stagingDirectoryFailed
    case manifestFetchFailed
    case manifestUnexpectedShape
    case manifestMalformedPackageName
    /// Argument 0: package name.
    case packageDownloadFailed
    /// Argument 0: package name.
    case packageChecksumMismatch
    case firstRunTimedOut
    /// Argument 0: the exit code.
    case firstRunExitedNonZero
    case couldNotHashBinary
    case installRootMismatch
    /// Argument 0: the offending path component.
    case installPathSymlink
    /// Argument 0: the underlying error description.
    case installDirectoryCreateFailed
    case unpackTimedOut
    /// Argument 0: tar's exit code. Argument 1: the first 200 characters of its output.
    case tarExitedNonZero
    /// Argument 0: the escaping symlink's path.
    case archiveSymlinkEscape
    /// Argument 0: the underlying error description.
    case retirePreviousFailed
    /// Argument 0: the underlying error description.
    case moveIntoPlaceFailed
    case executableOutsideInstall
    case noExecutableInArchive
    case codeSignatureInvalid
    /// Argument 0: the team that signed it. Argument 1: the expected team.
    case signedByUnexpectedTeam
    case unpackedBinaryQuarantined
}

struct SteamCMDDiagnosisCandidate: Equatable, Sendable {
    let path: String
    let source: SteamCMDBinarySource
}

/// Resolution order, and the label each candidate carries into the report.
/// Every entry is derived, never supplied: the managed install under this
/// process's own root, then three fixed package-manager paths — the whole
/// executable surface, none of it writable by a sandboxed app without a
/// grant this app never asks for. Pure so the app's tests pin the same
/// order the connector walks.
enum SteamCMDDiagnosisPlan {
    /// `managedInstall` is a parameter (not a call to
    /// `SteamCMDManagedInstaller.managedBinary()`) so tests pin ordering
    /// without a real install; `discovered` defaults to a filesystem walk,
    /// but tests pass a fixed list so it doesn't depend on what's under
    /// `/opt/homebrew`. `manual` goes first — pointing at a file is a
    /// stronger statement than anything inferred — but it's only a
    /// position: every entry clears the same gates in `firstTrusted`, so a
    /// failing manual pick falls through rather than breaking downloads.
    static func candidates(
        managedInstall: URL?,
        manual: URL? = SteamCMDManualBinding.load(),
        discovered: [URL] = SteamCMDBinaryResolver.autoDetectCandidates()
    ) -> [SteamCMDDiagnosisCandidate] {
        var plan: [SteamCMDDiagnosisCandidate] = []
        if let manual {
            plan.append(SteamCMDDiagnosisCandidate(
                path: manual.path(percentEncoded: false), source: .manual
            ))
        }
        if let managed = managedInstall {
            plan.append(SteamCMDDiagnosisCandidate(
                path: managed.path(percentEncoded: false), source: .managedInstall
            ))
        }
        for url in discovered {
            let path = url.path(percentEncoded: false)
            plan.append(SteamCMDDiagnosisCandidate(
                path: path, source: packageManagerSource(forCandidatePath: path)
            ))
        }
        return plan
    }

    /// First candidate that survives every gate, skipping the ones that
    /// don't. Split out from the connector so the rule this encodes — **a
    /// rejected candidate must not end the search** — is testable without
    /// planting real Mach-Os on the test machine. Getting it wrong is how a
    /// stale, unsigned copy shadows a working one: the diagnosis skips it
    /// and binds the good binary, while execution stops at the bad one.
    static func firstTrusted(
        in candidates: [String],
        resolve: (String) -> String?,
        isTrusted: (String) -> Bool
    ) -> String? {
        for candidate in candidates {
            guard let resolved = resolve(candidate), !SteamCMDExecutionFence.refusesExecution(of: resolved), isTrusted(resolved) else { continue }
            return resolved
        }
        return nil
    }

    /// Matched on path components, not on absolute prefixes: the Caskroom and
    /// command-wrapper candidates carry a version directory in the middle, and
    /// a custom `HOMEBREW_PREFIX` moves the whole tree.
    static func packageManagerSource(forCandidatePath path: String) -> SteamCMDBinarySource {
        if path.contains("/Caskroom/") || path.contains("/.homebrew-command-wrappers/") {
            return .homebrew
        }
        switch path {
        case "/opt/homebrew/bin/steamcmd": return .homebrew
        case "/usr/local/bin/steamcmd": return .usrLocal
        case "/opt/local/bin/steamcmd": return .macPorts
        default: return .notFound
        }
    }
}

struct SteamCMDSignatureVerdict: Codable, Equatable, Sendable {
    /// `codesign --verify --strict` completed cleanly. Deliberately not
    /// `spctl`: for a bare CLI Mach-O it answers `rejected (the code is
    /// valid but does not seem to be an app)`, a refusal to assess rather
    /// than a verdict, so gating on its exit status rejects every good
    /// binary.
    let isValid: Bool
    let teamIdentifier: String?
    let isHardenedRuntime: Bool

    var isValveSigned: Bool {
        isValid && teamIdentifier == SteamCMDBootstrapPackage.expectedTeamIdentifier
    }
}

/// What happened when the connector actually ran the binary.
struct SteamCMDLaunchProbe: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case succeeded
        case timedOut
        case exitedNonZero
        /// `Process.run()` itself failed. The usual cause is a quarantined
        /// Mach-O, which cannot be spawned at all (measured 2026-08-13).
        case couldNotSpawn
    }

    let outcome: Outcome
    /// The argv that was spawned, recorded so a report cannot claim this run
    /// while having done something else — see `SteamCMDDiagnosis.isUsable`.
    let arguments: [String]
    let exitCode: Int32
    let timeout: TimeInterval
    let outputTail: String

    /// A timeout outranks the exit status: the connector kills the process
    /// group, and a child that dies to SIGTERM at the right moment can still
    /// report 0.
    static func classify(exitCode: Int32, timedOut: Bool) -> Outcome {
        if timedOut {
            return .timedOut
        }
        if exitCode == 0 {
            return .succeeded
        }
        // `spawn` reports a failed `Process.run()` as -1 without a timeout.
        return exitCode < 0 ? .couldNotSpawn : .exitedNonZero
    }
}

/// The one thing the user can do about each failure, in English.
enum SteamCMDDiagnosisRemedy {
    /// Candidate paths that exist on disk. Callable only where `/opt/homebrew`
    /// is readable — the connector — which is why the result travels on the
    /// diagnosis rather than being recomputed by the sandboxed app.
    static func existingCandidates(
        candidates: [URL] = SteamCMDBinaryResolver.autoDetectCandidates(),
        fileManager: FileManager = .default
    ) -> [String] {
        candidates
            .map { $0.path(percentEncoded: false) }
            .filter { fileManager.fileExists(atPath: $0) }
    }

    static func advice(for diagnosis: SteamCMDDiagnosis) -> String? {
        let unusableExisting = diagnosis.rejectedExistingPaths
        if let reason = diagnosis.unavailableReason {
            return "The Steam connector did not finish the check (\(reason)). Run it again."
        }
        guard let path = diagnosis.canonicalPath else {
            let detail = diagnosis.resolutionFailure.map { " (\($0))" } ?? ""
            // Preserve the existing-copy evidence, but send first installs and
            // recovery through the same managed-install entry point.
            if let found = unusableExisting.first {
                return """
                SteamCMD is installed at \(found), but Loomscreen could not use it\(detail). \
                Choose Set up SteamCMD in Workshop settings to let Loomscreen install its \
                own copy, or choose another existing steamcmd binary yourself.
                """
            }
            return """
            SteamCMD was not found on this Mac\(detail). Choose Set up SteamCMD in \
            Workshop settings to let Loomscreen install it, or choose an existing \
            steamcmd binary yourself.
            """
        }
        // A trust-gate refusal has no launch receipt. Explain the gate before
        // falling back to the missing-receipt message.
        if diagnosis.launch == nil || diagnosis.launch?.outcome == .couldNotSpawn {
            if diagnosis.signature?.isValveSigned != true {
                return """
                Loomscreen did not start SteamCMD at \(path) because its Valve signature \
                could not be verified. Choose Set up SteamCMD in Workshop settings to let \
                Loomscreen install its own copy.
                """
            }
            if diagnosis.isQuarantined {
                return """
                macOS quarantined \(path), and a quarantined command-line binary cannot be \
                launched at all. Clear it with `xattr -d com.apple.quarantine \(path)`, then \
                run the check again.
                """
            }
        }
        guard let launch = diagnosis.launch else {
            return "Loomscreen did not start SteamCMD at \(path) during this check. Run the check again; you do not need to launch SteamCMD manually first."
        }

        switch launch.outcome {
        case .couldNotSpawn:
            return """
            \(path) could not be launched: \(condensed(launch.outputTail)). Check that it is \
            executable with `chmod +x \(path)`.
            """
        case .timedOut:
            return """
            SteamCMD did not finish its first run within \(Int(launch.timeout)) seconds. It \
            self-updates on first launch, so this is usually a network problem — run \
            `\(path) +quit` in Terminal once and let it finish.
            """
        case .exitedNonZero:
            return """
            SteamCMD exited with status \(launch.exitCode): \(condensed(launch.outputTail)). \
            Running `\(path) +quit` in Terminal shows the full log.
            """
        case .succeeded:
            guard let signature = diagnosis.signature, !signature.isValveSigned else { return nil }
            return """
            SteamCMD runs, but \(path) is not signed by Valve (team \
            \(signature.teamIdentifier ?? "unknown")). Replace it with a copy from Valve, or \
            let Loomscreen install its own.
            """
        }
    }

    /// The tail is up to a megabyte and the remedy is one sentence in a label.
    private static func condensed(_ text: String) -> String {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count <= 200 ? flattened : "…" + String(flattened.suffix(200))
    }
}
