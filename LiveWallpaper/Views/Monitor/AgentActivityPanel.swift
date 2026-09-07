import AppKit
import LiveWallpaperCore
import SwiftUI

/// A separate consumer: the activity panel works even without a desktop widget.
struct AgentActivityPanel: View {
    private let observesLiveSources: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot = MonitorSnapshot()
    @State private var search = ""
    @State private var provider = "all"
    @State private var activeOnly = false
    @State private var selectedID: String?
    @State private var histories: [String: [MonitorAgentToolEvent]] = [:]
    @State private var paused = false
    @State private var displayTime: Double

    init(snapshot: MonitorSnapshot = MonitorSnapshot(), observesLiveSources: Bool = true) {
        _snapshot = State(initialValue: snapshot)
        _selectedID = State(initialValue: snapshot.agents?.first?.id)
        _displayTime = State(initialValue: snapshot.timestamp)
        self.observesLiveSources = observesLiveSources
    }

    private var sessions: [MonitorAgentSessionState] {
        AgentSessionWidgetView.sorted(snapshot.agents ?? []).filter {
            (provider == "all" || $0.provider.rawValue == provider)
                && (!activeOnly || $0.status == .running || $0.status == .needsInput)
                && (search.isEmpty || [$0.title, $0.projectName, $0.gitBranch].compactMap(\.self)
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SteamSheetHeader(icon: "waveform.path", title: "Agent Activity", subtitle: "Live session activity · metadata only")
                .padding(DesignTokens.Spacing.lg)
            filters
            sourceHealth
            Divider()
            HSplitView {
                sessionList.frame(minWidth: 260, idealWidth: 290, maxWidth: 360)
                detail.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            SheetFooterBar(primaryTitle: "Done", primaryAction: { dismiss() }, leading: {
                Toggle("Pause display", isOn: $paused)
                    .toggleStyle(.checkbox)
                Spacer()
                Text("Recent local sessions")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            })
        }
        .frame(width: 860, height: 620)
        .background(DesignTokens.Colors.pageBackground)
        .task { await observe() }
    }

    private var filters: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            LibrarySearchField(text: $search, prompt: "Search sessions")
            Picker("Provider", selection: $provider) {
                Text("All").tag("all")
                Text(verbatim: "Claude").tag("claude")
                Text(verbatim: "Codex").tag("codex")
            }
            .pickerStyle(.menu)
            Toggle("Active only", isOn: $activeOnly).toggleStyle(.checkbox)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }

    private var sourceHealth: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ForEach((snapshot.health ?? []).filter { ["claude", "codex"].contains($0.sourceID) }, id: \.sourceID) { health in
                Label {
                    Text(verbatim: health.sourceID == "claude" ? "Claude" : "Codex")
                    Text(health.state == "ok" ? "Connected" : "Session source needs attention")
                } icon: {
                    Image(systemName: health.state == "ok" ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(health.state == "ok" ? DesignTokens.Colors.Status.active : DesignTokens.Colors.Status.warning)
                }
            }
            Spacer()
        }
        .font(DesignTokens.Typography.caption)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }

