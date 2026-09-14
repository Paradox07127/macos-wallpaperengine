import SwiftUI

/// Temperature chip: a band-coloured dot, the reading in the user's unit, and
/// the "sensor" tag that says this came from hardware rather than from the
/// utilisation model. CPU and GPU show the same thing and now draw it the same.
struct SensorCapsule: View {
    var celsius: Double
    var scale: Design.TypeScale

    var body: some View {
        let tint = Design.temperatureColor(celsius)
        HStack(spacing: scale.label * 0.5) {
            Circle()
                .fill(tint)
                .frame(width: scale.caption * 0.62, height: scale.caption * 0.62)
                .shadow(color: tint.opacity(0.7), radius: 2)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: MonitorTemperature.valueText(celsius))
                    .font(Design.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(Design.inkPrimary)
                Text(verbatim: MonitorTemperature.symbol)
                    .font(Design.captionFont(size: scale.caption * 0.68))
                    .foregroundStyle(Design.inkFaint)
            }
            Text("Sensor")
                .font(Design.labelFont(size: scale.label * 0.94))
                .tracking(Design.labelTracking(size: scale.label))
                .textCase(.uppercase)
                .foregroundStyle(Design.inkFaint)
        }
        .lineLimit(1)
        .monitorChip(scale)
    }
}

#Preview("Sensor capsule") {
    HStack(spacing: 20) {
        SensorCapsule(celsius: 38, scale: .init(cellHeight: 85))
        SensorCapsule(celsius: 74, scale: .init(cellHeight: 85))
    }
    .padding(28)
    .background(Design.boardWash)
}
