#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Observation
import os
import Testing

struct WPESceneSettingsEditorTests {
    @MainActor
    @Test func numericEditDoesNotPublishUnchangedRows() throws {
        let editor = try makeEditor()
        editor.toggleSection("main")
        let oldRows = editor.rows
        let rowChanged = OSAllocatedUnfairLock(initialState: false)
        let groupsChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = editor.rows } onChange: { rowChanged.withLock { $0 = true } }
        withObservationTracking { _ = editor.expandedSections } onChange: { groupsChanged.withLock { $0 = true } }
        #expect(editor.setValue(.number(0.123), forKey: "gain"))
        #expect(editor.layeredValues["gain"] == .number(0.123))
        #expect(editor.rows == oldRows)
        #expect(!rowChanged.withLock { $0 })
        #expect(!groupsChanged.withLock { $0 })
    }

    @MainActor
    @Test func conditionalRowsStillUpdateAndPreserveHiddenValues() throws {
        let editor = try makeEditor()
        editor.toggleSection("main")
        editor.setValue(.number(0.123), forKey: "gain")
        editor.setValue(.bool(true), forKey: "show")
        #expect(editor.rows.contains { $0.id == "property:detail" })
        editor.setValue(.number(0.456), forKey: "detail")
        editor.setValue(.bool(false), forKey: "show")
        #expect(!editor.rows.contains { $0.id == "property:detail" })
        #expect(editor.overrides["detail"] == .number(0.456))
        editor.toggleSection("main")
        editor.toggleSection("main")
        editor.setValue(.bool(true), forKey: "show")
        #expect(editor.rows.contains { $0.id == "property:detail" })
        #expect(editor.layeredValues["detail"] == .number(0.456))
        #expect(editor.layeredValues["gain"] == .number(0.123))
    }

    @MainActor
    private func makeEditor() throws -> WPESceneCustomSettingsCard.Editor {
        let json = #"{"general":{"properties":{"main":{"type":"group","text":"Main","order":0},"gain":{"type":"slider","text":"Gain","min":0,"max":300,"step":0.001,"value":0,"order":1},"show":{"type":"bool","text":"Show","value":false,"order":2},"detail":{"type":"slider","text":"Detail","value":0,"min":0,"max":1,"condition":"show.value","order":3}}}}"#
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data(json.utf8))
        let editor = WPESceneCustomSettingsCard.Editor()
        editor.load(
            identity: .init(screenID: 1, workshopID: "probe", cacheRelativePath: "probe", entryFile: "scene.json"),
            schema: schema,
            descriptor: SceneDescriptor(workshopID: "probe", cacheRelativePath: "probe", entryFile: "scene.json", capabilityTier: .imageOnly),
            excludedKeys: []
        )
        return editor
    }
}
#endif
