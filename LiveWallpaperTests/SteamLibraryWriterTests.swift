import Foundation
import Testing
@testable import LiveWallpaper

/// The connector is the only component that can write to the user's Steam
/// library, so its containment rules are the last line of defence. These cover
/// the pure parts — no SteamCMD, no filesystem mutation.
@Suite("Steam library write containment")
struct SteamLibraryPathsTests {

    private var contentRoot: URL { SteamLibraryPaths.workshopContentRoot() }
    private var engineRoot: URL { SteamLibraryPaths.wallpaperEngineInstallRoot() }

    @Test("Only the two agreed subtrees are writable")
    func writableSubtreesAreExactlyTwo() {
        let steam = SteamLibraryPaths.steamRoot()
        #expect(SteamLibraryPaths.isWritable(contentRoot, steamRoot: steam))
        #expect(SteamLibraryPaths.isWritable(contentRoot.appendingPathComponent("3725117707"), steamRoot: steam))
        #expect(SteamLibraryPaths.isWritable(engineRoot, steamRoot: steam))
        #expect(SteamLibraryPaths.isWritable(engineRoot.appendingPathComponent("assets"), steamRoot: steam))

        // Everything else in the Steam profile is Steam's, including the files
        // that hold the user's session.
        #expect(!SteamLibraryPaths.isWritable(steam, steamRoot: steam))
        #expect(!SteamLibraryPaths.isWritable(steam.appendingPathComponent("config"), steamRoot: steam))
        #expect(!SteamLibraryPaths.isWritable(steam.appendingPathComponent("config/config.vdf"), steamRoot: steam))
        #expect(!SteamLibraryPaths.isWritable(steam.appendingPathComponent("userdata"), steamRoot: steam))
        #expect(!SteamLibraryPaths.isWritable(steam.appendingPathComponent("steamapps"), steamRoot: steam))
        // Notably the acf ledger, which we deliberately never rewrite.
        #expect(!SteamLibraryPaths.isWritable(
            steam.appendingPathComponent("steamapps/workshop/appworkshop_431960.acf"),
            steamRoot: steam
        ))
    }

    /// The id becomes a path component under the user's real Steam library, so
    /// the rule is exactly ASCII `0-9`, 1...20 digits — not `Character.isNumber`,
    /// which also passes Nd/Nl/No ("\u{FF11}", "①", "٤") and would let a fabricated
    /// id create or delete `content/431960/①/`. The lenient `WPEPathSafety`
    /// check is a different contract (local cache components; folder imports use
    /// the folder name) and must NOT be tightened to match this one.
    @Test("Workshop ids are exactly 1-20 ASCII digits on the connector boundary")
    func workshopIDBoundaryIsASCIIDigitsOnly() {
        #expect(SteamLibraryPaths.isSafeWorkshopID("1"))
        #expect(SteamLibraryPaths.isSafeWorkshopID("3725117707"))
        #expect(SteamLibraryPaths.isSafeWorkshopID(String(repeating: "9", count: 20)))

        #expect(!SteamLibraryPaths.isSafeWorkshopID(""))
        #expect(!SteamLibraryPaths.isSafeWorkshopID(String(repeating: "9", count: 21)))
        #expect(!SteamLibraryPaths.isSafeWorkshopID("123abc"))
        #expect(!SteamLibraryPaths.isSafeWorkshopID(" 123"))
        #expect(!SteamLibraryPaths.isSafeWorkshopID("123\n"))
        #expect(!SteamLibraryPaths.isSafeWorkshopID("\u{FF11}\u{FF12}\u{FF13}"), "fullwidth digits")
        #expect(!SteamLibraryPaths.isSafeWorkshopID("\u{2460}"), "circled one")
        #expect(!SteamLibraryPaths.isSafeWorkshopID("\u{0664}"), "Arabic-Indic four")
        #expect(!SteamLibraryPaths.isSafeWorkshopID("-123"))
        #expect(!SteamLibraryPaths.isSafeWorkshopID("12.3"))
    }

    @Test("Nothing outside the Steam profile is writable")
    func pathsOutsideSteamAreRefused() {
        let steam = SteamLibraryPaths.steamRoot()
        #expect(!SteamLibraryPaths.isWritable(URL(fileURLWithPath: "/"), steamRoot: steam))
        #expect(!SteamLibraryPaths.isWritable(URL(fileURLWithPath: "/Applications"), steamRoot: steam))
        #expect(!SteamLibraryPaths.isWritable(
            URL(fileURLWithPath: SteamConnectorEnvironmentProbe.posixHomeDirectory()),
            steamRoot: steam
        ))
        #expect(!SteamLibraryPaths.isWritable(
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine"),
            steamRoot: steam
        ))
    }

}

