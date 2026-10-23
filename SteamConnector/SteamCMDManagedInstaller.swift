import Foundation

/// Valve's published SteamCMD bootstrap archive.
///
enum SteamCMDBootstrapPackage {
    /// Valve Corporation's Developer ID team. The extracted Mach-O must carry
    /// this or the managed install is refused.
    static let expectedTeamIdentifier = "MXGJJ98X76"

    /// SteamCMD writes into its own directory on every run (`logs/`, `package/`,
    /// cached host lists) and, on first launch, creates a `Frameworks` symlink
    /// one level *above* the executable. Keeping the payload one level down
    /// means that symlink lands in the install root instead of beside it.
    static let payloadSubdirectory = "MacOS"
}

/// Valve's own steamcmd update channel — the same manifest SteamCMD's
/// self-update reads. Installing from it directly removed the Rosetta
/// requirement (the historical `steamcmd_osx.tar.gz` bootstrapper is a frozen
/// 2020 Intel-only build; the manifest carries the current universal binary —
/// verified 2026-08-13: lipo x86_64+arm64, Valve team ID). Can't be
/// digest-pinned since it moves every release, so the trust chain is TLS to
/// Valve + per-package sha256 + the usual code-signature gate, which is the
/// authority on what runs; the hashes only confirm what was unpacked is what
/// Valve published.
enum SteamCMDManifest {
    static let url = URL(string: "https://media.steampowered.com/client/steam_cmd_osx")!

    /// What the consent sheet quotes. The real total is the sum of the manifest
    /// sizes and moves with releases; measured ~25 MB on 2026-08-13.
    static let approximateDownloadBytes = 25 * 1024 * 1024
    /// Rough on-disk size once SteamCMD has finished arranging itself.
    static let approximateInstalledBytes = 90 * 1024 * 1024

    /// Every package the manifest must supply. Mirrors what the bootstrapper
    /// downloads on first run; `steamcmd_osx` carries the executable itself.
    static let requiredPackages = [
        "steamcmd_public_all",
        "steamcmd_bins_osx",
        "steamcmd_breakpad_osx",
        "steamcmd_osx",
    ]

    struct Package: Equatable, Sendable {
        let name: String
        /// Plain-zip variant. The manifest also offers `.vz` (Valve LZMA)
        /// alongside; the plain zip needs no custom decompressor.
        let file: String
        let sha256: String
        let byteCount: Int
    }

    /// The filename becomes both a URL path component and a local path, so it
    /// gets the same shape rule as workshop ids: one flat component, nothing
    /// that can traverse.
    static func isSafePackageFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 200
            && !name.contains("..")
            && name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// Parses Valve's VDF-style manifest. All required packages must resolve or
    /// the whole parse fails — a partial install is not a smaller install, it
    /// is a broken one.
    static func parse(_ text: String) -> [Package]? {
        var packages: [Package] = []
        for name in requiredPackages {
            guard let nameRange = text.range(of: "\"\(name)\""), let open = text.range(of: "{", range: nameRange.upperBound ..< text.endIndex),
                  let close = text.range(of: "}", range: open.upperBound ..< text.endIndex) else {
                return nil
            }
            let block = text[open.upperBound ..< close.lowerBound]
            guard let file = firstQuoted(after: "file", in: block),
                  isSafePackageFileName(file),
                  let sha256 = firstQuoted(after: "sha2", in: block),
                  sha256.count == 64,
                  let sizeText = firstQuoted(after: "size", in: block),
                  let byteCount = Int(sizeText),
                  byteCount > 0
            else { return nil }
            packages.append(Package(
                name: name, file: file, sha256: sha256.lowercased(), byteCount: byteCount
            ))
        }
        return packages
    }

    private static func firstQuoted(after key: String, in block: Substring) -> String? {
        guard let match = block.range(
            of: "\"\(key)\"\\s*\"([^\"]+)\"",
            options: .regularExpression
        ) else { return nil }
        let quoted = block[match]
        // The capture is the second quoted run inside the match.
        let parts = quoted.split(separator: "\"")
        return parts.count >= 3 ? String(parts.last!) : nil
    }
}

