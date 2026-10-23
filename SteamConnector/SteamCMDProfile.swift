import Foundation

/// One monotonic budget shared by a SteamCMD run and its replacement trust checks.
struct SteamCMDRunDeadline {
    let time: DispatchTime

    init(timeout: TimeInterval, start: DispatchTime = .now()) {
        time = start + timeout
    }

    func remaining(at now: DispatchTime = .now()) -> TimeInterval {
        guard now.uptimeNanoseconds < time.uptimeNanoseconds else { return 0 }
        return Double(time.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
    }
}

enum SteamCMDSelfUpdateRestartPolicy {
    static let restartExitCode: Int32 = 42
    /// A measured fresh install asks twice (42, 42, 0 — 2026-08-28); three
    /// would fit exactly with no spare. Valve decides how many times its
    /// bootstrap asks — one more would misread as "First SteamCMD run
    /// exited 42" (broken) rather than a declined restart. Four keeps one
    /// spare; still asking after that is broken, not slow.
    static let maxExecutions = 4

    enum Outcome<Run> {
        /// The last run, whatever its exit status — the caller judges it.
        case completed(Run)
        /// The rewritten binary failed a trust gate; it was not relaunched.
        case gateFailed(String)
        /// No new child may start after this run's budget; retain the last diagnostic.
        case deadlineExceeded(Run?)
        case cancelled
    }

    static func run<Run>(
        deadline: SteamCMDRunDeadline,
        now: () -> DispatchTime = { .now() },
        isCancelled: () -> Bool = { false },
        execute: () -> Run,
        exitCode: (Run) -> Int32,
        timedOut: (Run) -> Bool,
        revalidate: () -> String?
    ) -> Outcome<Run> {
        guard !isCancelled() else { return .cancelled }
        guard deadline.remaining(at: now()) > 0 else { return .deadlineExceeded(nil) }
        var run = execute()
        var executions = 1
        // A timed-out run was killed by us; whatever status the kill produced
        // is not SteamCMD asking to be relaunched.
        while executions < maxExecutions,
              !timedOut(run),
              exitCode(run) == restartExitCode {
            guard !isCancelled() else { return .cancelled }
            guard deadline.remaining(at: now()) > 0 else { return .deadlineExceeded(run) }
            let reason = revalidate()
            guard !isCancelled() else { return .cancelled }
            // A timed-out signature helper must not turn budget exhaustion into
            // a false "untrusted replacement" diagnosis.
            guard deadline.remaining(at: now()) > 0 else { return .deadlineExceeded(run) }
            if let reason {
                return .gateFailed(reason)
            }
            run = execute()
            executions += 1
        }
        return isCancelled() ? .cancelled : .completed(run)
    }
}

/// Persistent login state, independent of the executable's installation source
/// and of the content library. Paths are chosen by the connector, never by XPC.
enum SteamCMDProfile {
    enum ProfileError: Error { case invalidAccount, unsafeDirectory, busy }

    /// A sibling of the managed executable, so reinstalling SteamCMD cannot
    /// delete authentication. Homebrew and managed binaries use the SAME home.
    static func root(realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) -> URL {
        URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Loomscreen/SteamCMDProfiles/v1", isDirectory: true)
    }

    static func home(accountName: String?, realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) throws -> URL {
        guard let accountName, accountName.lowercased() != "anonymous" else {
            return root(realHome: realHome).appendingPathComponent("Maintenance", isDirectory: true)
        }
        guard SteamAccountsFile.isValidAccountName(accountName) else { throw ProfileError.invalidAccount }
        return root(realHome: realHome).appendingPathComponent("Accounts/\(accountName.lowercased())", isDirectory: true)
    }

    /// The one directory a session removal may delete. `anonymous` and the nil
    /// account share the Maintenance profile, which belongs to no user and must
    /// stay unreachable from this path.
    static func sessionDirectory(accountName: String, realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) throws -> URL {
        guard SteamAccountsFile.isValidAccountName(accountName),
              accountName.lowercased() != "anonymous" else { throw ProfileError.invalidAccount }
        let directory = try home(accountName: accountName, realHome: realHome).standardizedFileURL
        let accounts = root(realHome: realHome)
            .appendingPathComponent("Accounts", isDirectory: true).standardizedFileURL
        guard directory.pathComponents.count == accounts.pathComponents.count + 1,
              Array(directory.pathComponents.dropLast()) == accounts.pathComponents else {
            throw ProfileError.unsafeDirectory
        }
        return directory
    }

