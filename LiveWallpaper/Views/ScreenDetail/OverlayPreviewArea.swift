import AppKit
import LiveWallpaperCore
import SwiftUI

/// One overlay page's preview. A peer of the wallpaper preview, not one of its
/// type branches — overlays sit *over* whatever wallpaper is playing, so both
/// pages keep the wallpaper as backdrop and layer their own thing on it.
struct OverlayPreviewArea: View {
    let screen: Screen
    let draft: DraftState
    let screenManager: ScreenManager
    let kind: OverlayKind
    let backdrop: MonitorPreviewBackdrop

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Cover art pulled from the fetcher's cache, keyed by track. Cache-only:
    /// the preview never starts a network request of its own.
    @State private var previewArtwork: [String: Data] = [:]
    /// Live drag offset in preview points. Kept in view state so the layer
    /// follows the cursor without a write per frame; only the drop persists.
    @State private var musicDragTranslation: CGSize = .zero
    @State private var isDraggingMusicLayer = false

    /// Stable frame of reference for the layer drag (see the gesture).
    private static let canvasSpace = "musicPreviewCanvas"

    var body: some View {
        Group {
            switch kind {
            case .monitor:
                // The board preview owns drag-to-arrange, and already draws
                // itself on the shared canvas.
                BoardPreviewArea(
                    screen: screen,
                    screenManager: screenManager,
                    backdrop: backdrop
                )
            case .weather:
                OverlayPreviewCanvas(screen: screen, backdrop: backdrop) {
                    weatherLayer
                }
            case .music:
                OverlayPreviewCanvas(screen: screen, backdrop: backdrop) {
                    musicLayer
                }
            }
        }
        .padding(24)
    }

    // MARK: - Music

    @ViewBuilder
    private var musicLayer: some View {
        let overlay = screenManager.monitorOverlay(for: screen)
        // Same predicate as the page's own switch: a board that still carries
        // the layer while Music is off must read as off here too.
        if overlay.musicEnabled,
           let placement = MusicOverlayBoardEditor.nowPlayingPlacement(in: overlay.board) {
            // 1 Hz tick advances `context.now`, which is what drives the
            // widget's own progress interpolation — no .animation needed.
            // Paused while dragging: a rebuild mid-gesture re-runs the layout
            // that the drag is reading from, which reads as a stutter.
            TimelineView(.periodic(from: .now, by: isDraggingMusicLayer ? 3600 : 1)) { timeline in
                musicWidgetPreview(placement: placement, now: timeline.date)
                    // The live readout rides the preview rather than the
                    // inspector list: it describes what is on this canvas, and
                    // over there it read as one more setting row.
                    .overlay(alignment: .topLeading) { nowPlayingReadout }
                    // Full track key, not `trackID`: Apple Music reports no ID
                    // at all, so keying on it never changed and the preview
                    // kept the first track's artwork for the whole session.
                    .task(id: NowPlayingArtworkFetcher.trackKey(
                        for: NowPlayingMonitor.shared.currentState
                    )) {
                        await loadCachedArtwork()
                    }
            }
        } else {
            Text("Music is off for this display")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // Same recipe as the weather page's off state.
                .thumbnailBadgeGlass(opacity: 0.45)
        }
    }

