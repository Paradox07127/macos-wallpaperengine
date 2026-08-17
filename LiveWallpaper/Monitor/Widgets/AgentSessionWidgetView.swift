import AppKit
import SwiftUI
import LiveWallpaperCore

struct AgentSessionWidgetView: View {
    let context: MonitorWidgetContext

    private var reduceMotion: Bool { context.reduceMotion }

    /// Sessions the module has, or nil when the runtime is not sampling agents (no agent-session widget placed).
    private var sessions: [MonitorAgentSessionState]? { context.snapshot.agents }

    /// Per-placement tuning bag (read-only here; the settings popover writes it).
    private var options: [String: MonitorWidgetOptionValue] { context.placement.options }

    /// Sessions after the provider filter — the set every count / row derives from
    /// so a filtered board's aggregate matches its rows.
    private var visibleSessions: [MonitorAgentSessionState] {
        Self.filtered(sessions ?? [], provider: Self.providerFilter(options))
    }

    var body: some View {
        GeometryReader { geo in
            let rowSpan: CGFloat = context.placement.size == .large ? 4 : 2
            let cellHeight = geo.size.height / rowSpan
            content(cellHeight: cellHeight, now: context.now.timeIntervalSince1970)
        }
    }

    @ViewBuilder
    private func content(cellHeight: CGFloat, now: Double) -> some View {
        switch context.placement.size {
        case .small, .medium:
            mediumBody(cellHeight: cellHeight, now: now)
        case .large:
            largeBody(cellHeight: cellHeight, now: now)
        }
    }

    // MARK: - Derived agent-session state

    private var ordered: [MonitorAgentSessionState] {
        Self.sorted(visibleSessions, mode: Self.sortMode(options))
    }

    private var counts: Self.Counts { Self.counts(visibleSessions) }

    private func totals(now: Double) -> Self.Totals { Self.totals(visibleSessions, now: now) }

    // MARK: - M (364×170) — action strip + up to 3 single-line rows

