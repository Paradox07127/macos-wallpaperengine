import Foundation

private func check(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL: \(message)"); exit(1) }
}

private func drainLifecycle() async {
    await withCheckedContinuation { continuation in WallpaperXPCHandler.queue.async { continuation.resume() } }
}

private struct Fixture {
    let store: SharedLibraryStore
    let registry = SurfaceRegistry()

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loomscreen-retarget-\(UUID().uuidString)", isDirectory: true)
        store = SharedLibraryStore(hostBundleID: "com.loomscreen.retarget-checks", rootOverride: root)
        try FileManager.default.createDirectory(at: store.videosDirectory(), withIntermediateDirectories: true)
    }

    func item(_ id: String, file: String, addedAt: Date) throws -> SystemWallpaperManifest.Item {
        let url = store.videosDirectory().appendingPathComponent(file)
        if url.pathExtension == "scene" {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data([0]).write(to: url)
        }
        return .init(id: id, title: id, fileName: file, addedAt: addedAt)
    }

    /// A surface already serving the selected tile with `item`, as `startPlayback` leaves it.
    func servingSurface(_ item: SystemWallpaperManifest.Item, isPreview: Bool) async -> WallpaperSurface? {
        let registry = registry
        nonisolated(unsafe) var made: WallpaperSurface?
        await withCheckedContinuation { continuation in
            WallpaperXPCHandler.queue.async {
                made = registry.makeSurface(for: UUID())
                made?.choiceID = SystemWallpaperManifest.selectedChoiceID
                made?.isPreview = isPreview
                made?.resolvedItemID = item.id
                made?.publishedAt = item.addedAt
                continuation.resume()
            }
        }
        return made
    }

    func resolvedItemID(of surface: WallpaperSurface) async -> String? {
        nonisolated(unsafe) let surface = surface
        return await withCheckedContinuation { continuation in
            WallpaperXPCHandler.queue.async { continuation.resume(returning: surface.resolvedItemID) }
        }
    }
}

@main struct Probe {
    static func main() async throws {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)

        // A library change must retarget the selected tile even when the Agent holds no connection.
        do {
            let fixture = try Fixture()
            let a = try fixture.item("a", file: "a.mov", addedAt: old)
            let b = try fixture.item("b", file: "b.mov", addedAt: new)
            try fixture.store.writeManifest(.init(version: 1, items: [a, b], selectedItemID: "a"))
            guard let surface = await fixture.servingSurface(a, isPreview: false) else { return check(false, "no surface") }
            try fixture.store.writeManifest(.init(version: 1, items: [a, b], selectedItemID: "b"))
            let bridge = WallpaperXPCBridge(store: fixture.store, registry: fixture.registry)
            bridge.libraryDidChange()
            await drainLifecycle()
            let resolved = await fixture.resolvedItemID(of: surface)
            check(resolved == "b", "selected tile kept playing \(resolved ?? "nil") after the app selected b with no live connection")
            surface.renderer.stopSync()
        }

        // A picker preview that switches from a video to a scene shows the scene's poster and records the scene.
        do {
            let fixture = try Fixture()
            let a = try fixture.item("a", file: "a.mov", addedAt: old)
            let b = try fixture.item("b", file: "b.scene", addedAt: new)
            try fixture.store.writeManifest(.init(version: 1, items: [a, b], selectedItemID: "a"))
            guard let surface = await fixture.servingSurface(a, isPreview: true) else { return check(false, "no surface") }
            try fixture.store.writeManifest(.init(version: 1, items: [a, b], selectedItemID: "b"))
            WallpaperXPCBridge(store: fixture.store, registry: fixture.registry).libraryDidChange()
            await drainLifecycle()
            let resolved = await fixture.resolvedItemID(of: surface)
            check(resolved == "b", "preview switched to a scene but still records \(resolved ?? "nil"), so every library change reseeds it")
            surface.renderer.stopSync()
        }

        print("PASS: provider retarget checks")
    }
}
