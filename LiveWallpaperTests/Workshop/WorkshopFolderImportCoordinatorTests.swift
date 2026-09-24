#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop folder import — queued requests")
@MainActor
struct WorkshopFolderImportCoordinatorTests {
    /// A library whose one project.json does not parse: the project counts as unreadable and nothing
    /// reaches settings.
    private func unreadableLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopFolderImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: project.appendingPathComponent("project.json"))
        return root
    }

    @Test(.timeLimit(.minutes(1)))
    func aFolderDroppedWhileImportingIsQueued() async throws {
        let first = try unreadableLibrary()
        let second = try unreadableLibrary()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let coordinator = WorkshopFolderImportCoordinator()
        let finished = ImportBatchLog()
        coordinator.onLocalLibraryImported = { _ in finished.batches += 1 }

        coordinator.importProjects(from: [first])
        coordinator.importProjects(from: [second])
        #expect(coordinator.isImporting)
        while coordinator.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(finished.batches == 2, "a folder that arrives mid-import must wait its turn, not vanish")
        #expect(coordinator.progress == nil)
    }
}

@MainActor
private final class ImportBatchLog {
    var batches = 0
}
#endif
