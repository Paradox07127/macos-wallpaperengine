import AppKit
import LiveWallpaperCore
import SwiftUI

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

    private static let canvasSpace = "musicPreviewCanvas"

    var body: some View {
        Group {
            switch kind {
            case .monitor:
                if screenManager.monitorOverlay(for: screen).enabled {
                    BoardPreviewArea(
                        screen: screen,
                        screenManager: screenManager,
                        backdrop: backdrop
                    )
                } else {
                    OverlayPreviewCanvas(screen: screen, backdrop: backdrop) {
                        OverlayOffNotice(text: "Widgets are off for this display")
                    }
                }
            case .weather:
                OverlayPreviewCanvas(screen: screen, backdrop: backdrop) {
                    weatherLayer
                }
            case .clock:
                OverlayPreviewCanvas(screen: screen, backdrop: backdrop) {
                    ClockOverlayPreview(screen: screen, screenManager: screenManager)
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
        let music = screenManager.monitorOverlay(for: screen).music
        if music.enabled {
            // 1 Hz tick drives the widget's own progress interpolation; 3600 parks it
            // while dragging, since a rebuild mid-gesture restarts the layout the drag reads.
            TimelineView(.periodic(from: .now, by: isDraggingMusicLayer ? 3600 : 1)) { timeline in
                musicWidgetPreview(music: music, now: timeline.date)
                    .overlay(alignment: .topLeading) { nowPlayingReadout }
                    // Full track key, not `trackID`: Apple Music reports no ID, so keying on it
                    // would never change and the preview would keep the first track's artwork.
                    .task(id: NowPlayingArtworkFetcher.trackKey(
                        for: NowPlayingMonitor.shared.currentState
                    )) {
                        await loadCachedArtwork()
                    }
            }
        } else {
            OverlayOffNotice(text: "Music is off for this display")
        }
    }

    /// Never hit-testable — the layer under it is draggable.
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

    /// Sized by the same geometry the board uses (`referenceWidth` = this display's
    /// width), so the preview is WYSIWYG with the Monitor page.
    private func musicWidgetPreview(music: MusicOverlayConfiguration, now: Date) -> some View {
        GeometryReader { geo in
            let geometry = MonitorBoardGeometry(
                boardSize: geo.size,
                referenceWidth: max(screen.frame.width, 1),
                safeArea: MonitorSafeAreaInsets.of(screen.nsScreen)
            )
            let cells = MusicOverlayLayout.cells(for: music.size)
            let footprint = geometry.pixelSize(columns: cells.columns, rows: cells.rows)
            // Clamped into the safe area exactly as the desktop layer is, or a tile at
            // the edge lands under the menu bar or the Dock.
            let raw = CGRect(
                origin: geometry.clampOrigin(
                    CGPoint(x: music.x * geo.size.width, y: music.y * geo.size.height),
                    footprint: footprint
                ),
                size: footprint
            )
            let rect = geometry.renderRect(forRawRect: raw)
            ZStack {
                NowPlayingWidgetView(context: musicPreviewContext(music: music, now: now))
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
            .gesture(musicDragGesture(music: music, footprint: footprint, canvas: geo.size, geometry: geometry))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Drag to move the Music layer"))
            .position(
                x: rect.midX + musicDragTranslation.width,
                y: rect.midY + musicDragTranslation.height
            )
        }
        .coordinateSpace(name: Self.canvasSpace)
        .environment(\.monitorSuspended, true)
    }

    private func musicDragGesture(
        music: MusicOverlayConfiguration,
        footprint: CGSize,
        canvas: CGSize,
        geometry: MonitorBoardGeometry
    ) -> some Gesture {
        // `.named` on the canvas, never `.local`: `.position` moves this very view,
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
                let dropped = geometry.clampOrigin(
                    CGPoint(
                        x: music.x * canvas.width + value.translation.width,
                        y: music.y * canvas.height + value.translation.height
                    ),
                    footprint: footprint
                )
                let x = dropped.x / canvas.width
                let y = dropped.y / canvas.height
                let current = screenManager.monitorOverlay(for: screen).music
                let next = MusicOverlayLayout.setting(x: x, y: y, on: current)
                if next != current {
                    screenManager.setMusicOverlay(next, for: screen)
                }
            }
    }

    private func musicPreviewContext(music: MusicOverlayConfiguration, now: Date) -> MusicOverlayContext {
        let live = NowPlayingMonitor.shared.currentState
        var state = live.title.isEmpty ? Self.sampleNowPlayingState : live
        // The monitor never carries artwork (attached downstream), so borrow the
        // fetcher's copy or the preview shows no cover where the desktop does.
        if state.artwork == nil, let key = NowPlayingArtworkFetcher.trackKey(for: state) {
            state.artwork = previewArtwork[key]
        }
        var snapshot = MonitorSnapshot()
        snapshot.nowPlaying = state
        return MusicOverlayContext(
            snapshot: snapshot,
            size: music.size,
            options: music.options,
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

    /// Stand-in track when nothing is playing. `positionSampledAt` is re-anchored
    /// on every read so the sample never runs past its duration and freezes full.
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
            OverlayOffNotice(text: "Weather is off for this display")
        } else {
            weatherBadge
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }

    /// Deliberately a static marker, not a particle simulation: a second copy of
    /// the particle system would cost real GPU time for a few seconds of looking.
    private var resolvedWeatherEffect: ParticleEffect {
        WeatherReactivePolicy.resolvedParticleEffect(
            chosen: draft.selectedParticleEffect,
            weatherReactive: draft.effectConfig.weatherReactive,
            weatherEffect: screenManager.weatherService.currentParticleEffect
        )
    }

    private var weatherBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: resolvedWeatherEffect.previewSymbol)
                .font(.callout)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(resolvedWeatherEffect.titleKey)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                if resolvedWeatherEffect == .none {
                    Text("No particles for current weather")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .thumbnailBadgeGlass()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Weather overlay active"))
        .accessibilityValue(Text(resolvedWeatherEffect.titleKey))
    }
}

private extension ParticleEffect {
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
        case .mist: return "cloud.fog"
        case .embers: return "flame"
        case .bubbles: return "bubbles.and.sparkles"
        case .meteors: return "sparkle"
        }
    }
}

struct OverlayOffNotice: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .thumbnailBadgeGlass(opacity: 0.45)
    }
}