/// SteamCMD signals "my self-update replaced the binary — relaunch me" by
/// exiting 42 (a fresh install does it twice before its first clean exit,
/// measured 2026-08-28; the rewritten binary must re-pass signature/
/// quarantine gates before each relaunch). One retry for a package download
/// that failed in transit: the managed install pulls four packages, ~25 MB
/// total, over a single `URLSession` download with no retry, so one dropped
/// connection failed the whole install ("Could not download …", re-running
/// as the only recourse). Scoped to the transport only: a digest disagreeing
/// with the manifest is `.tarballRejected` and is *not* retried — the bytes
/// arrived intact but weren't the published ones, an integrity signal, not a
/// transient one.
enum SteamCMDDownloadRetryPolicy {
    /// The original attempt plus one.
    static let maxAttempts = 2
    /// Long enough to outlast a link renegotiation, short enough that a real
    /// outage still fails the install promptly.
    static let retryDelay: TimeInterval = 2

    /// Runs `attempt` until it reports success or the budget is spent, waiting
    /// between tries. `wait` is injected so tests do not sleep.
    static func run(
        attempt: (Int) -> Bool,
        wait: (TimeInterval) -> Void
    ) -> Bool {
        for number in 1 ... maxAttempts {
            if attempt(number) {
                return true
            }
            if number < maxAttempts {
                wait(retryDelay)
            }
        }
        return false
    }
}

/// Unpacks and validates a managed SteamCMD install. Runs only in the
/// connector, which is unsandboxed, so every step assumes app-supplied
/// inputs are hostile: the app is the one process that can write into the
/// container these paths point at, so "the app already checked it" is not
/// a property this code may rely on.
enum SteamCMDManagedInstaller {
    /// The one directory a managed install may occupy. Derived here, not
    /// accepted from the caller: an unsandboxed service unpacking wherever
    /// it's told is an arbitrary-write primitive, and the caller has no
    /// info about a destination this process lacks. Deliberately *not* the
    /// app's container — writable by the sandboxed app, so every check
    /// would be check-then-use: the app could replace the leaf with a
    /// symlink after the `lstat` walk and before `removeItem`/`tar -C`
    /// runs, making this process recursively delete/rewrite whatever it
    /// points at. A path the app can't write is the only closed version of
    /// that window.
    static func canonicalInstallRoot(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Loomscreen", isDirectory: true)
            .appendingPathComponent("SteamCMD", isDirectory: true)
            .standardizedFileURL
    }

    /// Accepts the caller's install root only if it's byte-for-byte the one
    /// directory we would have chosen, and no path component is a symlink.
    /// Both halves matter: without the equality check, an unsandboxed
    /// service unpacks wherever the caller points it; without the symlink
    /// walk, a link planted at `…/Loomscreen/SteamCMD` sends the recursive
    /// delete and rewrite elsewhere (`standardizedFileURL` resolves `..`
    /// but never follows links).
    static func containedInstallRoot(
        _ path: String,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> Result<URL, SteamCMDManagedInstallResult> {
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let expected = canonicalInstallRoot(home: home)
        // Compare trailing-slash-normalised strings: a directory URL renders its
        // path with a trailing "/" and a caller-supplied string does not, so a
        // raw comparison rejects even the one path this is meant to accept.
        guard Self.normalisedPath(requested) == Self.normalisedPath(expected) else {
            return .failure(.failed(
                .extractionFailed,
                "Install root is not the managed SteamCMD directory",
                code: .installRootMismatch
            ))
        }
        if let offending = firstSymlinkComponent(of: expected) {
            return .failure(.failed(
                .extractionFailed,
                "Install path component is a symbolic link: \(offending)",
                code: .installPathSymlink, arguments: [offending]
            ))
        }
        return .success(expected)
    }

    static func normalisedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// `lstat`s every component so a link anywhere along the path is caught,
    /// not just a link at the leaf.
    static func firstSymlinkComponent(of url: URL) -> String? {
        var walked = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            walked.appendPathComponent(component)
            let path = walked.path(percentEncoded: false)
            // lstat, not attributesOfItem: ENOENT means "not created yet"
            // (fine, we will make it), but any other error means we could not
            // establish that this component is safe — which must read as unsafe,
            // not as absent.
            var info = stat()
            if lstat(path, &info) != 0 {
                if errno == ENOENT {
                    continue
                }
                return path
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                return path
            }
        }
        return nil
    }

