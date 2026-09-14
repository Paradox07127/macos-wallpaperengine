import SwiftUI

/// The swatch is `Design.peakMarker`, the same colour `ArcGauge` draws its peak
/// tick in — the tag is that tick's legend, so the two must not drift apart.
struct PeakTag: View {
    /// Optional direction glyph ("↓", "↑") for instruments with two directions.
    var glyph: String?
    var label: LocalizedStringKey = "peak"
    var value: String
    var scale: Design.TypeScale
    /// Label/value size. Defaults to the board's label size; the tighter tiles
    /// pass a fraction of it.
    var size: CGFloat?

    private var textSize: CGFloat {
        size ?? scale.label
    }

    var body: some View {
        let textSize = textSize
        HStack(alignment: .firstTextBaseline, spacing: textSize * 0.35) {
            RoundedRectangle(cornerRadius: Design.swatchCornerRadius, style: .continuous)
                .fill(Design.peakMarker.opacity(0.85))
                .frame(width: textSize * 0.5, height: textSize * 0.5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - textSize * 0.08 }
            if let glyph {
                Text(verbatim: glyph)
                    .font(Design.labelFont(size: textSize))
                    .foregroundStyle(Design.inkFaint)
            }
            Text(label)
                .font(Design.labelFont(size: textSize))
                .tracking(Design.labelTracking(size: textSize))
                .textCase(.uppercase)
                .foregroundStyle(Design.inkFaint)
            Text(verbatim: value)
                .font(Design.subFont(size: textSize))
                .monospacedDigit()
                .foregroundStyle(Design.inkMuted)
        }
        .lineLimit(1)
        .monitorChip(scale)
    }
}

#Preview("Peak tag") {
    VStack(alignment: .leading, spacing: 12) {
        PeakTag(value: "91%", scale: .init(cellHeight: 85))
        PeakTag(label: "R peak", value: "6.2 MB/s", scale: .init(cellHeight: 85))
        PeakTag(glyph: "↓", value: "12.4 MB/s", scale: .init(cellHeight: 85))
    }
    .padding(28)
    .background(Design.boardWash)
}
