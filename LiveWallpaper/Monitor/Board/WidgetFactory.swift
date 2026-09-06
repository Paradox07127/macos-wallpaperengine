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

    /// How far the board around this tile is being shrunk, so the one mode whose
    /// whole job is legibility can undo it.
    @Environment(\.monitorRenderScale) private var renderScale

    private var scale: Design.TypeScale { .init(cellHeight: cellHeight) }

    private var iconSize: CGFloat {
        scale.hero * 0.58
    }

    private var labelSize: CGFloat {
        scale.caption + 1
    }

    /// The label read at a fifth of a 5K desktop is under three points of text.
    /// This mode exists *for* canvases too small to read a real tile on, so it
    /// is the one tile that grows to meet a floor in screen points instead of
    /// shrinking with the board — the real-widget modes still predict the
    /// desktop exactly. Capped at what the cell can hold.
    private var typeBoost: CGFloat {
        guard renderScale > 0, renderScale < 1 else { return 1 }
        let stack = iconSize + max(4, cellHeight * 0.05) + labelSize * 1.2
        let room = max(cellHeight - 2 * Design.contentInsetH, 1) / max(stack, 1)
        return max(1, min(Self.minimumLabelScreenSize / (labelSize * renderScale), room))
    }

    /// Apple's smallest legible UI text.
    private static let minimumLabelScreenSize: CGFloat = 11

    var body: some View {
        VStack(spacing: max(4, cellHeight * 0.05) * typeBoost) {
            Image(systemName: WidgetFactory.icon(kind))
                .font(.system(size: iconSize * typeBoost, weight: .regular))
                .foregroundStyle(Design.inkFaint)
            Text(verbatim: WidgetFactory.displayName(kind))
                .font(Design.subFont(size: labelSize * typeBoost))
                .foregroundStyle(Design.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Design.contentInsetH)
        .monitorPanelChrome(cornerRadius: cornerRadius)
    }
}