    static func payloadDirectory(installRoot: URL) -> URL {
        installRoot.appendingPathComponent(
            SteamCMDBootstrapPackage.payloadSubdirectory, isDirectory: true
        )
    }

    /// The managed install's Mach-O, found under the root this process derives
    /// rather than one the caller names. The install root sits in the real home
    /// directory, which an unsandboxed service can see — so there is nothing the
    /// app needs to tell us, and taking its word would mean spawning whatever
    /// path its defaults happen to hold.
    static func managedBinary(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL? {
        let payload = payloadDirectory(installRoot: canonicalInstallRoot(home: home))
        guard case let .success(binary) = locateBinary(in: payload) else { return nil }
        return binary
    }

    /// Replaces any previous payload so a half-finished install can't be
    /// mistaken for a good one, then unpacks into `MacOS/`. Takes a list
    /// because the manifest ships one zip per package; they all unpack into
    /// the same staging tree, as SteamCMD's own updater arranges them —
    /// bsdtar detects the container format, so tarball and zip callers
    /// share this path.
    static func extract(
        archives: [URL],
        installRoot: URL,
        spawn: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool)
    ) -> Result<ExtractedInstall, SteamCMDManagedInstallResult> {
        let payload = payloadDirectory(installRoot: installRoot)

        // Unpack under an unpredictable name, then move into place:
        // extracting straight into the payload path let a symlink be
        // planted between the check and the write. A name nobody can
        // predict can't be pre-planted, and `mkdir` (no
        // `withIntermediateDirectories`) adopts nothing already there.
        let staging = installRoot.appendingPathComponent(
            ".unpack-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: installRoot, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: false
            )
        } catch {
            return .failure(.failed(
                .extractionFailed,
                "Could not create the install directory: \(error.localizedDescription)",
                code: .installDirectoryCreateFailed, arguments: [error.localizedDescription]
            ))
        }