    @ViewBuilder
    private func mediumBody(cellHeight: CGFloat, now: Double) -> some View {
        let scale = AgentTypeScale(cellHeight: cellHeight)
        let cap = Self.rowCap(options, fallback: Self.mediumRowCap)
        let rows = Self.mediumRows(ordered, cap: cap)
        let hiddenCount = visibleSessions.count - rows.count
        shell(scale: scale, cellHeight: cellHeight) {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: scale.gap) {
                    actionStrip(scale: scale, now: now)
                    ForEach(rows) { session in
                        AgentSessionCompactRow(session: session, now: now,
                                               reduceMotion: reduceMotion, scale: scale)
                    }
                    if hiddenCount > 0 { moreWhisper(hiddenCount, scale: scale) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if !visibleSessions.isEmpty {
                idleSummary(scale: scale, now: now)
            } else {
                quietState(scale: scale)
            }
        }
    }

    // MARK: - L (364×376) — action strip + up to 4 two-tier rows

    @ViewBuilder
    private func largeBody(cellHeight: CGFloat, now: Double) -> some View {
        let scale = AgentTypeScale(cellHeight: cellHeight)
        let cap = Self.rowCap(options, fallback: Self.largeRowCap)
        let rows = Self.largeRows(ordered, cap: cap)
        let hiddenCount = visibleSessions.count - rows.count
        shell(scale: scale, cellHeight: cellHeight) {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: scale.gap) {
                    actionStrip(scale: scale, now: now)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                        AgentSessionFullRow(session: session, now: now, isLead: index == 0,
                                            reduceMotion: reduceMotion, scale: scale)
                    }
                    if hiddenCount > 0 { moreWhisper(hiddenCount, scale: scale) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if !visibleSessions.isEmpty {
                idleSummary(scale: scale, now: now)
            } else {
                quietState(scale: scale)
            }
        }
    }

    @ViewBuilder
    private func shell<Body: View>(
        scale: AgentTypeScale,
        cellHeight: CGFloat,
        @ViewBuilder body: @escaping () -> Body
    ) -> some View {
        WidgetContainer(
            label: AgentSessionStrings.title,
            systemImage: "point.3.filled.connected.trianglepath.dotted",
            cellHeight: cellHeight,
            status: { headerStatus(scale: scale) },
            content: body
        )
    }

    // MARK: - Header status ("N agents" + state dot)

    @ViewBuilder
    private func headerStatus(scale: AgentTypeScale) -> some View {
        HStack(spacing: scale.label * 0.5) {
            Text(verbatim: AgentSessionStrings.agentCount(visibleSessions.count))
                .font(Design.subFont(size: scale.label))
                .monospacedDigit()
                .foregroundStyle(Design.inkMuted)
            Circle()
                .fill(counts.needsInput > 0 ? Design.signalCoral : Design.signalAmber)
                .frame(width: scale.label * 0.46, height: scale.label * 0.46)
                .shadow(color: (counts.needsInput > 0 ? Design.signalCoral
                                                      : Design.signalAmber).opacity(0.6),
                        radius: 3)
        }
    }

    // MARK: - Action strip (aggregate one-liner)

    @ViewBuilder
    private func actionStrip(scale: AgentTypeScale, now: Double) -> some View {
        let c = counts
        let t = totals(now: now)
        let alert = c.needsInput > 0 || t.anyWarn
        HStack(spacing: scale.label * 0.6) {
            if c.needsInput > 0 {
                actionSeg(dot: Design.signalCoral, count: c.needsInput,
                          keyword: AgentSessionStrings.needsYou, emphatic: true, scale: scale)
            }
            if c.running > 0 {
                if c.needsInput > 0 { actionDot() }
                actionSeg(dot: Design.signalAmber, count: c.running,
                          keyword: AgentSessionStrings.runningKeyword, emphatic: false, scale: scale)
            }
            if t.longest > 0 {
                actionDot()
                Text(verbatim: Format.mmss(t.longest))
                    .font(Design.subFont(size: scale.body))
                    .monospacedDigit()
                    .foregroundStyle(Design.inkMuted)
            }
            if t.anyWarn {
                actionDot()
                HStack(spacing: scale.label * 0.34) {
                    Circle()
                        .fill(Design.signalCoral)
                        .frame(width: scale.label * 0.44, height: scale.label * 0.44)
                        .shadow(color: Design.signalCoral.opacity(0.6), radius: 3)
                    Text(AgentSessionStrings.warnKeyword)
                        .font(Design.labelFont(size: scale.label))
                        .foregroundStyle(Design.signalCoral)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, scale.label * 0.7)
        .padding(.vertical, scale.label * 0.5)
        .background(
            RoundedRectangle(cornerRadius: AgentSessionRowStyle.radius, style: .continuous)
                .fill(actionStripFill(alert: alert))
                .overlay(
                    RoundedRectangle(cornerRadius: AgentSessionRowStyle.radius, style: .continuous)
                        .strokeBorder(alert ? Design.signalCoral.opacity(0.85)
                                            : Design.panelStroke,
                                      lineWidth: 1)
                )
        )
        .shadow(color: alert ? Design.signalCoral.opacity(0.35) : .clear, radius: alert ? 8 : 0)
        .opacity(alert ? 1 : 0.78)
    }

    private func actionStripFill(alert: Bool) -> LinearGradient {
        if alert {
            return LinearGradient(
                colors: [Design.oklch(0.30, 0.05, 34, alpha: 0.92),
                         Design.oklch(0.235, 0.03, 34, alpha: 0.86)],
                startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(
            colors: [Design.oklch(0.24, 0.013, 74, alpha: 0.9),
                     Design.oklch(0.20, 0.012, 74, alpha: 0.8)],
            startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private func actionSeg(dot: Color, count: Int, keyword: LocalizedStringKey,
                           emphatic: Bool, scale: AgentTypeScale) -> some View {
        HStack(spacing: scale.label * 0.34) {
            Circle()
                .fill(dot)
                .frame(width: scale.label * 0.48, height: scale.label * 0.48)
                .shadow(color: dot.opacity(0.6), radius: 3)
            Text(verbatim: "\(count)")
                .font(Design.subFont(size: scale.body))
                .monospacedDigit()
                .foregroundStyle(emphatic ? Design.oklch(0.94, 0.05, 40) : Design.inkMuted)
            Text(keyword)
                .font(Design.labelFont(size: scale.label))
                .foregroundStyle(Design.inkFaint)
        }
    }

    private func actionDot() -> some View {
        Circle()
            .fill(Design.inkFaint)
            .frame(width: 3, height: 3)
            .opacity(0.5)
    }

    // MARK: - Nothing worth a row (only idle / ended left)

    @ViewBuilder
    private func idleSummary(scale: AgentTypeScale, now: Double) -> some View {
        let c = counts
        VStack(alignment: .leading, spacing: scale.gap) {
            actionStrip(scale: scale, now: now)
            HStack(spacing: scale.body * 0.5) {
                if c.idle > 0 { countChip(Design.signalIdle, c.idle, AgentSessionStrings.idleKeyword, scale) }
                if c.ended > 0 { countChip(Design.signalSage, c.ended, AgentSessionStrings.doneKeyword, scale) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func countChip(_ color: Color, _ count: Int, _ word: LocalizedStringKey,
                           _ scale: AgentTypeScale) -> some View {
        HStack(spacing: scale.label * 0.4) {
            Circle()
                .fill(color)
                .frame(width: scale.label * 0.5, height: scale.label * 0.5)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            (Text(verbatim: "\(count) ") + Text(word))
                .font(Design.subFont(size: scale.body))
                .monospacedDigit()
                .foregroundStyle(Design.inkMuted)
        }
        .padding(.horizontal, scale.label * 0.55)
        .padding(.vertical, scale.label * 0.28)
        .background(
            Capsule(style: .continuous)
                .fill(Design.bg2.opacity(0.55))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(Design.hairlineHi.opacity(0.5), lineWidth: 1))
        )
    }

    // MARK: - Quiet state

    @ViewBuilder
    private func quietState(scale: AgentTypeScale) -> some View {
        let unauthorized = (context.snapshot.health ?? []).contains {
            ($0.sourceID == "claude" || $0.sourceID == "codex") && $0.state == "unauthorized"
        }
        VStack(alignment: .leading, spacing: scale.gap) {
            Spacer(minLength: 0)
            HStack(spacing: scale.label * 0.55) {
                Circle()
                    .fill(unauthorized ? Design.signalAmber : Design.signalIdle)
                    .frame(width: scale.label * 0.5, height: scale.label * 0.5)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                Text(unauthorized ? AgentSessionStrings.authorizeHint : AgentSessionStrings.noActiveSessions)
                    .font(Design.captionFont(size: scale.body))
                    .foregroundStyle(Design.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - "+N more" whisper

    @ViewBuilder
    private func moreWhisper(_ count: Int, scale: AgentTypeScale) -> some View {
        Text(verbatim: AgentSessionStrings.moreCount(count))
            .font(Design.labelFont(size: scale.label))
            .foregroundStyle(Design.inkFaint)
            .opacity(0.8)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Type scale

/// Deliberately not `Design.TypeScale`: that one caps at 12/13 pt, which
/// on a 4K wallpaper renders the session rows unreadable. Floors are what stays
/// legible at arm's length; ceilings stop the L tile from looking like a poster.
struct AgentTypeScale {
    /// Project name — the one thing that must read at a glance.
    let title: CGFloat
    /// Branch / worktree / model / status detail.
    let body: CGFloat
    /// Caps keywords and counts.
    let label: CGFloat
    /// Vertical rhythm between rows and between a row's two tiers.
    let gap: CGFloat

    init(cellHeight: CGFloat) {
        title = min(19, max(13, cellHeight * 0.17))
        body = min(15, max(11, cellHeight * 0.135))
        label = min(13, max(10, cellHeight * 0.115))
        gap = min(8, max(4, cellHeight * 0.06))
    }
}

// MARK: - Compact row (M)

private struct AgentSessionCompactRow: View {
    let session: MonitorAgentSessionState
    let now: Double
    let reduceMotion: Bool
    let scale: AgentTypeScale

    private var status: MonitorAgentStatus { session.status }
    private var accentColor: Color { AgentSessionWidgetView.accentColor(status) }
    private var isBlocked: Bool { status == .needsInput }
    private var isLive: Bool { status == .running || isBlocked }

    var body: some View {
        HStack(spacing: scale.label * 0.5) {
            BreathingDot(color: accentColor, size: scale.label * 0.55,
                         animated: !reduceMotion && isLive)
            AgentProviderMark(provider: session.provider, size: scale.title * 0.82)
            Text(verbatim: session.projectName)
                .font(Design.subFont(size: scale.title))
                .foregroundStyle(status == .ended ? Design.inkMuted
                                 : (isBlocked ? Design.oklch(0.97, 0.02, 40) : Design.inkPrimary))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let scope = AgentSessionWidgetView.scopeLabel(for: session) {
                Text(verbatim: scope)
                    .font(Design.captionFont(size: scale.body))
                    .foregroundStyle(Design.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: scale.label * 0.3)
            if isLive, AgentSessionWidgetView.warningLabel(for: session) != nil {
                Circle()
                    .fill(Design.signalCoral)
                    .frame(width: scale.label * 0.46, height: scale.label * 0.46)
                    .shadow(color: Design.signalCoral.opacity(0.6), radius: 3)
            }
            AgentSessionRowTimer(session: session, now: now, scale: scale)
        }
        .padding(.horizontal, scale.label * 0.7)
        .padding(.vertical, scale.label * 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentSessionRowStyle.fill(isBlocked: isBlocked))
        .overlay(alignment: .leading) {
            AgentSessionRowStyle.accentBar(color: accentColor, isBlocked: isBlocked, scale: scale)
        }
        .clipShape(RoundedRectangle(cornerRadius: AgentSessionRowStyle.radius, style: .continuous))
        .overlay(AgentSessionRowStyle.border(isBlocked: isBlocked))
        .opacity(status == .ended ? 0.55 : 1)
    }
}

// MARK: - Full row (L)

private struct AgentSessionFullRow: View {
    let session: MonitorAgentSessionState
    let now: Double
    var isLead: Bool = false
    let reduceMotion: Bool
    let scale: AgentTypeScale

    private var status: MonitorAgentStatus { session.status }
    private var accentColor: Color { AgentSessionWidgetView.accentColor(status) }
    private var isBlocked: Bool { status == .needsInput }
    private var isLive: Bool { status == .running || isBlocked }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.gap * 0.5) {
            header
            secondTier
            if isLead, isLive {
                TickTrack(events: session.recentEventTimes ?? [], now: now, span: 180,
                          tint: isBlocked ? Design.signalCoral : Design.signalAmber)
                    .frame(height: scale.label)
            }
        }
        .padding(.horizontal, scale.label * 0.7)
        .padding(.vertical, scale.label * 0.55)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AgentSessionRowStyle.fill(isBlocked: isBlocked))
        .overlay(alignment: .leading) {
            AgentSessionRowStyle.accentBar(color: accentColor, isBlocked: isBlocked, scale: scale)
        }
        .clipShape(RoundedRectangle(cornerRadius: AgentSessionRowStyle.radius, style: .continuous))
        .overlay(AgentSessionRowStyle.border(isBlocked: isBlocked))
        .opacity(status == .ended ? 0.55 : (status == .idle ? 0.62 : 1))
    }

    private var header: some View {
        HStack(spacing: scale.label * 0.5) {
            BreathingDot(color: accentColor, size: scale.label * 0.55,
                         animated: !reduceMotion && isLive)
            AgentProviderMark(provider: session.provider, size: scale.title * 0.9)
            Text(verbatim: session.projectName)
                .font(Design.subFont(size: scale.title))
                .foregroundStyle(status == .ended ? Design.inkMuted
                                 : (isBlocked ? Design.oklch(0.97, 0.02, 40) : Design.inkPrimary))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: scale.label * 0.3)
            if let warn = AgentSessionWidgetView.warningLabel(for: session) {
                AgentSessionWarningChip(warn: warn, scale: scale)
                    .fixedSize()
            }
            AgentSessionRowTimer(session: session, now: now, scale: scale)
        }
    }

    /// One line of "where and what": the checkout it runs in, the model, and the
    /// live activity (or the ask, when it is blocked on the user).
    @ViewBuilder
    private var secondTier: some View {
        let scope = AgentSessionWidgetView.scopeLabel(for: session)
        let detail = isBlocked || status == .running ? session.statusDetail : nil
        if scope != nil || session.model != nil || !(detail ?? "").isEmpty {
            HStack(spacing: scale.label * 0.45) {
                if let scope {
                    Text(verbatim: scope)
                        .font(Design.captionFont(size: scale.body))
                        .foregroundStyle(Design.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let model = session.model, !model.isEmpty {
                    if scope != nil { tierDot }
                    Text(verbatim: model)
                        .font(Design.captionFont(size: scale.body))
                        .foregroundStyle(Design.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: scale.label * 0.3)
                // Tokens, unlike the cost we removed, are read straight out of the
                // transcript's usage block — no price table, nothing inferred.
                if let tokens = AgentSessionWidgetView.tokenText(for: session) {
                    Text(verbatim: tokens)
                        .font(Design.subFont(size: scale.body))
                        .monospacedDigit()
                        .foregroundStyle(Design.inkFaint)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        if let detail, !detail.isEmpty {
            Text(verbatim: detail)
                .font(.system(size: scale.body, weight: .regular, design: .monospaced))
                .foregroundStyle(isBlocked ? Design.oklch(0.95, 0.028, 40) : Design.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if isBlocked {
            Text(AgentSessionStrings.needsYou)
                .font(Design.subFont(size: scale.body))
                .foregroundStyle(Design.signalCoral)
                .lineLimit(1)
        }
    }

    private var tierDot: some View {
        Circle()
            .fill(Design.inkFaint)
            .frame(width: 2.5, height: 2.5)
            .opacity(0.5)
    }
}

// MARK: - Shared row pieces

private enum AgentSessionRowStyle {
    static var radius: CGFloat { max(6, Design.cornerRadiusMin) }

    static func fill(isBlocked: Bool) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(isBlocked
                  ? LinearGradient(colors: [Design.oklch(0.315, 0.055, 34, alpha: 0.94),
                                            Design.oklch(0.235, 0.032, 34, alpha: 0.9)],
                                   startPoint: .top, endPoint: .bottom)
                  : LinearGradient(colors: [Design.oklch(0.255, 0.014, 74, alpha: 0.92),
                                            Design.oklch(0.205, 0.013, 74, alpha: 0.86)],
                                   startPoint: .top, endPoint: .bottom))
    }

    static func accentBar(color: Color, isBlocked: Bool, scale: AgentTypeScale) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(width: 2.5)
            .padding(.vertical, scale.label * 0.55)
            .shadow(color: color.opacity(isBlocked ? 0.9 : 0.6), radius: isBlocked ? 6 : 4)
    }

    static func border(isBlocked: Bool) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(isBlocked ? Design.signalCoral.opacity(0.85) : Design.panelStroke,
                          lineWidth: 1)
    }
}

/// Provider mark. Ships as an SF Symbol stand-in; drop the vendors' own icons
/// into the asset catalog under these names and they take over with no code change.
private struct AgentProviderMark: View {
    let provider: MonitorAgentProvider
    let size: CGFloat

    var body: some View {
        Group {
            if let image = NSImage(named: assetName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.86, weight: .medium))
                    .foregroundStyle(Design.inkMuted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(verbatim: provider.displayName))
    }

    private var assetName: String {
        switch provider {
        case .claude: return "provider-claude"
        case .codex: return "provider-codex"
        }
    }

    private var fallbackSymbol: String {
        switch provider {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

private struct AgentSessionRowTimer: View {
    let session: MonitorAgentSessionState
    let now: Double
    let scale: AgentTypeScale

    var body: some View {
        if let timer = AgentSessionWidgetView.timerText(for: session, now: now) {
            Text(verbatim: timer.text)
                .font(Design.subFont(size: scale.body))
                .monospacedDigit()
                .foregroundStyle(Self.color(for: session.status))
                .lineLimit(1)
                .layoutPriority(1)
        } else {
            Text(AgentSessionWidgetView.statusWord(session.status))
                .font(Design.labelFont(size: scale.label))
                .foregroundStyle(Design.inkFaint)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    static func color(for status: MonitorAgentStatus) -> Color {
        switch status {
        case .needsInput: return Design.oklch(0.9, 0.06, 40)
        case .running: return Design.signalAmber
        default: return Design.inkFaint
        }
    }
}

private struct AgentSessionWarningChip: View {
    let warn: AgentSessionWidgetView.WarningInfo
    let scale: AgentTypeScale

    var body: some View {
        HStack(spacing: scale.label * 0.35) {
            Circle()
                .fill(warn.isStale ? Design.signalAmber : Design.signalCoral)
                .frame(width: scale.label * 0.44, height: scale.label * 0.44)
                .shadow(color: (warn.isStale ? Design.signalAmber : Design.signalCoral).opacity(0.6),
                        radius: 3)
            Text(AgentSessionStrings.warningLabel(warn.text))
                .font(Design.labelFont(size: scale.label))
                .foregroundStyle(warn.isStale ? Design.oklch(0.9, 0.07, 80)
                                              : Design.oklch(0.92, 0.06, 44))
                .lineLimit(1)
        }
        .padding(.horizontal, scale.label * 0.42)
        .padding(.vertical, scale.label * 0.16)
        .background(
            Capsule(style: .continuous)
                .fill(warn.isStale ? Design.oklch(0.3, 0.05, 78, alpha: 0.35)
                                   : Design.oklch(0.34, 0.07, 38, alpha: 0.4))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(warn.isStale ? Design.oklch(0.5, 0.1, 78, alpha: 0.7)
                                                   : Design.oklch(0.5, 0.13, 40, alpha: 0.7),
                                      lineWidth: 1)
                )
        )
    }
}

// MARK: - Localizable word literals (catalog keys)

private enum AgentSessionStrings {
    static let title = "Agent Session"

    static var noActiveSessions: LocalizedStringKey { "No active sessions" }
    /// Why-no-data: a wanted AI source has no folder grant (synthesized
    /// `unauthorized` health from the runtime).
    static var authorizeHint: LocalizedStringKey { "Authorize the agent folders in Monitor settings." }

    static var runningKeyword: LocalizedStringKey { "running" }
    static var warnKeyword: LocalizedStringKey { "warn" }
    static var idleKeyword: LocalizedStringKey { "idle" }
    static var doneKeyword: LocalizedStringKey { "done" }

    static var needsYou: LocalizedStringKey { "needs you" }
    static var ended: LocalizedStringKey { "ended" }

    /// "3 agents" — count is data, so composed with a verbatim number at the call
    /// site rather than a format string. The word is the only localizable part.
    static func agentCount(_ n: Int) -> String {
        String(localized: "\(n) agents", comment: "Agent Session widget header: number of tracked agent sessions.")
    }

    static func moreCount(_ n: Int) -> String {
        String(localized: "+\(n) more", comment: "Agent Session widget: whisper for sessions not shown as rows.")
    }

    static func warningLabel(_ raw: String) -> LocalizedStringKey {
        LocalizedStringKey(raw)
    }
}

// MARK: - Pure agent-session logic (tested)

extension AgentSessionWidgetView {
    /// Row caps the layout was measured against — three single-line rows on M,
    /// four two-tier rows on L. Raising these re-introduces clipping.
    static let mediumRowCap = 3
    static let largeRowCap = 4

    nonisolated static func accentColor(_ status: MonitorAgentStatus) -> Color {
        switch status {
        case .running: return Design.signalAmber
        case .needsInput: return Design.signalCoral
        case .ended: return Design.signalSage
        case .idle, .unknown: return Design.signalIdle
        }
    }

    nonisolated static func statusWord(_ status: MonitorAgentStatus) -> LocalizedStringKey {
        switch status {
        case .running: return AgentSessionStrings.runningKeyword
        case .needsInput: return AgentSessionStrings.needsYou
        case .idle: return AgentSessionStrings.idleKeyword
        case .ended: return AgentSessionStrings.ended
        case .unknown: return AgentSessionStrings.idleKeyword
        }
    }

    /// Where the session is working: the worktree name when it runs in one,
    /// otherwise the git branch. Both answer "which checkout", so showing both
    /// is redundant — the worktree is the more specific answer.
    nonisolated static func scopeLabel(for session: MonitorAgentSessionState) -> String? {
        // ⧉ (a second copy) for a worktree, ⑂ for a plain branch — ⌥ reads as the
        // Option key and told the user nothing.
        if let worktree = session.worktreeName, !worktree.isEmpty { return "⧉ " + worktree }
        if let branch = session.gitBranch, !branch.isEmpty { return "⑂ " + branch }
        return nil
    }

    /// "128K tok" from the transcript's own usage counters, or nil before any
    /// usage-bearing event has been seen.
    nonisolated static func tokenText(for session: MonitorAgentSessionState) -> String? {
        let total = session.tokens.input + session.tokens.output
        guard total > 0 else { return nil }
        return Format.tokens(total) + " tok"
    }

    // MARK: settings (read side; the popover writes these keys)

    enum Option {
        static let maxRows = "fleetMaxRows"
        static let provider = "fleetProvider"
        static let sort = "fleetSort"
    }

    enum SortMode: String, Equatable {
        case attention   // default: needsInput > running > idle > ended, then recency
        case recent      // most-recent event first
    }

    /// Provider filter from the option bag; nil == show all (the default).
    nonisolated static func providerFilter(_ options: [String: MonitorWidgetOptionValue]) -> MonitorAgentProvider? {
        switch options[Option.provider]?.stringValue {
        case MonitorAgentProvider.claude.rawValue: return .claude
        case MonitorAgentProvider.codex.rawValue: return .codex
        default: return nil
        }
    }

    nonisolated static func filtered(_ sessions: [MonitorAgentSessionState],
                                     provider: MonitorAgentProvider?) -> [MonitorAgentSessionState] {
        guard let provider else { return sessions }
        return sessions.filter { $0.provider == provider }
    }

    nonisolated static func sortMode(_ options: [String: MonitorWidgetOptionValue]) -> SortMode {
        SortMode(rawValue: options[Option.sort]?.stringValue ?? "") ?? .attention
    }

    nonisolated static func rowCap(_ options: [String: MonitorWidgetOptionValue], fallback: Int) -> Int {
        options[Option.maxRows]?.intValue(clampedTo: 1 ... max(1, fallback)) ?? fallback
    }

    // MARK: sorting

    nonisolated static func sorted(_ sessions: [MonitorAgentSessionState]) -> [MonitorAgentSessionState] {
        sessions.sorted { lhs, rhs in
            let lp = lhs.status.attentionPriority, rp = rhs.status.attentionPriority
            if lp != rp { return lp > rp }
            return lhs.lastEventAt > rhs.lastEventAt
        }
    }

    nonisolated static func sorted(_ sessions: [MonitorAgentSessionState],
                                   mode: SortMode) -> [MonitorAgentSessionState] {
        switch mode {
        case .attention:
            return sorted(sessions)
        case .recent:
            return sessions.sorted { $0.lastEventAt > $1.lastEventAt }
        }
    }

    nonisolated static func mediumRows(_ sorted: [MonitorAgentSessionState],
                                       cap: Int) -> [MonitorAgentSessionState] {
        Array(sorted.filter { $0.status != .idle }.prefix(max(cap, 0)))
    }

    nonisolated static func largeRows(_ sorted: [MonitorAgentSessionState],
                                      cap: Int) -> [MonitorAgentSessionState] {
        Array(sorted.prefix(max(cap, 0)))
    }

    // MARK: counts + totals

    struct Counts: Equatable {
        var running = 0
        var needsInput = 0
        var idle = 0
        var ended = 0
        var unknown = 0
    }

    nonisolated static func counts(_ sessions: [MonitorAgentSessionState]) -> Counts {
        var c = Counts()
        for s in sessions {
            switch s.status {
            case .running: c.running += 1
            case .needsInput: c.needsInput += 1
            case .idle: c.idle += 1
            case .ended: c.ended += 1
            case .unknown: c.unknown += 1
            }
        }
        return c
    }

    struct Totals: Equatable {
        var longest: Double = 0
        var anyWarn = false
    }

    nonisolated static func totals(_ sessions: [MonitorAgentSessionState], now: Double) -> Totals {
        var t = Totals()
        for s in sessions {
            if s.status == .running, let started = s.startedAt {
                let run = now - started
                if run > t.longest { t.longest = run }
            }
            if s.warning != nil { t.anyWarn = true }
        }
        return t
    }

    // MARK: in-status timer source

    struct TimerText: Equatable {
        enum Source: Equatable { case running, waiting, finished }
        var source: Source
        var text: String
    }

    nonisolated static func timerText(for session: MonitorAgentSessionState, now: Double) -> TimerText? {
        switch session.status {
        case .running:
            guard let started = session.startedAt else { return nil }
            return TimerText(source: .running, text: Format.mmss(max(0, now - started)))
        case .needsInput:
            guard let since = session.waitSince else {
                return TimerText(source: .waiting, text: waitingText(0))
            }
            return TimerText(source: .waiting, text: waitingText(max(0, now - since)))
        case .ended:
            return TimerText(source: .finished, text: finishedText(max(0, now - session.lastEventAt)))
        case .idle, .unknown:
            return nil
        }
    }

    private nonisolated static func waitingText(_ seconds: Double) -> String {
        String(localized: "waiting \(Format.mmss(seconds))",
               comment: "Agent Session row timer: how long a session has been blocked waiting for the user; arg is mm:ss.")
    }

    private nonisolated static func finishedText(_ secondsAgo: Double) -> String {
        String(localized: "finished \(Format.ago(secondsAgo)) ago",
               comment: "Agent Session row: how long ago an ended session finished; arg is a compact age like 2m.")
    }

    // MARK: warning chip

    struct WarningInfo: Equatable {
        var text: String
        var isStale: Bool
    }

    nonisolated static func warningLabel(for session: MonitorAgentSessionState) -> WarningInfo? {
        guard let raw = session.warning, !raw.isEmpty else { return nil }
        switch raw {
        case "toolLoop": return WarningInfo(text: "tool loop", isStale: false)
        case "stale": return WarningInfo(text: "stale", isStale: true)
        default: return WarningInfo(text: raw, isStale: false)
        }
    }
}

// MARK: - Previews

#if DEBUG
private extension MonitorWidgetContext {
    static func agentSessionSample(size: MonitorWidgetSize) -> MonitorWidgetContext {
        let now = Date().timeIntervalSince1970
        func events(count: Int, step: Double, from offset: Double = 0) -> [Double] {
            (0..<count).map { now - offset - Double($0) * step }
        }

        var sessions: [MonitorAgentSessionState] = []

        var blocked = MonitorAgentSessionState(
            id: "codex:1", provider: .codex, projectName: "api-server",
            status: .needsInput, lastEventAt: now - 34, processAlive: true)
        blocked.statusDetail = "approve DB migration 0042_add_sessions"
        blocked.model = "gpt-5"
        blocked.gitBranch = "main"
        blocked.startedAt = now - 410
        blocked.waitSince = now - 34
        blocked.turnCount = 31
        blocked.tokens = MonitorTokenTotals(input: 80000, output: 5000)
        blocked.recentEventTimes = events(count: 20, step: 3, from: 34)
        sessions.append(blocked)

        var looping = MonitorAgentSessionState(
            id: "claude:1", provider: .claude, projectName: "LiveWallpaper",
            status: .running, lastEventAt: now - 2, processAlive: true)
        looping.statusDetail = "Bash: swift build"
        looping.model = "opus-5"
        looping.gitBranch = "main"
        looping.worktreeName = "agent-wallpaper"
        looping.startedAt = now - 192
        looping.turnCount = 14
        looping.warning = "toolLoop"
        looping.tokens = MonitorTokenTotals(input: 120000, output: 8000)
        looping.recentEventTimes = events(count: 40, step: 2.5)
        sessions.append(looping)

        var docs = MonitorAgentSessionState(
            id: "claude:2", provider: .claude, projectName: "docs-site",
            status: .running, lastEventAt: now - 5, processAlive: true)
        docs.statusDetail = "Edit: routing.md"
        docs.model = "haiku"
        docs.gitBranch = "fix/links"
        docs.startedAt = now - 47
        docs.turnCount = 6
        docs.recentEventTimes = events(count: 12, step: 9)
        sessions.append(docs)

        var idle = MonitorAgentSessionState(
            id: "claude:4", provider: .claude, projectName: "infra",
            status: .idle, lastEventAt: now - 300, processAlive: true)
        idle.startedAt = now - 900
        idle.turnCount = 2
        sessions.append(idle)

        var done = MonitorAgentSessionState(
            id: "claude:3", provider: .claude, projectName: "scratch",
            status: .ended, lastEventAt: now - 130, processAlive: false)
        done.statusDetail = "summarised logs"
        done.model = "sonnet"
        done.startedAt = now - 600
        done.turnCount = 9
        done.tokens = MonitorTokenTotals(input: 60000, output: 4000)
        sessions.append(done)

        var snapshot = MonitorSnapshot()
        snapshot.timestamp = now
        snapshot.agents = sessions

        return MonitorWidgetContext(
            snapshot: snapshot,
            history: MonitorHistorySnapshot(),
            placement: MonitorWidgetPlacement(kind: .fleet, size: size),
            isEditing: false,
            reduceMotion: false,
            now: Date(timeIntervalSince1970: now)
        )
    }

    static func agentSessionQuiet(size: MonitorWidgetSize) -> MonitorWidgetContext {
        var snapshot = MonitorSnapshot()
        snapshot.timestamp = Date().timeIntervalSince1970
        snapshot.agents = []
        return MonitorWidgetContext(
            snapshot: snapshot, history: MonitorHistorySnapshot(),
            placement: MonitorWidgetPlacement(kind: .fleet, size: size),
            isEditing: false, reduceMotion: false,
            now: Date())
    }
}

#Preview("Agent Session · M") {
    TimelineView(.periodic(from: .now, by: 1)) { t in
        VStack(spacing: 20) {
            AgentSessionWidgetView(context: .agentSessionSample(size: .medium).at(t.date))
                .frame(width: 364, height: 170)
            AgentSessionWidgetView(context: .agentSessionQuiet(size: .medium).at(t.date))
                .frame(width: 364, height: 170)
        }
        .padding(32)
        .background(Design.boardWash)
    }
}

#Preview("Agent Session · L") {
    TimelineView(.periodic(from: .now, by: 1)) { t in
        AgentSessionWidgetView(context: .agentSessionSample(size: .large).at(t.date))
            .frame(width: 364, height: 376)
            .padding(32)
            .background(Design.boardWash)
    }
}
#endif
