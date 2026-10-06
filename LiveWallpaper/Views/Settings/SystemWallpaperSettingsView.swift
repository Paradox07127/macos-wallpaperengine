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
                SettingRow(
                    icon: "play.rectangle",
                    iconColor: .indigo,
                    title: "Video playback",
                    info: "The lock screen and login window always play the video."
                ) {
                    GlassSegmentedPicker(
                        selection: Binding(get: { service.playbackMode }, set: { service.setPlaybackMode($0) }),
                        values: [.always, .stillOnDesktop], shell: .flat,
                        title: { (mode: SystemWallpaperPlaybackMode) in mode == .always ? "Always" : "Lock screen only" }
                    )
                    .frame(width: DesignTokens.Settings.segmentedPickerWidth)
                }
            } header: {
                SettingsSearchSectionHeader("Playback", anchor: .systemWallpaperPlayback)
            }

            Section {
                status
                if let provider = service.heartbeat?.provider {
                    DisclosureGroup {
                        Text(verbatim: provider.bundlePath).textSelection(.enabled)
                            .font(DesignTokens.Typography.codeCaption)
                    } label: {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                            Text("Last connected extension")
                                .font(DesignTokens.Typography.body)
                            if let heartbeat = service.heartbeat,
                               !heartbeat.isFromProvider(matching: SystemWallpaperProviderIdentity.bundledProvider()) {
                                Text("The last extension connection came from another app copy.")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    SettingsSearchSectionHeader("Extension status", anchor: .systemWallpaperStatus)
                    Spacer()
                    Button { service.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Refresh"))
                    .accessibilityLabel(Text("Refresh"))
                }
            } footer: {
                Text("macOS chooses the wallpaper for each display and Space. Importing a video does not apply it to every desktop.")
            }

            SystemWallpaperMaintenanceSection(service: service, confirmsRepair: $confirmsRepair)

            Section {
                SettingRow(
                    icon: "trash",
                    iconColor: DesignTokens.Colors.Status.danger,
                    title: "Remove All from System Wallpaper",
                    info: "System Wallpaper plays exported videos independently of Loomscreen. App wallpaper effects, overlays and playback controls do not apply here."
                ) {
                    Button("Remove All", role: .destructive) {
                        pendingDestructive = PendingDestructive(.clearSystemWallpaperLibrary(
                            itemCount: service.items.count,
                            formattedSize: WorkshopByteFormatter.platformDefault.string(fromByteCount: service.diskUsageBytes)
                        )) { try? service.clearLibrary() }
                    }
                    .disabled(service.items.isEmpty)
                    .fixedSize()
                }
            } header: {
                SettingsSearchSectionHeader("System Wallpaper Library", anchor: .systemWallpaperLibrary)
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
            SettingRow(
                icon: "info.circle",
                iconColor: DesignTokens.Colors.Status.warning,
                title: "Another app copy provides the system wallpaper",
                subtitle: "A different copy is not a playback failure. Inspect registrations below before switching providers."
            ) {
                EmptyView()
            }
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
                SystemWallpaperStatusLine("This version of macOS is not compatible with the wallpaper extension.",
                                          systemImage: "exclamationmark.triangle", tint: DesignTokens.Colors.Status.warning)
            case .inUse:
                SystemWallpaperStatusLine("Selected by macOS", systemImage: "checkmark.circle.fill", tint: DesignTokens.Colors.Status.active)
            case .empty:
                HStack {
                    SystemWallpaperStatusLine("No videos yet", systemImage: "photo.on.rectangle.angled", tint: DesignTokens.Colors.textSecondary)
                    Spacer(minLength: 0)
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Video", systemImage: "plus")
                    }
                }
            case .publishedNotSelected:
                HStack {
                    SystemWallpaperStatusLine("Choose a wallpaper in System Settings", systemImage: "gearshape", tint: DesignTokens.Colors.accent)
                    Spacer(minLength: 0)
                    Button("Open Wallpaper Settings") { service.openWallpaperSettings() }
                }
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
                SystemWallpaperStatusLine("Maintenance is unavailable in this build. Install a build that includes the maintenance service.",
                                          systemImage: "exclamationmark.triangle", tint: DesignTokens.Colors.Status.warning)
            }

            SettingRow(
                icon: "magnifyingglass",
                iconColor: DesignTokens.Colors.SettingsIcon.inspectRegistrations,
                title: "Inspect Registrations"
            ) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if maintenance.isBusy, maintenance.phase == .inspecting {
                        ProgressView().controlSize(.small)
                    }
                    Button("Inspect") { Task { await maintenance.inspect() } }
                        .disabled(maintenance.isBusy || !maintenance.helperAvailable)
                        .fixedSize()
                }
            }

            SettingRow(
                icon: "arrow.clockwise",
                iconColor: DesignTokens.Colors.SettingsIcon.restartService,
                title: "Restart Wallpaper Service",
                info: "Restarting briefly redraws all system wallpapers for your account. Repair removes the reviewed registrations, keeps this app, and preserves app files and videos."
            ) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if maintenance.isBusy, maintenance.phase == .restarting {
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
                .disabled(!maintenance.helperAvailable)
                .accessibilityLabel(Text("Automatically recover stalled connections"))
            }

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
                            .padding(.vertical, DesignTokens.Spacing.xxs)
                        }
                    }
                }
                if report.outcome == .inspected || report.copies.contains(where: \.willUnregister) {
                    SettingRow(
                        icon: "wrench.and.screwdriver",
                        iconColor: DesignTokens.Colors.SettingsIcon.repairExtension,
                        title: "Use This App's Extension",
                        info: "The registrations marked for removal will be unregistered. This app becomes the preferred provider and the system wallpaper service restarts."
                    ) {
                        Button("Repair and Restart") { confirmsRepair = true }
                            .disabled(maintenance.isBusy || report.outcome != .inspected)
                            .fixedSize()
                    }
                }
            }
        } header: {
            SettingsSearchSectionHeader("Maintenance", anchor: .systemWallpaperMaintenance)
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
                SystemWallpaperStatusLine("Registration check complete", systemImage: "checkmark.circle", tint: DesignTokens.Colors.Status.active)
                if report.copies.isEmpty {
                    Text("No registered app copies found.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .inspecting:
            progressLine("Inspecting registrations…")
        case .restarting:
            progressLine("Restarting wallpaper service…")
        case .repairing:
            progressLine("Repairing registrations…")
        case .verifying:
            progressLine("Waiting for the extension to reconnect…")
        case .verified:
            SystemWallpaperStatusLine("Extension connection verified", systemImage: "checkmark.circle.fill", tint: DesignTokens.Colors.Status.active)
        case .awaitingSelection:
            SystemWallpaperStatusLine("The service restarted, but no new connection was confirmed. In System Wallpaper, click Add Video to choose a video.",
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

/// A status message in a settings section; not a setting, so not a `SettingRow` and not indexed by search.
private struct SystemWallpaperStatusLine: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color

    init(_ title: LocalizedStringKey, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}
