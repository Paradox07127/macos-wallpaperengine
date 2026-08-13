import LiveWallpaperCore
import SwiftUI

struct MonitorWidgetSettingsPopover: View {
    /// Fixed host width (segmented pickers + deterministic board-card placement).
    static let preferredWidth: CGFloat = 360

    let placement: MonitorWidgetPlacement
    let onUpdate: (MonitorWidgetPlacement) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if placement.kind.allowedSizes.count > 1 {
                sizePicker
            }

            if hasKindOptions {
                kindOptions
            }

            Divider()
            removeButton
        }
        .settingsPopoverChrome(width: Self.preferredWidth)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: MonitorWidgetFactory.icon(placement.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .adaptiveGlassSurface(.roundedRectangle(10))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: MonitorWidgetFactory.displayName(placement.kind))
                    .font(.headline)
                Text("Instrument settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            onRemove()
        } label: {
            Label("Remove Instrument", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderless)
        .tint(.red)
    }

    private var hasKindOptions: Bool {
        switch placement.kind {
        case .processes, .cpu, .gpu, .memory, .disk, .fleet: return true
        default: return false
        }
    }

    // MARK: - Size

    @ViewBuilder
    private var sizePicker: some View {
        let allowed = placement.kind.allowedSizes
        if allowed.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Size")
                    .font(.subheadline.weight(.medium))
                Picker("", selection: Binding(
                    get: { placement.size },
                    set: { newSize in
                        var next = placement
                        next.size = newSize
                        onUpdate(next)
                    }
                )) {
                    ForEach(allowed, id: \.self) { size in
                        Text(verbatim: Self.sizeLabel(size)).tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("Widget size"))
            }
        }
    }

    // MARK: - Kind-specific options

    @ViewBuilder
    private var kindOptions: some View {
        switch placement.kind {
        case .processes:
            processesOptions
        case .cpu:
            cpuOptions
        case .gpu:
            gpuOptions
        case .memory:
            memoryOptions
        case .disk:
            diskOptions
        case .fleet:
            agentSessionOptions
        default:
            EmptyView()
        }
    }

    // MARK: Processes

    private var processesOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Stepper(
                value: Binding(
                    get: { MonitorWidgetDraft.processCount(placement) },
                    set: { onUpdate(MonitorWidgetDraft.settingProcessCount($0, on: placement)) }
                ),
                in: MonitorWidgetDraft.processCountRange
            ) {
                HStack {
                    Text("Rows")
                    Spacer()
                    Text(verbatim: "\(MonitorWidgetDraft.processCount(placement))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: CPU

    private var cpuOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            historyWindowPicker(defaultWindow: MonitorCPUDraft.defaultHistoryWindow(for: placement.size))
            VStack(spacing: 8) {
                toggleRow("Show heatmap", isOn: boolBinding(key: MonitorCPUDraft.showHeatmapKey, default: true))
                toggleRow("Show composition", isOn: boolBinding(key: MonitorCPUDraft.showCompositionKey, default: true))
                toggleRow("Show sensors", isOn: boolBinding(key: MonitorCPUDraft.showSensorsKey, default: true))
                if placement.size == .small {
                    toggleRow("Show history curve", isOn: boolBinding(key: MonitorWidgetDraft.showTrendKey, default: true))
                }
            }
        }
    }

    // MARK: GPU

    private var gpuOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            historyWindowPicker(defaultWindow: 60)
            gpuSamplingPicker
            VStack(spacing: 8) {
                toggleRow("Show load breakdown", isOn: boolBinding(key: MonitorWidgetDraft.showLoadBreakdownKey, default: true))
                toggleRow("Show sensors", isOn: boolBinding(key: MonitorWidgetDraft.showSensorsKey, default: true))
                if placement.size == .small {
                    toggleRow("Show history curve", isOn: boolBinding(key: MonitorWidgetDraft.showTrendKey, default: true))
                }
            }
        }
    }

    /// GPU IOAccelerator sample cadence (default 6s).
    private var gpuSamplingPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sampling interval")
                .font(.subheadline.weight(.medium))
            Picker("", selection: Binding(
                get: { MonitorWidgetDraft.gpuSampleSeconds(placement) ?? 6 },
                set: { onUpdate(MonitorWidgetDraft.settingGPUSampleSeconds($0, on: placement)) }
            )) {
                ForEach(MonitorWidgetDraft.gpuSampleChoices, id: \.self) { seconds in
                    Text(verbatim: "\(Int(seconds))s").tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("GPU sampling interval"))
        }
    }

    // MARK: Memory

    private var memoryOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            historyWindowPicker(defaultWindow: placement.size == .large ? 120 : 60)
            breakdownPicker
            VStack(alignment: .leading, spacing: 4) {
                toggleRow("Show top processes", isOn: boolBinding(key: MonitorWidgetDraft.showTopProcessesKey, default: true))
                if placement.size != .large {
                    Text("Top processes show on the large size only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Disk

    private var diskOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            historyWindowPicker(defaultWindow: 120)
            breakdownPicker
            VStack(alignment: .leading, spacing: 4) {
                toggleRow("Show top processes", isOn: boolBinding(key: MonitorWidgetDraft.showTopProcessesKey, default: true))
                if placement.size != .large {
                    Text("Top processes show on the large size only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Agent Session

    private var agentSessionOptions: some View {
        let fallback = placement.size == .large
            ? MonitorAgentSessionWidgetView.largeRowCap
            : MonitorAgentSessionWidgetView.mediumRowCap
        return VStack(alignment: .leading, spacing: 14) {
            providerPicker(key: MonitorAgentSessionWidgetView.Option.provider)

            Picker(selection: Binding(
                get: { MonitorAgentSessionWidgetView.sortMode(placement.options) },
                set: { onUpdate(MonitorWidgetDraft.settingAgentSessionSort($0, on: placement)) }
            )) {
                Text("Attention").tag(MonitorAgentSessionWidgetView.SortMode.attention)
                Text("Recent").tag(MonitorAgentSessionWidgetView.SortMode.recent)
            } label: {
                Text("Sort")
            }
            .controlSize(.small)

            Stepper(
                value: Binding(
                    get: { MonitorAgentSessionWidgetView.rowCap(placement.options, fallback: fallback) },
                    set: { onUpdate(MonitorWidgetDraft.settingAgentSessionMaxRows($0, fallback: fallback, on: placement)) }
                ),
                in: 1...fallback
            ) {
                HStack {
                    Text("Rows")
                    Spacer()
                    Text(verbatim: "\(MonitorAgentSessionWidgetView.rowCap(placement.options, fallback: fallback))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Shared controls

    @ViewBuilder
    private func historyWindowPicker(defaultWindow: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History window")
                .font(.subheadline.weight(.medium))
            Picker("", selection: Binding(
                get: { MonitorWidgetDraft.historyWindowTag(placement, clearValue: defaultWindow) },
                set: { onUpdate(MonitorWidgetDraft.settingHistoryWindow(tag: $0, clearValue: defaultWindow, on: placement)) }
            )) {
                Text(verbatim: "30s").tag(30)
                Text(verbatim: "60s").tag(60)
                Text(verbatim: "120s").tag(120)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("History window"))
        }
    }

    private var breakdownPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Breakdown")
                .font(.subheadline.weight(.medium))
            Picker("", selection: Binding(
                get: { MonitorWidgetDraft.breakdownCompact(placement) },
                set: { onUpdate(MonitorWidgetDraft.settingBreakdownCompact($0, on: placement)) }
            )) {
                Text("Full").tag(false)
                Text("Compact").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("Breakdown"))
        }
    }

    /// Agent Session provider filter (`all`/`claude`/`codex`).
    private func providerPicker(key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Provider")
                .font(.subheadline.weight(.medium))
            Picker("", selection: Binding(
                get: { MonitorWidgetDraft.providerTag(placement, key: key) },
                set: { onUpdate(MonitorWidgetDraft.settingProvider($0, key: key, on: placement)) }
            )) {
                Text("All").tag("all")
                Text(verbatim: "Claude").tag("claude")
                Text(verbatim: "Codex").tag("codex")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("Provider"))
        }
    }

    /// Drop the option key when value equals default (untouched widgets stay empty).
    private func boolBinding(key: String, default def: Bool) -> Binding<Bool> {
        Binding(
            get: { placement.options[key]?.boolValue ?? def },
            set: { onUpdate(MonitorWidgetDraft.settingBool($0, key: key, default: def, on: placement)) }
        )
    }

    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Labels

    static func sizeLabel(_ size: MonitorWidgetSize) -> String {
        switch size {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

}

// MARK: - Pure draft mutations (unit-tested)

/// Encode/decode helpers for a placement's option bag.
enum MonitorWidgetDraft {
    static let countKey = "count"

    static let processCountRange = 1...12
    static let defaultProcessCount = 5

    // MARK: GPU · sampling period

    static let gpuSampleSecondsKey = "gpuSampleSeconds"
    static let gpuSampleChoices: [Double] = [2, 6, 10]

    static func gpuSampleSeconds(_ placement: MonitorWidgetPlacement) -> Double? {
        guard let raw = placement.options[gpuSampleSecondsKey]?.numberValue else { return nil }
        return gpuSampleChoices.contains(raw) ? raw : nil
    }

    static let gpuDefaultSeconds: Double = 6

    /// Fastest GPU sample period across placements (runtime lease).
    static func gpuSampleSeconds(in widgets: [MonitorWidgetPlacement]) -> Double? {
        widgets.filter { $0.kind == .gpu }
            .map { gpuSampleSeconds($0) ?? gpuDefaultSeconds }
            .min()
    }

    static func settingGPUSampleSeconds(
        _ value: Double, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if value == 6 || !gpuSampleChoices.contains(value) {
            next.options.removeValue(forKey: gpuSampleSecondsKey)   // default drops the key
        } else {
            next.options[gpuSampleSecondsKey] = .number(value)
        }
        return next
    }

    // MARK: Processes · count

    static func processCount(_ placement: MonitorWidgetPlacement) -> Int {
        placement.options[countKey]?
            .intValue(clampedTo: processCountRange) ?? defaultProcessCount
    }

    static func settingProcessCount(
        _ value: Int, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        let clamped = min(max(value, processCountRange.lowerBound), processCountRange.upperBound)
        var next = placement
        next.options[countKey] = .number(Double(clamped))
        return next
    }

    // MARK: Shared option keys (must match widget readers)
    static let historyWindowKey = "historyWindow"
    static let showLoadBreakdownKey = "showLoadBreakdown"
    static let showSensorsKey = "showSensors"
    static let showTopProcessesKey = "showTopProcesses"
    static let showTrendKey = "showTrend"
    static let breakdownKey = "breakdown"

    static let historyWindowChoices = [30, 60, 120]

    // MARK: History window (CPU/GPU/Memory/Disk)

    /// Persisted in-catalog window, else `clearValue` for "unset".
    static func historyWindowTag(_ placement: MonitorWidgetPlacement, clearValue: Int) -> Int {
        guard let value = placement.options[historyWindowKey]?
            .intValue(clampedTo: 0 ... Int.max) else { return clearValue }
        return historyWindowChoices.contains(value) ? value : clearValue
    }

    static func settingHistoryWindow(
        tag: Int, clearValue: Int, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if tag == clearValue || !historyWindowChoices.contains(tag) {
            next.options.removeValue(forKey: historyWindowKey)
        } else {
            next.options[historyWindowKey] = .number(Double(tag))
        }
        return next
    }

    // MARK: Breakdown (Memory/Disk)

    static func breakdownCompact(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[breakdownKey]?.stringValue == "compact"
    }

    static func settingBreakdownCompact(
        _ compact: Bool, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if compact {
            next.options[breakdownKey] = .string("compact")
        } else {
            next.options.removeValue(forKey: breakdownKey)
        }
        return next
    }

    // MARK: Provider filter (Agent Session)

    static func providerTag(_ placement: MonitorWidgetPlacement, key: String) -> String {
        switch placement.options[key]?.stringValue {
        case "claude": return "claude"
        case "codex": return "codex"
        default: return "all"
        }
    }

    static func settingProvider(
        _ tag: String, key: String, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if tag == "claude" || tag == "codex" {
            next.options[key] = .string(tag)
        } else {
            next.options.removeValue(forKey: key)
        }
        return next
    }

    // MARK: Agent Session sort + row cap

    static func settingAgentSessionSort(
        _ mode: MonitorAgentSessionWidgetView.SortMode, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if mode == .attention {
            next.options.removeValue(forKey: MonitorAgentSessionWidgetView.Option.sort)
        } else {
            next.options[MonitorAgentSessionWidgetView.Option.sort] = .string(mode.rawValue)
        }
        return next
    }

    /// Pinning to per-size max drops the key so the widget stays on auto-max after resize.
    static func settingAgentSessionMaxRows(
        _ value: Int, fallback: Int, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        let clamped = min(max(value, 1), fallback)
        var next = placement
        if clamped >= fallback {
            next.options.removeValue(forKey: MonitorAgentSessionWidgetView.Option.maxRows)
        } else {
            next.options[MonitorAgentSessionWidgetView.Option.maxRows] = .number(Double(clamped))
        }
        return next
    }

    // MARK: Generic bool toggle (drop-on-default)

    static func settingBool(
        _ value: Bool, key: String, default def: Bool, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if value == def {
            next.options.removeValue(forKey: key)
        } else {
            next.options[key] = .bool(value)
        }
        return next
    }
}
