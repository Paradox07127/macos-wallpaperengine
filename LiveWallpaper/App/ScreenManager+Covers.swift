import AppKit
import Foundation
import LiveWallpaperCore

/// Serializes cover captures per entry so a stale in-flight capture cannot overwrite a newer one.
@MainActor
enum CoverCaptureGenerations {
    private static var generations: [UUID: UInt64] = [:]

    static func begin(_ id: UUID) -> UInt64 {
        let next = (generations[id] ?? 0) &+ 1
        generations[id] = next
        return next
    }

    /// The counter is kept after a claim: dropping it would reissue token 1 to the next capture while an
    /// older token 1 may still be in flight. One UInt64 per entry ever captured is the whole cost.
    static func claim(_ token: UInt64, for id: UUID) -> Bool {
        generations[id] == token
    }

    static func resetForTesting() {
        generations.removeAll()
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
            // A failed write keeps the cover `replace` preserved; unnaming it would hand the PNG to the orphan sweep.
            guard let fileName = WallpaperCoverStore.shared.store(image, for: id) else { return }
            SchemeStore.shared.setCover(fileName, for: id)
        }
    }
}
