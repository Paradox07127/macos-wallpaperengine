import Foundation
import Testing
@testable import LiveWallpaper

/// One writer, one place to audit.
///
/// Every mutation of the user's Steam library — installing Wallpaper Engine,
/// pruning it, downloading a Workshop item, deleting one — happens in the
/// connector, because only it runs outside the sandbox with the user's real
/// `$HOME`. The main app deliberately keeps no code path that can write there:
/// a SteamCMD spawned from this process would put files back in the container,
/// which is the failure this whole migration removed.
@Suite("Steam write ownership")
struct SteamWriteOwnershipTests {

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: RepositoryRoot.url(relativePath), encoding: .utf8)
    }

    private static let appSources = [
        "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift",
        "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorOperations.swift",
        "LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsInstaller.swift",
        "LiveWallpaper/Views/Workshop/WorkshopInstalledLibraryModel.swift"
    ]

    @Test("Workshop download and delete go through the connector")
    func repositoryMutationsAreDelegated() throws {
        let doctor = try Self.source(Self.appSources[0])
        #expect(doctor.contains("SteamConnectorClient.downloadWorkshopItem"))

        let model = try Self.source(Self.appSources[3])
        #expect(model.contains("deleteSharedRepositoryItem"))

        let view = try Self.source("LiveWallpaper/Views/Workshop/WorkshopInstalledView.swift")
        #expect(view.contains("SteamConnectorClient.deleteWorkshopItem"))
    }

    @Test("Wallpaper Engine install and update go through the connector")
    func engineAssetsAreDelegated() throws {
        let installer = try Self.source(Self.appSources[2])
        #expect(installer.contains("SteamConnectorClient.installWallpaperEngineAssets"))
        #expect(installer.contains("SteamConnectorClient.latestWallpaperEngineBuildID"))
    }

    /// The container-anchored writer is gone, not merely unused: leaving it
    /// compiled would let a future caller reach it and silently re-create the
    /// private Steam tree.
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

    /// `managedContainerRoot` pointed the engine-assets reader at the app's own
    /// container. The install now lives in the shared Steam library and is
    /// reached through a bookmark like any external link.
    @Test("Engine assets no longer resolve to a container path")
    func engineAssetsResolveThroughABookmark() throws {
        let library = try Self.source("LiveWallpaper/Infrastructure/Assets/WPEEngineAssetsLibrary.swift")
        #expect(!library.contains("func managedContainerRoot"))
        #expect(library.contains("func sharedLibraryInstallRoot"))
        #expect(library.contains("func adoptManagedInstall"))
    }

    /// Downloads used to build an in-process SteamCMD script; that path must stay gone.
    @Test("Workshop download no longer builds an in-process SteamCMD script")
    @MainActor
    func downloadGateMatchesReality() throws {
        let doctor = try Self.source(Self.appSources[0])
        #expect(!doctor.contains("SteamCMDScriptWriter.downloadItemScript"))
    }

    /// `SteamConnector.swift` is only compiled into the XPC target, so the gate
    /// wiring is pinned at source level: every entry point that spawns SteamCMD
    /// must get the path from `resolvedExecutablePath()` — the connector's own
    /// candidate list — and the probe runner must pass its argv through the
    /// allowlist.
    ///
    /// This replaced a digest gate that could not hold: the app supplied both
    /// the path and the digest it was compared against, so naming its own file
    /// passed. Deriving the path is the gate now.
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
            // Counted, not just present: `installWallpaperEngineAssets` spawns
            // twice and once only the first was gated, which a `contains` check
            // reported as covered.
            // `probeCachedLogin` spawns through a helper, so the floor of one
            // resolution covers it; the per-spawn count catches a second inline
            // spawn riding the first one's path across a long-running run.
            let spawns = body.components(separatedBy: "Self.runSteamCMD(").count - 1
            let gates = body.components(separatedBy: "Self.resolvedExecutablePath()").count - 1
            #expect(
                gates >= max(1, spawns),
                Comment(rawValue: "\(entryPoint): \(spawns) inline spawn(s) but only \(gates) resolution(s)")
            )
            // The whole point: nothing here may take a path from the caller.
            // Parameter list only — a body runs to the next non-private `func`,
            // so it can swallow the private helper that legitimately takes one.
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

    /// Text from `func <name>(` to the next top-level `func` (or EOF) — enough
    /// resolution to assert what a specific connector entry point calls.
    private static func functionBody(of name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        let tail = source[start.upperBound...]
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        return String(tail[..<end])
    }
}