    private var sessionList: some View {
        List(selection: $selectedID) {
            OutlineGroup(AgentSessionTreeNode.build(sessions), children: \.children) { node in
                let session = node.session
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if session.parentSessionID != nil {
                            Image(systemName: "arrow.turn.down.right")
                        }
                        Text(verbatim: session.title ?? session.projectName)
                            .font(DesignTokens.Typography.bodyEmphasized)
                            .lineLimit(1)
                    }
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: AgentPresentation.symbol(session.effectivePhase))
                        Text(verbatim: AgentPresentation.phase(session.effectivePhase))
                    }
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(AgentPresentation.color(session.effectivePhase))
                    Text(verbatim: session.provider.displayName + " · " + session.projectName)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
                .tag(session.id)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if sessions.isEmpty {
                Text("No matching sessions")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let session = sessions.first(where: { $0.id == selectedID }) ?? sessions.first {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    detailHeader(session)
                    usage(session)
                    if let parent = session.parentSessionID {
                        LabeledContent("Parent session") {
                            Text(verbatim: (snapshot.agents ?? []).first(where: { $0.id == parent })?.title ?? String(parent.suffix(12)))
                        }
                    }
                    toolHistory(session)
                }
                .padding(DesignTokens.Spacing.lg)
            }
        } else {
            IllustratedEmptyState(symbol: "waveform.path", title: "No active sessions",
                                  message: "Authorize the agent folders in Widgets settings.")
        }
    }

    private func detailHeader(_ session: MonitorAgentSessionState) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(verbatim: session.title ?? session.projectName).font(DesignTokens.Typography.pageTitle)
            Label(AgentPresentation.phase(session.effectivePhase), systemImage: AgentPresentation.symbol(session.effectivePhase))
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(AgentPresentation.color(session.effectivePhase))
            HStack {
                Text(verbatim: [session.model, session.gitBranch].compactMap(\.self).joined(separator: " · "))
                    .lineLimit(2)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(Text("Copy session ID"))
                    .accessibilityLabel(Text("Copy session ID"))
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            if let started = session.turnStartedAt {
                LabeledContent("Current turn") {
                    Text(verbatim: Format.mmss(max(0, (session.completedAt ?? displayTime) - started)))
                        .font(DesignTokens.Typography.metric)
                }
            }
            LabeledContent("Last activity") {
                Text(verbatim: Format.ago(max(0, displayTime - session.lastEventAt)))
                    .font(DesignTokens.Typography.metric)
            }
            if session.livenessEvidence != "processDescriptor" {
                Text("Activity inferred from local logs")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
    }

    private func usage(_ session: MonitorAgentSessionState) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                LabeledContent("Session tokens", value: Format.tokens(session.totalTokenCount))
                LabeledContent("Output tokens", value: Format.tokens(session.tokens.output))
                LabeledContent("Cached input", value: Format.tokens(session.tokens.cacheRead))
                if let current = session.contextTokens, let window = session.contextWindow, window > 0 {
                    LabeledContent("Last request context", value: "\(Int(min(1, Double(current) / Double(window)) * 100))%")
                    ProgressView(value: min(1, max(0, Double(current) / Double(window))))
                }
                if session.partialHistory == true {
                    Text("Partial history").foregroundStyle(DesignTokens.Colors.Status.warning)
                }
            }
            .font(DesignTokens.Typography.metric)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private func toolHistory(_ session: MonitorAgentSessionState) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Tool activity").font(DesignTokens.Typography.sectionTitle)
            let tools = (histories[session.id] ?? session.toolActivity ?? session.recentTools ?? []).filter { $0.name != "exec" }
            if tools.isEmpty {
                Text("No tool events yet").foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            ForEach(Array(tools.reversed().enumerated()), id: \.offset) { _, tool in
                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: tool.ok == false ? "exclamationmark.circle" : (tool.completedAt == nil ? "circle.dotted" : "checkmark.circle"))
                        .foregroundStyle(tool.ok == false ? DesignTokens.Colors.Status.warning : DesignTokens.Colors.textSecondary)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text(verbatim: tool.name).font(DesignTokens.Typography.codeCaption)
                        Text(verbatim: AgentPresentation.toolOutcome(tool)).font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                    Spacer()
                    if let duration = tool.durationSeconds {
                        Text(verbatim: Format.mmss(duration)).font(DesignTokens.Typography.metric)
                    }
                    Text(Date(timeIntervalSince1970: tool.at), style: .time).font(DesignTokens.Typography.metric)
                }
                Divider()
            }
        }
    }

    @MainActor private func observe() async {
        guard observesLiveSources else { return }
        SourceRegistration.registerDefaultFactories()
        let slot = Runtime.shared.makeLeaseSlot()
        let handle = slot.acquire(options: MonitorRuntimeOptions(system: false, agents: true, activeWidgetKinds: [.fleet]))
        defer { handle.release() }
        var generation: UInt64 = 0
        while !Task.isCancelled {
            if !paused {
                displayTime = Date().timeIntervalSince1970
            }
            if !paused, let update = Runtime.shared.broker.latest(after: generation) {
                generation = update.generation
                snapshot = update.snapshot
                if selectedID == nil || !(snapshot.agents ?? []).contains(where: { $0.id == selectedID }) {
                    selectedID = sessions.first?.id
                }
                histories = histories.filter { key, _ in (snapshot.agents ?? []).contains { $0.id == key } }
                for session in snapshot.agents ?? [] {
                    var history = histories[session.id] ?? []
                    for tool in session.toolActivity ?? session.recentTools ?? [] {
                        if let index = history.firstIndex(where: { $0.id == tool.id && $0.at == tool.at }) {
                            history[index] = tool
                        } else {
                            history.append(tool)
                        }
                    }
                    histories[session.id] = Array(history.sorted { $0.at < $1.at }.suffix(128))
                }
            } else if !paused, Runtime.shared.broker.currentGeneration > generation {
                generation = Runtime.shared.broker.currentGeneration
                snapshot = MonitorSnapshot()
                histories.removeAll()
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
        }
    }
}