/// SteamCMD's progress lines drive the only feedback a multi-minute install
/// gives, and both the connector and the app read them — one parser, one
/// reading.
@Suite("SteamCMD progress line")
struct SteamCMDProgressLineTests {

    @Test("The detailed form yields fraction and byte counts")
    func parsesDetailedForm() throws {
        let progress = try #require(
            SteamCMDProgressLine.parse("Update state (0x61) downloading, progress: 42.34 (12345 / 67890)")
        )
        #expect(progress.phase == .downloading)
        #expect(progress.fraction.map { abs($0 - 0.4234) < 0.0001 } == true)
        #expect(progress.downloadedBytes == 12345)
        #expect(progress.totalBytes == 67890)
    }

    /// SteamCMD frequently omits the byte detail; dropping those updates would
    /// stall the bar at whatever the last detailed line said.
    @Test("The percent-only form still reports a fraction")
    func parsesPercentOnlyForm() throws {
        let progress = try #require(
            SteamCMDProgressLine.parse("Update state (0x61) downloading, progress: 7.00")
        )
        #expect(progress.fraction.map { abs($0 - 0.07) < 0.0001 } == true)
        #expect(progress.downloadedBytes == nil)
    }

    @Test("Verifying is distinguished from downloading")
    func recognisesVerifyPhase() throws {
        let progress = try #require(
            SteamCMDProgressLine.parse("Update state (0x81) verifying update, progress: 99.10 (1 / 2)")
        )
        #expect(progress.phase == .verifying)
    }

    @Test("Lines that carry no progress are ignored rather than guessed at")
    func ignoresNonProgressLines() {
        #expect(SteamCMDProgressLine.parse("") == nil)
        #expect(SteamCMDProgressLine.parse("Logging in user 'x' to Steam Public...OK") == nil)
        #expect(SteamCMDProgressLine.parse("Update state (0x61) downloading") == nil)
        #expect(SteamCMDProgressLine.parse("progress: not-a-number") == nil)
    }

    @Test("Fractions stay inside 0…1 even when SteamCMD overshoots")
    func fractionIsClamped() throws {
        let over = try #require(SteamCMDProgressLine.parse("progress: 137.5"))
        #expect(over.fraction == 1)
        #expect(SteamCMDProgressLine.parse("progress: -4") == nil)
    }
}

/// buildid drives the update check; reading the wrong branch would offer
/// updates for a build the user cannot install.
@Suite("Wallpaper Engine buildid parsing")
struct WallpaperEngineBuildIDTests {

    @Test("The public branch buildid is preferred over earlier ones in the dump")
    func readsPublicBranchBuildID() {
        let dump = """
        "431960"
        {
            "depots"
            {
                "branches"
                {
                    "beta"
                    {
                        "buildid"  "11111111"
                    }
                    "public"
                    {
                        "buildid"  "23967692"
                        "timeupdated"  "1785000000"
                    }
                }
            }
        }
        """
        #expect(SteamConnectorBuildInfo.parsePublicBuildID(from: dump) == "23967692")
    }

    @Test("A dump without a public branch yields nothing rather than a guess")
    func missingPublicBranchYieldsNil() {
        #expect(SteamConnectorBuildInfo.parsePublicBuildID(from: "") == nil)
        #expect(SteamConnectorBuildInfo.parsePublicBuildID(from: #""beta" { "buildid" "1" }"#) == nil)
    }
}

/// The containment guard's real adversary is not `../` — numeric ids already
/// exclude that — but a symlink swapped in *above* the target, which made the
/// target and its own anchor resolve consistently and look contained.
@Suite("Steam write containment against symlinks")
struct SteamLibrarySymlinkContainmentTests {

