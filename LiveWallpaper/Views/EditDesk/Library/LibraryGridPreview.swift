import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// Hover to play on the library grid, by the shelf's rule: one per grid, so at most one tile plays.
@MainActor
@Observable
final class LibraryGridPreview {
    /// The tile whose `settledHover` last reported the pointer resting on it; nil once it left.
    var settledID: LibraryItem.ID?
    var reduceMotion = false
    /// A tile drag, or a page presented over the grid.
    var obscured = false
    /// Settings → hover to play preview, read whenever a tile asks.
    @ObservationIgnored var autoplayEnabled: () -> Bool = {
        UserDefaults.appScoped().object(forKey: EditDeskPreferences.hoverAutoplayPreview) as? Bool
            ?? EditDeskPreferences.hoverAutoplayPreviewDefault
    }

    @ObservationIgnored var load: @MainActor (WPEOrigin, Int) async -> ShelfPreviewFrames? = { origin, maxPixelSize in
        await ShelfPreviewFrames.load(origin, maxPixelSize: maxPixelSize)
    }

    func settle(_ id: LibraryItem.ID, hovering: Bool) {
        if hovering {
            settledID = id
        } else if settledID == id {
            settledID = nil
        }
    }

    func plays(_ id: LibraryItem.ID, displaysGIF: Bool) -> Bool {
        ShelfPreviewPlayback.plays(
            displaysGIF: displaysGIF, hoverSettled: settledID == id, autoplayEnabled: autoplayEnabled(),
            reduceMotion: reduceMotion, obscured: obscured
        )
    }
}

/// A grid tile's picture: its poster, or while the tile plays, its GIF preview's frames at their own delays.
struct LibraryGridTilePicture: View {
    let poster: CGImage
    let id: LibraryItem.ID
    let thumbnail: LibraryGridTile.Thumbnail
    let preview: LibraryGridPreview?
    /// nil shows the poster.
    @State private var frame: CGImage?

    private var origin: WPEOrigin? {
        thumbnail.request.scenePreviewOrigin
    }

    private var plays: Bool {
        preview?.plays(id, displaysGIF: ShelfPreviewPlayback.displaysGIF(showsPicture: true, previewOrigin: origin)) == true
    }

    var body: some View {
        Image(decorative: frame ?? poster, scale: 1)
            .resizable()
            .scaledToFill()
            .task(id: plays) {
                frame = nil
                let maxPixelSize = Int(max(thumbnail.pixelSize.width, thumbnail.pixelSize.height))
                guard plays, let preview, let origin, let frames = await preview.load(origin, maxPixelSize) else { return }
                var index = 0
                while !Task.isCancelled {
                    frame = frames.images[index]
                    do {
                        try await Task.sleep(for: .seconds(frames.delays[index]))
                    } catch {
                        return
                    }
                    index = (index + 1) % frames.images.count
                }
            }
    }
}
