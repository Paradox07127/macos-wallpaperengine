import Foundation
import Testing

@Suite("Steam library workdir access contract")
struct WorkdirAccessContractTests {
    /// Call sites that only pass the path along or check that a grant exists; everything else must hold `beginWorkdirAccess()`.
    private static let allowedCallCounts: [String: Int] = [
        "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift": 1,
        "LiveWallpaper/Infrastructure/Workshop/WPEEngineAssetsInstaller.swift": 1,
        "LiveWallpaper/Application/Workshop/WorkshopFolderImportCoordinator.swift": 1,
        "LiveWallpaper/Views/Settings/CacheView+Actions.swift": 1,
        "LiveWallpaper/Views/EditDesk/Library/ModalActions.swift": 1,
    ]

    @Test("Only path-only call sites use the derived workdir URL")
    func derivedWorkdirURLStaysOutOfDiskReads() throws {
        let files = RepositoryRoot.swiftFiles(under: "LiveWallpaper")
        #expect(!files.isEmpty, "Source sweep found no files; the scan is misconfigured, not passing")

        var counts: [String: Int] = [:]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let calls = source.components(separatedBy: "resolveWorkdirURL(").count - 1
            if calls > 0 {
                counts[RepositoryRoot.relativePath(of: file)] = calls
            }
        }

        #expect(
            counts == Self.allowedCallCounts,
            Comment(rawValue: """
            resolveWorkdirURL() call sites changed: \(counts.sorted { $0.key < $1.key }). \
            Its derived URL cannot open the sandbox scope, so reading the library in this process \
            must hold beginWorkdirAccess() and read through access.url until access.end().
            """)
        )
    }
}
