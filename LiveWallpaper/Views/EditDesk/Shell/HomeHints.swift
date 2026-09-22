import LiveWallpaperCore
import SwiftUI

/// The three home-page swipe hints (SCREENS S1/S2/S3). Each one's opacity and offset are pure
/// functions of `progress`, so they cross-fade and drift with the finger instead of popping at a
/// threshold, and the shelf hint rides on the shelf rather than a fixed y.
struct HomeHints: View {
    /// Read per frame in `body` rather than handed in, so a moving gesture invalidates this view
    /// instead of the whole page.
    let stage: EditDeskStageModel

    /// Chevrons lean toward the state they take you to as the gesture gets closer to it.
    private static let drift: CGFloat = 10

    static func hiddenHintOpacity(_ progress: Double) -> Double {
        1 - ramp(progress, from: 0, to: 0.18)
    }

    static func shelfHintOpacity(_ progress: Double) -> Double {
        ramp(progress, from: 0.12, to: 0.45) * (1 - ramp(progress, from: 1.15, to: 1.45))
    }

    static func libraryHintOpacity(_ progress: Double) -> Double {
        ramp(progress, from: 1.35, to: 1.75)
    }

    /// Smoothstep so the fades start and finish gently instead of switching on.
    static func ramp(_ value: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return value >= end ? 1 : 0 }
        let t = min(max((value - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        let progress = stage.progress
        ZStack {
            hint("⌃ Wallpaper Library", opacity: Self.hiddenHintOpacity(progress))
                .offset(y: -Self.drift * Self.ramp(progress, from: 0, to: 0.18))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 14)

            hint("⌃ Keep Swiping · Full Wallpaper Library", opacity: Self.shelfHintOpacity(progress))
                .offset(
                    y: Self.shelfHintTop(progress: progress, windowSize: stage.stageSize)
                        - Self.drift * Self.ramp(progress, from: 1, to: 1.5)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            hint("⌄ Swipe Down to Return Home", opacity: Self.libraryHintOpacity(progress))
                .offset(y: Self.drift * (1 - Self.ramp(progress, from: 1.35, to: 1.75)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, StageGeometry.topBarHeight)
        }
        .font(DesignTokens.EditDesk.Typography.chip)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
        .allowsHitTesting(false)
    }

    /// Sits one line above the card row's *current* top, so it rises with the shelf instead of
    /// waiting at the shelf's resting y for the cards to reach it.
    static func shelfHintTop(progress: Double, windowSize: CGSize) -> CGFloat {
        max(
            StageGeometry.topBarHeight,
            StageGeometry.shelfRowTop(progress: progress, windowSize: windowSize)
                - StageGeometry.chipRowGap - 34
        )
    }

    private func hint(_ key: LocalizedStringKey, opacity: Double) -> some View {
        Text(key)
            .opacity(opacity)
    }
}
