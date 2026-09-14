import Foundation
@testable import LiveWallpaper
import Testing

@Suite("WPE storage inventory: off-main walk, budget, cancellation")
struct WPEStorageInventoryTests {
    @Test("Walks the whole tree when the budget allows it")
    func walksWholeTreeWithinBudget() async throws {
        let directory = try makeFixture(fileCount: 40, bytesPerFile: 16)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inventory = await WPEStorageInventoryScanner.shared.scan(
            roots: WPEStorageInventory.ScanRoots(steamRoot: nil, engineAssetsRoot: directory),
            budget: .max
        )

        #expect(inventory.engineAssetsBytes > 0)
        #expect(inventory.engineAssetsURL == directory)
    }

    @Test("A budget smaller than the tree stops the walk short")
    func budgetStopsTheWalkShort() async throws {
        let directory = try makeFixture(fileCount: 40, bytesPerFile: 16)
        defer { try? FileManager.default.removeItem(at: directory) }
        let roots = WPEStorageInventory.ScanRoots(steamRoot: nil, engineAssetsRoot: directory)

        let full = await WPEStorageInventoryScanner.shared.scan(roots: roots, budget: .max)
        let capped = await WPEStorageInventoryScanner.shared.scan(roots: roots, budget: 10)

        #expect(capped.engineAssetsBytes < full.engineAssetsBytes)
        #expect(capped.engineAssetsBytes > 0, "the budget stopped the walk before it read anything")
    }

    @Test("A cancelled task stops the walk before it reads an entry")
    func cancelledWalkStopsImmediately() async throws {
        let directory = try makeFixture(fileCount: 40, bytesPerFile: 16)
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = Task { () -> UInt64 in
            // Start walking only once cancellation is already visible, so the
            // assertion does not race the enumerator.
            while !Task.isCancelled {
                await Task.yield()
            }
            var visited = 0
            return WPEStoragePaths.allocatedBytes(at: directory, budget: .max, visited: &visited)
        }
        task.cancel()

        #expect(await task.value == 0)
    }

    @Test("A large engine-assets tree does not starve the workshop walk")
    func engineAssetsDoNotStarveProjects() async throws {
        let assets = try makeFixture(fileCount: 40, bytesPerFile: 16)
        defer { try? FileManager.default.removeItem(at: assets) }
        let steamRoot = try makeSteamFixture(projectCount: 2, filesPerProject: 4, bytesPerFile: 16)
        defer { try? FileManager.default.removeItem(at: steamRoot) }

        // Ample for either tree alone, short of their sum.
        let inventory = await WPEStorageInventoryScanner.shared.scan(
            roots: WPEStorageInventory.ScanRoots(steamRoot: steamRoot, engineAssetsRoot: assets),
            budget: 30
        )

        #expect(inventory.engineAssetsBytes > 0)
        #expect(inventory.projects.count == 2, "workshop walk was starved: \(inventory.projects)")
        #expect(inventory.projectsTotalBytes > 0)
    }

    @Test("A symlink as the root still measures the tree behind it")
    func symlinkRootIsMeasured() throws {
        let directory = try makeFixture(fileCount: 4, bytesPerFile: 16)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEStorageInventoryTests-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(WPEStoragePaths.allocatedBytes(at: link) == WPEStoragePaths.allocatedBytes(at: directory))
        #expect(WPEStoragePaths.allocatedBytes(at: link) > 0)
    }

    @Test("A missing engine-assets root yields an empty inventory")
    func missingRootYieldsEmptyInventory() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEStorageInventoryTests-absent-\(UUID().uuidString)", isDirectory: true)

        let inventory = await WPEStorageInventoryScanner.shared.scan(
            roots: WPEStorageInventory.ScanRoots(steamRoot: nil, engineAssetsRoot: missing),
            budget: .max
        )

        #expect(inventory.engineAssetsBytes == 0)
        #expect(inventory.engineAssetsURL == nil)
    }

    /// `steamapps/workshop/content/<appID>/<workshopID>/` is the only shape
    /// `scanProjects` walks, and the id folders must pass `isSafeProjectID`.
    private func makeSteamFixture(
        projectCount: Int, filesPerProject: Int, bytesPerFile: Int
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEStorageInventoryTests-steam-\(UUID().uuidString)", isDirectory: true)
        let content = root.appendingPathComponent(
            "steamapps/workshop/content/\(SteamCMDDoctorService.wallpaperEngineAppID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xCD, count: bytesPerFile)
        for project in 0 ..< projectCount {
            let folder = content.appendingPathComponent("300000000\(project)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0 ..< filesPerProject {
                try payload.write(to: folder.appendingPathComponent("asset-\(index).bin"))
            }
        }
        return root
    }

    private func makeFixture(fileCount: Int, bytesPerFile: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEStorageInventoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xAB, count: bytesPerFile)
        for index in 0 ..< fileCount {
            try payload.write(to: root.appendingPathComponent("file-\(index).bin"))
        }
        return root
    }
}
