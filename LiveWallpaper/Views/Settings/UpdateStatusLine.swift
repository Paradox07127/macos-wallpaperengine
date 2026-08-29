import SwiftUI
import AppKit
import LiveWallpaperCore

/// About-page readout for Sparkle, sitting inline under the version line rather
/// than in a card of its own — the update state is a fact about the build named
/// directly above it, not a separate section. Sparkle owns the actual update UI;
/// this view only reports whether something is pending and offers a manual
/// check, and pressing either control hands off to Sparkle's own dialog.
struct UpdateStatusLine: View {
    @State private var updater = SparkleUpdaterController.shared

    var body: some View {
        HStack(spacing: 5) {
            statusGlyph
            Text(statusTitle)
            if let detail = statusDetail {
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                Text(detail)
            }
            trailingAction
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Status rendering

    /// "No pending update" and "never successfully checked" are different facts.
    /// Reporting the second as "up to date" would tell a user whose feed is
    /// unreachable that they are current, which is the one thing they are not
    /// in a position to know.
    private var hasCheckedBefore: Bool { updater.lastUpdateCheckDate != nil }

    @ViewBuilder
    private var statusGlyph: some View {
        if updater.availableVersion != nil {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.info)
        } else if hasCheckedBefore {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.active)
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        if let version = updater.availableVersion {
            return String(
                localized: "Version \(version) available",
                comment: "About page update status when a release is available. Placeholder is the new version."
            )
        }
        guard hasCheckedBefore else {
            return String(
                localized: "Update status unknown",
                comment: "About panel update status before any successful check has run."
            )
        }
        return String(
            localized: "Up to date",
            comment: "About page update status when current, shown inline under the version line."
        )
    }

    /// When an update is waiting, the useful second fact is what it is, not when
    /// we last looked.
    private var statusDetail: String? {
        guard updater.availableVersion == nil else { return nil }
        guard let date = updater.lastUpdateCheckDate else {
            return String(localized: "Not checked yet", comment: "About panel update detail when no check has run.")
        }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        return String(
            localized: "Last checked \(relative)",
            comment: "About panel update detail. Placeholder is a relative date string."
        )
    }

    @ViewBuilder
    private var trailingAction: some View {
        if updater.availableVersion != nil {
            Button("Open") {
                updater.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .padding(.leading, 2)
        } else {
            Button {
                updater.checkForUpdates()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!updater.canCheckForUpdates)
            .help(Text("Check for updates now"))
            .accessibilityLabel(Text("Check for updates now"))
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
