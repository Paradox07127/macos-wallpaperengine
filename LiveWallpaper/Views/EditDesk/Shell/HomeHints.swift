import LiveWallpaperCore
import SwiftUI

/// The home-page swipe hints (SCREENS S1/S2). Opacity and offset are functions of `progress`, so they
/// cross-fade and drift with the finger; the shelf hint rides on the shelf and also leaves after a dwell there.
struct HomeHints: View {
    /// Read per frame in `body` rather than handed in, so a moving gesture invalidates this view
    /// instead of the whole page.
    let stage: EditDeskStageModel

    /// Chevrons lean toward the state they take you to as the gesture gets closer to it.
    private static let drift: CGFloat = 10

    /// How long the shelf hint stays once the stage rests on the shelf.
    static let shelfHintDwell: TimeInterval = 3
    /// Resting on the shelf means inside this band: a settling spring never lands on exactly 1.
    private static let shelfBand: ClosedRange<Double> = 0.97 ... 1.03

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLibraryHintHovered = false
    /// Set once the dwell runs out; cleared only where the hint's own fade has already hidden it.
    @State private var shelfHintDismissed = false

    static func hiddenHintOpacity(_ progress: Double) -> Double {
        1 - ramp(progress, from: 0, to: 0.18)
    }

    static func shelfHintOpacity(_ progress: Double) -> Double {
        ramp(progress, from: 0.12, to: 0.45) * (1 - ramp(progress, from: 1.15, to: 1.45))
    }

    static func isRestingOnShelf(_ progress: Double) -> Bool {
        shelfBand.contains(progress)
    }

    static func shelfHintShows(restingFor elapsed: TimeInterval) -> Bool {
        elapsed < shelfHintDwell
    }

    /// Outside `shelfHintOpacity`'s fades, so the next arrival shows the hint again without it popping back here.
    static func rearmsShelfHint(_ progress: Double) -> Bool {
        progress < 0.12 || progress > 1.45
    }

    /// Smoothstep so the fades start and finish gently instead of switching on.
    static func ramp(_ value: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return value >= end ? 1 : 0 }
        let t = min(max((value - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        let progress = stage.progress
        let libraryHintOpacity = Self.hiddenHintOpacity(progress)
        ZStack {
            if progress == 0,
               let target = StageGeometry.arrangement(
                   frames: stage.displays.map(\.frame),
                   in: StageGeometry.stageRect(windowSize: stage.stageSize, topInset: stage.arrangementTopInset)
               ).contentRects.first {
                Color.clear
                    .frame(width: target.width, height: target.height)
                    .pageGuideTarget(.display)
                    .position(x: target.midX, y: target.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            Button { stage.setProgress(1, animated: true) } label: {
                hint("⌃ Wallpaper Library", opacity: libraryHintOpacity)
                    .foregroundStyle(isLibraryHintHovered ? DesignTokens.EditDesk.Colors.textPrimary : DesignTokens.EditDesk.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .pageGuideTarget(.shelfHandle)
            .onHover { isLibraryHintHovered = $0 }
            .allowsHitTesting(libraryHintOpacity > ShelfChromeRide.interactiveOpacity)
            .accessibilityHidden(libraryHintOpacity <= ShelfChromeRide.interactiveOpacity)
            .accessibilityLabel(Text("Wallpaper Library"))
            .offset(y: -Self.drift * Self.ramp(progress, from: 0, to: 0.18))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 14)

            hint("⌃ Keep Swiping · Full Wallpaper Library", opacity: shelfHintDismissed ? 0 : Self.shelfHintOpacity(progress))
                .offset(
                    y: Self.shelfHintTop(progress: progress, windowSize: stage.stageSize)
                        - Self.drift * Self.ramp(progress, from: 1, to: 1.5)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
        .font(DesignTokens.EditDesk.Typography.chip)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
        .task(id: Self.isRestingOnShelf(progress)) {
            guard Self.isRestingOnShelf(stage.progress) else { return }
            let arrival = Date.now
            try? await Task.sleep(for: .seconds(Self.shelfHintDwell))
            guard !Task.isCancelled, !Self.shelfHintShows(restingFor: Date.now.timeIntervalSince(arrival)) else { return }
            withAnimation(DesignTokens.motion(reduceMotion, .easeOut(duration: DesignTokens.Motion.enterDuration))) {
                shelfHintDismissed = true
            }
        }
        .onChange(of: Self.rearmsShelfHint(progress)) { _, rearms in
            if rearms {
                shelfHintDismissed = false
            }
        }
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
