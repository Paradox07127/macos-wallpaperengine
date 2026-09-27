#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// SwiftUI builds no accessibility tree offscreen, so the toast is found as the pixels its capsule paints
/// over a magenta window.
@MainActor
@Suite("EditDeskToastHost placement", .serialized)
struct EditDeskToastHostPlacementTests {
    @MainActor
    private final class NoBookmarks: BookmarkPersisting {
        func load() -> [WallpaperBookmark] {
            []
        }

        func save(_: [WallpaperBookmark]) {}
    }

    @Test("An Undo toast sits top centre, below the tallest page top bar and in the window's upper half")
    func undoToastSitsTopCentreBelowTheTopBar() async throws {
        let size = CGSize(width: 1040, height: 700)
        let center = EditDeskToastCenter()
        center.post("Applied to Built-in Display", style: .success, undoStepID: UUID())
        let manager = UndoTestManager()
        let bookmarks = BookmarkStore(persistence: NoBookmarks())
        let undo = EditDeskUndoStack(
            manager: manager, router: ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: false), bookmarks: bookmarks
        )
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .standard) {
            Color(nsColor: ProbeRenderer.heroMagenta)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) { EditDeskToastHost(center: center) }
                .environment(undo)
                // Glass does not composite offscreen and blanks the whole cached frame; the fallback draws an opaque capsule.
                .environment(\._accessibilityReduceTransparency, true)
        })
        host.frame = CGRect(origin: .zero, size: size)
        let window = ParkedTestWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try ProbeImage(cgImage: #require(bitmap.cgImage), viewWidth: size.width)

        let toast = try #require(image.boundingBox { !($0.r > 235 && $0.g < 25 && $0.b > 235) }, "the toast painted nothing")
        let topBar = max(DesignTokens.EditDesk.Spacing.topBar, DetailGeometry.topBarHeight)
        #expect(abs(toast.midX - size.width / 2) <= 1, Comment(rawValue: "toast \(toast) is off centre"))
        #expect(toast.minY >= topBar, Comment(rawValue: "toast \(toast) reaches into the \(topBar)pt top bar"))
        #expect(toast.maxY < size.height / 2, Comment(rawValue: "toast \(toast) is not in the upper half"))
    }
}
#endif
