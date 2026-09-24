import LiveWallpaperCore
import SwiftUI

@available(macOS 26.0, *)
struct SystemWallpaperSettingsView: View {
    @Environment(WallpaperExportService.self) private var service
    @State private var confirmsRepair = false
    @State private var pendingDestructive: PendingDestructive?
    @State private var showingAddSheet = false

    var body: some View {
        Form {
            Section {
                SettingRow(icon: "play.rectangle", iconColor: .indigo, title: "Video playback") {
                    GlassSegmentedPicker(
                        selection: Binding(get: { service.playbackMode }, set: { service.setPlaybackMode($0) }),
                        values: [.always, .stillOnDesktop], shell: .flat,
                        title: { (mode: SystemWallpaperPlaybackMode) in mode == .always ? "Always" : "Lock screen only" }
                    )
                    .frame(width: 230)
                }
            } header: {
                SettingsSearchSectionHeader("Playback", anchor: .systemWallpaperPlayback)
            } footer: {
                Text("The lock screen and login window always play the video.")
            }

            Section {
                status
                if let provider = service.heartbeat?.provider {
                    if let heartbeat = service.heartbeat,
                       !heartbeat.isFromProvider(matching: SystemWallpaperProviderIdentity.bundledProvider()) {
                        Text("The last extension connection came from another app copy.")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Last connected extension") {
                        Text(verbatim: provider.bundlePath).textSelection(.enabled)
                            .font(DesignTokens.Typography.codeCaption)
                    }
                }
                Button("Refresh") { service.refresh() }
            } header: {
                SettingsSearchSectionHeader("Extension status", anchor: .systemWallpaperStatus)
            } footer: {
                Text("macOS chooses the wallpaper for each display and Space. Importing a video does not apply it to every desktop.")
            }

            SystemWallpaperMaintenanceSection(service: service, confirmsRepair: $confirmsRepair)

            Section {
                Button("Remove All from System Wallpaper", role: .destructive) {
                    pendingDestructive = PendingDestructive(.clearSystemWallpaperLibrary(
                        itemCount: service.items.count,
                        formattedSize: WorkshopByteFormatter.platformDefault.string(fromByteCount: service.diskUsageBytes)
                    )) { try? service.clearLibrary() }
                }
                .disabled(service.items.isEmpty)
            } header: {
                SettingsSearchSectionHeader("System Wallpaper Library", anchor: .systemWallpaperLibrary)
            } footer: {
                Text("System Wallpaper plays exported videos independently of Loomscreen. App wallpaper effects, overlays and playback controls do not apply here.")
            }
        }
        .settingsFormChrome()
        .confirmDestructive($pendingDestructive)
        .sheet(isPresented: $showingAddSheet) {
            AppLanguageScope(defaults: .appScoped()) {
                SystemWallpaperAddSheet()
            }
        }
        .onAppear { service.refresh() }
        .task { service.startObservingSharedRoot() }
    }

    @ViewBuilder
    private var status: some View {
        if service.providerIssue == .differentCopy {
            SettingRow(icon: "info.circle", title: "Another app copy provides the system wallpaper") {
                EmptyView()
            }
            Text("A different copy is not a playback failure. Inspect registrations below before switching providers.")
                .foregroundStyle(.secondary)
        } else if service.providerIssue == .stopped || service.providerIssue == .unresponsive {
            InlineNoticeBanner(tint: DesignTokens.Colors.Status.warning, symbol: "exclamationmark.triangle",
                               title: Text("System Wallpaper needs attention"),
                               message: Text("Use Restart Wallpaper Service below to rebuild the system connection."), surface: .content)
        } else {
            switch service.status {
            case let .failed(message):
                InlineNoticeBanner(tint: DesignTokens.Colors.Status.warning, symbol: "exclamationmark.triangle.fill",
                                   title: Text("Couldn't update System Wallpaper"), message: Text(verbatim: message), surface: .content)
            case .systemIncompatible:
                Text("This version of macOS is not compatible with the wallpaper extension.")
            case .inUse:
                Label("Selected by macOS", systemImage: "checkmark.circle.fill")
            case .empty:
                nextStepRow(Text("No videos yet"))
            case .publishedNotSelected:
                nextStepRow(Text("Choose a wallpaper in System Settings"))
            }
        }
    }