    /// Polled, not subscribed: the listener only pushes on change, and a 2 s
    /// re-read of an in-memory value is cheaper than threading a subscription
    /// down here. Never hit-testable — the layer under it is draggable.
    private var nowPlayingReadout: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            MusicStatusBadge(state: NowPlayingMonitor.shared.currentState, onGlass: true)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .thumbnailBadgeGlass(opacity: 0.55)
        }
        .padding(14)
        .allowsHitTesting(false)
    }

    /// The real widget view, sized and positioned by the same geometry the
    /// board itself uses (`referenceWidth` = this display's width), so the
    /// preview is WYSIWYG with the Monitor page rather than scaled against a
    /// fixed reference board.
    private func musicWidgetPreview(placement: MonitorWidgetPlacement, now: Date) -> some View {
        GeometryReader { geo in
            let geometry = MonitorBoardGeometry(
                boardSize: geo.size,
                referenceWidth: max(screen.frame.width, 1)
            )
            let footprint = geometry.pixelSize(for: .nowPlaying, size: placement.size)
            let raw = CGRect(
                origin: CGPoint(x: placement.x * geo.size.width, y: placement.y * geo.size.height),
                size: footprint
            )
            let rect = geometry.renderRect(forRawRect: raw)
            ZStack {
                NowPlayingWidgetView(context: musicPreviewContext(placement: placement, now: now))
                    // The widget's own layers opt out of hit testing in places,
                    // so the drag rides on a clear sheet over the whole tile.
                    .allowsHitTesting(false)
                Color.clear.contentShape(Rectangle())
            }
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .scaleEffect(isDraggingMusicLayer ? 1.03 : 1)
            .overlay {
                if isDraggingMusicLayer {
                    RoundedRectangle(cornerRadius: geometry.cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .gesture(musicDragGesture(placement: placement, footprint: footprint, canvas: geo.size))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Drag to move the Music layer"))
            .position(
                x: rect.midX + musicDragTranslation.width,
                y: rect.midY + musicDragTranslation.height
            )
        }
        .coordinateSpace(name: Self.canvasSpace)
        // A preview must not run a second copy of the live animations: the
        // audio Canvas and the platter spin both stand down when suspended,
        // mirroring the weather page's refusal to simulate particles here.
        .environment(\.monitorSuspended, true)
    }

    private func musicDragGesture(
        placement: MonitorWidgetPlacement,
        footprint: CGSize,
        canvas: CGSize
    ) -> some Gesture {
        // `.named` on the canvas, never the default `.local`: this gesture is
        // attached to the very view that `.position` moves by the translation,
        // so a view-local origin re-bases every frame and the layer strobes.
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                isDraggingMusicLayer = true
                musicDragTranslation = value.translation
            }
            .onEnded { value in
                isDraggingMusicLayer = false
                musicDragTranslation = .zero
                guard canvas.width > 0, canvas.height > 0 else { return }
                let maxX = max(0, 1 - footprint.width / canvas.width)
                let maxY = max(0, 1 - footprint.height / canvas.height)
                let x = min(max(placement.x + value.translation.width / canvas.width, 0), maxX)
                let y = min(max(placement.y + value.translation.height / canvas.height, 0), maxY)
                let board = screenManager.monitorOverlay(for: screen).board
                let next = MusicOverlayBoardEditor.settingOrigin(x: x, y: y, on: board)
                if next != board {
                    screenManager.setMonitorOverlayBoard(next, for: screen)
                }
            }
    }

    private func musicPreviewContext(placement: MonitorWidgetPlacement, now: Date) -> MonitorWidgetContext {
        let live = NowPlayingMonitor.shared.currentState
        var state = live.title.isEmpty ? Self.sampleNowPlayingState : live
        // The monitor never carries artwork — that is attached downstream by
        // the source — so borrow whatever the fetcher already has for this
        // track; otherwise the desktop shows a cover and the preview doesn't.
        if state.artwork == nil, let key = NowPlayingArtworkFetcher.trackKey(for: state) {
            state.artwork = previewArtwork[key]
        }
        var snapshot = MonitorSnapshot()
        snapshot.nowPlaying = state
        return MonitorWidgetContext(
            snapshot: snapshot,
            history: MonitorHistorySnapshot(),
            placement: placement,
            isEditing: false,
            reduceMotion: reduceMotion,
            now: now
        )
    }

    private func loadCachedArtwork() async {
        let state = NowPlayingMonitor.shared.currentState
        guard let key = NowPlayingArtworkFetcher.trackKey(for: state),
              previewArtwork[key] == nil,
              let data = await NowPlayingArtworkFetcher.shared.cachedArtwork(forKey: key)
        else { return }
        previewArtwork = [key: data]
    }

    /// Stand-in track when nothing real is playing, so style/size edits still
    /// have something to react to. `positionSampledAt` is re-anchored on every
    /// read so the sample never runs past its own duration and freezes full.
    private static var sampleNowPlayingState: MonitorNowPlayingState {
        var state = MonitorNowPlayingState(phase: .playing, title: "Midnight Drive")
        state.artist = "The Neon Coast"
        state.album = "City Lights"
        state.duration = 245
        state.position = 63
        state.positionSampledAt = Date().timeIntervalSince1970
        state.artwork = sampleArtwork
        return state
    }

    /// Drawn once, not shipped as an asset: without a cover the poster style
    /// has nothing to show while vinyl still draws its platter, which reads as
    /// "poster lost its artwork" rather than "this stand-in has no cover".
    private static let sampleArtwork: Data? = {
        let side = 256
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        defer { image.unlockFocus() }
        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.86, green: 0.44, blue: 0.24, alpha: 1),
                NSColor(calibratedRed: 0.25, green: 0.18, blue: 0.42, alpha: 1)
            ]
        )
        gradient?.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: 55)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }()

    @ViewBuilder
    private var weatherLayer: some View {
        if draft.selectedParticleEffect == .none {
            Text("Weather is off for this display")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // Same recipe as the active badge, dialled down: this is the
                // "nothing is running" state, not a live readout.
                .thumbnailBadgeGlass(opacity: 0.45)
        } else {
            weatherBadge
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }

    /// Deliberately a static marker, not a particle simulation. Running a second
    /// copy of the particle system just to fill a preview would cost real GPU
    /// time for a surface the user looks at for a few seconds — and a fake
    /// animation that didn't match the real one would be worse than none.
    private var weatherBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: draft.selectedParticleEffect.previewSymbol)
                .font(.callout)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.selectedParticleEffect.titleKey)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Drawn over the wallpaper")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .thumbnailBadgeGlass()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Weather overlay active"))
        .accessibilityValue(Text(draft.selectedParticleEffect.titleKey))
    }
}

private extension ParticleEffect {
    /// Static stand-in glyph. Only used to mark the overlay in the preview.
    var previewSymbol: String {
        switch self {
        case .none: return "circle.dashed"
        case .snow: return "snowflake"
        case .rain: return "cloud.rain"
        case .bokeh: return "circle.hexagongrid"
        case .fireflies: return "sparkles"
        case .dust: return "aqi.low"
        case .stars: return "star"
        case .fallingLeaves: return "leaf"
        case .sakura: return "camera.macro"
        }
    }
}
