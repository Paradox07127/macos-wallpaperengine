import SwiftUI
import LiveWallpaperCore

struct MonitorAIEngineWidgetView: View {
    let context: MonitorWidgetContext

    init(context: MonitorWidgetContext) {
        self.context = context
    }

    var body: some View {
        GeometryReader { geo in
            let rowSpan: CGFloat = context.placement.size == .large ? 2 : 1
            AIEngineContent(context: context, cellHeight: geo.size.height / (2 * rowSpan))
        }
    }
}

private struct AIEngineContent: View {
    /// The tested pure logic lives on the public widget type (see the extension
    /// at the bottom); the view body only ever calls through this alias.
    private typealias Widget = MonitorAIEngineWidgetView

    let context: MonitorWidgetContext
    let cellHeight: CGFloat

    private var system: MonitorSystemSnapshot? { context.snapshot.system }
    private var scale: MonitorDesign.TypeScale { .init(cellHeight: cellHeight) }

    /// The honest tri-state.
    private var state: Widget.DisplayState {
        Widget.displayState(footprintPresent: system?.aneFootprintPresent)
    }
    /// Whether any process has ANE-attributed memory. This does not imply current execution.
    private var hasANEFootprint: Bool { state == .present }
    private var totalFootprintBytes: UInt64? { system?.aneFootprintBytes }
    /// The top-k processes by attributed footprint (non-nil iff a footprint exists).
    private var processes: [MonitorANEProcess]? { system?.aneProcesses }
    var body: some View {
        MonitorWidgetContainer(
            label: "ANE MEMORY",
            cellHeight: cellHeight,
            status: { statusAccessory }
        ) {
            switch context.placement.size {
            case .small: smallBody
            case .medium: mediumBody
            case .large: largeBody
            }
        }
    }

    // MARK: - Header accessory

