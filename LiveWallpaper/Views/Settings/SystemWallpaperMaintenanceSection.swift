import LiveWallpaperCore
import SwiftUI

@available(macOS 26.0, *)
struct SystemWallpaperMaintenanceSection: View {
    let service: WallpaperExportService
    /// Owned by the settings page, which hosts the registrations overlay over the whole form.
    @Binding var showingRegistrations: Bool
    private var maintenance: SystemWallpaperMaintenanceController {
        service.maintenance
    }

    var body: some View {
        Section {
            if !maintenance.helperAvailable {
                SystemWallpaperStatusLine("Maintenance is unavailable in this build. Install a build that includes the maintenance service.",
                                          systemImage: "exclamationmark.triangle", tint: DesignTokens.Colors.Status.warning)
            }

            SettingRow(
                icon: "puzzlepiece.extension",
                iconColor: DesignTokens.Colors.SettingsIcon.inspectRegistrations,
                title: "Manage Extension Registrations"
            ) {
                Button("Manage") { showingRegistrations = true }
                    .disabled(!maintenance.helperAvailable)
                    .fixedSize()
                    .atlasRole("ManageRegistrations")
            }

            SettingRow(
                icon: "arrow.clockwise",
                iconColor: DesignTokens.Colors.SettingsIcon.restartService,
                title: "Restart Wallpaper Service",
                info: "Restarting it briefly redraws all system wallpapers for your account."
            ) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if maintenance.phase == .restarting || maintenance.phase == .verifying {
                        ProgressView().controlSize(.small)
                    }
                    Button("Restart") { Task { await maintenance.recover(service: service) } }
                        .disabled(maintenance.isBusy || !maintenance.helperAvailable)
                        .fixedSize()
                }
            }

            SettingRow(
                icon: "bolt.shield",
                iconColor: DesignTokens.Colors.SettingsIcon.automaticRecovery,
                title: "Automatically recover stalled connections",
                info: "Automatic recovery runs while Loomscreen is open, waits for persistent failure, and restarts at most once every five minutes."
            ) {
                Toggle("", isOn: Binding(
                    get: { maintenance.automaticRecovery }, set: { maintenance.automaticRecovery = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!maintenance.helperAvailable && !maintenance.automaticRecovery)
                .accessibilityLabel(Text("Automatically recover stalled connections"))
            }

            if !showingRegistrations {
                SystemWallpaperMaintenanceResult(maintenance: maintenance)
            }
        } header: {
            SettingsSearchSectionHeader("Maintenance", anchor: .systemWallpaperMaintenance)
        }
    }
}

/// The outcome of the last restart or repair; inspection results live in the registration sheet.
@available(macOS 26.0, *)
struct SystemWallpaperMaintenanceResult: View {
    let maintenance: SystemWallpaperMaintenanceController

    var body: some View {
        switch maintenance.phase {
        case .idle, .inspecting:
            EmptyView()
        case .restarting:
            progressLine("Restarting wallpaper service…")
        case .repairing:
            progressLine("Repairing registrations…")
        case .verifying:
            progressLine("Waiting for the extension to reconnect…")
        case .verified:
            SystemWallpaperStatusLine("Extension connection verified", systemImage: "checkmark.circle.fill", tint: DesignTokens.Colors.Status.active)
        case .awaitingSelection:
            SystemWallpaperStatusLine("The service restarted, but no new connection was confirmed. Choose the Loomscreen tile in System Settings › Wallpaper again.",
                                      systemImage: "exclamationmark.triangle", tint: DesignTokens.Colors.Status.warning)
        case .failed:
            HStack {
                SystemWallpaperStatusLine("Maintenance did not complete. Inspect registrations again before retrying.",
                                          systemImage: "exclamationmark.triangle.fill", tint: DesignTokens.Colors.Status.warning)
                Spacer(minLength: 0)
                if let code = maintenance.errorCode {
                    ErrorCodeChip(code: code, tint: DesignTokens.Colors.Status.warning)
                }
            }
        }
    }

    private func progressLine(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(title)
        }
    }
}
