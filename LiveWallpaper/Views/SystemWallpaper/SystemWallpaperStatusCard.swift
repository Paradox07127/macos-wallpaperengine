import LiveWallpaperCore
import SwiftUI

/// Answers "is the system side set up?" at the top of the System Wallpaper page.
@available(macOS 26.0, *)
struct SystemWallpaperStatusCard: View {
    let service: WallpaperExportService

    private var health: SystemWallpaperHealth {
        SystemWallpaperHealth.evaluate(
            status: service.status,
            providerIssue: service.providerIssue,
            activeDisplayCount: service.heartbeat?.followingDisplayCount ?? 0
        )
    }

    var body: some View {
        switch health {
        case .unavailable:
            EmptyView()
        case .serviceUnresponsive:
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.warning,
                symbol: "exclamationmark.triangle.fill",
                title: Text("The system wallpaper service is not responding"),
                message: Text("Restarting it briefly redraws all system wallpapers for your account."),
                code: service.maintenance.errorCode,
                surface: .content
            ) {
                restartButton
            }
        case .otherCopyProvides:
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.warning,
                symbol: "exclamationmark.triangle.fill",
                title: Text("Another copy of Loomscreen provides the system wallpaper"),
                message: Text("Quit the other copy, or remove its registration in Settings › System Wallpaper › Manage Extension Registrations."),
                surface: .content
            ) {
                EmptyView()
            }
        case .notConfigured:
            GroupBox {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        Text("Let macOS follow Loomscreen")
                            .font(DesignTokens.Typography.bodyEmphasized)
                        Text("1. Open System Settings › Wallpaper.")
                        Text("2. Choose “\(SystemWallpaperStatusCard.tileName)” for each display.")
                    }
                    .font(DesignTokens.Typography.body)
                    Spacer(minLength: 0)
                    Button("Open Wallpaper Settings") { service.openWallpaperSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        case let .following(displayCount):
            GroupBox {
                HStack(spacing: DesignTokens.Spacing.lg) {
                    Label {
                        Text("Following Loomscreen on \(displayCount) displays")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DesignTokens.Colors.Status.active)
                    }
                    .font(DesignTokens.Typography.body)
                    Spacer(minLength: 0)
                    Button("Open Wallpaper Settings") { service.openWallpaperSettings() }
                        .buttonStyle(.bordered)
                }
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    @ViewBuilder
    private var restartButton: some View {
        let maintenance = service.maintenance
        if maintenance.helperAvailable {
            HStack(spacing: DesignTokens.Spacing.sm) {
                if maintenance.phase == .restarting || maintenance.phase == .verifying {
                    ProgressView().controlSize(.small)
                }
                Button("Restart Wallpaper Service") { Task { await maintenance.recover(service: service) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(maintenance.isBusy)
            }
        }
    }

    /// The name macOS shows for the provider's tile; must match `SettingsProvider` in the extension, whose display name equals the app's.
    static var tileName: String {
        let brand = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Loomscreen"
        return brand + " — " + String(localized: "Selected Wallpaper", bundle: .appLanguage)
    }
}

/// Shown above the gallery only while copies without a follow source remain.
@available(macOS 26.0, *)
struct SystemWallpaperLegacyBanner: View {
    let service: WallpaperExportService
    @Binding var pendingDestructive: PendingDestructive?
    @Environment(\.locale) private var locale
    @State private var legacyBytes: Int64 = 0

    private var legacyItems: [SystemWallpaperManifest.Item] {
        SystemWallpaperLegacyCopies.items(in: service.items)
    }

    var body: some View {
        let items = legacyItems
        if !items.isEmpty {
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.info,
                symbol: "info.circle.fill",
                title: Text("\(items.count) old copies are not followed automatically"),
                message: Text("They use \(formattedSize) and only play when no display has a selection."),
                surface: .content
            ) {
                Button("Remove Old Copies") { confirmRemoval(of: items) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .task(id: items.map(\.id)) {
                let directory = service.videosDirectory
                let fileNames = items.flatMap { [$0.fileName] + ($0.thumbnailFileName.map { [$0] } ?? []) }
                legacyBytes = await Task.detached {
                    SystemWallpaperLegacyCopies.byteCount(of: fileNames, in: directory)
                }.value
            }
        }
    }

    private var formattedSize: String {
        legacyBytes.formatted(.byteCount(style: .file).locale(locale))
    }

    private func confirmRemoval(of items: [SystemWallpaperManifest.Item]) {
        let playing = items.filter { service.isItemInUse($0.id) }.map(\.title)
        pendingDestructive = PendingDestructive(
            .clearLegacySystemWallpapers(itemCount: items.count, formattedSize: formattedSize, playingTitles: playing,
                                         tileName: SystemWallpaperStatusCard.tileName)
        ) {
            var failures: [String] = []
            for item in items {
                do { try service.remove(itemID: item.id) } catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty {
                service.reportPublishFailures(failures)
            }
        }
    }
}
