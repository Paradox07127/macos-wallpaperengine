import SwiftUI

/// Header state dot for a 0…1 load; breathes only above `Design.Load.elevated`.
struct LoadStateDot: View {
    var fraction: Double

    var body: some View {
        BreathingDot(
            color: Design.loadDotColor(fraction),
            size: Design.stateDotSize,
            animated: fraction >= Design.Load.elevated
        )
    }
}

#Preview("Load state dot") {
    HStack(spacing: 20) {
        ForEach([0.1, 0.7, 0.95], id: \.self) { value in
            LoadStateDot(fraction: value)
        }
    }
    .padding(28)
    .background(Design.boardWash)
}
