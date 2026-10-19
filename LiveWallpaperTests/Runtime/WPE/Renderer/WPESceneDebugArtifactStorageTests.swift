#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Shared scene debug artifact storage")
struct WPESceneDebugArtifactStorageTests {
    @Test func disabledArtifactsWriteNothingAndExistingFilesAreNeverOverwritten() throws {
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        let folder = try #require(artifacts.beginSession(workshopID: UUID().uuidString, descriptor: "raw storage"))
        defer { artifacts.endSession(); try? FileManager.default.removeItem(at: folder) }
        let bytes = Data([204, 51, 153, 96, 128, 129, 64, 96])
        artifacts.setEnabledForTesting(false)
        #expect(try artifacts.recordPassOutputBytes(name: "disabled.rgba8", bytes: bytes, sessionFolder: folder) == nil)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.allSatisfy { $0.pathExtension != "rgba8" })
        artifacts.setEnabledForTesting(true)
        let path = try #require(try artifacts.recordPassOutputBytes(name: "exclusive.rgba8", bytes: bytes, sessionFolder: folder))
        #expect(throws: (any Error).self) {
            _ = try artifacts.recordPassOutputBytes(name: "exclusive.rgba8", bytes: Data([0]), sessionFolder: folder)
        }
        #expect(try Data(contentsOf: path) == bytes)
        #expect(try artifacts.recordPassOutputBytes(name: "foreign.rgba8", bytes: bytes,
                                                    sessionFolder: folder.deletingLastPathComponent()) == nil)
        for name in ["../scene.pkg", "..\\scene2.pkg", "/absolute/scene3.pkg"] {
            let path = try #require(try artifacts.recordPassOutputBytes(name: name, bytes: bytes, sessionFolder: folder))
            #expect(path.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            #expect(try Data(contentsOf: path) == bytes)
        }
        artifacts.endSession()
        #expect(try artifacts.recordPassOutputBytes(name: "closed.rgba8", bytes: bytes, sessionFolder: folder) == nil)
    }

    @Test func sameWorkshopSessionsNeverReuseADirectory() throws {
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        let id = UUID().uuidString
        let first = try #require(artifacts.beginSession(workshopID: id, descriptor: "first"))
        let second = try #require(artifacts.beginSession(workshopID: id, descriptor: "second"))
        defer {
            artifacts.endSession()
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        #expect(first != second)
        let current = try #require(try artifacts.recordPassOutputBytes(name: "current.rgba8", bytes: Data([1]), sessionFolder: second))
        #expect(try Data(contentsOf: current) == Data([1]))
        #expect(try artifacts.recordPassOutputBytes(name: "stale.rgba8", bytes: Data([0]), sessionFolder: first) == nil)
        #expect(!FileManager.default.fileExists(atPath: first.appendingPathComponent("stale.rgba8").path))
    }
}
#endif
