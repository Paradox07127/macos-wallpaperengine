import AppKit
import CoreGraphics
import Foundation
import ImageIO
import IOSurface

private func check(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL: \(message)"); exit(1) }
}

private func isBlack(_ surface: IOSurface) -> Bool {
    surface.lock(options: .readOnly, seed: nil)
    defer { surface.unlock(options: .readOnly, seed: nil) }
    let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
    for row in 0 ..< surface.height {
        for column in 0 ..< surface.width {
            let pixel = bytes + row * surface.bytesPerRow + column * 4
            if pixel[0] > 8 || pixel[1] > 8 || pixel[2] > 8 {
                return false
            }
        }
    }
    return true
}

/// The renderer publishes a displayed pixel buffer only while its layer is composited.
@MainActor private func hostOnScreen(_ layer: CALayer) -> NSWindow {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView?.wantsLayer = true
    window.contentView?.layer = layer
    window.orderFrontRegardless()
    return window
}

/// Polls because the compositor publishes the displayed buffer after the renderer accepts it.
private func displayedFrameIsBlack(_ renderer: WallpaperRenderer, expected: Bool) async -> Bool? {
    var last: Bool?
    for _ in 0 ..< 100 {
        last = renderer.snapshot().map(isBlack)
        if last == expected {
            return last
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return last
}

private func whitePoster(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("white.png")
    guard let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return url
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
    func servingSurface(_ item: SystemWallpaperManifest.Item, isPreview: Bool, displayID: UInt32? = nil) async -> WallpaperSurface? {
        let registry = registry
        nonisolated(unsafe) var made: WallpaperSurface?
        await withCheckedContinuation { continuation in
            WallpaperXPCHandler.queue.async {
                made = registry.makeSurface(for: UUID())
                made?.displayID = displayID
                made?.choiceID = SystemWallpaperManifest.selectedChoiceID
                made?.isPreview = isPreview
                made?.resolvedItemID = item.id
                made?.publishedAt = item.addedAt
                made?.publishedContentIdentity = WallpaperPublishedContentIdentity.read(at: store.videoURL(for: item))
                continuation.resume()
            }
        }
        return made
    }

    func playbackGeneration(of surface: WallpaperSurface, failure: String? = nil) async -> UInt64 {
        nonisolated(unsafe) let surface = surface
        return await withCheckedContinuation { continuation in
            WallpaperXPCHandler.queue.async {
                if let failure {
                    surface.playbackFailure = failure
                }
                continuation.resume(returning: surface.playbackGeneration)
            }
        }
    }

    /// Match the publisher's directory swap while keeping the same manifest item and date.
    func replaceCapsule(_ item: SystemWallpaperManifest.Item) throws {
        let url = store.videoURL(for: item)
        let incoming = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let backup = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let oldIdentity = WallpaperPublishedContentIdentity.read(at: url)
        check(oldIdentity != nil, "fixture cannot observe the original capsule identity")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("new parity capsule".utf8).write(to: incoming.appendingPathComponent("configuration.json"))
        try FileManager.default.moveItem(at: url, to: backup)
        defer { try? FileManager.default.removeItem(at: backup) }
        try FileManager.default.moveItem(at: incoming, to: url)
        let newIdentity = WallpaperPublishedContentIdentity.read(at: url)
        check(newIdentity != nil && newIdentity != oldIdentity, "fixture did not replace the filesystem object")
    }

    /// Writes a heartbeat from the current registry on the lifecycle queue and decodes it back.
    func heartbeat() async -> SystemWallpaperHeartbeat? {
        let registry = registry
        let store = store
        await withCheckedContinuation { continuation in
            WallpaperXPCHandler.queue.async {
                WallpaperXPCHandler.writeActiveHeartbeat(registry: registry, store: store)
                continuation.resume()
            }
        }
        guard let data = try? Data(contentsOf: store.sharedRoot().appendingPathComponent("heartbeat.json")) else { return nil }
        return try? SystemWallpaperCoding.decoder.decode(SystemWallpaperHeartbeat.self, from: data)
    }

    func rate(of surface: WallpaperSurface) async -> Double {
        nonisolated(unsafe) let surface = surface
        return await withCheckedContinuation { continuation in
            WallpaperXPCHandler.queue.async {
                continuation.resume(returning: WallpaperXPCHandler.rate(for: surface, playbackMode: .always))
            }
        }
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
        do {
            try await SceneLifecycleChecks.run()
        } catch {
            print("FAIL: scene lifecycle checks: \(error)")
            exit(1)
        }
        let contractFailures = XPCContractChecks.run()
        for failure in contractFailures {
            print("FAIL: XPC contract: \(failure)")
        }
        check(contractFailures.isEmpty, "XPC contract differs from the system protocols")
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

        // Migration keeps ID/date. A replacement must restart both an already failed and an in-flight/loaded surface,
        // while subsequent unchanged notifications must not retry a failed load or reseed the preview repeatedly.
        for (isPreview, failure) in [(false, nil), (false, "scene.load.failed"), (true, nil)] as [(Bool, String?)] {
            let fixture = try Fixture()
            let item = try fixture.item("same", file: "same.scene", addedAt: old)
            let manifest = SystemWallpaperManifest(version: 1, items: [item], selectedItemID: item.id)
            try fixture.store.writeManifest(manifest)
            guard let surface = await fixture.servingSurface(item, isPreview: isPreview) else { return check(false, "no surface") }
            let before = await fixture.playbackGeneration(of: surface, failure: failure)
            let bridge = WallpaperXPCBridge(store: fixture.store, registry: fixture.registry)
            bridge.libraryDidChange()
            await drainLifecycle()
            await check(fixture.playbackGeneration(of: surface) == before, "unchanged capsule restarted")

            try fixture.replaceCapsule(item)
            bridge.libraryDidChange()
            await drainLifecycle()
            await check(fixture.playbackGeneration(of: surface) == before + 1,
                        "same-ID/date capsule replacement did not restart preview=\(isPreview), failure=\(failure ?? "none")")
            check(fixture.store.loadManifest() == manifest, "retarget mutated user identity/date/selection")
            bridge.libraryDidChange()
            await drainLifecycle()
            await check(fixture.playbackGeneration(of: surface) == before + 1, "unchanged replacement repeatedly restarted")
            surface.renderer.stopSync()
        }

        // Admission timing out is transient: the next policy pass restarts a visible, moving surface, and the app never sees it as a failure.
        do {
            let fixture = try Fixture()
            let a = try fixture.item("a", file: "a.mov", addedAt: old)
            try fixture.store.writeManifest(.init(version: 1, items: [a], selectedItemID: "a"))
            guard let surface = await fixture.servingSurface(a, isPreview: false) else { return check(false, "no surface") }
            let before = await fixture.playbackGeneration(of: surface, failure: "scene.busy")
            let rate = await fixture.rate(of: surface)
            check(rate > 0, "precondition: this machine's power state pauses playback (rate \(rate))")
            WallpaperXPCHandler.reapplyPolicy(registry: fixture.registry, store: fixture.store)
            await drainLifecycle()
            await check(fixture.playbackGeneration(of: surface) == before + 1, "a visible surface stuck on scene.busy was not restarted")
            surface.renderer.stopSync()
        }
        do {
            let fixture = try Fixture()
            let a = try fixture.item("a", file: "a.mov", addedAt: old)
            try fixture.store.writeManifest(.init(version: 1, items: [a], selectedItemID: "a"))
            guard let surface = await fixture.servingSurface(a, isPreview: false) else { return check(false, "no surface") }
            _ = await fixture.playbackGeneration(of: surface, failure: "scene.busy")
            let beat = await fixture.heartbeat()
            check(beat?.playbackFailures?.values.contains("scene.busy") == false, "heartbeat reports a retryable scene.busy as a failure")
            surface.renderer.stopSync()
        }

        // The heartbeat names what the renderer still plays, not the selection it could not switch to.
        do {
            let fixture = try Fixture()
            let a = try fixture.item("a", file: "a.mov", addedAt: old)
            let b = SystemWallpaperManifest.Item(id: "b", title: "b", fileName: "b.mov", addedAt: new)
            try fixture.store.writeManifest(.init(version: 1, items: [a, b], selectedItemID: "b"))
            guard let surface = await fixture.servingSurface(a, isPreview: false) else { return check(false, "no surface") }
            _ = await fixture.playbackGeneration(of: surface, failure: "scene.load.failed")
            let beat = await fixture.heartbeat()
            let active = beat?.activeChoiceIDs ?? []
            check(active.contains("a") && !active.contains("b"), "heartbeat active \(active) while the renderer still plays a")
            check(beat?.playbackFailures == ["a": "scene.load.failed"],
                  "failure filed as \(beat?.playbackFailures ?? [:]) instead of under the playing item a")
            surface.renderer.stopSync()
        }

        // Clearing the display a running surface serves replaces its last frame with black.
        do {
            let fixture = try Fixture()
            let a = try fixture.item("a", file: "a.mov", addedAt: old)
            var manifest = SystemWallpaperManifest(version: 1, items: [a], selectedItemID: "a")
            try fixture.store.writeManifest(manifest)
            guard let surface = await fixture.servingSurface(a, isPreview: false, displayID: 7) else { return check(false, "no surface") }
            let window = hostOnScreen(surface.renderer.layer)
            let poster = try whitePoster(in: fixture.store.videosDirectory())
            surface.renderer.enqueueStill(posterURL: poster, size: CGSize(width: 4, height: 4))
            let seeded = await displayedFrameIsBlack(surface.renderer, expected: false)
            check(seeded == false, "precondition: the seeded last frame never reached the snapshot (\(String(describing: seeded)))")
            manifest.clearedDisplays["7"] = 1
            try fixture.store.writeManifest(manifest)
            WallpaperXPCHandler.retargetSurfaces(registry: fixture.registry, store: fixture.store)
            await drainLifecycle()
            let cleared = await displayedFrameIsBlack(surface.renderer, expected: true)
            check(cleared == true, "cleared display still shows the last frame instead of black (\(String(describing: cleared)))")
            print("PASS: cleared display shows black")
            surface.renderer.stopSync()
            window.orderOut(nil)
        }

        print("PASS: provider retarget checks")
    }
}