        func discardStaging() {
            try? FileManager.default.removeItem(at: staging)
        }
        for archive in archives {
            let run = spawn(
                "/usr/bin/tar",
                [
                    "-xf", archive.path(percentEncoded: false),
                    "-C", staging.path(percentEncoded: false),
                ],
                300
            )
            guard !run.timedOut else {
                discardStaging()
                return .failure(.failed(.extractionFailed, "Unpacking timed out", code: .unpackTimedOut))
            }
            guard run.exitCode == 0 else {
                discardStaging()
                return .failure(.failed(
                    .extractionFailed,
                    "tar exited \(run.exitCode): \(run.output.prefix(200))",
                    code: .tarExitedNonZero,
                    arguments: ["\(run.exitCode)", String(run.output.prefix(200))]
                ))
            }
        }
        // Valve's manifest zips carry no unix permissions (measured 2026-08-13:
        // everything lands 0644), and `steamcmd.sh` checks `-x` without ever
        // chmodding — the bootstrapper used to set these bits. Without this the
        // freshly installed steamcmd cannot be spawned at all.
        for name in ["steamcmd", "steamcmd.sh"] {
            let executable = staging.appendingPathComponent(name, isDirectory: false)
            if FileManager.default.fileExists(atPath: executable.path(percentEncoded: false)) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o755))],
                    ofItemAtPath: executable.path(percentEncoded: false)
                )
            }
        }

        // bsdtar refuses `..` members and strips leading `/`, but it happily
        // creates a symlink pointing outside the destination. On its own that is
        // inert; combined with a later write through it, it is an escape. The
        // archive is digest-pinned, so this is belt-and-braces — but the digest
        // gate is exactly the kind of thing that gets relaxed later.
        if let escaping = firstEscapingSymlink(under: staging) {
            discardStaging()
            return .failure(.failed(
                .extractionFailed,
                "Archive contains a symbolic link escaping the install directory: \(escaping)",
                code: .archiveSymlinkEscape, arguments: [escaping]
            ))
        }

        // Swap into place. The audited tree is what becomes the payload; the
        // previous one is moved aside first so a failure never leaves a
        // half-replaced install behind.
        let retired = installRoot.appendingPathComponent(
            ".retired-\(UUID().uuidString)", isDirectory: true
        )
        let payloadPath = payload.path(percentEncoded: false)
        var hadPrevious = false
        if FileManager.default.fileExists(atPath: payloadPath) {
            do {
                try FileManager.default.moveItem(at: payload, to: retired)
                hadPrevious = true
            } catch {
                discardStaging()
                return .failure(.failed(
                    .extractionFailed,
                    "Could not retire the previous install: \(error.localizedDescription)",
                    code: .retirePreviousFailed, arguments: [error.localizedDescription]
                ))
            }
        }
        do {
            try FileManager.default.moveItem(at: staging, to: payload)
        } catch {
            if hadPrevious {
                try? FileManager.default.moveItem(at: retired, to: payload)
            }
            discardStaging()
            return .failure(.failed(
                .extractionFailed,
                "Could not move the unpacked install into place: \(error.localizedDescription)",
                code: .moveIntoPlaceFailed, arguments: [error.localizedDescription]
            ))
        }
        // The previous tree stays on disk. Everything that decides whether this
        // install is usable — the `+quit` self-update, and re-verifying the
        // binary it rewrites — runs in the caller, and deleting the old copy
        // here would leave a reinstall that fails those checks with nothing to
        // fall back to.
        return .success(ExtractedInstall(payload: payload, retired: hadPrevious ? retired : nil))
    }

    /// A freshly unpacked payload plus the install it displaced, if any.
    struct ExtractedInstall {
        let payload: URL
        /// Previous install, moved aside. `commit` deletes it; `rollBack`
        /// puts it back. Exactly one of the two must run.
        let retired: URL?
    }

    /// Accepts the new install and discards the old one.
    static func commit(_ install: ExtractedInstall) {
        guard let retired = install.retired else { return }
        try? FileManager.default.removeItem(at: retired)
    }

    /// What a rollback actually managed to do. Reported rather than swallowed:
    /// the canonical path holding a payload that just failed its checks, or the
    /// working copy stranded under a random `.retired-*` name, are both states
    /// the user has to be told about — silently they read as "nothing happened".
    enum RollbackOutcome: Equatable, Sendable {
        case restored
        /// Nothing was displaced; the failed payload is gone.
        case noPreviousInstall
        case recoveryFailed(retiredPath: String, reason: String)
    }

    /// Puts the previous install back after a post-extraction check failed.
    /// The new payload is cleared out first — it is the one that just proved
    /// itself unusable, and leaving it would win the next `locateBinary`.
    @discardableResult
    static func rollBack(_ install: ExtractedInstall) -> RollbackOutcome {
        guard let retired = install.retired else {
            try? FileManager.default.removeItem(at: install.payload)
            let installRoot = install.payload.deletingLastPathComponent()
            if let remaining = try? FileManager.default.contentsOfDirectory(
                at: installRoot,
                includingPropertiesForKeys: nil
            ), remaining.isEmpty {
                try? FileManager.default.removeItem(at: installRoot)
            }
            return .noPreviousInstall
        }
        let retiredPath = retired.path(percentEncoded: false)
        do {
            try FileManager.default.removeItem(at: install.payload)
        } catch {
            // Undeletable (file flags, ACL, I/O): moving it aside still frees
            // the canonical path, which is what the old copy needs back.
            let failed = install.payload.deletingLastPathComponent()
                .appendingPathComponent(".failed-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.moveItem(at: install.payload, to: failed)
            } catch {
                return .recoveryFailed(
                    retiredPath: retiredPath,
                    reason: "the new payload could not be cleared: \(error.localizedDescription)"
                )
            }
        }
        do {
            try FileManager.default.moveItem(at: retired, to: install.payload)
            return .restored
        } catch {
            return .recoveryFailed(
                retiredPath: retiredPath,
                reason: error.localizedDescription
            )
        }
    }

    /// Any symlink under `root` whose target resolves outside `root`.
    static func firstEscapingSymlink(under root: URL) -> String? {
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { return nil }
        for case let entry as URL in walker {
            guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
                continue
            }
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            if !isDescendant(resolved.pathComponents, of: rootComponents) {
                return entry.path(percentEncoded: false)
            }
        }
        return nil
    }

    static func isDescendant(_ components: [String], of root: [String]) -> Bool {
        components.count > root.count && Array(components.prefix(root.count)) == root
    }

    /// Locates the Mach-O inside a freshly unpacked payload, and refuses one
    /// that resolves outside it. The shared resolver honours `STEAMEXE=`
    /// from the wrapper script and resolves symlinks, both of which can
    /// name an absolute path elsewhere on disk — without this check a
    /// swapped archive could aim the signature check and the spawn at some
    /// other Valve-signed binary.
    static func locateBinary(in payload: URL) -> Result<URL, SteamCMDManagedInstallResult> {
        let payloadComponents = payload.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for candidate in ["steamcmd.sh", "steamcmd"] {
            let url = payload.appendingPathComponent(candidate, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                  case let .success(resolved) = SteamCMDBinaryResolver.resolveCanonicalBinary(at: url) else {
                continue
            }
            let resolvedComponents = resolved.resolvingSymlinksInPath()
                .standardizedFileURL.pathComponents
            guard isDescendant(resolvedComponents, of: payloadComponents) else {
                return .failure(.failed(
                    .binaryNotFound,
                    "Archive points its executable outside the install directory",
                    code: .executableOutsideInstall
                ))
            }
            return .success(resolved)
        }
        return .failure(.failed(
            .binaryNotFound, "No SteamCMD executable in the unpacked archive",
            code: .noExecutableInArchive
        ))
    }

    /// `codesign --verify` alone isn't enough: it answers "is this signature
    /// intact", not "is this Valve's binary" — both halves are required.
    /// Deliberately not `spctl`: for a bare CLI Mach-O it reports `rejected
    /// (the code is valid but does not seem to be an app)`, a refusal to
    /// assess, not a verdict, so gating on its exit status rejects every
    /// good binary.
    static func verifySignature(
        binaryPath: String,
        spawn: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool)
    ) -> Result<Void, SteamCMDManagedInstallResult> {
        let verify = spawn("/usr/bin/codesign", ["--verify", "--strict", binaryPath], 30)
        guard SteamCMDCodeSignatureParser.signatureValid(
            verifyExitCode: verify.exitCode, timedOut: verify.timedOut
        ) else {
            return .failure(.failed(
                .signatureRejected, "Code signature is not valid", code: .codeSignatureInvalid
            ))
        }

        let describe = spawn("/usr/bin/codesign", ["-dv", "--verbose=4", binaryPath], 30)
        let team = SteamCMDCodeSignatureParser.teamIdentifier(in: describe.output)
        guard team == SteamCMDBootstrapPackage.expectedTeamIdentifier else {
            return .failure(.failed(
                .signatureRejected,
                "Signed by team \(team ?? "unknown"), expected \(SteamCMDBootstrapPackage.expectedTeamIdentifier)",
                code: .signedByUnexpectedTeam,
                arguments: [team ?? "unknown", SteamCMDBootstrapPackage.expectedTeamIdentifier]
            ))
        }
        return .success(())
    }

    /// A quarantine stamp on the unpacked binary means it was produced by a
    /// sandboxed process after all, and `Process.run()` would fail EPERM at
    /// first use. Reported as an extraction problem, not a signature one — the
    /// signature is fine, the file just cannot be executed.
    static func rejectIfQuarantined(binaryPath: String) -> Result<Void, SteamCMDManagedInstallResult> {
        let quarantined = (try? URL(fileURLWithPath: binaryPath)
            .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties) ?? nil
        guard quarantined == nil else {
            return .failure(.failed(
                .extractionFailed,
                "Unpacked binary is quarantined and could not be executed",
                code: .unpackedBinaryQuarantined
            ))
        }
        return .success(())
    }
}
