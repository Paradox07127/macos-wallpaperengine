import SwiftUI
import LiveWallpaperCore

// MARK: - Widget factory

enum MonitorWidgetFactory {

    static func displayName(_ kind: MonitorWidgetKind) -> String {
        switch kind {
        case .cpu: return String(localized: "CPU", comment: "Monitor widget name: CPU instrument.")
        case .memory: return String(localized: "Memory", comment: "Monitor widget name: Memory instrument.")
        case .gpu: return String(localized: "GPU", comment: "Monitor widget name: GPU instrument.")
        case .network: return String(localized: "Network", comment: "Monitor widget name: Network instrument.")
        case .disk: return String(localized: "Disk", comment: "Monitor widget name: Disk I/O instrument.")
        case .power: return String(localized: "Power", comment: "Monitor widget name: Power/battery instrument.")
        case .processes: return String(localized: "Processes", comment: "Monitor widget name: top-processes instrument.")
        case .fleet: return String(localized: "Agent Session", comment: "Monitor widget name: AI agent session instrument.")
        case .aiEngine: return String(localized: "ANE Memory", comment: "Monitor widget name for process-attributed Neural Engine memory footprint; not activity or utilization.")
        }
    }

    static func icon(_ kind: MonitorWidgetKind) -> String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "cpu.fill"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .power: return "bolt.fill"
        case .processes: return "list.bullet"
        case .fleet: return "point.3.filled.connected.trianglepath.dotted"
        case .aiEngine: return "brain"
        }
    }

    /// `cornerRadius` is threaded for layout geometry but not consumed here.
    @MainActor @ViewBuilder
    static func tile(context: MonitorWidgetContext, cornerRadius: CGFloat) -> some View {
        switch context.placement.kind {
        case .cpu:
            MonitorCPUWidgetView(context: context)
        case .memory:
            MonitorMemoryWidgetView(context: context)
        case .gpu:
            MonitorGPUWidgetView(context: context)
        case .network:
            MonitorNetworkWidgetView(context: context)
        case .disk:
            MonitorDiskWidgetView(context: context)
        case .power:
            MonitorPowerWidgetView(context: context)
        case .processes:
            MonitorProcessesWidgetView(context: context)
        case .fleet:
            MonitorAgentSessionWidgetView(context: context)
        case .aiEngine:
            MonitorAIEngineWidgetView(context: context)
        }
    }
}

/// Icon + localized name centered in panel chrome (inspector/name-only preview).
struct MonitorWidgetNameTile: View {
    let kind: MonitorWidgetKind
    let cellHeight: CGFloat
    /// Board-authoritative radius so fill stays concentric with the selection border.
    var cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius

    private var scale: MonitorDesign.TypeScale { .init(cellHeight: cellHeight) }

    var body: some View {
        VStack(spacing: max(4, cellHeight * 0.05)) {
            Image(systemName: MonitorWidgetFactory.icon(kind))
                .font(.system(size: scale.hero * 0.58, weight: .regular))
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: MonitorWidgetFactory.displayName(kind))
                .font(MonitorDesign.subFont(size: scale.caption + 1))
                .foregroundStyle(MonitorDesign.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MonitorDesign.contentInsetH)
        .monitorPanelChrome(cornerRadius: cornerRadius)
    }
}
