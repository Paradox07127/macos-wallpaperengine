import LiveWallpaperCore
import SwiftUI

struct WidgetSettingsPopover: View {
    /// Fixed width shared with board settings-card placement.
    static let preferredWidth: CGFloat = 280

    let placement: MonitorWidgetPlacement
    let onUpdate: (MonitorWidgetPlacement) -> Void
    let onRemove: () -> Void
    /// The Edit Desk inspector: grouped `SettingRow`s, and removal lives in the inspector's header.
    var embedded = false

    var body: some View {
        if embedded {
            VStack(spacing: DesignTokens.Spacing.md) {
                if placement.kind.allowedSizes.count > 1 {
                    group { sizePicker }
                }
                if hasKindOptions {
                    group { kindOptions }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
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
    }

    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        GroupBox { content() }
            .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: WidgetFactory.icon(placement.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                        .fill(.quaternary.opacity(0.6))
                )
            Text(verbatim: WidgetFactory.displayName(placement.kind))
                .font(.headline)
            Spacer(minLength: 0)
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            onRemove()
        } label: {
            Label("Remove Widget", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .buttonStyle(.borderless)
        .destructiveControlTint()
    }

    private var hasKindOptions: Bool {
        switch placement.kind {
        case .systemOverview, .processes, .cpu, .gpu, .memory, .disk, .fleet, .weather: true
        default: false
        }
    }

    /// Embedded rows share one spacing, with dividers doing the separating.
    private func spacing(_ popover: CGFloat) -> CGFloat {
        embedded ? DesignTokens.Spacing.sm : popover
    }

    // MARK: - Size

    @ViewBuilder
    private var sizePicker: some View {
        let allowed = placement.kind.allowedSizes
        if allowed.count > 1 {
            optionRow("Size", icon: "arrow.up.left.and.arrow.down.right", first: true) {
                GlassSegmentedPicker(
                    selection: Binding(
                        get: { placement.size },
                        set: { newSize in
                            var next = placement
                            next.size = newSize
                            onUpdate(next)
                        }
                    ),
                    values: allowed,
                    shell: .flat,
                    title: { Self.sizeLabel($0) }
                )
                .frame(width: 170)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Widget size"))
            }
        }
    }

    // MARK: - Kind-specific options

    @ViewBuilder
    private var kindOptions: some View {
        switch placement.kind {
        case .systemOverview:
            overviewOptions
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
        case .weather:
            weatherOptions
        default:
            EmptyView()
        }
    }

    // MARK: System Overview

    private var overviewOptions: some View {
        VStack(alignment: .leading, spacing: spacing(DesignTokens.Spacing.sm)) {
            gpuSamplingPicker(first: true)
            if placement.size == .large {
                historyWindowPicker(defaultWindow: SystemOverviewOptions.defaultHistoryWindow)
                toggleRow("Show history curve", icon: "chart.xyaxis.line",
                          isOn: boolBinding(key: MonitorWidgetDraft.showTrendKey, default: true))
                toggleRow("Show sensors", icon: "thermometer.medium",
                          isOn: boolBinding(key: MonitorWidgetDraft.showSensorsKey, default: true))
            }
        }
    }

    // MARK: Weather

    private var weatherOptions: some View {
        toggleRow(
            "Show caption", icon: "text.below.photo", first: true,
            isOn: boolBinding(key: WeatherWidgetOptions.showCaptionKey, default: WeatherWidgetOptions.showCaptionDefault)
        )
    }

    // MARK: Processes

    private var processesOptions: some View {
        VStack(alignment: .leading, spacing: spacing(DesignTokens.Spacing.md)) {
            rowsStepper(
                value: Binding(
                    get: { MonitorWidgetDraft.processCount(placement) },
                    set: { onUpdate(MonitorWidgetDraft.settingProcessCount($0, on: placement)) }
                ),
                in: MonitorWidgetDraft.processCountRange, first: true
            )
        }
    }

    // MARK: CPU

    private var cpuOptions: some View {
        VStack(alignment: .leading, spacing: spacing(DesignTokens.Spacing.sm)) {
            historyWindowPicker(defaultWindow: MonitorCPUDraft.defaultHistoryWindow(for: placement.size), first: true)
            VStack(spacing: spacing(DesignTokens.Spacing.xs)) {
                toggleRow("Show heatmap", icon: "square.grid.3x3.fill",
                          isOn: boolBinding(key: MonitorCPUDraft.showHeatmapKey, default: true))
                toggleRow("Show composition", icon: "chart.pie",
                          isOn: boolBinding(key: MonitorCPUDraft.showCompositionKey, default: true))
                toggleRow("Show sensors", icon: "thermometer.medium",
                          isOn: boolBinding(key: MonitorCPUDraft.showSensorsKey, default: true))
                if placement.size == .small {
                    toggleRow("Show history curve", icon: "chart.xyaxis.line",
                              isOn: boolBinding(key: MonitorWidgetDraft.showTrendKey, default: true))
                }
            }
        }
    }

    // MARK: GPU

    private var gpuOptions: some View {
        VStack(alignment: .leading, spacing: spacing(DesignTokens.Spacing.sm)) {
            historyWindowPicker(defaultWindow: 60, first: true)
            gpuSamplingPicker()
            VStack(spacing: spacing(DesignTokens.Spacing.xs)) {
                toggleRow("Show load breakdown", icon: "chart.bar.xaxis",
                          isOn: boolBinding(key: MonitorWidgetDraft.showLoadBreakdownKey, default: true))
                toggleRow("Show sensors", icon: "thermometer.medium",
                          isOn: boolBinding(key: MonitorWidgetDraft.showSensorsKey, default: true))
                if placement.size == .small {
                    toggleRow("Show history curve", icon: "chart.xyaxis.line",
                              isOn: boolBinding(key: MonitorWidgetDraft.showTrendKey, default: true))
                }
            }
        }
    }

    /// GPU IOAccelerator sample cadence (default 6s).
    private func gpuSamplingPicker(first: Bool = false) -> some View {
        optionRow("Sampling interval", icon: "timer", first: first) {
            GlassSegmentedPicker(
                selection: Binding(
                    get: { MonitorWidgetDraft.gpuSampleSeconds(placement) ?? MonitorWidgetDraft.gpuDefaultSeconds },
                    set: { onUpdate(MonitorWidgetDraft.settingGPUSampleSeconds($0, on: placement)) }
                ),
                values: MonitorWidgetDraft.gpuSampleChoices,
                shell: .flat
            ) { seconds, isSelected in
                Text(verbatim: "\(Int(seconds))s")
                    .font(isSelected ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
            }
            .frame(width: 120)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("GPU sampling interval"))
        }
    }

    // MARK: Memory

    private var memoryOptions: some View {
        VStack(alignment: .leading, spacing: spacing(DesignTokens.Spacing.sm)) {
            historyWindowPicker(defaultWindow: placement.size == .large ? 120 : 60, first: true)
            breakdownPicker
            topProcessesRow
        }
    }

    // MARK: Disk

    private var diskOptions: some View {
        VStack(alignment: .leading, spacing: spacing(DesignTokens.Spacing.sm)) {
            historyWindowPicker(defaultWindow: 120, first: true)
            breakdownPicker
            topProcessesRow
        }
    }

    /// Embedded, the size note is the row's subtitle; the popover prints it underneath.
    private var topProcessesRow: some View {
        VStack(alignment: .leading, spacing: spacing(DesignTokens.Spacing.xs)) {
            toggleRow("Show top processes", icon: "list.bullet",
                      note: placement.size == .large ? nil : "Top processes are hidden at this size.",
                      isOn: boolBinding(key: MonitorWidgetDraft.showTopProcessesKey, default: true))
            if !embedded, placement.size != .large {
                Text("Top processes are hidden at this size.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Agent Session

    private var agentSessionOptions: some View {
        let fallback = placement.size == .large
            ? AgentSessionWidgetView.largeRowCap
            : AgentSessionWidgetView.mediumRowCap
        return VStack(alignment: .leading, spacing: spacing(DesignTokens.Spacing.md)) {
            providerPicker(key: AgentSessionWidgetView.Option.provider, first: true)
            sortPicker
            rowsStepper(
                value: Binding(
                    get: { AgentSessionWidgetView.rowCap(placement.options, fallback: fallback) },
                    set: { onUpdate(MonitorWidgetDraft.settingAgentSessionMaxRows($0, fallback: fallback, on: placement)) }
                ),
                in: 1 ... fallback
            )
        }
    }

    private var sortBinding: Binding<AgentSessionWidgetView.SortMode> {
        Binding(
            get: { AgentSessionWidgetView.sortMode(placement.options) },
            set: { onUpdate(MonitorWidgetDraft.settingAgentSessionSort($0, on: placement)) }
        )
    }

    @ViewBuilder
    private var sortChoices: some View {
        Text("Attention").tag(AgentSessionWidgetView.SortMode.attention)
        Text("Recent").tag(AgentSessionWidgetView.SortMode.recent)
    }

    @ViewBuilder
    private var sortPicker: some View {
        if embedded {
            Divider()
            SettingRow(icon: "arrow.up.arrow.down", iconColor: .blue, title: "Sort") {
                Picker("", selection: sortBinding) { sortChoices }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Sort"))
            }
        } else {
            Picker(selection: sortBinding) { sortChoices } label: {
                Text("Sort")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func rowsStepper(value: Binding<Int>, in range: ClosedRange<Int>, first: Bool = false) -> some View {
        if embedded {
            if !first {
                Divider()
            }
            SettingRow(icon: "list.number", iconColor: .blue, title: "Rows") {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(verbatim: "\(value.wrappedValue)")
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                    Stepper("", value: value, in: range)
                        .labelsHidden()
                        .accessibilityLabel(Text("Rows"))
                }
            }
        } else {
            Stepper(value: value, in: range) {
                HStack {
                    Text("Rows")
                    Spacer()
                    Text(verbatim: "\(value.wrappedValue)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Shared controls

    private func historyWindowPicker(defaultWindow: Int, first: Bool = false) -> some View {
        optionRow("History window", icon: "clock.arrow.circlepath", first: first) {
            GlassSegmentedPicker(
                selection: Binding(
                    get: { MonitorWidgetDraft.historyWindowTag(placement, clearValue: defaultWindow) },
                    set: { onUpdate(MonitorWidgetDraft.settingHistoryWindow(tag: $0, clearValue: defaultWindow, on: placement)) }
                ),
                values: [30, 60, 120],
                shell: .flat
            ) { seconds, isSelected in
                Text(verbatim: "\(seconds)s")
                    .font(isSelected ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
            }
            .frame(width: 140)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("History window"))
        }
    }

    private var breakdownPicker: some View {
        optionRow("Breakdown", icon: "chart.bar") {
            GlassSegmentedPicker(
                selection: Binding(
                    get: { MonitorWidgetDraft.breakdownCompact(placement) },
                    set: { onUpdate(MonitorWidgetDraft.settingBreakdownCompact($0, on: placement)) }
                ),
                values: [false, true],
                shell: .flat,
                title: { $0 ? "Compact" : "Full" }
            )
            .frame(width: 140)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Breakdown"))
        }
    }

    private func providerPicker(key: String, first: Bool = false) -> some View {
        optionRow("Provider", icon: "person.2", first: first) {
            GlassSegmentedPicker(
                selection: Binding(
                    get: { MonitorWidgetDraft.providerTag(placement, key: key) },
                    set: { onUpdate(MonitorWidgetDraft.settingProvider($0, key: key, on: placement)) }
                ),
                values: ["all", "claude", "codex"],
                shell: .flat
            ) { provider, isSelected in
                Group {
                    switch provider {
                    case "claude": Text(verbatim: "Claude")
                    case "codex": Text(verbatim: "Codex")
                    default: Text("All")
                    }
                }
                .font(isSelected ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
            }
            .frame(width: 160)
            .accessibilityElement(children: .contain)
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

    /// `first` leaves out the divider an embedded row otherwise draws above itself.
    @ViewBuilder
    private func optionRow<Control: View>(
        _ title: LocalizedStringKey,
        icon: String,
        first: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        let control = control()
        if embedded {
            if !first {
                Divider()
            }
            SettingRow(icon: icon, iconColor: .blue, title: title) {
                control.fixedSize()
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(title).font(.subheadline)
                    Spacer(minLength: DesignTokens.Spacing.sm)
                    control.fixedSize()
                }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(title).font(.subheadline)
                    control.frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func toggleRow(
        _ title: LocalizedStringKey,
        icon: String,
        first: Bool = false,
        note: LocalizedStringKey? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        if embedded {
            if !first {
                Divider()
            }
            SettingRow(icon: icon, iconColor: .orange, title: title, subtitle: note) {
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(Text(title))
            }
        } else {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(title).font(.subheadline)
                Spacer(minLength: 8)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Labels

    static func sizeLabel(_ size: MonitorWidgetSize) -> LocalizedStringKey {
        switch size {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

}

// MARK: - Pure draft mutations (unit-tested)

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

    static func gpuSampleSeconds(in widgets: [MonitorWidgetPlacement]) -> Double? {
        widgets.filter { $0.kind == .gpu || $0.kind == .systemOverview }
            .map { gpuSampleSeconds($0) ?? gpuDefaultSeconds }
            .min()
    }

    static func settingGPUSampleSeconds(
        _ value: Double, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if value == gpuDefaultSeconds || !gpuSampleChoices.contains(value) {
            next.options.removeValue(forKey: gpuSampleSecondsKey)
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
        _ mode: AgentSessionWidgetView.SortMode, on placement: MonitorWidgetPlacement
    ) -> MonitorWidgetPlacement {
        var next = placement
        if mode == .attention {
            next.options.removeValue(forKey: AgentSessionWidgetView.Option.sort)
        } else {
            next.options[AgentSessionWidgetView.Option.sort] = .string(mode.rawValue)
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
            next.options.removeValue(forKey: AgentSessionWidgetView.Option.maxRows)
        } else {
            next.options[AgentSessionWidgetView.Option.maxRows] = .number(Double(clamped))
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
