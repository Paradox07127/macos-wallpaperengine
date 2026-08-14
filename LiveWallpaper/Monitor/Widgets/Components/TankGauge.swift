import SwiftUI

enum MonitorPressure {
    case normal, warn, critical

    var fillColors: [Color] {
        switch self {
        case .normal:  return [Design.oklch(0.60, 0.08, 158), Design.signalSage]
        case .warn:    return [Design.signalAmber, Design.oklch(0.74, 0.15, 44)]
        case .critical: return [Design.oklch(0.70, 0.13, 40), Design.signalCoral]
        }
    }
}

/// Vertical liquid-fill gauge (memory).
struct TankGauge: View {
    var level: Double
    var pressure: MonitorPressure = .normal
    var cornerRadius: CGFloat = 8

    @Environment(\.monitorReduceMotion) private var reduceMotion

    init(level: Double, pressure: MonitorPressure = .normal, cornerRadius: CGFloat = 8) {
        self.level = level
        self.pressure = pressure
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let clamped = min(1, max(0, level))
            let fillHeight = h * CGFloat(clamped)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Design.bg0.opacity(0.6), Design.bg1.opacity(0.35)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Design.hairline.opacity(0.6), lineWidth: 1)
                    )

                ForEach([0.25, 0.5, 0.75], id: \.self) { q in
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 1)
                        .offset(y: -h * CGFloat(q))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }

                ZStack(alignment: .top) {
                    LinearGradient(colors: pressure.fillColors, startPoint: .bottom, endPoint: .top)
                    Rectangle()   // bright liquid-top line
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 2)
                }
                .frame(height: fillHeight)
                .clipShape(RoundedRectangle(cornerRadius: max(0, cornerRadius - 2), style: .continuous))
                .padding(2)
            }
            .transaction { $0.animation = reduceMotion ? nil : .easeOut(duration: 0.35) }
        }
    }
}

#Preview("Tank gauge") {
    HStack(spacing: 28) {
        TankGauge(level: 0.45, pressure: .normal).frame(width: 44, height: 130)
        TankGauge(level: 0.72, pressure: .warn).frame(width: 44, height: 130)
        TankGauge(level: 0.93, pressure: .critical).frame(width: 44, height: 130)
    }
    .padding(28)
    .background(Design.boardWash)
}
