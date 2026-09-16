import AppKit
import Foundation
import LiveWallpaperCore

/// Serializes cover captures per entry so a stale in-flight capture cannot overwrite a newer one.
@MainActor
private enum CoverCaptureGenerations {
    private static var generations: [UUID: UInt64] = [:]

    static func begin(_ id: UUID) -> UInt64 {
        let next = (generations[id] ?? 0) &+ 1
        generations[id] = next
        return next
    }

    /// Clears the entry on the way out so the table cannot grow with the library.
    static func claim(_ token: UInt64, for id: UUID) -> Bool {
        guard generations[id] == token else { return false }
        generations[id] = nil
        return true
    }
}

extension ScreenManager {
    func captureCover(forBookmark id: UUID, from screen: Screen) {
        guard let configuration = getConfiguration(for: screen) else { return }
        let expectedContent = configuration.activeWallpaper
        let token = CoverCaptureGenerations.begin(id)
        Task { @MainActor in
            let image = await WallpaperCoverCapture.captureWallpaper(
                screen: screen,
                configuration: configuration
            )
            // Claim first: a capture that yields nothing must still retire its generation entry.
            guard CoverCaptureGenerations.claim(token, for: id), let image else { return }
            // The display may have moved on to a different wallpaper while the
            // frame was being read; that frame is not this bookmark.
            guard getConfiguration(for: screen)?.activeWallpaper == expectedContent else { return }
            guard BookmarkStore.shared.bookmarks.contains(where: { $0.id == id }) else { return }
            // One expression, no suspension point: the file lands and its name is recorded before the orphan sweep can observe a file no entry names yet.
            BookmarkStore.shared.setCover(
                WallpaperCoverStore.shared.store(image, for: id),
                for: id
            )
        }
    }

    func captureCover(forScheme id: UUID, from screen: Screen) {
        guard let configuration = getConfiguration(for: screen) else { return }
        let expectedContent = configuration.activeWallpaper
        let token = CoverCaptureGenerations.begin(id)
        Task { @MainActor in
            let image = await WallpaperCoverCapture.captureWithOverlay(
                screen: screen,
                configuration: configuration
            )
            guard CoverCaptureGenerations.claim(token, for: id), let image else { return }
            guard getConfiguration(for: screen)?.activeWallpaper == expectedContent else { return }
            guard SchemeStore.shared.schemes.contains(where: { $0.id == id }) else { return }
            SchemeStore.shared.setCover(
                WallpaperCoverStore.shared.store(image, for: id),
                for: id
            )
        }
    }
}