    @ViewBuilder
    private var statusAccessory: some View {
        if state == .unsampled {
            Text(verbatim: "-")
                .tracking(0.5)
                .foregroundStyle(MonitorDesign.inkFaint)
        } else {
            HStack(spacing: 6) {
                if let right = headerRightLabel {
                    Text(verbatim: right)
                        .font(MonitorDesign.labelFont(size: scale.label))
                        .foregroundStyle(MonitorDesign.inkMuted)
                }
                if hasANEFootprint {
                    Circle()
                        .fill(MonitorDesign.signalAmber)
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    private var headerRightLabel: String? {
        switch context.placement.size {
        case .small:  return nil
        case .medium: return "ACTIVITY -"
        case .large:  return "ACTIVITY -"
        }
    }

    // MARK: - S (170×170 — content ≈ 138×125)

    @ViewBuilder
    private var smallBody: some View {
        switch state {
        case .unsampled:
            unavailableBody
        case .empty, .present:
            smallFootprintBody
        }
    }

    private var smallFootprintBody: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            footprintIndicator(heroFactor: 0.72)
            topApp
            Text("ri_neural_footprint · no util", bundle: .main)
                .font(MonitorDesign.captionFont(size: scale.caption * 0.92))
                .tracking(scale.caption * 0.05)
                .foregroundStyle(MonitorDesign.inkFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monitorChip(scale)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// nil sampling → an explicit unavailable state. Never a 0%/idle claim.
    private var unavailableBody: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Circle()
                    .fill(MonitorDesign.signalIdle.opacity(0.6))
                    .frame(width: 9, height: 9)
                Text("ANE Memory", bundle: .main)
                    .font(MonitorDesign.heroFont(size: scale.hero * 0.5))
                    .tracking(scale.label * 0.12)
                    .foregroundStyle(MonitorDesign.inkMuted)
            }
            Text(verbatim: "-")
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkFaint)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - M (364×170 — content ≈ 332×125)

    @ViewBuilder
    private var mediumBody: some View {
        switch state {
        case .unsampled:
            unavailableBody
        case .empty, .present:
            VStack(alignment: .leading, spacing: 7) {
                mediumFootprintHeader
                listOrIdle
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var mediumFootprintHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            footprintIndicator(heroFactor: 0.5)
                .monitorChip(scale)
            Spacer(minLength: 6)
            topApp
        }
    }

    /// The ranked-list slot both tiers share: the per-process footprint list
    /// when present, and a quiet empty caption otherwise.
    @ViewBuilder
    private var listOrIdle: some View {
        if let list = processes {
            processList(Widget.rankedProcesses(list))
        } else {
            idlePlaceholder
        }
    }

    // MARK: - L (364×376 — content ≈ 332×331)

    @ViewBuilder
    private var largeBody: some View {
        switch state {
        case .unsampled:
            unavailableBody
        case .empty, .present:
            VStack(alignment: .leading, spacing: scale.caption * 0.7) {
                largeFootprintHeader
                if let list = processes {
                    Rectangle()
                        .fill(MonitorDesign.hairline)
                        .frame(height: MonitorDesign.hairlineWidth)
                        .opacity(0.7)
                    processList(
                        Widget.rankedProcesses(list),
                        rowGap: scale.caption * 1.3,
                        barHeight: scale.caption * 0.52
                    )
                }
                Spacer(minLength: 0)
                honestFooter
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var largeFootprintHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            footprintIndicator(heroFactor: 0.62)
                .monitorChip(scale)
            Spacer(minLength: 8)
            topApp
        }
    }

    /// Shows an explicit empty state when sampling succeeds without a footprint.
    private var idlePlaceholder: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("ri_neural_footprint · no util", bundle: .main)
                .font(MonitorDesign.captionFont(size: scale.caption * 0.92))
                .tracking(scale.caption * 0.05)
                .foregroundStyle(MonitorDesign.inkFaint)
                .monitorChip(scale)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The on-card honest boundary (L only): neural footprint is a memory
    /// attribution signal, not utilization or power.
    private var honestFooter: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(MonitorDesign.neuralDim)
                    .frame(width: scale.caption * 0.5, height: scale.caption * 0.5)
                    .opacity(0.8)
                Text("ri_neural_footprint · no util", bundle: .main)
                    .font(MonitorDesign.captionFont(size: scale.caption * 0.9))
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .monitorChip(scale)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Shared pieces

    private func footprintIndicator(heroFactor: CGFloat) -> some View {
        HStack(spacing: scale.hero * heroFactor * 0.28) {
            Circle()
                .fill(hasANEFootprint ? MonitorDesign.neural : MonitorDesign.signalIdle)
                .frame(width: scale.hero * heroFactor * 0.42,
                       height: scale.hero * heroFactor * 0.42)
            footprintValue(totalFootprintBytes ?? 0, size: scale.hero * heroFactor)
        }
    }

    @ViewBuilder
    private var topApp: some View {
        Group {
            if hasANEFootprint, let busiest = Widget.busiestProcess(processes ?? []) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: busiest.name)
                        .font(MonitorDesign.subFont(size: scale.caption))
                        .foregroundStyle(MonitorDesign.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "·")
                        .font(MonitorDesign.captionFont(size: scale.caption))
                        .foregroundStyle(MonitorDesign.inkFaint)
                    footprintValue(busiest.footprintBytes, size: scale.caption)
                }
            } else {
                Text("No attributed memory", bundle: .main)
                    .font(MonitorDesign.captionFont(size: scale.caption))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
        }
        .monitorChip(scale)
    }

    private func footprintValue(_ bytes: UInt64, size: CGFloat) -> some View {
        let parts = Widget.splitBytes(bytes)
        return (Text(verbatim: parts.value)
            + Text(verbatim: parts.unit)
                .font(MonitorDesign.labelFont(size: size * 0.7))
                .foregroundStyle(MonitorDesign.inkFaint))
            .font(MonitorDesign.subFont(size: size))
            .monospacedDigit()
            .foregroundStyle(MonitorDesign.neuralValue)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func processList(_ list: [MonitorANEProcess], rowGap: CGFloat? = nil, barHeight: CGFloat? = nil) -> some View {
        let top = list.first?.footprintBytes ?? 1
        return VStack(alignment: .leading, spacing: rowGap ?? scale.caption * 0.34) {
            HStack(spacing: 10) {
                Text(verbatim: "PROGRAM")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "ANE MEM")
                    .frame(width: memColumnWidth, alignment: .trailing)
            }
            .font(MonitorDesign.labelFont(size: scale.label * 0.98))
            .tracking(scale.label * 0.08)
            .foregroundStyle(MonitorDesign.inkFaint)

            ForEach(Array(list.enumerated()), id: \.offset) { _, proc in
                processRow(proc, topFootprint: top, barHeight: barHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func processRow(_ proc: MonitorANEProcess, topFootprint: UInt64, barHeight: CGFloat? = nil) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(MonitorDesign.neuralDim)
                    .frame(width: scale.caption * 0.5, height: scale.caption * 0.5)
                    .opacity(0.85)
                Text(verbatim: proc.name)
                    .font(.system(size: scale.caption, weight: .medium, design: .rounded))
                    .foregroundStyle(MonitorDesign.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ANEBar(fraction: Widget.barFraction(proc.footprintBytes, top: topFootprint))
                    .frame(maxWidth: .infinity)
                    .frame(height: barHeight ?? scale.caption * 0.42)
                footprintValue(proc.footprintBytes, size: scale.caption * 0.94)
                    .frame(width: memValueWidth, alignment: .trailing)
            }
            .frame(width: memColumnWidth)
        }
    }

    // MARK: - Layout metrics

    private var memColumnWidth: CGFloat { context.placement.size == .large ? 120 : 96 }
    private var memValueWidth: CGFloat { 46 }
}

// MARK: - Pure logic (tested)

extension MonitorAIEngineWidgetView {
    /// Render state for the sampled memory-footprint signal. It deliberately
    /// makes no claim about current ANE utilization or execution.
    enum DisplayState: Equatable { case unsampled, empty, present }

    nonisolated static func displayState(footprintPresent: Bool?) -> DisplayState {
        switch footprintPresent {
        case .none: return .unsampled
        case .some(false): return .empty
        case .some(true): return .present
        }
    }

    nonisolated static func busiestProcess(_ list: [MonitorANEProcess]) -> MonitorANEProcess? {
        list.max { $0.footprintBytes < $1.footprintBytes }
    }

    /// Top-k processes ranked by footprint (desc), capped at 5 — the honest per-process layer.
    nonisolated static func rankedProcesses(_ list: [MonitorANEProcess]) -> [MonitorANEProcess] {
        Array(list.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(5))
    }

    /// Bar length = this process's footprint ÷ the top (max) footprint, 0…1. The
    /// top row is always full; a zero top yields an empty bar (never a divide-by-0).
    nonisolated static func barFraction(_ footprint: UInt64, top: UInt64) -> Double {
        guard top > 0 else { return 0 }
        return min(1, max(0, Double(footprint) / Double(top)))
    }

    nonisolated static func splitBytes(_ bytes: UInt64) -> (value: String, unit: String) {
        splitFormatted(MonitorFormat.bytes(bytes))
    }

    nonisolated static func splitFormatted(_ text: String) -> (value: String, unit: String) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[space...]))
    }
}

// MARK: - Process footprint bar

private struct ANEBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clamped = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(MonitorDesign.track2)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                    )
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [MonitorDesign.oklch(0.54, 0.06, 300), MonitorDesign.neural],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, w * CGFloat(clamped)))
            }
        }
    }
}

