import SwiftUI

/// The board's headline percentage: large tabular digits with a smaller unit
/// beside them.
///
/// Every instrument that shows a 0…1 utilisation as its hero number draws it
/// here, so the unit's size relationship and the three-digit shrink are decided
/// once. Without the shrink, "100%" needs a text scale below the
/// `minimumScaleFactor` floor in the tighter arc-gauge centres and truncates to
/// "1…%" instead — `WidgetReadoutFitTests` measures that for every tile.
struct HeroPercent: View {
    /// 0…1. Clamped and rounded to a whole percent.
    var fraction: Double
    /// Digit size before the three-digit shrink.
    var baseSize: CGFloat
    /// Floor for `minimumScaleFactor`; below it `Text` truncates rather than shrinks.
    var minimumScale: CGFloat = 0.6

    var body: some View {
        let text = Format.wholeNumber(fraction)
        let size = Design.heroSize(base: baseSize, digits: text.count)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: text)
                .font(Design.heroFont(size: size))
                .monospacedDigit()
                .foregroundStyle(Design.inkPrimary)
            Text(verbatim: "%")
                .font(Design.heroFont(size: size * Design.heroUnitRatio))
                .foregroundStyle(Design.inkFaint)
        }
        .lineLimit(1)
        .minimumScaleFactor(minimumScale)
    }
}

#Preview("Hero percent") {
    HStack(spacing: 24) {
        ForEach([0.07, 0.42, 1.0], id: \.self) { value in
            HeroPercent(fraction: value, baseSize: 34)
        }
    }
    .padding(32)
    .background(Design.boardWash)
}
