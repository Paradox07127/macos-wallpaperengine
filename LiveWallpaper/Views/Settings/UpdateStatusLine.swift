import SwiftUI
import AppKit
import LiveWallpaperCore

/// About-page readout for Sparkle. Sparkle owns the actual update UI — this
/// view only reports whether something is pending and offers a manual check;
/// pressing either control hands off to Sparkle's own dialog.
struct UpdateBannerView: View {
    @State private var updater = SparkleUpdaterController.shared

    var body: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                statusGlyph
                    .font(.title3)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.medium))
                    if let detail = statusDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingAction
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
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
                localized: "\(BundleIdentity.productDisplayName) \(version) available",
                comment: "About panel update status when a release is available. Placeholders are product name and version."
            )
        }
        guard hasCheckedBefore else {
            return String(
                localized: "Update status unknown",
                comment: "About panel update status before any successful check has run."
            )
        }
        return String(
            localized: "\(BundleIdentity.productDisplayName) is up to date",
            comment: "About panel update status when current. Placeholder is the product name."
        )
    }

    private var statusDetail: String? {
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
            .controlSize(.small)
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
