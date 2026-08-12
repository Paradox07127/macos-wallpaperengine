import AppKit
import LiveWallpaperCore
import SwiftUI

/// The display-shaped stage both overlay pages arrange against: a still of what
/// the display is playing, fitted to its aspect ratio, with the page's own layer
/// on top. Extracted from `MonitorBoardPreviewArea` when overlays split into
/// Weather and Monitor pages — otherwise the two pages would each draw their own
/// slightly different rectangle.
struct OverlayPreviewCanvas<Content: View>: View {
    let screen: Screen
    var backdrop: MonitorPreviewBackdrop = .none
    @ViewBuilder var content: () -> Content

    @AppStorage(MonitorPreviewBackdrop.showsWallpaperDefaultsKey) private var showsWallpaper = true
    /// A frame grabbed off the running scene renderer, so the overlay is arranged
    /// over what the display is showing now rather than the project's shipped
    /// preview art. One shot per session — `captureLivePosterFromNextFrame`
    /// waits for a presented frame and reads it back, so it is not free.
    @State private var liveFrame: NSImage?

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fittedSize(in: geo.size, aspect: screenAspect)
            ZStack {
                backdropLayer
                content()
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: liveFrameIdentity) { await captureLiveFrame() }
    }

    /// The display's aspect ratio.
    private var screenAspect: CGFloat {
        let f = screen.frame
        guard f.width > 0, f.height > 0 else { return 16.0 / 9.0 }
        return f.width / f.height
    }

    /// Empty canvas whenever the wallpaper backdrop is off or unavailable, so
    /// the overlay stays legible while the user is arranging it.
    @ViewBuilder
    private var backdropLayer: some View {
        if showsWallpaper, let liveFrame {
            Image(nsImage: liveFrame)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if showsWallpaper, case .still(let image) = backdrop {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            #if !LITE_BUILD
            // Lite never produces `.projectPreview` — Workshop origins are Pro-only.
            if showsWallpaper, case .projectPreview(let url, let bookmark) = backdrop {
                WPEPreviewView(imageURL: url, securityScopedBookmarkData: bookmark)
            } else {
                DesignTokens.Colors.surfaceSunken
            }
            #else
            DesignTokens.Colors.surfaceSunken
            #endif
        }
    }

    /// Re-capture when the display or its running session changes; nil session
    /// (or Lite) leaves this constant so the task never re-runs.
    private var liveFrameIdentity: String {
        #if !LITE_BUILD
        if let session = screen.runtimeSession as? SceneWallpaperSession {
            return "\(screen.id)#\(ObjectIdentifier(session).hashValue)"
        }
        #endif
        return "\(screen.id)#none"
    }

    private func captureLiveFrame() async {
        #if !LITE_BUILD
        guard let session = screen.runtimeSession as? SceneWallpaperSession else {
            liveFrame = nil
            return
        }
        liveFrame = await session.captureLivePosterFromNextFrame()
        #else
        liveFrame = nil
        #endif
    }

    /// The largest box with `aspect` (width/height) that fits within
    /// `available`, i.e. `contentMode: .fit` computed by hand.
    static func fittedSize(in available: CGSize, aspect: CGFloat) -> CGSize {
        guard available.width > 0, available.height > 0, aspect > 0 else { return .zero }
        if available.width / available.height > aspect {
            let height = available.height
            return CGSize(width: height * aspect, height: height)
        } else {
            let width = available.width
            return CGSize(width: width, height: width / aspect)
        }
    }
}
