import SwiftUI

public struct ArcSpinner: View {
    public var size: CGFloat = 44
    public var lineWidth: CGFloat = 4
    public var tint: Color = DesignTokens.Colors.overlayForeground
    public var progressText: String?

    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animate: Bool {
        isVisible && !reduceMotion
    }

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
        VStack(spacing: DesignTokens.Spacing.md) {
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
                    .animation(animate ? .linear(duration: 1.1).repeatForever(autoreverses: false) : nil, value: animate)

                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(
                        tint.opacity(0.55),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(animate ? -360 : 0))
                    .blendMode(.plusLighter)
                    .animation(animate ? .linear(duration: 1.7).repeatForever(autoreverses: false) : nil, value: animate)
            }
            .frame(width: size, height: size)

            if let progressText {
                Text(verbatim: progressText)
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                    .thumbnailBadgeGlass()
                    .accessibilityLabel(Text(verbatim: progressText))
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityElement(children: progressText == nil ? .ignore : .contain)
    }
}
