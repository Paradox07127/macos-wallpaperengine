#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

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

    /// A bookmark the shared resolver can actually resolve; `Data([0x01])`
    /// elsewhere in this file is a deliberately broken grant.
    private func resolvableBookmark() throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionStepState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try dir.bookmarkData()
    }

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

    @Test("A binding carried across launches does not offer to install again")
    func boundBinarySurvivesRelaunchWithoutOfferingInstall() throws {
        let (service, _) = try makeService()
        service.binaryPath = "/tmp/steamcmd"

        #expect(!service.isBinaryReady)
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

    @Test("A check that ended without a verdict asks for attention and says why")
    func noVerdictReadsAsAttentionWithItsReason() throws {
        let (service, _) = try makeService()
        service.binaryPath = "/tmp/steamcmd"
        let busy = SteamCMDDoctorError.connectorBusy.localizedDescription
        service.setProbe(.binaryIdentity, status: .yellow(message: busy, command: nil))

        #expect(service.binaryStepState == .attention)
        #expect(service.attentionMessage(for: .binaryIdentity) == busy)
        #expect(service.isBinaryPresumedReady, "no verdict offered a reinstall of a binary nothing refused")

        service.setProbe(.binaryIdentity, status: .running)
        #expect(service.binaryStepState == .working)
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
