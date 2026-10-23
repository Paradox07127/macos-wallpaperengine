import CryptoKit
import Foundation

/// SHA-256 of a file on disk. Shared so the app's tests exercise the exact
/// function the connector re-hashes with, rather than a lookalike.
enum SteamCMDBinaryDigest {
    /// Streams the file: a helper that hashes whatever path it is handed should
    /// not size its memory off that path's contents.
    static func sha256(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Where this process refuses to execute from, whatever the signature or
/// digest says. Every pre-spawn check — `codesign --verify`, quarantine
/// read, re-hash — opens, decides, and closes the path; the spawn opens it
/// again. macOS has no `fexecve` binding those two opens to one inode, so a
/// caller that can write the path can swap bytes in between (steamcmd also
/// must run from inside its own directory tree, so executing a verified
/// copy elsewhere isn't available). What's left: keep the executable out of
/// the caller's own writable storage — where a compromised app could stage
/// a replacement — including the temp directory it's handed (the sandbox
/// redirects that into the container too); a real SteamCMD never lives in
/// either. Matched on substrings, not prefixes: the home directory varies,
/// and `/Users/x/Library/Containers/…` is the shape that matters.
enum SteamCMDExecutionFence {
    static let callerWritableMarkers = [
        "/Library/Containers/",
        "/Library/Group Containers/",
    ]

    /// Symlinks are resolved first: a link outside a container pointing into one
    /// executes the file inside it, so judging the link's own path would miss.
    static func refusesExecution(of path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path(percentEncoded: false)
        return callerWritableMarkers.contains { resolved.contains($0) }
    }
}

/// Reads `codesign` output. Shared so the connector produces the verdict and the
/// app's tests can pin the parsing without spawning anything.
enum SteamCMDCodeSignatureParser {
    /// Fail-closed: anything other than a clean, completed `--verify` is invalid.
    /// A timeout in particular must never read as "signed".
    static func signatureValid(verifyExitCode: Int32, timedOut: Bool) -> Bool {
        verifyExitCode == 0 && !timedOut
    }

    static func teamIdentifier(in text: String) -> String? {
        firstCapture(in: text, pattern: #"TeamIdentifier=([A-Z0-9]+)"#)
    }

    static func isHardenedRuntime(in text: String) -> Bool {
        text.range(
            of: #"flags=0x[0-9a-fA-F]+\([^)]*runtime"#,
            options: .regularExpression
        ) != nil || text.contains("runtime")
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }
}

/// Resolves a user-selected SteamCMD path to the canonical Mach-O binary we
/// are willing to execute. `steamcmd.sh` wrappers are accepted only as a
/// discovery convenience — we parse them to extract `STEAMEXE` and refuse to
/// execute the wrapper itself (the wrapper is shell code that runs before
/// SteamCMD, so a tampered install could inject arbitrary commands).
enum SteamCMDBinaryResolver {
    static func resolveCanonicalBinary(at userPickedURL: URL) -> Result<URL, SteamCMDBinaryError> {
        let pickedURL = userPickedURL.resolvingSymlinksInPath().standardizedFileURL
        guard fileExists(pickedURL) else {
            return .failure(.fileNotFound)
        }
        // A Mach-O is the executable itself. Anything else — Valve's
        // `steamcmd.sh`, Homebrew's `steamcmd.wrapper.sh`, or a
        // `/opt/homebrew/bin/steamcmd` symlink that resolves to one — is a
        // shell wrapper we follow to the real binary.
        if isMachO(pickedURL) {
            return validateBinary(pickedURL).map { pickedURL }
        }
        return resolveWrapper(pickedURL)
    }

    /// Where the package managers put SteamCMD, in the order tried.
    /// `which steamcmd` isn't an option — launchd starts this XPC service
    /// without sourcing the shell profile, so `/opt/homebrew/bin` isn't on
    /// `PATH` — so these are `stat`s at derived paths instead, covering
    /// Homebrew's three historical cask layouts: (1) `<prefix>/bin/steamcmd`,
    /// the `binary` stanza's symlink, the only thing searched until
    /// 2026-08-14; (2) `<prefix>/.homebrew-command-wrappers/steamcmd`, the
    /// Command Wrapper stanza upstream's cask moved to, which writes no
    /// `bin` symlink so layer 1 alone misreports "not installed"; (3)
    /// `<prefix>/Caskroom/steamcmd/<version>/MacOS/steamcmd`, the real
    /// Mach-O, reached when both links are absent (e.g. after `brew unlink`,
    /// which renames the symlink to `steamcmd.off` — deliberately not
    /// honoured, since `.off` means the user disabled it). Measured
    /// 2026-08-14 on a Homebrew Mac: all three old fixed paths were missing,
    /// reachable only through layer 3. Not searched: `~/steamcmd`, `~/Steam`
    /// (read the sandbox container until 2026-08-02, never matched), nor the
    /// managed install (`SteamCMDManagedInstaller.managedBinary()`, spliced
    /// in by `SteamCMDDiagnosisPlan`).
    static func autoDetectCandidates(
        roots: SearchRoots = SearchRoots(),
        fileManager: FileManager = .default
    ) -> [URL] {
        var candidates: [URL] = []

        for prefix in roots.homebrewPrefixes {
            candidates.append(URL(fileURLWithPath: prefix + "/bin/steamcmd"))
        }
        candidates.append(URL(fileURLWithPath: roots.macPortsPrefix + "/bin/steamcmd"))
        for prefix in roots.homebrewPrefixes {
            candidates.append(URL(fileURLWithPath: prefix + "/.homebrew-command-wrappers/steamcmd"))
        }
        for prefix in roots.homebrewPrefixes {
            candidates.append(contentsOf: caskroomBinaries(homebrewPrefix: prefix, fileManager: fileManager))
        }
        return candidates
    }

    /// The prefixes searched. Injectable so the Caskroom walk can be exercised
    /// against a fixture instead of whatever the test machine happens to have
    /// installed.
    struct SearchRoots: Sendable {
        var homebrewPrefixes: [String]
        var macPortsPrefix: String

        /// `HOMEBREW_PREFIX` deliberately absent: it lives in the user's
        /// shell profile, and launchd starts this service without sourcing
        /// one (same reason `which steamcmd` is unusable, see
        /// `autoDetectCandidates`) — reading it would look like
        /// relocated-prefix support while always empty here. A Homebrew
        /// elsewhere is covered by the manual pick instead.
        init(
            homebrewPrefixes: [String] = ["/opt/homebrew", "/usr/local"],
            macPortsPrefix: String = "/opt/local"
        ) {
            self.homebrewPrefixes = homebrewPrefixes
            self.macPortsPrefix = macPortsPrefix
        }
    }

    /// Entry points inside one Caskroom version directory, in the order
    /// tried. The wrapper comes first, Mach-O paths after: `resolveWrapper`
    /// already follows the cask's `steamcmd.wrapper.sh` to whatever the
    /// payload contains, covering layouts this list has never seen.
    /// Offering only `MacOS/steamcmd` — all this used to do — made
    /// discovery depend on one internal path Homebrew is free to change,
    /// and when it did the app reported "not found" for an install sitting
    /// right there.
    static let caskroomEntryPoints = [
        "steamcmd.wrapper.sh",
        "MacOS/steamcmd",
        "steamcmd",
        "osx32/steamcmd",
    ]

    /// Every installed cask version's entry points, newest version first —
    /// all versions, not just the newest: Homebrew leaves older version
    /// directories behind after an upgrade, and if the newest fails a trust
    /// gate, `SteamCMDDiagnosisPlan.firstTrusted` should get to try the one
    /// that passes.
    private static func caskroomBinaries(homebrewPrefix: String, fileManager: FileManager) -> [URL] {
        let cask = URL(fileURLWithPath: homebrewPrefix + "/Caskroom/steamcmd", isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(
            at: cask,
            includingPropertiesForKeys: [.contentModificationDateKey],
            // Skips `.metadata`, which is a sibling of the version directories.
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return versions
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
            .flatMap { version in
                caskroomEntryPoints.map {
                    version.appendingPathComponent($0, isDirectory: false)
                }
            }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// `depth` bounds the wrapper chain. Homebrew's cask is genuinely two deep
    /// (`steamcmd.wrapper.sh` execs `MacOS/steamcmd.sh`, which execs the Mach-O),
    /// and a wrapper that execs itself would otherwise spin here.
    private static func resolveWrapper(_ wrapperURL: URL, depth: Int = 0) -> Result<URL, SteamCMDBinaryError> {
        let wrapperDir = wrapperURL.deletingLastPathComponent()

        // 1) An explicit `STEAMEXE=<path>` line (Valve's tarball `steamcmd.sh`).
        if let value = try? steamExecutableValue(in: wrapperURL) {
            let target = resolveShellPath(value, relativeTo: wrapperDir)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if fileExists(target), isMachO(target), case .success = validateBinary(target) {
                return .success(target)
            }
        }

        // 2) Otherwise locate the `steamcmd` Mach-O next to the wrapper. Covers
        //    Homebrew's `steamcmd.wrapper.sh` (binary under `MacOS/`) and
        //    Valve's tarball layout (alongside, or under `osx32/`).
        for relative in ["steamcmd", "MacOS/steamcmd", "osx32/steamcmd"] {
            let candidate = wrapperDir.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
            if fileExists(candidate), isMachO(candidate), case .success = validateBinary(candidate) {
                return .success(candidate)
            }
        }

        // 3) Follow a bare `exec '<path>' "$@"`. Homebrew's Command Wrapper
        //    stanza and its cask wrapper are both this shape, and neither sits
        //    anywhere near the Mach-O, so neither (1) nor (2) can reach it.
        if depth < 2, let target = execTarget(in: wrapperURL, relativeTo: wrapperDir) {
            if isMachO(target) {
                return validateBinary(target).map { target }
            }
            if fileExists(target) {
                return resolveWrapper(target, depth: depth + 1)
            }
        }

        return .failure(.wrapperParseFailed(reason: "Couldn't find the SteamCMD Mach-O binary near \(wrapperURL.lastPathComponent)."))
    }

    /// The path from the first `exec <path>` line, quoted or not.
    private static func execTarget(in wrapperURL: URL, relativeTo wrapperDir: URL) -> URL? {
        guard let data = try? Data(contentsOf: wrapperURL, options: .mappedIfSafe),
              let script = String(data: data.prefix(64 * 1024), encoding: .utf8) else { return nil }

        for rawLine in script.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("exec ") else { continue }
            let argument = String(line.dropFirst("exec ".count)).trimmingCharacters(in: .whitespaces)
            guard let value = firstShellWord(argument) else { continue }
            // `exec "$0"` is the restart line at the bottom of Valve's script.
            guard !value.isEmpty, !value.contains("$") else { continue }
            return resolveShellPath(value, relativeTo: wrapperDir)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
        return nil
    }

    private static func steamExecutableValue(in wrapperURL: URL) throws -> String {
        let data = try Data(contentsOf: wrapperURL, options: .mappedIfSafe)
        guard let script = String(data: data.prefix(64 * 1024), encoding: .utf8) else {
            throw SteamCMDBinaryError.wrapperParseFailed(reason: "steamcmd.sh is not valid UTF-8")
        }

        for rawLine in script.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("STEAMEXE=") else { continue }
            let stripped = stripShellQuoting(String(line.dropFirst("STEAMEXE=".count)).trimmingCharacters(in: .whitespaces))
            guard !stripped.isEmpty else {
                throw SteamCMDBinaryError.wrapperParseFailed(reason: "STEAMEXE is empty")
            }
            return stripped
        }
        throw SteamCMDBinaryError.wrapperParseFailed(reason: "STEAMEXE assignment not found")
    }

    /// The first argument of a command line, unquoted. Everything after it —
    /// `"$@"` in practice — is dropped.
    private static func firstShellWord(_ argument: String) -> String? {
        guard let first = argument.first else { return nil }
        if first == "'" || first == "\"" {
            let body = argument.dropFirst()
            guard let end = body.firstIndex(of: first) else { return nil }
            return String(body[body.startIndex ..< end])
        }
        return String(argument.prefix(while: { !$0.isWhitespace }))
    }

    private static func stripShellQuoting(_ value: String) -> String {
        var output = value
        if let commentRange = output.range(of: #"\s+#"#, options: .regularExpression) {
            output = String(output[..<commentRange.lowerBound])
        }
        if output.count >= 2,
           let first = output.first,
           let last = output.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            output.removeFirst()
            output.removeLast()
        }
        return output
    }

    private static func resolveShellPath(_ value: String, relativeTo wrapperDirectory: URL) -> URL {
        let wrapperPath = wrapperDirectory.path(percentEncoded: false)
        var expanded = value
            .replacingOccurrences(of: "${STEAMROOT}", with: wrapperPath)
            .replacingOccurrences(of: "$STEAMROOT", with: wrapperPath)

        if expanded.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(expanded.dropFirst(2)))
                .path(percentEncoded: false)
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        let direct = wrapperDirectory.appendingPathComponent(expanded, isDirectory: false)
        if fileExists(direct) {
            return direct
        }

        for child in ["MacOS", "osx32"] {
            let candidate = wrapperDirectory
                .appendingPathComponent(child, isDirectory: true)
                .appendingPathComponent((expanded as NSString).lastPathComponent, isDirectory: false)
            if fileExists(candidate) {
                return candidate
            }
        }
        return direct
    }

    private static func validateBinary(_ url: URL) -> Result<Void, SteamCMDBinaryError> {
        guard isMachO(url) else { return .failure(.notMachO) }
        guard FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) else {
            return .failure(.notExecutable)
        }
        return .success(())
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let bytes = Array(data)
        return bytes == [0xFE, 0xED, 0xFA, 0xCE]
            || bytes == [0xCE, 0xFA, 0xED, 0xFE]
            || bytes == [0xFE, 0xED, 0xFA, 0xCF]
            || bytes == [0xCF, 0xFA, 0xED, 0xFE]
            || bytes == [0xCA, 0xFE, 0xBA, 0xBE]
            || bytes == [0xBE, 0xBA, 0xFE, 0xCA]
            || bytes == [0xCA, 0xFE, 0xBA, 0xBF]
            || bytes == [0xBF, 0xBA, 0xFE, 0xCA]
    }

    private static func fileExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

enum SteamCMDBinaryError: Error, Equatable, Sendable {
    case fileNotFound
    case notMachO
    case wrapperParseFailed(reason: String)
    case notExecutable
}