    /// Builds a scratch Steam tree so the walk runs against real inodes without
    /// touching the user's library.
    private func makeSteamTree() throws -> (root: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steam-containment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true),
            withIntermediateDirectories: true
        )
        return (root, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("A plain item under the content root is writable")
    func plainItemIsWritable() throws {
        let tree = try makeSteamTree()
        defer { tree.cleanup() }
        let item = tree.root.appendingPathComponent("steamapps/workshop/content/431960/3725117707")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        #expect(SteamLibraryPaths.isWritable(item, steamRoot: tree.root))
    }

    /// The attack the old guard missed: replace an ancestor with a link, and
    /// target plus anchor resolve consistently so the target looks contained.
    @Test("A symlinked ancestor makes everything under it unwritable")
    func symlinkedAncestorIsRefused() throws {
        let tree = try makeSteamTree()
        defer { tree.cleanup() }

        let outside = tree.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("3725117707", isDirectory: true),
            withIntermediateDirectories: true
        )
        let contentRoot = tree.root.appendingPathComponent("steamapps/workshop/content/431960")
        try FileManager.default.removeItem(at: contentRoot)
        try FileManager.default.createSymbolicLink(at: contentRoot, withDestinationURL: outside)

        #expect(!SteamLibraryPaths.isWritable(contentRoot, steamRoot: tree.root))
        #expect(!SteamLibraryPaths.isWritable(
            contentRoot.appendingPathComponent("3725117707"), steamRoot: tree.root
        ))
    }

    @Test("A symlinked leaf is refused too")
    func symlinkedLeafIsRefused() throws {
        let tree = try makeSteamTree()
        defer { tree.cleanup() }
        let outside = tree.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let item = tree.root.appendingPathComponent("steamapps/workshop/content/431960/3725117707")
        try FileManager.default.createSymbolicLink(at: item, withDestinationURL: outside)
        #expect(!SteamLibraryPaths.isWritable(item, steamRoot: tree.root))
    }

    @Test("Paths outside the two subtrees stay refused")
    func nonAllowedSubtreesAreRefused() throws {
        let tree = try makeSteamTree()
        defer { tree.cleanup() }
        #expect(!SteamLibraryPaths.isWritable(tree.root.appendingPathComponent("config"), steamRoot: tree.root))
        #expect(!SteamLibraryPaths.isWritable(tree.root.appendingPathComponent("steamapps"), steamRoot: tree.root))
        #expect(!SteamLibraryPaths.isWritable(
            tree.root.appendingPathComponent("steamapps/workshop/content/431960/../../../config"),
            steamRoot: tree.root
        ))
    }
}
/// A `public` block with no readable buildid must not fall through to the next
/// branch — reporting a beta build as public drives a wrong update verdict.
@Suite("Public build branch isolation")
struct PublicBranchIsolationTests {

    @Test("A public block without a buildid does not borrow the beta one")
    func emptyPublicBlockYieldsNil() {
        let dump = """
        "branches"
        {
            "public"
            {
                "timeupdated"  "1785000000"
            }
            "beta"
            {
                "buildid"  "99999999"
            }
        }
        """
        #expect(SteamConnectorBuildInfo.parsePublicBuildID(from: dump) == nil)
    }

    @Test("A buildid inside the public block is still found after nesting")
    func nestedPublicBlockStillParses() {
        let dump = """
        "branches"
        {
            "public"
            {
                "description" { "loc" "en" }
                "buildid"  "23967692"
            }
            "beta" { "buildid" "111" }
        }
        """
        #expect(SteamConnectorBuildInfo.parsePublicBuildID(from: dump) == "23967692")
    }
}

/// Serializing every SteamCMD run means a request can wait behind a long
/// install. Executing it anyway — after the caller's own deadline passed —
/// would delete or download with nobody listening.
@Suite("Connector queue-wait expiry")
struct ConnectorQueueExpiryTests {

    @Test("Every queued SteamCMD entry point checks the caller has not given up")
    func everyQueuedBodyChecksExpiry() throws {
        let source = try String(
            contentsOf: RepositoryRoot.url("SteamConnector/SteamConnector.swift"),
            encoding: .utf8
        )
        let enqueues = source.components(separatedBy: "Self.steamCMDQueue.async {").count - 1
        let guards = source.components(separatedBy: "callerAbandoned(enqueuedAt:").count - 1
        #expect(enqueues > 0)
        // One definition plus one guard per enqueue.
        #expect(guards == enqueues + 1, "a queued body is missing its abandonment check")
    }

