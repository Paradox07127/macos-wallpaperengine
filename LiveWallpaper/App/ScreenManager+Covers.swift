import AppKit
import Foundation
import LiveWallpaperCore

/// Serializes cover captures per entry.
///
/// A capture is asynchronous and its entry keeps its id across a replace, so two
/// captures for the same id can be in flight at once — and the *older* one can
/// finish last. Without a token the stale frame wins and the cover shows the
/// setup that was just overwritten.
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
    /// Grabs a still of what `screen` is showing and records it as the entry's
    /// cover, once the capture comes back.
    ///
    /// Detached from the save on purpose: a scene has to present a frame and a
    /// web view has to be snapshotted, which takes long enough that making the
    /// user wait for it would turn an instant action into a stall. The entry is
    /// saved immediately and shows its computed thumbnail until the cover lands.
    func captureCover(forBookmark id: UUID, from screen: Screen) {
        guard let configuration = getConfiguration(for: screen) else { return }
        let expectedContent = configuration.activeWallpaper
        let token = CoverCaptureGenerations.begin(id)
        Task { @MainActor in
            guard let image = await WallpaperCoverCapture.captureWallpaper(
                screen: screen,
                configuration: configuration
            ) else { return }
            // The display may have moved on to a different wallpaper while the
            // frame was being read; that frame is not this bookmark.
            guard getConfiguration(for: screen)?.activeWallpaper == expectedContent else { return }
            guard CoverCaptureGenerations.claim(token, for: id),
                  BookmarkStore.shared.bookmarks.contains(where: { $0.id == id }) else { return }
            // One expression, no suspension point: the file lands and its name is
            // recorded before anything else — including the orphan sweep, which
            // also runs on this actor — can observe a file no entry names yet.
            BookmarkStore.shared.setCover(
                WallpaperCoverStore.shared.store(image, for: id),
                for: id
            )
        }
    }

    /// The scheme flavour: a scheme restores overlays too, so its cover shows them.
    func captureCover(forScheme id: UUID, from screen: Screen) {
        guard let configuration = getConfiguration(for: screen) else { return }
        let token = CoverCaptureGenerations.begin(id)
        Task { @MainActor in
            guard let image = await WallpaperCoverCapture.captureWithOverlay(
                screen: screen,
                configuration: configuration
            ) else { return }
            guard CoverCaptureGenerations.claim(token, for: id),
                  SchemeStore.shared.schemes.contains(where: { $0.id == id }) else { return }
            SchemeStore.shared.setCover(
                WallpaperCoverStore.shared.store(image, for: id),
                for: id
            )
        }
    }
}
