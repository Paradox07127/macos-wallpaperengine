import LiveWallpaperCore
import SwiftUI

@available(macOS 26.0, *)
struct SystemWallpaperSettingsView: View {
    @Environment(WallpaperExportService.self) private var service
    @Environment(EditDeskRouter.self) private var router: EditDeskRouter?
    @Environment(\.locale) private var locale
    @State private var pendingDestructive: PendingDestructive?
    #if !LITE_BUILD
    @AppStorage(SystemWallpaperFollowPreferences.sceneMode, store: .appScoped())
    private var sceneMode: SystemWallpaperPreparationOptions.SceneMode = .live
    @AppStorage(SystemWallpaperFollowPreferences.resolutionCap, store: .appScoped())
    private var resolutionCap: SystemWallpaperFollowPreferences.ResolutionCap = .matchDisplay
    @AppStorage(SystemWallpaperFollowPreferences.frameRate, store: .appScoped()) private var frameRate = 30
    @AppStorage(SystemWallpaperFollowPreferences.loopLength, store: .appScoped()) private var loopLength = 15
    #endif

    var body: some View {
        Form {
            if let message = service.lastError {
                Section {
                    InlineNoticeBanner(
                        tint: DesignTokens.Colors.Status.warning,
                        symbol: "exclamationmark.triangle.fill",
                        title: Text("Couldn't update System Wallpaper"),
                        message: Text(verbatim: message),
                        surface: .content
                    ) {
                        Button("Dismiss") { service.clearLastError() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            Section {
                SettingRow(
                    icon: "play.rectangle",
                    iconColor: .indigo,
                    title: "Video playback",
                    info: playbackInfo
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

            #if !LITE_BUILD
            liveScenes
            videoCopies
            #endif

            Section {
                SettingRow(
                    icon: "internaldrive",
                    iconColor: DesignTokens.Colors.LibraryTint.systemWallpaper,
                    title: "Storage used",
                    valueSubtitle: usedSpace
                ) {
                    Button("Manage in System Wallpaper") { router?.page = .systemWallpaper }
                        .fixedSize()
                }
                SettingRow(
                    icon: "trash",
                    iconColor: DesignTokens.Colors.Status.danger,
                    title: "Remove All from System Wallpaper",
                    info: removeAllInfo
                ) {
                    Button("Remove All", role: .destructive) {
                        pendingDestructive = PendingDestructive(.clearSystemWallpaperLibrary(
                            itemCount: service.items.count,
                            formattedSize: usedSpace
                        )) {
                            do {
                                try service.clearLibrary()
                            } catch {
                                service.reportPublishFailures([error.localizedDescription])
                            }
                        }
                    }
                    .disabled(service.items.isEmpty)
                    .fixedSize()
                }
            } header: {
                SettingsSearchSectionHeader("Storage", anchor: .systemWallpaperStorage)
            }

            SystemWallpaperMaintenanceSection(service: service)
        }
        .settingsFormChrome()
        .confirmDestructive($pendingDestructive)
        .onAppear { service.refresh() }
        .task { service.startObservingSharedRoot() }
    }

    /// Formatted in the app language; `ByteCountFormatter` follows the system language instead.
    private var usedSpace: String {
        service.diskUsageBytes.formatted(.byteCount(style: .file).locale(locale))
    }

    private var playbackInfo: String.LocalizationValue {
        #if LITE_BUILD
        "Applies to videos. When the Mac is hot, in Low Power Mode or on battery, the frame rate drops or playback pauses."
        #else
        "Applies to videos and live scenes. When the Mac is hot, in Low Power Mode or on battery, the frame rate drops or playback pauses."
        #endif
    }

    private var removeAllInfo: String.LocalizationValue {
        #if LITE_BUILD
        "System Wallpaper plays video copies independently of Loomscreen. App wallpaper effects, overlays and playback controls do not apply here."
        #else
        "System Wallpaper plays live scenes and video copies independently of Loomscreen. App wallpaper effects, overlays and playback controls do not apply here."
        #endif
    }

    #if !LITE_BUILD
    private var liveScenes: some View {
        Section {
            SettingRow(
                icon: "cube.transparent",
                iconColor: .purple,
                title: "Scene playback",
                info: "Live keeps clocks and calendars accurate. A video copy records the current appearance and uses less energy."
            ) {
                GlassSegmentedPicker(
                    selection: $sceneMode, values: [.live, .videoCopy], shell: .flat,
                    title: { (mode: SystemWallpaperPreparationOptions.SceneMode) in mode == .live ? "Live" : "Video Copy" }
                )
                .frame(width: DesignTokens.Settings.segmentedPickerWidth)
            }
            SettingRow(
                icon: "aspectratio",
                iconColor: .teal,
                title: "Resolution limit",
                info: "Also applies to video copies."
            ) {
                Picker("Resolution limit", selection: $resolutionCap) {
                    Text("Match Display").tag(SystemWallpaperFollowPreferences.ResolutionCap.matchDisplay)
                    Text("1080p").tag(SystemWallpaperFollowPreferences.ResolutionCap.p1080)
                    Text("1440p").tag(SystemWallpaperFollowPreferences.ResolutionCap.p1440)
                    Text("4K").tag(SystemWallpaperFollowPreferences.ResolutionCap.p4K)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingRow(icon: "speedometer", iconColor: .orange, title: "Frame Rate", info: "Also applies to video copies.") {
                Picker("Frame Rate", selection: $frameRate) {
                    Text("15 FPS").tag(15)
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingRow(
                icon: "clock",
                iconColor: .gray,
                title: "Hide the wallpaper’s clock and calendar on the lock screen",
                info: "macOS shows its own clock there."
            ) {
                Toggle("", isOn: Binding(
                    get: { service.hidesClockCalendarOnLockScreen }, set: { service.setHidesClockCalendarOnLockScreen($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Hide the wallpaper’s clock and calendar on the lock screen"))
            }
        } header: {
            SettingsSearchSectionHeader("Live scenes", anchor: .systemWallpaperLiveScenes)
        }
    }

    private var videoCopies: some View {
        Section {
            SettingRow(
                icon: "repeat",
                iconColor: .blue,
                title: "Loop length",
                info: "Used when web wallpapers and scenes are recorded as video copies."
            ) {
                Picker("Loop length", selection: $loopLength) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
                .labelsHidden()
                .fixedSize()
            }
        } header: {
            SettingsSearchSectionHeader("Video copies", anchor: .systemWallpaperVideoCopies)
        }
    }
    #endif
}

/// A status message in a settings section; not a setting, so not a `SettingRow` and not indexed by search.
struct SystemWallpaperStatusLine: View {
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
