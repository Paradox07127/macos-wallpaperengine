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
            }
        }
        .padding(24)
    }

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
