#if LITE_BUILD
import SwiftUI
import AppKit
import LiveWallpaperCore

/// Renders only in the Loomscreen Lite build. Update delivery remains a manual
/// download from GitHub Releases; this view does not install updates.
struct UpdateBannerView: View {
    @State private var checker = UpdateChecker.shared
    @State private var showingAvailableAlert = false
    @State private var availableRelease: UpdateChecker.LatestRelease?

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
        // If the launch-time check completes BEFORE the About panel is opened, the `.onChange` handler below never fires for that transition.
        .onAppear { presentAvailableAlertIfNeeded(for: checker.status) }
        .onChange(of: checker.status) { _, newStatus in
            presentAvailableAlertIfNeeded(for: newStatus)
        }
        .alert(
            "New version available",
            isPresented: $showingAvailableAlert,
            presenting: availableRelease
        ) { release in
            Button("Open download page") {
                NSWorkspace.shared.open(release.releasePageURL)
            }
            Button("Skip this version") {
                checker.skipCurrentAvailable()
            }
            Button("Later", role: .cancel) {}
        } message: { release in
            let productName = BundleIdentity.productDisplayName
            let versionText = release.version.description
            Text("\(productName) \(versionText) is available. Open the GitHub Releases page to download the new build.")
        }
    }

    // MARK: - Status rendering

    @ViewBuilder
    private var statusGlyph: some View {
        switch checker.status {
        case .idle:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.active)
        case .available:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
        }
    }

    private var statusTitle: String {
        switch checker.status {
        case .idle:
            return String(localized: "Update checker idle", comment: "About panel update status when idle.")
        case .checking:
            return String(localized: "Checking for updates…", comment: "About panel update status while checking.")
        case .upToDate:
            return String(
                localized: "\(BundleIdentity.productDisplayName) is up to date",
                comment: "About panel update status when current. Placeholder is the product name."
            )
        case .available(let release):
            return String(
                localized: "\(BundleIdentity.productDisplayName) \(release.version.description) available",
                comment: "About panel update status when a release is available. Placeholders are product name and version."
            )
        case .failed:
            return String(localized: "Update check failed", comment: "About panel update status after a failed check.")
        }
    }

    private var statusDetail: String? {
        switch checker.status {
        case .idle:
            return lastCheckedSummary
        case .checking:
            return String(
                localized: "Asking GitHub for the latest release tag…",
                comment: "About panel detail while querying GitHub Releases."
            )
        case .upToDate:
            return lastCheckedSummary
        case .available(let release):
            if let publishedAt = release.publishedAt {
                let relative = Self.relativeFormatter.localizedString(for: publishedAt, relativeTo: Date())
                return String(
                    localized: "Released \(relative)",
                    comment: "About panel detail for release date. Placeholder is a relative date string."
                )
            }
            return release.tagName
        case .failed(let reason):
            return reason
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch checker.status {
        case .available(let release):
            Button("Open") {
                NSWorkspace.shared.open(release.releasePageURL)
            }
            .controlSize(.small)
        case .checking:
            EmptyView()
        default:
            Button {
                Task { await checker.checkNow(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(Text("Check for updates now"))
            .accessibilityLabel(Text("Check for updates now"))
        }
    }

    private var lastCheckedSummary: String {
        guard let date = checker.lastCheckedAt else {
            return String(localized: "Not checked yet", comment: "About panel update detail when no check has run.")
        }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        return String(
            localized: "Last checked \(relative)",
            comment: "About panel update detail. Placeholder is a relative date string."
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private func presentAvailableAlertIfNeeded(for status: UpdateChecker.Status) {
        guard case .available(let release) = status else { return }
        availableRelease = release
        showingAvailableAlert = true
    }
}
#endif
