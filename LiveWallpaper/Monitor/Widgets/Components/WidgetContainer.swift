import SwiftUI

struct WidgetContainer<Content: View, Status: View>: View {
    var label: String
    /// Optional SF Symbol name shown before the label.
    var systemImage: String?
    var cellHeight: CGFloat
    var cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius
    @ViewBuilder var status: () -> Status
    @ViewBuilder var content: () -> Content

    init(
        label: String,
        systemImage: String? = nil,
        cellHeight: CGFloat = 150,
        cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius,
        @ViewBuilder status: @escaping () -> Status = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.systemImage = systemImage
        self.cellHeight = cellHeight
        self.cornerRadius = cornerRadius
        self.status = status
        self.content = content
    }

    private var scale: Design.TypeScale { .init(cellHeight: cellHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, Design.contentInsetH)
        .padding(.vertical, Design.contentInsetV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .monitorPanelChrome(cornerRadius: cornerRadius)
    }

    private var header: some View {
        let titleSize = scale.label + 1
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(Design.inkFaint)
            }
            Text(verbatim: label.uppercased())
                .font(Design.labelFont(size: titleSize))
                .tracking(Design.labelTracking(size: titleSize))
                .foregroundStyle(Design.inkFaint)
            Spacer(minLength: 4)
            status()
                .font(Design.labelFont(size: scale.label))
                .foregroundStyle(Design.inkFaint)
        }
    }
}

#Preview("Widget container") {
    HStack(spacing: 24) {
        WidgetContainer(label: "CPU", systemImage: "cpu", cellHeight: 150) {
            HStack(spacing: 5) {
                BreathingDot(color: Design.signalAmber, size: 6)
                Text(verbatim: "42%").foregroundStyle(Design.inkMuted)
            }
        } content: {
            ArcGauge(value: 0.42, peak: 0.61) {
                Text(verbatim: "42")
                    .font(Design.heroFont(size: 28)).monospacedDigit()
                    .foregroundStyle(Design.inkPrimary)
            }
        }
        .frame(width: 150, height: 150)

        WidgetContainer(label: "NETWORK", systemImage: "wifi", cellHeight: 150) {
            Text(verbatim: "6.2 MB/s").foregroundStyle(Design.inkMuted)
        } content: {
            MirroredAreaChart(
                up: [3, 4, 5.5, 6.8, 5.2, 4.1, 6.3, 8.1, 7.2, 5.4],
                down: [0.4, 0.6, 0.9, 0.7, 0.5, 0.8, 1.1, 0.9, 0.6, 0.5]
            )
        }
        .frame(width: 320, height: 150)
    }
    .padding(32)
    .background(Design.boardWash)
}
