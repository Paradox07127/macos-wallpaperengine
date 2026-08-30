import Foundation
import Testing
@testable import LiveWallpaper

/// Install/remove status is instance state, so every surface that starts or
/// renders a managed install has to observe the same coordinator — otherwise
/// one view installs while another reads idle and offers Install again.
@MainActor
@Suite("Managed install coordinator sharing")
struct SteamCMDManagedInstallSharingTests {
    /// One file now, because the three views route their installs through it —
    /// which is the strongest form of what this test was asserting.
    private static let consumerViews = [
        "LiveWallpaper/Views/Workshop/Setup/WorkshopSetupController.swift"
    ]

    @Test("Every consumer view observes the shared coordinator, not its own")
    func consumersUseSharedInstance() throws {
        #expect(SteamCMDManagedInstallCoordinator.shared === SteamCMDManagedInstallCoordinator.shared)
        for path in Self.consumerViews {
            let source = try RepositoryRoot.source(path)
            #expect(
                !source.contains("SteamCMDManagedInstallCoordinator()"),
                Comment(rawValue: "\(path) constructs a private coordinator; its status diverges from the shared one")
            )
            #expect(
                source.contains("SteamCMDManagedInstallCoordinator.shared"),
                Comment(rawValue: "\(path) no longer references the shared coordinator")
            )
        }
    }
}

/// Native Browse only needs a Steam Web API key; SteamCMD is a download-time
/// requirement. The Installed empty state must not hide Browse Online behind
/// the SteamCMD doctor probes.
@Suite("Installed empty state browse entry")
struct InstalledEmptyStateBrowseEntryTests {
    @Test("Browse Online is offered without consulting SteamCMD state")
    func browseEntryIgnoresSteamCMD() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/InstalledView.swift")
        let marker = "private var emptyStatePrimaryAction"
        let start = try #require(source.range(of: marker), "emptyStatePrimaryAction no longer exists; retarget this test")
        let end = try #require(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        // Control: the entry itself is still produced by this property.
        #expect(body.contains("Browse Online"))
        #expect(
            !body.contains("doctor."),
            Comment(rawValue: "Browse Online is gated on SteamCMD doctor state, but browsing only needs the Web API key")
        )
    }
}
