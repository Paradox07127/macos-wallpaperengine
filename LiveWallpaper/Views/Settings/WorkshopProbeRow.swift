#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Collapses probe evidence by default and expands the first failure automatically.
struct WorkshopProbeRow: View {
    let report: DoctorProbeReport
    let service: SteamCMDDoctorService
    let onCopied: () -> Void
    var onConnectAccount: (() -> Void)?

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
        // Include initial status because a probe can finish before the view appears.
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
                        .marqueeOnHover(truncationMode: .tail)
                }

                if hasDetail {
                    Image(systemName: "chevron.right")
                        .font(DesignTokens.Typography.captionEmphasized)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Guard in the action to avoid disabled styling on passing probes.
        .accessibilityHint(
            hasDetail
                ? (isExpanded ? Text("Hide details") : Text("Show details"))
                : Text(verbatim: "")
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
                if needsAccountConnection {
                    DisclosureGroup {
                        TerminalCommandPanel(command: command, redactedPreview: false, onCopied: onCopied)
                    } label: {
                        Text("Use Terminal instead")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TerminalCommandPanel(command: command, redactedPreview: false, onCopied: onCopied)
                }
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
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// Offer a fix only when the probe has an applicable recovery action.
    @ViewBuilder private var fixButton: some View {
        if needsAccountConnection {
            Button("Connect account") { onConnectAccount?() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else if report.id == .binaryIdentity, case .red = report.status {
            // Re-detect rather than re-select: the fix for a bad identity is a
            // binary from a source we trust, not another path typed at us.
            Button("Locate automatically") {
                Task { await service.autoDetectBinary() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Derived

    /// A credential verdict, not a network one: only these are fixed by signing
    /// in again.
    private var needsAccountConnection: Bool {
        guard report.id == .cachedLogin else { return false }
        switch service.cachedLoginVerdict {
        case .noCachedSession, .sessionExpired, .loginFailed: return true
        default: return false
        }
    }

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
            return String(localized: "Checking…", bundle: .appLanguage, comment: "Workshop Doctor probe is running.")
        case .notRun:
            return String(localized: "Not run", bundle: .appLanguage, comment: "Workshop Doctor probe has not been run.")
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
