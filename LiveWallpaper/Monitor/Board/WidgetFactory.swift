import SwiftUI
import LiveWallpaperCore

// MARK: - Widget factory

enum WidgetFactory {

    static func displayName(_ kind: MonitorWidgetKind) -> String {
        switch kind {
        case .cpu: String(localized: "CPU", bundle: .appLanguage, comment: "Monitor widget name: CPU instrument.")
        case .memory: String(localized: "Memory", bundle: .appLanguage, comment: "Monitor widget name: Memory instrument.")
        case .gpu: String(localized: "GPU", bundle: .appLanguage, comment: "Monitor widget name: GPU instrument.")
        case .network: String(localized: "Network", bundle: .appLanguage, comment: "Monitor widget name: Network instrument.")
        case .disk: String(localized: "Disk", bundle: .appLanguage, comment: "Monitor widget name: Disk I/O instrument.")
        case .power: String(localized: "Power", bundle: .appLanguage, comment: "Monitor widget name: Power/battery instrument.")
        case .processes: String(localized: "Processes", bundle: .appLanguage, comment: "Monitor widget name: top-processes instrument.")
        case .fleet: String(localized: "Agent Session", bundle: .appLanguage, comment: "Monitor widget name: AI agent session instrument.")
        case .aiEngine: String(localized: "ANE Memory", bundle: .appLanguage, comment: "Monitor widget name for process-attributed Neural Engine memory footprint; not activity or utilization.")
        case .weather: String(localized: "Weather", bundle: .appLanguage, comment: "Monitor widget name: ambient scene of the local weather.")
        }
    }

    static func icon(_ kind: MonitorWidgetKind) -> String {
        switch kind {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "cpu.fill"
        case .network: "network"
        case .disk: "internaldrive"
        case .power: "bolt.fill"
        case .processes: "list.bullet"
        case .fleet: "point.3.filled.connected.trianglepath.dotted"
        case .aiEngine: "brain"
        case .weather: "cloud.sun.rain"
        }
    }

    @MainActor @ViewBuilder
    static func tile(context: MonitorWidgetContext) -> some View {
        if let notice = context.readingsNotice {
            WidgetContainer(label: displayName(context.placement.kind), systemImage: icon(context.placement.kind)) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(verbatim: "—")
                        .font(DesignTokens.Typography.hero)
                    Text(notice)
                        .font(DesignTokens.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Design.inkMuted)
                .accessibilityElement(children: .combine)
            }
        } else {
            availableTile(context: context)
        }
    }

    @MainActor @ViewBuilder
    private static func availableTile(context: MonitorWidgetContext) -> some View {
        switch context.placement.kind {
        case .cpu:
            CPUWidgetView(context: context)
        case .memory:
            MemoryWidgetView(context: context)
        case .gpu:
            GPUWidgetView(context: context)
        case .network:
            NetworkWidgetView(context: context)
        case .disk:
            DiskWidgetView(context: context)
        case .power:
            PowerWidgetView(context: context)
        case .processes:
            ProcessesWidgetView(context: context)
        case .fleet:
            AgentSessionWidgetView(context: context)
        case .aiEngine:
            AIEngineWidgetView(context: context)
        case .weather:
            WeatherWidgetView(context: context)
        }
    }
}

/// Icon + localized name centered in panel chrome (inspector/name-only preview).
struct MonitorWidgetNameTile: View {
    let kind: MonitorWidgetKind
    let cellHeight: CGFloat
    /// Board-authoritative radius so fill stays concentric with the selection border.
    var cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius

    private var scale: Design.TypeScale { .init(cellHeight: cellHeight) }

    var body: some View {
        VStack(spacing: max(4, cellHeight * 0.05)) {
            Image(systemName: WidgetFactory.icon(kind))
                .font(.system(size: scale.hero * 0.58, weight: .regular))
                .foregroundStyle(Design.inkFaint)
            Text(verbatim: WidgetFactory.displayName(kind))
                .font(Design.subFont(size: scale.caption + 1))
                .foregroundStyle(Design.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Design.contentInsetH)
        .monitorPanelChrome(cornerRadius: cornerRadius)
    }
}
