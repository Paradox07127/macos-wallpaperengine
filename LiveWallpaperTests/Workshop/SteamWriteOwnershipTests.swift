import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Steam write ownership")
struct SteamWriteOwnershipTests {

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: RepositoryRoot.url(relativePath), encoding: .utf8)
    }

    private static let appSources = [
        "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift",
        "LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsInstaller.swift",
        "LiveWallpaper/Views/Workshop/InstalledLibrary.swift"
    ]

    @Test("Workshop download and delete go through the connector")
    func repositoryMutationsAreDelegated() throws {
        let doctor = try Self.source(Self.appSources[0])
        #expect(doctor.contains("SteamConnectorClient.downloadWorkshopItem"))

        let model = try Self.source(Self.appSources[2])
        #expect(model.contains("deleteSharedRepositoryItem"))

        let view = try Self.source("LiveWallpaper/Views/Workshop/InstalledView.swift")
        #expect(view.contains("SteamConnectorClient.deleteWorkshopItem"))
    }

    @Test("Wallpaper Engine install and update go through the connector")
    func engineAssetsAreDelegated() throws {
        let installer = try Self.source(Self.appSources[1])
        #expect(installer.contains("SteamConnectorClient.installWallpaperEngineAssets"))
        #expect(installer.contains("SteamConnectorClient.latestWallpaperEngineBuildID"))
    }

    @Test("The retired container-anchored asset writer stays deleted")
    func retiredWriterStaysDeleted() throws {
        for name in [
            "WPEEngineAssetsFilesystemOwner",
            "WPEEngineAssetsStartupRecovery",
            "WPEEngineAssetsTransaction"
        ] {
            let path = "LiveWallpaper/Infrastructure/Workshop/\(name).swift"
            #expect(
                !FileManager.default.fileExists(atPath: RepositoryRoot.url(path).path),
                Comment(rawValue: "\(name) came back — Steam writes belong to the connector")
            )
        }
    }

    @Test("Engine assets no longer resolve to a container path")
    func engineAssetsResolveThroughABookmark() throws {
        let library = try Self.source("LiveWallpaper/Infrastructure/Assets/WPEEngineAssetsLibrary.swift")
        #expect(!library.contains("func managedContainerRoot"))
        #expect(library.contains("func sharedLibraryInstallRoot"))
        #expect(library.contains("func adoptManagedInstall"))
    }

    @Test("Workshop download no longer builds an in-process SteamCMD script")
    @MainActor
    func downloadGateMatchesReality() throws {
        let doctor = try Self.source(Self.appSources[0])
        #expect(!doctor.contains("SteamCMDScriptWriter.downloadItemScript"))
    }

    /// `+force_install_dir` must precede `+login` (the order Valve documents), the directory is the ONE
    /// shared library for every account, and no `validate`.
    @Test("Workshop downloads land in the one shared library, unvalidated")
    func workshopDownloadTargetsSharedLibrary() throws {
        let connector = try Self.source("SteamConnector/SteamConnector.swift")
        let start = try #require(connector.range(of: "func downloadWorkshopItem("))
        let body = String(connector[start.lowerBound...].prefix(3000))

        let installDir = try #require(body.range(of: "\"+force_install_dir\""))
        let login = try #require(body.range(of: "\"+login\""))
        #expect(installDir.lowerBound < login.lowerBound)
        #expect(body.contains("\"+force_install_dir\", libraryRoot.path(percentEncoded: false)"))
        #expect(!body.contains("\"validate\""))
        #expect(!body.contains("publishContent"))

        // Control: the engine-assets install must still validate — prune deletes files only `validate` can restore.
        let assets = try #require(connector.range(of: "func installWallpaperEngineAssets("))
        let assetsBody = String(connector[assets.lowerBound...].prefix(5000))
        #expect(assetsBody.contains("\"+app_update\", SteamLibraryPaths.wallpaperEngineAppID, \"validate\""))
        // …and it must clear any stale Workshop tree BEFORE running, or that
        // tree joins the AppID's update session and `validate` re-fetches it.
        let discard = try #require(assetsBody.range(of: "discardStagedWorkshopTree(accountName:"))
        let update = try #require(assetsBody.range(of: "\"+app_update\""))
        #expect(discard.lowerBound < update.lowerBound)
        #expect(assetsBody.contains("publishContent"))
        #expect(!assetsBody.contains("\"+force_install_dir\""))
    }

    /// `SteamConnector.swift` is only compiled into the XPC target, so the gate wiring is pinned at source level.
    @Test("Connector spawn paths resolve their own binary and probe argv is allowlisted")
    func connectorSpawnPathsAreGated() throws {
        let connector = try Self.source("SteamConnector/SteamConnector.swift")
        for entryPoint in [
            "downloadWorkshopItem",
            "installWallpaperEngineAssets",
            "runSteamCMDProbe",
            "probeCachedLogin",
            "latestWallpaperEngineBuildID",
        ] {
            let body = try #require(
                Self.functionBody(of: entryPoint, in: connector),
                Comment(rawValue: "\(entryPoint) not found in SteamConnector.swift")
            )
            // Counted, not just present: a `contains` check reports a second ungated spawn as covered.
            // `probeCachedLogin` spawns through a helper, so the floor of one resolution covers it.
            let spawns = body.components(separatedBy: "Self.runSteamCMD(").count - 1
            let gates = body.components(separatedBy: "Self.resolvedExecutablePath()").count - 1
            #expect(
                gates >= max(1, spawns),
                Comment(rawValue: "\(entryPoint): \(spawns) inline spawn(s) but only \(gates) resolution(s)")
            )
            // Parameter list only: a body runs to the next non-private `func`,
            // so it can swallow the private helper that legitimately takes a path.
            let signature = body.prefix { $0 != "{" }
            #expect(
                !signature.contains("steamCMDPath"),
                Comment(rawValue: "\(entryPoint) accepts a caller-supplied binary path")
            )
        }
        let probe = try #require(Self.functionBody(of: "runSteamCMDProbe", in: connector))
        #expect(probe.contains("SteamCMDProbeArgumentPolicy.isAllowed"))

        // Control: the one function that legitimately takes a path is the shared
        // spawn helper every entry point above funnels through.
        let runner = try #require(Self.functionBody(of: "runSteamCMD", in: connector))
        #expect(runner.contains("SteamCMDExecutionFence.refusesExecution"))
    }

    @Test("The connector is told which Steam library to write, and validates it")
    func connectorTakesTheAuthorizedLibraryPath() throws {
        let connector = try Self.source("SteamConnector/SteamConnector.swift")
        #expect(
            !connector.contains("SteamLibraryPaths.steamRoot()"),
            "The connector derives the shared library itself instead of using the authorized one"
        )
        for entryPoint in ["downloadWorkshopItem", "installWallpaperEngineAssets", "deleteWorkshopItem"] {
            let start = try #require(connector.range(of: "func \(entryPoint)("))
            let body = String(connector[start.lowerBound...].prefix(3000))
            // The whole binding, not just the call: `contains` alone passes a variant that keeps the call
            // and adds a `??` fallback.
            #expect(
                body.contains("guard let libraryRoot = SteamLibraryPaths.validatedLibraryRoot(libraryPath) else {"),
                Comment(rawValue: "\(entryPoint) does not refuse outright on an unvalidated library path")
            )
        }

        // The writer must not offer a fallback either: a default there would let
        // a future caller reach the hardcoded library without naming it.
        let writer = try Self.source("SteamConnector/SteamLibraryWriter.swift")
        #expect(!writer.contains("= SteamLibraryPaths.steamRoot()"))
    }

    private static func functionBody(of name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        let tail = source[start.upperBound...]
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        return String(tail[..<end])
    }
}
