import AppKit
import LiveWallpaperCore
import SwiftUI

/// Shown only while no aerials are listed, so a connected library without a scan error has none downloaded.
struct AerialsSourceStatusCard: View {
    enum Presentation {
        /// The guide card that fills a library page's content area.
        case page
        /// The state and its main action on one line, under the shelf's filter row.
        case inline
    }

    private enum Status {
        case unauthorized
        case scanFailed(message: String)
        case notDownloaded
    }

    var presentation: Presentation = .page
    private let library = AppleAerialsLibrary.shared

    private var status: Status {
        if !library.isAuthorized {
            return .unauthorized
        }
        if let message = library.lastScanError, !message.isEmpty {
            return .scanFailed(message: message)
        }
        return .notDownloaded
    }

    var body: some View {
        switch presentation {
        case .page: page
        case .inline: inline
        }
    }

    @ViewBuilder
    private var page: some View {
        switch status {
        case .unauthorized:
            LibraryGuideCard(
                icon: "sparkles.tv",
                tint: DesignTokens.Colors.LibraryTint.aerials,
                title: "Connect Apple Aerials",
                message: "Authorize access to downloaded aerials. Original files remain unchanged.",
                actionTitle: library.isScanning ? "Connecting…" : "Connect Library",
                actionSystemImage: "folder.badge.plus",
                isActionInProgress: library.isScanning,
                errorMessage: library.lastScanError,
                action: connect
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .scanFailed(message):
            LibraryGuideCard(
                icon: "exclamationmark.triangle",
                tint: DesignTokens.Colors.LibraryTint.aerials,
                title: "Couldn't scan Aerials",
                actionTitle: "Reconnect",
                actionSystemImage: "folder.badge.gearshape",
                secondaryTitle: "Retry",
                secondarySystemImage: "arrow.clockwise",
                errorMessage: message,
                action: {
                    library.clearAccess()
                },
                secondaryAction: refresh
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notDownloaded:
            LibraryGuideCard(
                icon: "sparkles.tv",
                tint: DesignTokens.Colors.LibraryTint.aerials,
                title: "No aerials downloaded yet",
                message: "Download an aerial in System Settings, then refresh when the download completes.",
                actionTitle: "Open System Settings",
                actionSystemImage: "gearshape",
                secondaryTitle: "Refresh",
                secondarySystemImage: "arrow.clockwise",
                action: openWallpaperSettings,
                secondaryAction: refresh
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var inline: some View {
        switch status {
        case .unauthorized:
            inlineLine("Connect Apple Aerials", action: library.isScanning ? "Connecting…" : "Connect Library", perform: connect)
                .disabled(library.isScanning)
        case .scanFailed:
            inlineLine("Couldn't scan Aerials", action: "Retry", perform: refresh)
        case .notDownloaded:
            inlineLine("No aerials downloaded yet", action: "Open System Settings", perform: openWallpaperSettings)
        }
    }

    private func inlineLine(_ title: LocalizedStringKey, action: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            Text(title)
                .font(DesignTokens.EditDesk.Typography.chip)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
            Button(action, action: perform)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func connect() {
        Task { _ = await library.requestAccess() }
    }

    private func refresh() {
        Task { await library.refresh() }
    }

    private func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct AerialsSourceControls: View {
    private let library = AppleAerialsLibrary.shared
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            GlassIconButton("arrow.clockwise", size: .small) {
                Task { await library.refresh() }
            }
            .help(Text("Refresh Aerials library"))
            .accessibilityLabel(Text("Refresh Aerials library"))
            .disabled(library.isScanning)
            GlassIconButton("folder.badge.minus", size: .small, tint: DesignTokens.Colors.Status.danger, role: .destructive) {
                pendingDestructive = PendingDestructive(.disconnectAerialsLibrary) {
                    library.clearAccess()
                }
            }
            .help(Text("Disconnect the Apple Aerials library folder"))
            .accessibilityLabel(Text("Disconnect Aerials Library"))
        }
        .confirmDestructive($pendingDestructive)
    }
}