// MARK: - ANE memory palette
private extension MonitorDesign {
    static let neural = oklch(0.72, 0.11, 300)
    static let neuralDim = oklch(0.60, 0.07, 300)
    static let neuralValue = oklch(0.85, 0.055, 300)
}

// MARK: - Previews

#if DEBUG
private func aiEnginePreviewContext(
    size: MonitorWidgetSize,
    footprintPresent: Bool? = true,
    processes: [MonitorANEProcess]? = defaultANEProcesses()
) -> MonitorWidgetContext {
    var sys = MonitorSystemSnapshot()
    sys.aneFootprintPresent = footprintPresent
    sys.aneProcesses = processes
    sys.aneFootprintBytes = processes.map { list in
        list.reduce(UInt64(0)) { $0 + $1.footprintBytes }
    }
    var snapshot = MonitorSnapshot()
    snapshot.timestamp = Date().timeIntervalSince1970
    snapshot.system = sys

    return MonitorWidgetContext(
        snapshot: snapshot,
        history: MonitorHistorySnapshot(),
        placement: MonitorWidgetPlacement(kind: .aiEngine, size: size),
        isEditing: false,
        reduceMotion: false,
        now: Date()
    )
}

private func defaultANEProcesses() -> [MonitorANEProcess] {
    let mb = 1_048_576.0
    return [
        MonitorANEProcess(name: "WhisperKit", footprintBytes: UInt64(762 * mb)),
        MonitorANEProcess(name: "Xcode", footprintBytes: UInt64(120 * mb)),
        MonitorANEProcess(name: "Claude", footprintBytes: UInt64(88 * mb)),
        MonitorANEProcess(name: "Photos", footprintBytes: UInt64(54 * mb)),
        MonitorANEProcess(name: "Spotlight", footprintBytes: UInt64(31 * mb)),
    ]
}

#Preview("ANE Memory · S") {
    HStack(spacing: 20) {
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(size: .small))
            .frame(width: 170, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .small, footprintPresent: false, processes: nil))
            .frame(width: 170, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .small, footprintPresent: nil, processes: nil))
            .frame(width: 170, height: 170)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("ANE Memory · M") {
    VStack(spacing: 20) {
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(size: .medium))
            .frame(width: 364, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .medium, footprintPresent: false, processes: nil))
            .frame(width: 364, height: 170)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .medium, footprintPresent: nil, processes: nil))
            .frame(width: 364, height: 170)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}

#Preview("ANE Memory · L") {
    HStack(alignment: .top, spacing: 20) {
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(size: .large))
            .frame(width: 364, height: 376)
        MonitorAIEngineWidgetView(context: aiEnginePreviewContext(
            size: .large, footprintPresent: false, processes: nil))
            .frame(width: 364, height: 376)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}
#endif