    /// The client must outlast the service's expiry, or it walks away while the
    /// work is still running.
    @Test("The client backstop is longer than the connector's queue expiry")
    func clientBackstopOutlastsServiceExpiry() throws {
        let client = try String(
            contentsOf: RepositoryRoot.url("LiveWallpaper/Infrastructure/Workshop/SteamConnectorClient.swift"),
            encoding: .utf8
        )
        let service = try String(
            contentsOf: RepositoryRoot.url("SteamConnector/SteamConnector.swift"),
            encoding: .utf8
        )
        let clientTimeout = try #require(
            client.firstMatch(of: /timeout: TimeInterval = (\d+)/).flatMap { Double($0.output.1) }
        )
        let serviceExpiry = try #require(
            service.firstMatch(of: /maxQueueWait: TimeInterval = (\d+)/).flatMap { Double($0.output.1) }
        )
        #expect(clientTimeout > serviceExpiry)
    }
}

/// The connector is unsandboxed, so what it hands its child matters more here
/// than it would in the app. An earlier version passed a bare `Process()` and
/// silently inherited the service's whole environment.
@Suite("SteamCMD child environment")
struct SteamCMDChildEnvironmentTests {

    @Test("Only the four agreed variables are passed through")
    func environmentIsAWhitelist() {
        let env = SteamCMDChildEnvironment.make(home: "/Users/example", temporaryDirectory: "/tmp/x/")
        #expect(Set(env.keys) == ["HOME", "PATH", "TMPDIR", "LANG"])
        #expect(env["HOME"] == "/Users/example")
        #expect(env["TMPDIR"] == "/tmp/x/")
    }

    /// Injection vectors the app's runner already drops; the connector inherits
    /// nothing, so they can only be absent.
    @Test("Nothing that could redirect loading or leak credentials survives")
    func dangerousVariablesAreAbsent() {
        let env = SteamCMDChildEnvironment.make()
        for key in [
            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
            "SSH_AUTH_SOCK", "http_proxy", "https_proxy", "LD_PRELOAD",
        ] {
            #expect(env[key] == nil, "\(key) reached the child")
        }
    }

    /// Matches the app runner's pin. The parser reads decimals positionally and
    /// stops at the first character that is not a digit, `.` or space, so a
    /// comma-decimal rendering degrades silently rather than failing loudly —
    /// which is the harder failure to notice, and the reason to pin rather than
    /// to teach the parser more formats.
    @Test("The locale is pinned, and the parser's comma behaviour is degradation not refusal")
    func localeIsPinned() throws {
        #expect(SteamCMDChildEnvironment.make()["LANG"] == "en_US.UTF-8")

        let dotted = try #require(SteamCMDProgressLine.parse("progress: 42.34 (1 / 2)"))
        #expect(dotted.fraction.map { abs($0 - 0.4234) < 0.0001 } == true)

        // Not nil, and not right: the fraction truncates at the separator.
        let comma = try #require(SteamCMDProgressLine.parse("progress: 42,34"))
        #expect(comma.fraction.map { abs($0 - 0.42) < 0.0001 } == true)
    }

    /// The real home, not the container — the whole reason the connector exists.
    @Test("HOME defaults to the POSIX home, never the sandbox container")
    func homeDefaultsToRealHome() {
        let env = SteamCMDChildEnvironment.make()
        #expect(env["HOME"] == SteamConnectorEnvironmentProbe.posixHomeDirectory())
        #expect(env["HOME"]?.contains("/Library/Containers/") != true)
    }

    /// A presence ratchet, not a behaviour test, and deliberately so: the tests
    /// above pin what the whitelist contains but cannot reach `runSteamCMD` —
    /// `SteamConnector.swift` belongs only to the connector target. Dropping the
    /// assignment would restore the inherit-everything bug with every test above
    /// still green, so the assignment itself is what gets pinned here.
    @Test("The spawn actually applies the whitelist")
    func spawnUsesTheWhitelist() throws {
        let source = try String(
            contentsOf: RepositoryRoot.url("SteamConnector/SteamConnector.swift"),
            encoding: .utf8
        )
        // Count invariant, not `contains`: every Process the connector creates
        // must apply the whitelist, and a second spawn point sharing the first
        // one's assignment is exactly what `contains` cannot see. Two today:
        // the shared pipe runner and the interactive login's PTY session.
        let spawns = source.components(separatedBy: "Process()").count - 1
        let whitelisted = source.components(
            separatedBy: "process.environment = SteamCMDChildEnvironment.make()"
        ).count - 1
        #expect(spawns >= 1)
        #expect(
            whitelisted == spawns,
            "every Process() in the connector must apply SteamCMDChildEnvironment"
        )
    }
}

/// The descriptor-based delete permanently removes the user's files, and two
/// rounds of reading it missed a use-after-close that silently skipped every
/// nested entry. Source-text assertions cannot see that; these run it.
///
/// Every case builds its own scratch Steam tree — `steamRoot` is injectable for
/// exactly this reason — so the user's real library is never touched.
@Suite("Steam library writer, behaviour")
struct SteamLibraryWriterBehaviourTests {

