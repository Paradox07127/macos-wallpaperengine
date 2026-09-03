#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

/// What the Workshop page's status bar says about the Steam connection.
@Suite("Workshop connection step state", .serialized)
@MainActor
struct ConnectionStepStateTests {
    private func makeService(function: String = #function) throws -> (SteamCMDDoctorService, UserDefaults) {
        let scratch = try TestScratch.defaultsSuite(
            prefix: "LiveWallpaperTests.ConnectionStepState", function: function
        )
        let service = SteamCMDDoctorService(defaults: scratch.defaults)
        return (service, scratch.defaults)
    }

    /// A bookmark the shared resolver can actually resolve (plain bookmark to a
    /// real folder; the live resolver falls back to plain resolution). The old
    /// `Data([0x01])` stand-in now reads as a broken grant on purpose.
    private func resolvableBookmark() throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionStepState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try dir.bookmarkData()
    }

    /// The reported bug: after Locate found and bound SteamCMD, the bar stayed
    /// amber until the user ran the probes by hand. Nothing had failed — the
    /// cached-login probe simply had not run yet, and "unchecked" was being
    /// read as "failing".
    @Test("A step that has not been checked yet is not a failure")
    func uncheckedStepDoesNotReadAsFailure() throws {
        let (service, _) = try makeService()
        service.workdirBookmarkData = try resolvableBookmark()
        service.binaryPath = "/tmp/steamcmd"
        service.setProbe(.binaryIdentity, status: .green(detail: "ok"))
        service.username = "someone"
        // cachedLogin left at .notRun, exactly as it is right after a Locate.

        #expect(service.accountStepState == .notStarted)
        #expect(service.connectionStepState != .attention)
    }

    /// Reading a step state from a completely unconfigured service returns
    /// before it ever touches `probes`, so the only thing that could register an
    /// Observation dependency is the defaults-backed property in the `guard`.
    /// Those are computed, and `@Observable` does not track computed properties
    /// — the status bar stayed on "not started" for the rest of the session.
    @Test("Configuring the library notifies observers of the step state")
    func libraryStepStateNotifiesWhenConfiguredFromEmpty() async throws {
        let (service, _) = try makeService()
        #expect(service.libraryStepState == .notStarted)

        await confirmation("observer fired") { fired in
            withObservationTracking {
                _ = service.libraryStepState
            } onChange: {
                fired()
            }
            service.workdirBookmarkData = Data([0x01])
        }
    }

    @Test("Binding a binary notifies observers of the step state")
    func binaryStepStateNotifiesWhenBoundFromEmpty() async throws {
        let (service, _) = try makeService()
        #expect(service.binaryStepState == .notStarted)

        await confirmation("observer fired") { fired in
            withObservationTracking {
                _ = service.binaryStepState
            } onChange: {
                fired()
            }
            service.binaryPath = "/tmp/steamcmd"
        }
    }

    @Test("Setting the account notifies observers of the step state")
    func accountStepStateNotifiesWhenSetFromEmpty() async throws {
        let (service, _) = try makeService()
        #expect(service.accountStepState == .notStarted)

        await confirmation("observer fired") { fired in
            withObservationTracking {
                _ = service.accountStepState
            } onChange: {
                fired()
            }
            service.username = "someone"
        }
    }

    /// The relaunch bug: probe results are not persisted, so a binding carried
    /// across launches arrives at `.notRun`. The prominent button was gated on
    /// the strict flag, so an already-installed SteamCMD was greeted with
    /// "Install SteamCMD" — clicking it reinstalls what is already there.
    @Test("A binding carried across launches does not offer to install again")
    func boundBinarySurvivesRelaunchWithoutOfferingInstall() throws {
        let (service, _) = try makeService()
        service.binaryPath = "/tmp/steamcmd"
        // Fresh launch: bound, nothing probed yet.

        #expect(!service.isBinaryReady)          // strict gate still says unverified
        #expect(service.isBinaryPresumedReady)   // the UI still offers "Change"
    }

    @Test("A binary whose identity probe failed does offer to install")
    func failedIdentityProbeOffersInstall() throws {
        let (service, _) = try makeService()
        service.binaryPath = "/tmp/steamcmd"
        service.setProbe(
            .binaryIdentity,
            status: .red(message: "signature mismatch", command: nil)
        )

        // Control: only an actual failure may demote it back to Install.
        #expect(!service.isBinaryPresumedReady)
    }

    @Test("A binary bound but never probed reads as unverified, not broken")
    func boundButUnprobedBinaryIsNotAFailure() throws {
        let (service, _) = try makeService()
        service.binaryPath = "/tmp/steamcmd"

        #expect(service.binaryStepState == .working)
        #expect(service.connectionStepState != .attention)
    }

    @Test("A failing probe is what turns the bar amber")
    func failingProbeReadsAsAttention() throws {
        let (service, _) = try makeService()
        service.workdirBookmarkData = Data([0x01])
        service.binaryPath = "/tmp/steamcmd"
        service.setProbe(.binaryIdentity, status: .red(message: "not Valve's binary", command: nil))

        #expect(service.binaryStepState == .attention)
        #expect(service.connectionStepState == .attention)
    }

    @Test("All three steps green is the only way to read ready")
    func allStepsGreenReadsAsReady() throws {
        let (service, _) = try makeService()
        service.workdirBookmarkData = try resolvableBookmark()
        service.binaryPath = "/tmp/steamcmd"
        service.setProbe(.binaryIdentity, status: .green(detail: "ok"))
        service.username = "someone"
        service.setProbe(.cachedLogin, status: .green(detail: "someone"))

        #expect(service.connectionStepState == .ready)
    }

    /// Deliberate rewrite of what this test used to pin: a one-byte fake
    /// bookmark used to read as Ready because only the bytes were checked.
    /// Bytes that no longer resolve are the "Not authorized + Ready badge"
    /// contradiction — the badge must say attention.
    @Test("Green probes cannot outrank a library grant that no longer resolves")
    func unresolvableLibraryGrantIsNotReady() throws {
        let (service, _) = try makeService()
        service.workdirBookmarkData = Data([0x01])
        service.binaryPath = "/tmp/steamcmd"
        service.setProbe(.binaryIdentity, status: .green(detail: "ok"))
        service.username = "someone"
        service.setProbe(.cachedLogin, status: .green(detail: "someone"))

        #expect(service.libraryStepState == .attention)
        #expect(service.connectionStepState == .attention)
    }

    @Test("Nothing set up at all reads as not started")
    func nothingSetUpReadsAsNotStarted() throws {
        let (service, _) = try makeService()

        #expect(service.connectionStepState == .notStarted)
    }
}
#endif
