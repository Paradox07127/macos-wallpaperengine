import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop local project info")
struct LocalProjectInfoTests {
    /// The bookmark-resolved folder is the enumeration root, and
    /// `FileManager.enumerator(at:)` yields nothing when that root is a symlink.
    @Test("A symlink as the project folder still sums the files behind it")
    func symlinkFolderIsMeasured() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        #expect(directorySize(of: fixture.link) == directorySize(of: fixture.directory))
        #expect(directorySize(of: fixture.link) > 0)
    }

    @Test("A real project folder sums its files")
    func realFolderIsMeasured() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        #expect(directorySize(of: fixture.directory) > 0)
    }

    private func makeFixture() throws -> (directory: URL, link: URL, cleanup: () -> Void) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 64).write(to: directory.appendingPathComponent("scene.pkg"))
        let link = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: directory)
        return (directory, link, {
            try? fileManager.removeItem(at: link)
            try? fileManager.removeItem(at: directory)
        })
    }
}
