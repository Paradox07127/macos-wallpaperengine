import Darwin
import Foundation

/// Staleness has its own app tests; this harness isolates the actual picker model and store.
enum ProviderStaleness {
    static func declaredVerdict(store _: SharedLibraryStore) -> SystemWallpaperProviderStaleness.Verdict {
        .current
    }
}

@main struct SelectedWallpaperCheck {
    static func main() throws {
        precondition(dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_LAZY) != nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedLibraryStore(hostBundleID: "fixture", rootOverride: root)
        let settings = SettingsProvider(store: store, providerID: "fixture.wallpaper")
        precondition(SettingsViewModelsEncoder.makeXPCObject(settings.makeViewModels()) != nil, "macOS rejected the picker model")
        let empty = settings.makeViewModels().desktop!.groups[0].items
        precondition(empty.count == 1 && empty[0].choice.identifier == SystemWallpaperManifest.selectedChoiceID)
        try FileManager.default.createDirectory(at: store.videosDirectory(), withIntermediateDirectories: true)
        let a = SystemWallpaperManifest.Item(id: "a", title: "A", fileName: "a.mov", thumbnailFileName: "a.jpg", addedAt: Date())
        let b = SystemWallpaperManifest.Item(id: "b", title: "B", fileName: "b.scene", thumbnailFileName: "b.jpg", addedAt: Date())
        for item in [a, b] {
            try Data([0]).write(to: store.videoURL(for: item))
            try Data([0]).write(to: store.videosDirectory().appendingPathComponent(item.thumbnailFileName!))
        }
        var manifest = SystemWallpaperManifest(version: 1, items: [a, b], selectedItemID: a.id, displaySelections: ["42": a.id, "43": b.id])
        try store.writeManifest(manifest)
        let before = settings.makeViewModels().desktop!.groups[0].items
        precondition(before.count == 1 && before[0].id.id == empty[0].id.id)
        precondition(before[0].choice.id.descriptor.files == [store.videoURL(for: a)])
        manifest.selectedItemID = b.id
        try store.writeManifest(manifest)
        let after = settings.makeViewModels().desktop!.groups[0].items
        precondition(after.count == 1 && after[0].id.id == before[0].id.id)
        precondition(after[0].choice.id.descriptor.files == [store.videoURL(for: b)])
        precondition(store.loadManifest().item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42)?.id == a.id)
        precondition(store.loadManifest().item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 43)?.id == b.id)
        let old = try JSONSerialization.data(withJSONObject: ["version": 1, "items": []])
        let legacy = try JSONDecoder().decode(SystemWallpaperManifest.self, from: old)
        precondition(legacy.displaySelections.isEmpty)
        precondition(SettingsViewModelsEncoder.makeXPCObject(settings.makeViewModels()) != nil)
        print("PASS: native macOS picker-model decoding, stable picker identity, empty-library tile, retargeting, per-display resolution and legacy manifest decoding")
    }
}