    private func nextStepRow(_ message: Text) -> some View {
        HStack {
            message
            Spacer(minLength: 0)
            switch service.status.settingsNextStep {
            case .addVideo:
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Video", systemImage: "plus")
                }
                .accessibilityLabel(Text("Add Video"))
            case .openWallpaperSettings:
                Button("Open Wallpaper Settings") { service.openWallpaperSettings() }
            case nil:
                EmptyView()
            }
        }
    }
}

@available(macOS 26.0, *)
private struct SystemWallpaperMaintenanceSection: View {
    let service: WallpaperExportService
    @Binding var confirmsRepair: Bool
    private var maintenance: SystemWallpaperMaintenanceController {
        service.maintenance
    }

    var body: some View {
        Section {
            if !maintenance.helperAvailable {
                Text("Maintenance is unavailable in this build. Install a build that includes the maintenance service.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Inspect Registrations") { Task { await maintenance.inspect() } }
                Button("Restart Wallpaper Service") { Task { await maintenance.recover(service: service) } }
                if maintenance.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .disabled(maintenance.isBusy || !maintenance.helperAvailable)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Toggle("Automatically recover stalled connections", isOn: Binding(
                get: { maintenance.automaticRecovery }, set: { maintenance.automaticRecovery = $0 }
            ))
            .disabled(!maintenance.helperAvailable)
            Text("Automatic recovery runs while Loomscreen is open, waits for persistent failure, and restarts at most once every five minutes.")
                .font(DesignTokens.Typography.caption).foregroundStyle(.secondary)

            result
            if let report = maintenance.report {
                if !report.copies.isEmpty {
                    DisclosureGroup("Registered app copies") {
                        ForEach(report.copies) { copy in
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                                HStack {
                                    if copy.isCurrent {
                                        Text("This app")
                                    } else if copy.willUnregister {
                                        Text("Registration to remove")
                                    } else {
                                        Text("Preserved")
                                    }
                                    Spacer(minLength: 0)
                                    if copy.exists {
                                        Button("Show in Finder") { maintenance.reveal(copy.path) }.buttonStyle(.link)
                                    }
                                }
                                Text(verbatim: copy.path).font(DesignTokens.Typography.codeCaption).textSelection(.enabled)
                            }
                        }
                    }
                }
                if report.outcome == .inspected || report.copies.contains(where: \.willUnregister) {
                    Button("Use This App's Extension") { confirmsRepair = true }
                        .disabled(maintenance.isBusy || report.outcome != .inspected)
                }
            }
        } header: {
            SettingsSearchSectionHeader("Maintenance", anchor: .systemWallpaperMaintenance)
        } footer: {
            Text("Restarting briefly redraws all system wallpapers for your account. Repair removes the reviewed registrations, keeps this app, and preserves app files and videos.")
        }
        .confirmationDialog("Use This App's Extension?", isPresented: $confirmsRepair, titleVisibility: .visible) {
            Button("Repair and Restart") { Task { await maintenance.recover(service: service, repair: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The registrations marked for removal will be unregistered. This app becomes the preferred provider and the system wallpaper service restarts.")
        }
    }

    @ViewBuilder
    private var result: some View {
        switch maintenance.phase {
        case .idle:
            if let report = maintenance.report, report.outcome == .inspected {
                Label("Registration check complete", systemImage: "checkmark.circle")
                if report.copies.isEmpty {
                    Text("No registered app copies found.")
                }
            }
        case .inspecting: Text("Inspecting registrations…")
        case .restarting: Text("Restarting wallpaper service…")
        case .repairing: Text("Repairing registrations…")
        case .verifying: Text("Waiting for the extension to reconnect…")
        case .verified: Label("Extension connection verified", systemImage: "checkmark.circle")
        case .awaitingSelection:
            Text("The service restarted, but no new connection was confirmed. In System Wallpaper, click Add Video to choose a video.")
        case .failed:
            Text("Maintenance did not complete. Inspect registrations again before retrying.")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
            if let code = maintenance.errorCode {
                ErrorCodeChip(code: code, tint: DesignTokens.Colors.Status.warning)
            }
        }
    }
}

enum SystemWallpaperNextStep {
    case addVideo
    case openWallpaperSettings
}

extension WallpaperExportService.Status {
    /// nil = the settings page has nothing to offer for this status.
    var settingsNextStep: SystemWallpaperNextStep? {
        switch self {
        case .empty: .addVideo
        case .publishedNotSelected: .openWallpaperSettings
        case .systemIncompatible, .failed, .inUse: nil
        }
    }
}
