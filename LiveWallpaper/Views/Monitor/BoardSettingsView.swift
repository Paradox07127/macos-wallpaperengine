import AppKit
import LiveWallpaperCore
import SwiftUI
import UniformTypeIdentifiers

struct BoardSettingsView: View {
    let screen: Screen
    let screenManager: ScreenManager

    @AppStorage("Monitor.SettingsExpanded") private var isExpanded = true
    @AppStorage("Monitor.AuthorizationExpanded") private var isAuthorizationExpanded = true

    @State private var draft: MonitorBoardConfiguration = .default

    @State private var claudeAuthorized = false
    @State private var codexAuthorized = false
    @State private var showsAgentActivity = false

    /// Display-only temperature unit for every sensor readout (app-wide, not per-board).


    var body: some View {
        VStack(spacing: 12) {
            boardSection
            authorizationSection
        }
        .onAppear(perform: reload)
        .onChange(of: screen.id) { _, _ in reload() }
        // Board edits made on the preview or the live overlay bypass this panel.
        .onChange(of: persistedBoard) { _, _ in reload() }
        .sheet(isPresented: $showsAgentActivity) { AgentActivityPanel() }
    }

    private var boardSection: some View {
        GroupBox {
            CollapsibleSection(
                title: "Monitor",
                systemImage: "gauge.with.dots.needle.67percent",
                isExpanded: $isExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    refreshRateRow
                    Divider()
                    mouseInteractionRow
                    Divider()
                    reduceMotionRow
                    Divider()
                    layoutManagementRow
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var authorizationSection: some View {
        GroupBox {
            CollapsibleSection(
                title: "AI Session History Access",
                systemImage: "folder.badge.person.crop",
                isExpanded: $isAuthorizationExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    authorizationRows
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    // MARK: - Board-level controls

    private var refreshRateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(
                icon: "arrow.triangle.2.circlepath",
                iconColor: .blue,
                title: "Refresh Interval (seconds)",
                info: "Longer sampling intervals use less energy."
            ) {
                Text(verbatim: Self.refreshIntervalLabel(draft.refreshIntervalSeconds))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.secondary)
                    .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
            }
            // Bind the step index so unequal time intervals have equal drag distances.
            Slider(
                value: Binding(
                    get: { Double(Self.refreshIntervalIndex(draft.refreshIntervalSeconds)) },
                    set: { draft.refreshIntervalSeconds = Self.refreshInterval(atIndex: Int($0.rounded())) }
                ),
                in: 0...Double(MonitorBoardConfiguration.refreshIntervalSteps.count - 1),
                step: 1,
                onEditingChanged: { editing in
                    if !editing { commit(draft) }
                }
            )
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("Refresh Interval (seconds)"))
            .accessibilityValue(Text(verbatim: Self.refreshIntervalLabel(draft.refreshIntervalSeconds)))
        }
    }

    private var mouseInteractionRow: some View {
        SettingRow(
            icon: "cursorarrow.rays",
            iconColor: draft.mouseInteractionEnabled ? .blue : .secondary,
            title: "Mouse Interaction",
            info: "Receives clicks that would otherwise reach the desktop."
        ) {
            Toggle("", isOn: Binding(
                get: { draft.mouseInteractionEnabled },
                set: { setMouseInteraction($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(Text("Enable mouse interaction"))
        }
    }

    private var reduceMotionRow: some View {
        SettingRow(
            icon: "wind",
            iconColor: .teal,
            title: "Reduce Motion"
        ) {
            Picker("", selection: Binding(
                get: { ReduceMotionChoice(draft.reduceMotionOverride) },
                set: { setReduceMotion($0) }
            )) {
                Text("System").tag(ReduceMotionChoice.system)
                Text("On").tag(ReduceMotionChoice.on)
                Text("Off").tag(ReduceMotionChoice.off)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Reduce motion"))
        }
    }





    // MARK: - Layout management (reset / import / export)

    private var layoutManagementRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(
                icon: "square.grid.2x2",
                iconColor: .purple,
                title: "Layout",
                subtitle: "Reset replaces widgets. Import replaces widgets and board settings."
            ) {
                EmptyView()
            }
            HStack(spacing: 6) {
                Button("Reset", action: resetLayout)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(isDefaultLayout)
                Button("Import", action: importLayout)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                Button("Export", action: exportLayout)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(draft.widgets.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var isDefaultLayout: Bool {
        let defaults = MonitorBoardConfiguration.defaultSystemPlacements()
        let current = draft.widgets
        guard current.count == defaults.count else { return false }
        func key(_ p: MonitorWidgetPlacement) -> String {
            "\(p.kind.rawValue)|\(p.size.rawValue)|\((p.x * 1000).rounded())|\((p.y * 1000).rounded())"
        }
        return Set(current.map(key)) == Set(defaults.map(key))
    }

    // MARK: - AI-agent surfaces

    @ViewBuilder
    private var authorizationRows: some View {
        Button("Open Agent Activity") { showsAgentActivity = true }
            .buttonStyle(.bordered)
        authorizationRow(
            title: "Claude Folder",
            subtitle: "Read-only access to ~/.claude",
            info: "Used by Agent Session and Agent Activity to display session metadata. Prompt text, replies and tool arguments are excluded.",
            isAuthorized: claudeAuthorized,
            authorize: {
                SourceAuthorization.shared.requestAccess(for: .claude, from: hostWindow()) {
                    refreshAuthorizationState()
                    Task { await Runtime.shared.refreshSources() }
                }
            },
            revoke: { revoke(.claude) }
        )

        Divider()

        authorizationRow(
            title: "Codex Folder",
            subtitle: "Read-only access to ~/.codex",
            info: "Used by Agent Session and Agent Activity to display session metadata. Prompt text, replies and tool arguments are excluded.",
            isAuthorized: codexAuthorized,
            authorize: {
                SourceAuthorization.shared.requestAccess(for: .codex, from: hostWindow()) {
                    refreshAuthorizationState()
                    Task { await Runtime.shared.refreshSources() }
                }
            },
            revoke: { revoke(.codex) }
        )
    }

    @ViewBuilder
    private func authorizationRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        info: String.LocalizationValue,
        isAuthorized: Bool,
        authorize: @escaping () -> Void,
        revoke: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(
                icon: "folder.badge.person.crop",
                iconColor: .indigo,
                title: title,
                titleBadge: isAuthorized
                    ? SettingRowTitleBadge(
                        systemImage: "checkmark.circle.fill",
                        tint: DesignTokens.Colors.Status.active,
                        accessibilityLabel: Text("Authorized")
                    )
                    : nil,
                subtitle: subtitle,
                info: info
            ) {
                if !isAuthorized {
                    Button("Authorize", action: authorize)
                        .fixedSize()
                }
            }
            if isAuthorized {
                HStack(spacing: 6) {
                    Button("Revoke", action: revoke)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    Button("Re-authorize", action: authorize)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func revoke(_ provider: SourceAuthorization.Provider) {
        SourceAuthorization.shared.revokeAccess(provider)
        refreshAuthorizationState()
        Task { await Runtime.shared.refreshSources() }
    }

    // MARK: - Draft mutations (persist through ScreenManager)

    private func setMouseInteraction(_ enabled: Bool) {
        var next = draft
        next.mouseInteractionEnabled = enabled
        commit(next)
    }

    private func setReduceMotion(_ choice: ReduceMotionChoice) {
        var next = draft
        next.reduceMotionOverride = choice.override
        commit(next)
    }

    // MARK: - Layout reset / import / export

    private func resetLayout() {
        var next = draft
        next.widgets = MonitorBoardConfiguration.defaultSystemPlacements()
        commit(next)
    }

    private func exportLayout() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "monitor-layout.json"
        panel.canCreateDirectories = true
        panel.title = String(localized: "Export Widget Layout", bundle: .appLanguage, comment: "Save-panel title for exporting a widget board layout.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(draft).write(to: url, options: .atomic)
        } catch {
            presentLayoutError(error, isImport: false)
        }
    }

    private func importLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = String(localized: "Import Widget Layout", bundle: .appLanguage, comment: "Open-panel title for importing a widget board layout.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: data)
            var next = imported
            next.widgets = imported.widgets.map { w in
                MonitorWidgetPlacement(kind: w.kind, size: w.size, x: w.x, y: w.y, options: w.options)
            }
            next.schemaVersion = MonitorBoardConfiguration.currentSchemaVersion
            commit(next)
        } catch {
            presentLayoutError(error, isImport: true)
        }
    }

    private func presentLayoutError(_ error: Error, isImport: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isImport
            ? String(localized: "Couldn’t import layout", bundle: .appLanguage, comment: "Alert title when a monitor layout file fails to import.")
            : String(localized: "Couldn’t export layout", bundle: .appLanguage, comment: "Alert title when a monitor layout file fails to export.")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK", bundle: .appLanguage, comment: "Dismiss button on the monitor layout error alert."))
        if let window = hostWindow() {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func commit(_ config: MonitorBoardConfiguration) {
        draft = config
        screenManager.setMonitorOverlayBoard(config, for: screen)
    }

    // MARK: - Loading

    private var persistedBoard: MonitorBoardConfiguration {
        screenManager.monitorOverlay(for: screen).board
    }

    private func reload() {
        draft = persistedBoard
        refreshAuthorizationState()
    }

    private func refreshAuthorizationState() {
        claudeAuthorized = SourceAuthorization.shared.isAuthorized(.claude)
        codexAuthorized = SourceAuthorization.shared.isAuthorized(.codex)
    }

    private func hostWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
    }

    // MARK: - Formatting helpers

    nonisolated static func refreshIntervalLabel(_ seconds: Double) -> String {
        let snapped = MonitorBoardConfiguration.snappedRefreshInterval(seconds)
        return snapped == snapped.rounded()
            ? String(format: "%.0f", snapped)
            : String(format: "%.1f", snapped)
    }

    nonisolated static func refreshIntervalIndex(_ seconds: Double) -> Int {
        let snapped = MonitorBoardConfiguration.snappedRefreshInterval(seconds)
        return MonitorBoardConfiguration.refreshIntervalSteps.firstIndex(of: snapped) ?? 0
    }

    nonisolated static func refreshInterval(atIndex index: Int) -> Double {
        let steps = MonitorBoardConfiguration.refreshIntervalSteps
        return steps[min(max(index, 0), steps.count - 1)]
    }

}

// MARK: - Reduce-motion tri-state

enum ReduceMotionChoice: Hashable {
    case system
    case on
    case off

    init(_ override: Bool?) {
        switch override {
        case .none: self = .system
        case .some(true): self = .on
        case .some(false): self = .off
        }
    }

    var override: Bool? {
        switch self {
        case .system: return nil
        case .on: return true
        case .off: return false
        }
    }
}
