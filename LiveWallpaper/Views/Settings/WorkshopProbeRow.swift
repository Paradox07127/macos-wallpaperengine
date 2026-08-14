#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// One diagnostic probe, as a row that states its conclusion and hides its
/// evidence until asked.
///
/// The previous row laid everything out at once — name, monospaced value, a
/// paragraph of description, a terminal panel, and a button strip — so five of
/// them stacked read as a log rather than a checklist. Here the collapsed row
/// is a single line (status, name, result), and the description, the command
/// and the fix only appear when the row is expanded. Failing probes expand
/// themselves, because a checklist nobody opens is not a diagnostic.
struct WorkshopProbeRow: View {
    let report: DoctorProbeReport
    let service: SteamCMDDoctorService
    let onCopied: () -> Void

    @State private var isExpanded = false
    /// Distinguishes "the user has not touched this row" from "the user closed
    /// it": a failure auto-expands once, and stays closed if they close it.
    @State private var didAutoExpand = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            summaryRow
            if isExpanded, hasDetail {
                detail
                    .padding(.leading, Self.glyphColumn)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: report.status)
        // `initial: true`: probes often finish before this sheet is opened
        // (autoConfigureIfNeeded runs on .task), so without it a row that was
        // already failing on first render never expands itself.
        .onChange(of: report.status, initial: true) { _, status in
            guard !didAutoExpand, isFailure(status) else { return }
            didAutoExpand = true
            isExpanded = true
        }
    }

    /// Glyph width + its spacing, so expanded detail lines up under the title
    /// rather than under the icon.
    private static let glyphColumn: CGFloat = 16 + DesignTokens.Spacing.sm

    private var summaryRow: some View {
        Button {
            guard hasDetail else { return }
            isExpanded.toggle()
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                SteamStatusGlyph(state: stepState)

                Text(report.id.displayName)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.primary)

                Spacer(minLength: DesignTokens.Spacing.sm)

                if let resultText {
                    Text(resultText)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if hasDetail {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Deliberately not `.disabled(!hasDetail)`: SwiftUI dims the whole
        // label, so every *passing* probe would render greyed out — the one
        // state that must look confident. The action guards instead.
        .accessibilityHint(
            hasDetail
                ? (isExpanded ? Text("Hide details") : Text("Show details"))
                : Text("")
        )
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if let descriptionText {
                Text(descriptionText)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let command = commandFromStatus {
                TerminalCommandPanel(command: command, redactedPreview: false, onCopied: onCopied)
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                fixButton
                Spacer(minLength: 0)
                Button {
                    Task { await service.runProbe(report.id) }
                } label: {
                    Label("Re-run", systemImage: "arrow.clockwise")
                        .font(DesignTokens.Typography.caption)
                }
                .buttonStyle(.link)
                .help(Text("Re-run this probe"))
            }
        }
    }

    /// Only the probes with a real remedy get a button; the rest would be a
    /// row of greyed verbs teaching the user nothing.
    @ViewBuilder private var fixButton: some View {
        if report.id == .binaryIdentity, case .red = report.status {
            // Re-detect rather than re-select: the fix for a bad identity is a
            // binary from a source we trust, not another path typed at us.
            Button("Locate automatically") {
                Task { await service.autoDetectBinary() }
            }
            .adaptiveGlassButton(.regular, size: .small)
        }
    }

    // MARK: - Derived

    private var stepState: WorkshopStepState {
        switch report.status {
        case .green: return .ready
        case .running: return .working
        case .yellow, .red: return .attention
        case .notRun: return .notStarted
        }
    }

    private func isFailure(_ status: DoctorProbeStatus) -> Bool {
        switch status {
        case .yellow, .red: return true
        default: return false
        }
    }

    /// The one-line conclusion on the collapsed row. A passing probe shows what
    /// it found; a failing one says so in a word and keeps the sentence inside.
    private var resultText: String? {
        switch report.status {
        case .green(let detail):
            if report.id == .cachedLogin, let user = service.username { return user }
            return detail
        case .running:
            return String(localized: "Checking…", comment: "Workshop Doctor probe is running.")
        case .notRun:
            return String(localized: "Not run", comment: "Workshop Doctor probe has not been run.")
        case .yellow, .red:
            return nil
        }
    }

    private var descriptionText: String? {
        switch report.status {
        case .yellow(let message, _), .red(let message, _): return message
        default: return nil
        }
    }

    private var commandFromStatus: String? {
        switch report.status {
        case .yellow(_, let command), .red(_, let command): return command
        default: return nil
        }
    }

    private var hasDetail: Bool {
        descriptionText != nil || commandFromStatus != nil
    }
}
#endif
