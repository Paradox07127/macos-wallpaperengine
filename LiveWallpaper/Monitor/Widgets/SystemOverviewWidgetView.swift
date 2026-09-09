import LiveWallpaperCore
import SwiftUI

struct SystemOverviewWidgetView: View {
    let context: MonitorWidgetContext

    private var large: Bool {
        context.placement.size == .large
    }

    private var readings: SystemOverviewReadings {
        .init(context: context)
    }

    private var showsHistory: Bool {
        SystemOverviewOptions.showsHistory(context.placement)
    }

    private var showsSensors: Bool {
        SystemOverviewOptions.showsSensors(context.placement)
    }

    var body: some View {
        GeometryReader { geometry in
            let cellHeight = geometry.size.height / (large ? 4 : 2)
            let scale = Design.TypeScale(cellHeight: cellHeight)
            WidgetContainer(
                label: "System Overview",
                systemImage: WidgetFactory.icon(.systemOverview),
                cellHeight: cellHeight,
                status: { powerStatus },
                content: {
                    VStack(spacing: DesignTokens.Spacing.sm) {
                        instruments(scale: scale)
                            .frame(maxHeight: .infinity)
                        rule
                        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
                            throughput(
                                title: "Network", first: readings.download, second: readings.upload,
                                firstLabel: "Download", secondLabel: "Upload", scale: scale
                            )
                            throughput(
                                title: "Disk", first: readings.diskRead, second: readings.diskWrite,
                                firstLabel: "Disk read", secondLabel: "Disk write", scale: scale
                            )
                        }
                        if showsSensors {
                            rule
                            sensors(scale: scale)
                        }
                    }
                }
            )
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Design.hairline)
            .frame(height: Design.hairlineWidth)
    }

    private var powerStatus: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: powerSymbol)
            if let battery = readings.battery {
                Text(verbatim: Format.percent(battery))
                    .monospacedDigit()
            } else if readings.powerSource == "ac" {
                Text("Plugged in")
            } else if readings.powerSource == "ups" {
                Text(verbatim: "UPS")
            } else {
                Text(verbatim: "—")
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Power"))
        .accessibilityValue(powerAccessibilityValue)
    }

    private var powerAccessibilityValue: Text {
        if let battery = readings.battery {
            return Text(verbatim: Format.percent(battery)) + Text(verbatim: " · ")
                + Text(readings.charging ? "Charging" : readings.powerSource == "ac" ? "Plugged in" : "Battery")
        }
        if readings.powerSource == "ups" {
            return Text(verbatim: "UPS")
        }
        return readings.powerSource == "ac" ? Text("Plugged in") : Text("Readings unavailable")
    }

    private var powerSymbol: String {
        guard let level = readings.battery else {
            return readings.powerSource == nil ? "questionmark" : "powerplug"
        }
        if readings.charging {
            return "battery.100.bolt"
        }
        switch level {
        case 0.9...: return "battery.100"
        case 0.65 ..< 0.9: return "battery.75"
        case 0.4 ..< 0.65: return "battery.50"
        case 0.15 ..< 0.4: return "battery.25"
        default: return "battery.0"
        }
    }

    private func instruments(scale: Design.TypeScale) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            instrument(title: "CPU", fraction: readings.cpu, kind: .cpu, scale: scale)
            instrument(title: "Memory", fraction: readings.memory, kind: .memory, scale: scale)
            instrument(title: "GPU", fraction: readings.gpu, kind: .gpu, scale: scale)
        }
    }

    private func instrument(
        title: LocalizedStringKey, fraction: Double?, kind: MonitorWidgetKind, scale: Design.TypeScale
    ) -> some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                if kind == .memory, readings.memoryPressure == "warn" || readings.memoryPressure == "critical" {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityLabel(Text(readings.memoryPressure == "critical" ? "Critical" : "Warning"))
                }
            }
            .font(Design.labelFont(size: scale.label))
            .foregroundStyle(Design.inkMuted)
            .lineLimit(1)
            ArcGauge(value: fraction, color: gaugeColor(kind, fraction: fraction)) {
                gaugeReadout(fraction, scale: scale)
                    .monospacedDigit()
                    .foregroundStyle(Design.inkPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: fraction.map(Format.percent) ?? "—"))

            if large {
                detail(kind)
                    .font(Design.captionFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(Design.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if showsHistory {
                    history(kind)
                        .frame(height: scale.caption * 2)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gaugeColor(_ kind: MonitorWidgetKind, fraction: Double?) -> Color {
        if kind == .memory {
            switch readings.memoryPressure {
            case "warn": return Design.signalAmber
            case "critical": return Design.signalCoral
            default: return Design.loadSteel
            }
        }
        return Design.loadBandColor(fraction ?? 0)
    }

    private func gaugeReadout(_ fraction: Double?, scale: Design.TypeScale) -> Text {
        let font = Design.heroFont(size: scale.hero * (large ? 0.7 : 0.6))
        guard let fraction else { return Text(verbatim: "—").font(font) }
        return Text(verbatim: String(Int((fraction * 100).rounded()))).font(font)
            + Text(verbatim: "%").font(Design.labelFont(size: scale.label))
    }

    private func detail(_ kind: MonitorWidgetKind) -> Text {
        switch kind {
        case .cpu:
            guard readings.cpu != nil,
                  let load = CPUWidgetView.loadText(system: context.snapshot.system, triple: false)
            else { return Text(verbatim: "—") }
            return Text("load") + Text(verbatim: " " + load)
        case .memory:
            guard let used = readings.memoryUsed, let total = readings.memoryTotal else { return Text(verbatim: "—") }
            return Text(verbatim: String(format: "%.1f / %.0f GiB", Format.gib(Double(used)), Format.gib(Double(total))))
        case .gpu:
            guard readings.gpu != nil, let cores = context.snapshot.system?.gpuCoreCount else { return Text(verbatim: "—") }
            return Text("\(cores) cores")
        default:
            return Text(verbatim: "—")
        }
    }

    private func history(_ kind: MonitorWidgetKind) -> some View {
        let seconds = Double(SystemOverviewOptions.historyWindow(context.placement))
        let source = context.history
        let window = kind == .gpu
            ? source.gpuChartWindow(reference: context.now, seconds: seconds)
            : source.chartWindow(reference: context.now, seconds: seconds)
        let series = kind == .cpu ? source.cpuTotal : kind == .gpu ? source.gpuDevice : source.memUsedFraction
        let points = kind == .gpu
            ? source.gpuPoints(series, in: window) : source.points(series, in: window)
        return Sparkline(points: points, window: window, domain: 0 ... 1, lineColor: Design.loadSteel)
    }

    private func throughput(
        title: LocalizedStringKey, first: Double?, second: Double?,
        firstLabel: LocalizedStringKey, secondLabel: LocalizedStringKey, scale: Design.TypeScale
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(Design.labelFont(size: scale.label))
                .foregroundStyle(Design.inkFaint)
            if large {
                rateRow(firstLabel, value: first, scale: scale)
                rateRow(secondLabel, value: second, scale: scale)
            } else {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    compactRate(first, direction: "arrow.down", label: firstLabel, scale: scale)
                    compactRate(second, direction: "arrow.up", label: secondLabel, scale: scale)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rateRow(_ title: LocalizedStringKey, value: Double?, scale: Design.TypeScale) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(title).foregroundStyle(Design.inkMuted)
            Spacer(minLength: 0)
            Text(verbatim: value.map(Format.rate) ?? "—")
                .monospacedDigit()
                .foregroundStyle(Design.inkPrimary)
        }
        .font(Design.captionFont(size: scale.caption))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private func compactRate(
        _ value: Double?, direction: String, label: LocalizedStringKey, scale: Design.TypeScale
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: direction).foregroundStyle(Design.inkFaint)
            Text(verbatim: value.map(Format.rate) ?? "—")
                .monospacedDigit()
                .foregroundStyle(Design.inkMuted)
        }
        .font(Design.labelFont(size: scale.label))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value.map(Format.rate) ?? "—"))
    }

    private func sensors(scale: Design.TypeScale) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            sensor("CPU", value: temperature(readings.cpuTemperature), scale: scale)
            sensor("GPU", value: temperature(readings.gpuTemperature), scale: scale)
            sensor("Fan speed", value: readings.fanRPM.map { String(format: "%.0f rpm", $0) } ?? "—", scale: scale)
        }
    }

    private func temperature(_ value: Double?) -> String {
        value.map { MonitorTemperature.valueText($0) + MonitorTemperature.symbol } ?? "—"
    }

    private func sensor(_ title: LocalizedStringKey, value: String, scale: Design.TypeScale) -> some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text(title).foregroundStyle(Design.inkFaint)
            Text(verbatim: value).monospacedDigit().foregroundStyle(Design.inkMuted)
        }
        .font(Design.captionFont(size: scale.caption))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
}
