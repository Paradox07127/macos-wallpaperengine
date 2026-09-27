import Foundation
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("Managed install coordinator sharing")
struct SteamCMDManagedInstallSharingTests {
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