    private static let itemID = "3725117707"

    /// A scratch tree shaped like a Steam root, with the item folder populated
    /// deeply enough that a walk which stops at the first level is visible.
    private static func makeTree() throws -> (root: URL, item: URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("steam-writer-\(UUID().uuidString)", isDirectory: true)
        let item = SteamLibraryPaths.workshopContentRoot(steamRoot: root)
            .appendingPathComponent(itemID, isDirectory: true)
        try fm.createDirectory(at: item.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try Data("scene".utf8).write(to: item.appendingPathComponent("project.json"))
        try Data("nested".utf8).write(to: item.appendingPathComponent("a/b/c/scene.pkg"))
        try Data("mid".utf8).write(to: item.appendingPathComponent("a/preview.jpg"))
        return (root, item, { try? fm.removeItem(at: root) })
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    /// The regression this suite exists for: with the recursion running on a
    /// closed descriptor, `fstatat` failed, every nested entry was treated as
    /// absent, and the final `AT_REMOVEDIR` failed on a still-populated folder.
    @Test("Deleting an item removes the whole nested tree")
    func deleteRemovesNestedTree() throws {
        let tree = try Self.makeTree()
        defer { tree.cleanup() }

        let result = SteamLibraryWriter.deleteWorkshopItem(
            workshopID: Self.itemID,
            steamRoot: tree.root
        )

        #expect(result.outcome == .deleted)
        #expect(result.freedBytes > 0)
        #expect(!Self.exists(tree.item))
        // The content root itself is the parent we opened, not something we own.
        #expect(Self.exists(SteamLibraryPaths.workshopContentRoot(steamRoot: tree.root)))
    }

    /// A link inside the item must be unlinked, never descended into, or a
    /// wallpaper could take its author's chosen target down with it.
    @Test("A symlink inside the item is unlinked, its target untouched")
    func symlinkInsideItemIsNotFollowed() throws {
        let tree = try Self.makeTree()
        defer { tree.cleanup() }
        let fm = FileManager.default

        let outside = tree.root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let bystander = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: bystander)
        try fm.createSymbolicLink(
            at: tree.item.appendingPathComponent("a/escape"),
            withDestinationURL: outside
        )

        let result = SteamLibraryWriter.deleteWorkshopItem(
            workshopID: Self.itemID,
            steamRoot: tree.root
        )

        #expect(result.outcome == .deleted)
        #expect(!Self.exists(tree.item))
        #expect(Self.exists(bystander))
        #expect(Self.exists(outside))
    }

    /// The item folder itself being a link is the ancestor-swap attack; the
    /// containment guard must refuse before anything is opened.
    @Test("A symlinked item folder is refused, its target untouched")
    func symlinkedItemFolderIsRefused() throws {
        let tree = try Self.makeTree()
        defer { tree.cleanup() }
        let fm = FileManager.default

        let outside = tree.root.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let bystander = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: bystander)
        try fm.removeItem(at: tree.item)
        try fm.createSymbolicLink(at: tree.item, withDestinationURL: outside)

        let result = SteamLibraryWriter.deleteWorkshopItem(
            workshopID: Self.itemID,
            steamRoot: tree.root
        )

        #expect(result.outcome == .refused)
        #expect(Self.exists(bystander))
    }

    @Test("A non-numeric id is refused before any filesystem work")
    func unsafeIDIsRefused() throws {
        let tree = try Self.makeTree()
        defer { tree.cleanup() }
        for id in ["../../config", "3725117707/../..", "", "abc"] {
            let result = SteamLibraryWriter.deleteWorkshopItem(workshopID: id, steamRoot: tree.root)
            #expect(result.outcome == .refused, "accepted id \(id)")
        }
        #expect(Self.exists(tree.item))
    }

    @Test("An id that was never downloaded reports notFound rather than success")
    func missingItemIsNotFound() throws {
        let tree = try Self.makeTree()
        defer { tree.cleanup() }
        let result = SteamLibraryWriter.deleteWorkshopItem(workshopID: "1234567890", steamRoot: tree.root)
        #expect(result.outcome == .notFound)
    }

