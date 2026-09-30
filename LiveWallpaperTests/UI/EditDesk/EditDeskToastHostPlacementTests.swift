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

    @Test("The toast's pill height is the page pill's drawn height")
    func navPillHeightMatchesThePill() {
        let pill = NSHostingView(rootView: NavPill(selection: .constant(.home), workshopAvailable: true))
        #expect(pill.fittingSize.height == DesignTokens.EditDesk.Spacing.navPillHeight, Comment(rawValue: "the pill is \(pill.fittingSize.height)pt tall"))
    }

    @Test("An Undo toast sits top centre, just under the top bar's page pill and in the window's upper half")
    func undoToastSitsTopCentreBelowTheTopBar() async throws {
        let center = EditDeskToastCenter()
        center.post("Applied to Built-in Display", style: .success, undoStepID: UUID())
        let manager = UndoTestManager()
        let bookmarks = BookmarkStore(persistence: NoBookmarks())
        let undo = EditDeskUndoStack(
            manager: manager, router: ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: false), bookmarks: bookmarks
        )
        try await withHost(center: center, undo: undo) { host in
            let painted = try await waitUntil { try host.image().boundingBox(Self.isToastPixel) != nil }
            try #require(painted, "the toast painted nothing")
            let toast = try #require(host.image().boundingBox(Self.isToastPixel))
            let pillBottom = (DesignTokens.EditDesk.Spacing.topBar + DesignTokens.EditDesk.Spacing.navPillHeight) / 2
            #expect(abs(toast.midX - host.size.width / 2) <= 1, Comment(rawValue: "toast \(toast) is off centre"))
            #expect(toast.minY >= pillBottom, Comment(rawValue: "toast \(toast) reaches into the page pill ending at \(pillBottom)"))
            #expect(
                toast.minY <= pillBottom + DesignTokens.Spacing.xs + 1,
                Comment(rawValue: "toast \(toast) hangs further below the page pill than \(DesignTokens.Spacing.xs)pt")
            )
            #expect(toast.maxY < host.size.height / 2, Comment(rawValue: "toast \(toast) is not in the upper half"))
        }
    }

    @Test("Two three-line messages retain their full height with background between them")
    func multilineToastsDoNotOverlap() async throws {
        let center = EditDeskToastCenter()
        center.post("Older message, line one\nOlder message, line two\nOlder message, line three", style: .info, persistent: true)
        try await withHost(center: center) { host in
            let painted = try await waitUntil { try Self.toastBands(in: host.image()).count == 1 }
            try #require(painted, "the first message painted nothing")
            let single = try #require(Self.toastBands(in: host.image()).first)
            // This fixture must really be tall enough to distinguish flowing layout from the old 44pt offset.
            #expect(single.count > 44, "the three-line fixture did not exercise a tall toast")

            center.post("Newest message, line one\nNewest message, line two\nNewest message, line three", style: .info, persistent: true)
            let separated = try await waitUntil { try Self.toastBands(in: host.image()).count == 2 }
            try #require(separated, "the two messages form one overlapping band instead of two separate capsules")
            let bands = try Self.toastBands(in: host.image())
            try #require(bands.count == 2)
            #expect(bands.allSatisfy { $0.count >= single.count - 1 }, "one of the messages was compressed or clipped")
            #expect(bands[1].lowerBound - bands[0].upperBound >= 4, "no clear background separates the messages")
        }
    }

    @Test("An already mounted empty host automatically removes a newly posted short-lived toast")
    func mountedHostExpiresPostedToast() async throws {
        let center = EditDeskToastCenter()
        try await withHost(center: center) { host in
            #expect(try host.image().boundingBox(Self.isToastPixel) == nil)
            let id = center.post("Brief status", style: .info, duration: 0.25)
            #expect(center.toasts.contains { $0.id == id })
            let painted = try await waitUntil { try Self.toastBands(in: host.image()).count == 1 }
            try #require(painted, "the posted message never painted")
            let expired = try await waitUntil { center.toasts.isEmpty }
            #expect(expired, "the mounted host did not expire the message without a manual reap")
            let cleared = try await waitUntil { try host.image().boundingBox(Self.isToastPixel) == nil }
            #expect(cleared, "the expired message still paints into the window")
        }
    }

    @Test("Posting an earlier deadline interrupts the host's existing wait without removing the later toast")
    func earlierDeadlineReschedulesMountedHost() async throws {
        let center = EditDeskToastCenter()
        // The host must not wait for this deadline before noticing the second toast. We never sleep for it.
        let later = center.post("Longer status", style: .info, duration: 30)
        try await withHost(center: center) { host in
            let painted = try await waitUntil { try Self.toastBands(in: host.image()).count == 1 }
            try #require(painted, "the later-deadline message did not mount")
            // Let the mounted host enter its initial wait before changing the deadline.
            try await Task.sleep(for: .milliseconds(20))
            let earlier = center.post("Brief status", style: .success, duration: 0.2)
            #expect(center.toasts.contains { $0.id == earlier })
            let bothPainted = try await waitUntil { try Self.toastBands(in: host.image()).count == 2 }
            try #require(bothPainted, "the earlier-deadline message never painted")
            let expired = try await waitUntil { !center.toasts.contains { $0.id == earlier } }
            #expect(expired, "the earlier deadline was left behind the existing 30-second wait")
            #expect(center.toasts.map(\.id) == [later], "rescheduling expired the later message too")
            let oneRemains = try await waitUntil { try Self.toastBands(in: host.image()).count == 1 }
            #expect(oneRemains, "the short-lived message did not leave the rendered stack")
        }
    }

    // MARK: Harness

    @MainActor
    private struct Host {
        let view: NSView
        let size: CGSize

        func image() throws -> ProbeImage {
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try ProbeImage(cgImage: #require(bitmap.cgImage), viewWidth: size.width)
        }
    }

    @MainActor
    private final class MountState {
        var appeared = false
    }

    private func withHost(
        center: EditDeskToastCenter,
        undo: EditDeskUndoStack? = nil,
        _ body: (Host) async throws -> Void
    ) async throws {
        let size = CGSize(width: 1040, height: 700)
        let mounted = MountState()
        let view = NSHostingView(rootView: AppLanguageScope(defaults: .standard) {
            Color(nsColor: ProbeRenderer.heroMagenta)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) { EditDeskToastHost(center: center) }
                .environment(undo)
                // Glass does not composite offscreen; the fallback paints an opaque capsule.
                .environment(\._accessibilityReduceTransparency, true)
                .transaction { $0.disablesAnimations = true }
                .onAppear { mounted.appeared = true }
        })
        view.frame = CGRect(origin: .zero, size: size)
        let window = ParkedTestWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        let appeared = try await waitUntil { mounted.appeared }
        try #require(appeared, "the toast host never appeared")
        await Task.yield()
        try await body(Host(view: view, size: size))
    }

    /// Bounded event-loop polling: returns as soon as the observed result arrives, without a long settling sleep.
    private func waitUntil(_ condition: () throws -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while try !condition() {
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static func isToastPixel(_ color: ProbeColor) -> Bool {
        !(color.r > 235 && color.g < 25 && color.b > 235)
    }

    /// One sample per point along the shared horizontal centre. Opaque capsule backgrounds make each
    /// message one uninterrupted band; the natural magenta gap separates them regardless of text or tint.
    private static func toastBands(in image: ProbeImage) -> [Range<Int>] {
        let x = image.width / 2
        let height = Int(CGFloat(image.height) / image.scale)
        var bands: [Range<Int>] = []
        var start: Int?
        for y in 0 ..< height {
            let pixelY = min(image.height - 1, Int((CGFloat(y) + 0.5) * image.scale))
            if isToastPixel(image.rgb(px: x, pixelY)) {
                if start == nil {
                    start = y
                }
            } else if let first = start {
                bands.append(first ..< y)
                start = nil
            }
        }
        if let first = start {
            bands.append(first ..< height)
        }
        return bands
    }
}
#endif
