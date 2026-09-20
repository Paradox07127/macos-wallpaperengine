import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// MOTION 10: the chrome follows the hero in rather than arriving with it.
private let detailChromeDelay: TimeInterval = 0.25

/// The top bar's segment selects the wallpaper preview or overlay editing surface.
enum DetailSection: Hashable {
    case wallpaper
    case overlay
}

/// Everything the detail shell hands back out; the host owns the side effects.
struct DetailActions {
    var back: () -> Void
    var selectDisplay: (CGDirectDisplayID) -> Void
    var saveAsScheme: () -> Void
    var applyToAll: () -> Void
    var clearWallpaper: () -> Void
    /// The transport drives the desktop session, not the still hero.
    var playback: (StagePlaybackAction) -> Void
    var recapture: () -> Void
    var openSettings: () -> Void
    var copyOverlays: () -> Void
    var snapEnabled: Binding<Bool>
}

/// GAP_ANALYSIS.md §8.2 layout B: backdrop, top bar, the still hero with its HUD on the left and a
/// resident inspector column on the right. Both the HUD's controls and the inspector arrive from
/// the host, which owns the draft they write through.
@MainActor
struct DisplayDetail<HUD: View, Inspector: View, Overlay: View>: View {
    let displayName: String
    let tags: [DetailDisplayTag]
    let hero: DetailHeroStatus
    let heroImage: CGImage?
    let backdropImage: CGImage?
    /// The stage's own `bounds.size`. A `GeometryReader` here would measure one title bar short.
    let windowSize: CGSize
    @Binding var section: DetailSection
    /// The host flips this once the stage's tile has flown into the hero's box (MOTION 10).
    let heroVisible: Bool
    let actions: DetailActions
    @ViewBuilder let hud: () -> HUD
    @ViewBuilder let inspector: () -> Inspector
    let overlayLogicalSize: CGSize
    @ViewBuilder let overlayCanvas: (CGSize) -> Overlay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chromeVisible = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            if section == .overlay {
                canvasLayer
            } else {
                heroLayer(DetailGeometry.heroFrame(in: windowSize))
            }
            inspectorLayer
            topBarLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: heroVisible) { await revealChrome() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: displayName))
    }

    // MARK: Layers

    private var backdrop: some View {
        ZStack {
            DesignTokens.EditDesk.Colors.background
            DetailBackdrop(cover: backdropImage)
        }
        // The stage's flight layer sits under this view: an opaque backdrop would hide the tile in flight.
        .opacity(heroVisible ? 1 : 0)
        .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.25)), value: heroVisible)
    }

    private func heroLayer(_ box: CGRect) -> some View {
        VStack(spacing: DetailGeometry.heroNoteGap) {
            DetailHero(status: hero, image: heroImage, size: box.size, hud: hud)
            stillFrameNote
                .frame(width: box.width, height: DetailGeometry.heroNoteHeight)
        }
        .offset(x: box.minX, y: box.minY)
        .opacity(heroVisible ? 1 : 0)
        // The stage hides its tile in the same transaction; an animated fade shows both or neither.
        .animation(nil, value: heroVisible)
    }

    private var canvasLayer: some View {
        let box = OverlayGeometry.aspectFit(logicalSize: overlayLogicalSize, in: DetailGeometry.heroFrame(in: windowSize))
        return overlayCanvas(box.size)
            .frame(width: box.width, height: box.height)
            .padding(.leading, box.minX)
            .padding(.top, box.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(heroVisible ? 1 : 0)
            .allowsHitTesting(heroVisible)
            .animation(nil, value: heroVisible)
    }

    private var stillFrameNote: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            Text("Preview is a still frame · changes are already live on your desktop")
                .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
            Button("Recapture preview", action: actions.recapture)
                .buttonStyle(.borderless)
        }
        .font(DesignTokens.EditDesk.Typography.metaMono)
        .lineLimit(1)
    }

    private var inspectorLayer: some View {
        inspector()
            .frame(
                width: DetailGeometry.inspectorWidth,
                height: windowSize.height - DetailGeometry.topBarHeight,
                alignment: .top
            )
            .background(DesignTokens.EditDesk.Colors.panel)
            .overlay(alignment: .leading) {
                DesignTokens.EditDesk.Colors.strokePanel.frame(width: 1)
            }
            .offset(x: windowSize.width - DetailGeometry.inspectorWidth, y: DetailGeometry.topBarHeight)
            .opacity(chromeVisible ? 1 : 0)
    }

    private var topBarLayer: some View {
        DetailTopBar(tags: tags, section: $section, actions: actions)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(chromeVisible ? 1 : 0)
    }

    // MARK: Motion

    private func revealChrome() async {
        guard heroVisible else {
            chromeVisible = false
            return
        }
        try? await Task.sleep(for: .seconds(detailChromeDelay))
        guard !Task.isCancelled else { return }
        withAnimation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.25))) {
            chromeVisible = true
        }
    }
}
