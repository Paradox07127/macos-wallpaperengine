#if DEBUG
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("QA full library", .serialized)
@MainActor
struct QAControlPlaneLibraryTests {
    @Test("Read-only catalog exposes unmarked content and opaque Aerial IDs without probing or migration")
    func readOnlyCatalog() throws {
        let saved = WallpaperBookmark(label: "Saved", content: .video(bookmarkData: Data("saved-grant".utf8)))
        let aerial = AerialAsset(id: "sky", url: URL(fileURLWithPath: "/private/secret/sky.mov"), displayName: "Sky", category: nil, fileSize: nil, bookmarkData: Data("aerial-grant".utf8))
        var mutations = 0
        var probes = 0
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { [saved] }
        inputs.aerials = { .init(assets: [aerial]) }
        inputs.remapLibraryBookmark = { _, _ in mutations += 1 }
        inputs.sourceAvailable = { _ in probes += 1; return true }
        inputs.removeOrphanCovers = { _ in mutations += 1 }
        inputs.scanAerials = { mutations += 1 }
        let entries = try QALibraryCatalog.entries(inputs: inputs)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { !$0.bookmarked })
        let json = try JSONSerialization.data(withJSONObject: QALibraryCatalog.list(entries, arguments: [:]))
        let text = try #require(String(bytes: json, encoding: .utf8))
        #expect(!text.contains("/private/secret"))
        #expect(!text.contains("aerial-grant"))
        #expect(!text.contains("saved-grant"))
        #expect(mutations == 0 && probes == 0)
        #expect(try QALibraryCatalog.list(entries, arguments: ["bookmarked": true])["total"] as? Int == 0)
        #expect(try QALibraryCatalog.list(entries, arguments: ["source": "aerial"])["total"] as? Int == 1)
    }

    @Test("Pagination rejects changed content, filters, malformed limits and unknown fields")
    func pagination() throws {
        var saved = (0 ..< 3).map { WallpaperBookmark(label: "Item \($0)", content: .video(bookmarkData: Data([UInt8($0)]))) }
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { saved }
        let entries = try QALibraryCatalog.entries(inputs: inputs)
        let page = try QALibraryCatalog.list(entries, arguments: ["limit": 1])
        let cursor = try #require(page["nextCursor"] as? String)
        let next = try QALibraryCatalog.list(entries, arguments: ["cursor": cursor, "limit": 2])
        #expect(next["count"] as? Int == 2)
        #expect(next["nextCursor"] is NSNull)
        #expect(throws: (any Error).self) { try QALibraryCatalog.list(entries, arguments: ["cursor": cursor, "query": "different"]) }
        saved.removeLast()
        #expect(throws: (any Error).self) { try QALibraryCatalog.list(QALibraryCatalog.entries(inputs: inputs), arguments: ["cursor": cursor]) }
        for arguments: [String: Any] in [["limit": true], ["limit": 1.5], ["limit": 201], ["type": "web"], ["unknown": 1]] {
            #expect(throws: (any Error).self) { try QALibraryCatalog.list(entries, arguments: arguments) }
        }
    }

    #if !LITE_BUILD
    @Test("Projection keeps tuned variants, folds plain saves and logically moves marks without writing")
    func workshopProjection() {
        let origin = origin("123", type: .scene)
        let descriptor = SceneDescriptor(workshopID: "123", cacheRelativePath: "wpe-cache/123", entryFile: "scene.json", capabilityTier: .imageOnly)
        let plain = WallpaperBookmark(label: "Plain", content: .scene(descriptor), wpeOrigin: origin)
        let tuned = WallpaperBookmark(label: "Tuned", content: .scene(descriptor.withPropertyOverrides(["gain": .number(0.5)])), wpeOrigin: origin)
        var writes = 0
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { [plain, tuned] }
        inputs.history = { [WPEHistoryEntry(origin: origin, importedAt: .distantPast)] }
        inputs.libraryBookmarks = { ["bookmark:\(plain.id)"] }
        inputs.remapLibraryBookmark = { _, _ in writes += 1 }
        let snapshot = SavedLibraryModel.catalogSnapshot(inputs: inputs)
        #expect(snapshot.items.count == 2)
        #expect(snapshot.bookmarkedIDs == ["workshop:123"])
        #expect(snapshot.items.first { $0.title == "Tuned" }?.parentID == "workshop:123")
        #expect(snapshot.items.first { $0.title == "Tuned" }?.source == .bookmark(tuned))
        #expect(writes == 0)
    }

    @Test("Unmarked installed scene/video/web route through installed intents and retry IDs do not apply twice", arguments: [WPEType.scene, .video, .web])
    func unmarkedWorkshopApply(_ type: WPEType) async throws {
        let fixture = Fixture(capabilities: .pro)
        defer { fixture.close() }
        let entry = WPEHistoryEntry(origin: origin("123", type: type), importedAt: .distantPast)
        var inputs = SavedLibraryModel.Inputs()
        inputs.history = { [entry] }
        fixture.control.libraryInputs = inputs
        var calls = 0
        fixture.control.libraryApply = { intent, _ in
            guard case let .installedWorkshop(actual) = intent else { Issue.record("Did not route installed content"); return .init(outcome: .failed(.unrecognizedDrop), exitedSpanMode: false) }
            #expect(actual == entry)
            calls += 1
            await Task.yield()
            return .init(outcome: .failed(.sourceMissing), exitedSpanMode: false)
        }
        let catalog = try QALibraryCatalog.entries(inputs: inputs)
        let item = try #require(catalog.first)
        #expect(!item.bookmarked)
        let arguments: [String: Any] = ["itemID": item.id, "screenID": fixture.screen.id, "expectedItemRevision": item.revision, "requestID": "retry"]
        let accepted = try await fixture.call("wallpaper.applyLibraryItem", arguments)
        let operationID = try #require(accepted["operationID"] as? String)
        let duplicate = try await fixture.call("wallpaper.applyLibraryItem", arguments)
        #expect(duplicate["operationID"] as? String == operationID)
        let completed = try await fixture.call("operation.wait", ["operationID": operationID, "timeoutMs": 1000])
        #expect(completed["status"] as? String == "failed")
        #expect((completed["result"] as? [String: Any])?["code"] as? String == "source.missing")
        #expect(calls == 1)
        #expect(try await fixture.call("wallpaper.applyLibraryItem", arguments)["operationID"] as? String == operationID)
        #expect(calls == 1)
    }

    private func origin(_ id: String, type: WPEType) -> WPEOrigin {
        WPEOrigin(workshopID: id, title: "Installed \(id)", originalType: type, sourceFolderBookmark: Data("grant".utf8), cacheRelativePath: "wpe-cache/\(id)", previewFileName: nil)
    }
    #endif

    @Test("Missing local source fails through the real product router without creating content or changing the screen")
    func missingSource() async throws {
        let fixture = Fixture(capabilities: .lite)
        defer { fixture.close() }
        let bookmark = WallpaperBookmark(label: "Unavailable", content: .video(bookmarkData: Data("not-a-grant".utf8)))
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { [bookmark] }
        fixture.control.libraryInputs = inputs
        let item = try #require(QALibraryCatalog.entries(inputs: inputs).first)
        let before = fixture.manager.configurationRevision(for: fixture.screen)
        let accepted = try await fixture.call("wallpaper.applyLibraryItem", ["screenID": fixture.screen.id, "itemID": item.id])
        let result = try await fixture.call("operation.wait", ["operationID": #require(accepted["operationID"] as? String), "timeoutMs": 1000])
        #expect(result["status"] as? String == "failed")
        #expect(fixture.manager.configurationRevision(for: fixture.screen) == before)
        #expect(fixture.screen.runtimeSession == nil)
    }

    @Test("Changing a source revision after listing rejects the apply before dispatch")
    func staleRevision() async throws {
        let fixture = Fixture(capabilities: .lite)
        defer { fixture.close() }
        var saved = WallpaperBookmark(label: "Old", content: .video(bookmarkData: Data([1])))
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { [saved] }
        fixture.control.libraryInputs = inputs
        let old = try #require(QALibraryCatalog.entries(inputs: inputs).first)
        saved.content = .video(bookmarkData: Data([2]))
        let response = try await fixture.control.respond(to: request("wallpaper.applyLibraryItem", ["screenID": fixture.screen.id, "itemID": old.id, "expectedItemRevision": old.revision]))
        #expect(response.contains("Library item changed"))
        #expect(!response.contains("operationID"))
    }

    @Test("Full schemas expose typed inputs, required fields and bounded wait")
    func schemas() throws {
        let tools = QAControlPlane.libraryToolDescriptions
        let apply = try #require(tools.first { $0["name"] as? String == "wallpaper.applyLibraryItem" })
        let schema = try #require(apply["inputSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["screenID", "itemID"])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(apply["outputSchema"] != nil)
        #expect(JSONSerialization.isValidJSONObject(tools))
    }

    @Test("An empty-display checkpoint restores through the product clear path and refuses stale revisions")
    func emptyCheckpointRestore() async throws {
        let fixture = Fixture(capabilities: .lite)
        defer { fixture.close() }
        let before = fixture.manager.configurationRevision(for: fixture.screen)
        let captured = try await fixture.call("screen.checkpoint", ["screenID": fixture.screen.id])
        #expect(fixture.manager.configurationRevision(for: fixture.screen) == before)
        let token = try #require(captured["checkpointID"] as? String)
        #expect(fixture.control.screenCheckpoints[token]?.configuration == nil)
        var changed = ScreenConfiguration(screenID: fixture.screen.id, videoBookmarkData: Data("test".utf8))
        changed.displayFingerprint = fixture.screen.displayFingerprint
        fixture.manager.saveConfiguration(changed)
        let wrong = try await fixture.control.respond(to: request("screen.restoreCheckpoint", ["checkpointID": token, "expectedConfigurationRevision": before]))
        #expect(wrong.contains("restore refused"))
        let current = fixture.manager.configurationRevision(for: fixture.screen)
        let accepted = try await fixture.call("screen.restoreCheckpoint", ["checkpointID": token, "expectedConfigurationRevision": current])
        let restored = try await fixture.call("operation.wait", ["operationID": #require(accepted["operationID"] as? String), "timeoutMs": 1000])
        #expect(restored["status"] as? String == "completed")
        #expect(fixture.manager.getConfiguration(for: fixture.screen) == nil)
        _ = try await fixture.call("screen.releaseCheckpoint", ["checkpointID": token])
        #expect(fixture.control.screenCheckpoints.isEmpty)
    }

    private func request(_ tool: String, _ arguments: [String: Any]) throws -> String {
        try #require(String(bytes: JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments]), encoding: .utf8))
    }

    @MainActor
    private final class Fixture {
        let screen = Screen(nsScreen: QALibraryTestScreen())
        let manager: ScreenManager
        let control: QAControlPlane

        init(capabilities: ProductCapabilities) {
            manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false, startAutomation: false,
                powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
                featureCatalog: FeatureCatalog(capabilities: capabilities), originReconciler: PreservingOriginReconciler()
            ))
            control = QAControlPlane(screenManager: manager)
        }

        func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let line = try #require(String(bytes: JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments]), encoding: .utf8))
            let response = await control.respond(to: line)
            let envelope = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            #expect(envelope["ok"] as? Bool == true, "\(response)")
            return try #require(envelope["result"] as? [String: Any])
        }

        func close() {
            control.applyOperations.shutdown()
            manager.tearDownForTermination()
            manager.configurationStore.remove(for: screen.id)
        }
    }
}

private final class QALibraryTestScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xEDFA_00AB)]
    }

    override var localizedName: String {
        "QA library test"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}
#endif
