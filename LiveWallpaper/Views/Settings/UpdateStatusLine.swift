import SwiftUI
import AppKit
import LiveWallpaperCore

/// Shows update status beneath the app version; actions open Sparkle’s update UI.
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

    /// Missing check history must not be presented as "Up to date".
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
                bundle: .appLanguage, comment: "About page update status when a release is available. Placeholder is the new version."
            )
        }
        guard hasCheckedBefore else {
            return String(
                localized: "Update status unknown",
                bundle: .appLanguage, comment: "About panel update status before any successful check has run."
            )
        }
        return String(
            localized: "Up to date",
            bundle: .appLanguage, comment: "About page update status when current, shown inline under the version line."
        )
    }

    /// Available updates show their version instead of the previous check date.
    private var statusDetail: String? {
        guard updater.availableVersion == nil else { return nil }
        guard let date = updater.lastUpdateCheckDate else { return nil }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        return String(
            localized: "Last checked \(relative)",
            bundle: .appLanguage, comment: "About panel update detail. Placeholder is a relative date string."
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