    /// A tree deep enough to exhaust the stack is hostile input; refusing beats
    /// crashing the connector mid-delete.
    @Test("A pathologically deep tree is refused, not descended")
    func deepTreeIsRefused() throws {
        let tree = try Self.makeTree()
        defer { tree.cleanup() }
        let deep = tree.item.appendingPathComponent(
            Array(repeating: "d", count: 80).joined(separator: "/")
        )
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let result = SteamLibraryWriter.deleteWorkshopItem(
            workshopID: Self.itemID,
            steamRoot: tree.root
        )

        #expect(result.outcome == .refused)
        #expect(Self.exists(tree.item))
    }
}

/// Prune trims a finished Wallpaper Engine install to `assets/`. It refuses
/// rather than guesses: everything it removes is unrecoverable.
@Suite("Wallpaper Engine prune, behaviour")
struct WallpaperEnginePruneBehaviourTests {

    private static func makeInstall(
        withAssets: Bool,
        assetsPopulated: Bool = true
    ) throws -> (root: URL, install: URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("steam-prune-\(UUID().uuidString)", isDirectory: true)
        let install = SteamLibraryPaths.wallpaperEngineInstallRoot(steamRoot: root)
        try fm.createDirectory(at: install.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: install.appendingPathComponent("wallpaper64.exe"))
        try Data("dll".utf8).write(to: install.appendingPathComponent("bin/steam_api64.dll"))
        if withAssets {
            let assets = install.appendingPathComponent("assets/shaders", isDirectory: true)
            try fm.createDirectory(at: assets, withIntermediateDirectories: true)
            if assetsPopulated {
                try Data("frag".utf8).write(to: assets.appendingPathComponent("effect.frag"))
            } else {
                try fm.removeItem(at: install.appendingPathComponent("assets/shaders"))
            }
        }
        return (root, install, { try? fm.removeItem(at: root) })
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    @Test("Prune keeps assets/ and removes everything beside it")
    func pruneKeepsOnlyAssets() throws {
        let tree = try Self.makeInstall(withAssets: true)
        defer { tree.cleanup() }

        let kept = try SteamLibraryWriter.pruneWallpaperEngineInstall(steamRoot: tree.root)

        #expect(kept.lastPathComponent == "assets")
        #expect(Self.exists(tree.install.appendingPathComponent("assets/shaders/effect.frag")))
        #expect(!Self.exists(tree.install.appendingPathComponent("wallpaper64.exe")))
        #expect(!Self.exists(tree.install.appendingPathComponent("bin")))
    }

    /// No `assets/` means this is not the install we think it is — and by then
    /// removing the rest would have destroyed something unidentified.
    @Test("A missing assets/ aborts before anything is removed")
    func missingAssetsRemovesNothing() throws {
        let tree = try Self.makeInstall(withAssets: false)
        defer { tree.cleanup() }

        #expect(throws: SteamLibraryWriter.WriteError.self) {
            try SteamLibraryWriter.pruneWallpaperEngineInstall(steamRoot: tree.root)
        }
        #expect(Self.exists(tree.install.appendingPathComponent("wallpaper64.exe")))
        #expect(Self.exists(tree.install.appendingPathComponent("bin/steam_api64.dll")))
    }

    /// An empty `assets/` is a half-finished download, not a valid install.
    @Test("An empty assets/ aborts before anything is removed")
    func emptyAssetsRemovesNothing() throws {
        let tree = try Self.makeInstall(withAssets: true, assetsPopulated: false)
        defer { tree.cleanup() }

        #expect(throws: SteamLibraryWriter.WriteError.self) {
            try SteamLibraryWriter.pruneWallpaperEngineInstall(steamRoot: tree.root)
        }
        #expect(Self.exists(tree.install.appendingPathComponent("wallpaper64.exe")))
    }

    /// The install root being a link is the ancestor swap again, aimed at the
    /// larger of the two writable subtrees.
    @Test("A symlinked install root is refused, its target untouched")
    func symlinkedInstallRootIsRefused() throws {
        let tree = try Self.makeInstall(withAssets: true)
        defer { tree.cleanup() }
        let fm = FileManager.default

        let outside = tree.root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let bystander = outside.appendingPathComponent("payroll.txt")
        try Data("keep".utf8).write(to: bystander)
        try fm.removeItem(at: tree.install)
        try fm.createSymbolicLink(at: tree.install, withDestinationURL: outside)

        #expect(throws: SteamLibraryWriter.WriteError.self) {
            try SteamLibraryWriter.pruneWallpaperEngineInstall(steamRoot: tree.root)
        }
        #expect(Self.exists(bystander))
    }
}
