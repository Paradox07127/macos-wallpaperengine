import SwiftUI

/// Two counter-rotating arcs over a static track ring, kept gentle so the
/// motion doesn't compete with the preview fading through beneath it.
///
/// Named for what it draws. It was `LiquidGlassSpinner`, which was wrong twice
/// over: the rings are plain `Circle().stroke()` — no material, no glass — and
/// the name sent readers hunting for a glass cost the browse-grid ablation
/// (2026-09-04) showed was not there. The one badge-glass here is the optional
/// `progressText` label, an ordinary `thumbnailBadgeGlass()` badge that honours
/// `thumbnailBadgeSurface` like every other.
public struct ArcSpinner: View {
    public var size: CGFloat = 44
    public var lineWidth: CGFloat = 4
    public var tint: Color = DesignTokens.Colors.overlayForeground
    public var progressText: String?

    @State private var animate = false

    public init(
        size: CGFloat = 44,
        lineWidth: CGFloat = 4,
        tint: Color = DesignTokens.Colors.overlayForeground,
        progressText: String? = nil
    ) {
        self.size = size
        self.lineWidth = lineWidth
        self.tint = tint
        self.progressText = progressText
    }

    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.12), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: 0.32)
                    .stroke(
                        tint.opacity(0.85),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(animate ? 360 : 0))
                    .blendMode(.plusLighter)
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: animate)

                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(
                        tint.opacity(0.55),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(animate ? -360 : 0))
                    .blendMode(.plusLighter)
                    .animation(.linear(duration: 1.7).repeatForever(autoreverses: false), value: animate)
            }
            .frame(width: size, height: size)

            if let progressText {
                Text(verbatim: progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.overlayForeground.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .thumbnailBadgeGlass()
                    .accessibilityLabel(Text(verbatim: progressText))
            }
        }
        .onAppear { animate = true }
        .accessibilityElement(children: progressText == nil ? .ignore : .contain)
    }
}