    static func steamRoot(accountName: String?, realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) throws -> URL {
        try home(accountName: accountName, realHome: realHome)
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    /// The Workshop tree inside an account's profile. Nothing writes here any
    /// more — items download straight into the shared library — so this names
    /// what the old staging design left behind, for removal.
    static func stagedWorkshopTree(accountName: String, realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) throws -> URL {
        try sessionDirectory(accountName: accountName, realHome: realHome)
            .appendingPathComponent("Library/Application Support/Steam/steamapps/workshop", isDirectory: true)
    }

    /// A throwaway `force_install_dir` for the subscription probe, outside the
    /// shared library; the UUID leaf keeps concurrent probes apart.
    static func subscriptionProbeDirectory(accountName: String, id: UUID = UUID(), realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) throws -> URL {
        try sessionDirectory(accountName: accountName, realHome: realHome)
            .appendingPathComponent("SubscriptionProbe/\(id.uuidString)", isDirectory: true)
    }

    /// Writes `steamapps/appmanifest` through descriptors walked from the real home, never through a link.
    static func prepareSubscriptionProbe(accountName: String, id: UUID, realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) throws -> URL {
        let probe = try subscriptionProbeDirectory(accountName: accountName, id: id, realHome: realHome)
        let relative = probe.pathComponents.dropFirst(URL(fileURLWithPath: realHome).pathComponents.count)
        let steamapps = try openPrivateDirectory(Array(relative) + ["steamapps"], realHome: realHome)
        defer { close(steamapps) }
        let name = "appmanifest_\(SteamLibraryPaths.wallpaperEngineAppID).acf"
        let file = openat(steamapps, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw ProfileError.unsafeDirectory }
        defer { close(file) }
        let bytes = Array(SteamWorkshopManifest.probeAppManifest.utf8)
        guard bytes.withUnsafeBytes({ write(file, $0.baseAddress, $0.count) }) == bytes.count else {
            throw ProfileError.unsafeDirectory
        }
        return probe
    }

    static func prepareDownloadWorker(id: UUID, realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) throws -> URL {
        let directory = root(realHome: realHome).appendingPathComponent("DownloadWorkers/\(id.uuidString)", isDirectory: true)
        let relative = directory.pathComponents.dropFirst(URL(fileURLWithPath: realHome).pathComponents.count)
        let fd = try openPrivateDirectory(Array(relative), realHome: realHome)
        close(fd)
        return directory
    }

    static func subscriptionsFile(accountName: String, accountID: UInt32, realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) throws -> URL {
        try steamRoot(accountName: accountName, realHome: realHome).appendingPathComponent(
            "userdata/\(accountID)/ugc/\(SteamLibraryPaths.wallpaperEngineAppID)_subscriptions.vdf",
            isDirectory: false
        )
    }

    static func account(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "+login"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Creates private directories without following symlinks; a per-profile
    /// advisory lock also covers separate XPC service instances. Caller closes fd.
    static func acquire(accountName: String?, realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) throws -> (home: URL, fd: Int32) {
        let profile = try home(accountName: accountName, realHome: realHome)
        let relative = profile.pathComponents.dropFirst(URL(fileURLWithPath: realHome).pathComponents.count)
        let fd = try openPrivateDirectory(Array(relative) + ["Library", "Application Support", "Steam", "config"], realHome: realHome)
        defer { close(fd) }
        let lock = openat(fd, ".loomscreen.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw ProfileError.unsafeDirectory }
        var info = stat()
        guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            close(lock)
            throw ProfileError.unsafeDirectory
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw ProfileError.busy
        }
        return (profile, lock)
    }

    /// Walks `components` below the resolved real home, creating missing levels 0700 and refusing links. Caller closes fd.
    private static func openPrivateDirectory(_ components: [String], realHome: String) throws -> Int32 {
        let anchor = URL(fileURLWithPath: realHome).resolvingSymlinksInPath()
        var fd = open(anchor.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ProfileError.unsafeDirectory }
        for component in components {
            let next = mkdirat(fd, component, 0o700) != 0 && errno != EEXIST
                ? -1 : openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd)
            guard next >= 0 else { throw ProfileError.unsafeDirectory }
            fd = next
        }
        return fd
    }

    /// Merge public identity hints only. Never copy Steam client credentials.
    static func accounts(realHome: String = SteamConnectorEnvironmentProbe.posixHomeDirectory()) -> [SteamAccountSummary] {
        let accountsRoot = root(realHome: realHome).appendingPathComponent("Accounts")
        let children = (try? FileManager.default.contentsOfDirectory(at: accountsRoot, includingPropertiesForKeys: nil)) ?? []
        let configs = children.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { child -> URL? in
            guard SteamAccountsFile.isValidAccountName(child.lastPathComponent),
                  SteamCMDManagedInstaller.firstSymlinkComponent(of: child) == nil else { return nil }
            let config = child.appendingPathComponent("Library/Application Support/Steam/config/config.vdf")
            return SteamCMDManagedInstaller.firstSymlinkComponent(of: config) == nil ? config : nil
        } + [SteamConnectorEnvironmentProbe.steamConfigURL(realHome: realHome)]
        var seen: Set<String> = []
        return configs.flatMap { config in
            SteamAccountsFile.parseAccounts(fromConfigVDF: (try? String(contentsOf: config, encoding: .utf8)) ?? "")
        }.filter { seen.insert($0.accountName.lowercased()).inserted }
    }
}

/// Scrubbed environment; SteamCMD runners explicitly supply an isolated home.
enum SteamCMDChildEnvironment {
    /// Everything the child is allowed to see. Anything absent is dropped.
    static func make(
        home: String = SteamConnectorEnvironmentProbe.posixHomeDirectory(),
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> [String: String] {
        [
            // Only non-Steam utilities use the default. Both SteamCMD runners
            // pass the same account profile regardless of binary provenance.
            "HOME": home,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporaryDirectory,
            // Pinned to match the app runner. The progress parser reads
            // `progress: 42.34` positionally and stops at the first non-digit, so
            // a comma-decimal rendering would truncate to 42% rather than fail —
            // a silent wrong number, which is the kind worth pinning against.
            "LANG": "en_US.UTF-8",
        ]
    }
}
