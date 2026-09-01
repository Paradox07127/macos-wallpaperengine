import LiveWallpaperCore
import SwiftUI
import AppKit
import os

struct MenuBarContent: View {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.loomscreen.pro",
        category: "MenuBar"
    )

    let openSettings: () -> Void
    let openSettingsForScreen: (CGDirectDisplayID) -> Void
    /// `nil` targets whichever display the settings window lands on; a display ID
    /// aims the prompt at that display's row.
    let openSettingsAndAddWallpaper: (CGDirectDisplayID?) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var ownsSystemMonitorLease = false
    /// The same shared updater the About panel drives, so both surfaces agree
    /// on whether an update is pending.
    @State private var updater = SparkleUpdaterController.shared

    private var monitor: SystemMonitor { .shared }

    private var isWallpaperEnabled: Bool {
        screenManager.wallpapersGloballyEnabled
    }

    private var isWallpaperSwitchDisabled: Bool {
        screenManager.wallpaperOverviewStatus == .notConfigured
    }

    var body: some View {
        let id = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("MenuBarBody", id: id)
        defer { Self.signposter.endInterval("MenuBarBody", interval) }
        return content
    }

    private var content: some View {
        AdaptiveGlassContainer(spacing: MenuBarMetrics.componentSpacing) {
            VStack(alignment: .leading, spacing: MenuBarMetrics.componentSpacing) {
                header
                sectionDivider
                displays
                sectionDivider
                footer
            }
            .padding(MenuBarMetrics.outerPadding)
            .frame(width: MenuBarMetrics.popoverWidth)
        }
        .modifier(MenuBarOuterShell())
        .onAppear(perform: acquireSystemMonitorLeaseIfNeeded)
        .onDisappear(perform: releaseSystemMonitorLeaseIfNeeded)

    }

    private func acquireSystemMonitorLeaseIfNeeded() {
        guard !ownsSystemMonitorLease else { return }
        ownsSystemMonitorLease = true
        monitor.startMonitoring()
    }

    private func releaseSystemMonitorLeaseIfNeeded() {
        guard ownsSystemMonitorLease else { return }
        ownsSystemMonitorLease = false
        monitor.stopMonitoring()
    }

    /// Subtle horizontal rule used between sections inside the single glass shell.
    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(verbatim: BundleIdentity.productDisplayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                updateButton

                Toggle("", isOn: Binding(
                    get: { isWallpaperEnabled },
                    set: { enabled in
                        guard enabled != isWallpaperEnabled else { return }
                        screenManager.setWallpapersEnabled(enabled)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(isWallpaperSwitchDisabled)
                .accessibilityElement(children: .ignore)
                .help(Text("LiveWallpaper system on/off — keeps the app running in the background"))
                .accessibilityLabel(Text("LiveWallpaper system"))
                .accessibilityValue(isWallpaperEnabled ? Text("On") : Text("Off"))
                .accessibilityAddTraits(.isButton)
            }

            usageStrip
        }
        .frame(maxWidth: .infinity)
    }

    /// Present only when Sparkle is holding an update it has already found and
    /// deliberately not shown (see `SparkleUpdaterController`). Clicking hands
    /// control to Sparkle's own install UI.
    @ViewBuilder
    private var updateButton: some View {
        if updater.availableVersion != nil {
            Button {
                updater.checkForUpdates()
                dismiss()
            } label: {
                Label("Update…", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .adaptiveGlassButton(.regular, size: .small)
            .fixedSize()
            .tint(DesignTokens.Colors.Status.info)
            .help(Text("New version available"))
            .accessibilityLabel(Text("Update available"))
        }
    }

    private var displays: some View {
        VStack(spacing: MenuBarMetrics.componentSpacing) {
            if screenManager.screens.isEmpty {
                Text("No displays detected")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            } else {
                let screens = screenManager.screens
                ForEach(screens, id: \.id) { screen in
                    let summary = screenManager.wallpaperSummary(for: screen)
                    let visualState = displayVisualState(for: summary.activity)

                    MenuBarDisplayRow(
                        title: screen.name,
                        subtitle: displaySubtitleAttributed(for: screen, summary: summary),
                        subtitleAccessibilityText: displaySubtitleText(for: screen, summary: summary),
                        iconName: WallpaperType.displaySymbolName(for: summary.wallpaperType),
                        visualState: visualState,
                        isPlaying: summary.activity == .active,
                        supportsPlayback: summary.supportsPlaybackControl,
                        canStepPlaylist: canStepPlaylist(for: screen),
                        screenID: screen.id,
                        audioVolume: audioVolumeBinding(for: screen),
                        addAction: summary.wallpaperType == nil
                            ? { invokeAddWallpaper(screen.id) }
                            : nil,
                        openAction: { invokeOpenScreenSettings(screen.id) },
                        previousAction: {
                            screenManager.regressPlaylist(for: screen)
                        },
                        playbackAction: { screenManager.togglePlayback(for: screen) },
                        nextAction: {
                            screenManager.advancePlaylist(for: screen)
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var usageStrip: some View {
        let cpuPercent = monitor.systemCpuUsage
        let gpuPercent = monitor.gpuUsage
        let ramPercent = monitor.systemMemoryUsage * 100
        let thermalState = monitor.thermalState

        return HStack(spacing: 2) {
            performanceItem(
                tint: usageColor(for: cpuPercent),
                label: "CPU",
                value: FormatUtils.formatPercent(cpuPercent.rounded())
            )
            performanceItem(
                tint: gpuPercent.map { usageColor(for: $0) } ?? DesignTokens.Colors.textTertiary,
                label: "GPU",
                value: gpuPercent.map { FormatUtils.formatPercent($0.rounded()) } ?? "-"
            )
            performanceItem(
                tint: usageColor(for: ramPercent),
                label: "RAM",
                value: FormatUtils.formatPercent(ramPercent.rounded())
            )
            performanceItem(
                tint: thermalColor(for: thermalState),
                label: "THERM",
                value: thermalShortLabel(for: thermalState)
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Thermal pressure has no percent — short word; over-wide localized values truncate.
    private func thermalShortLabel(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return String(localized: "Normal", bundle: .appLanguage)
        case .fair:     return String(localized: "Warm", bundle: .appLanguage)
        case .serious:  return String(localized: "Hot", bundle: .appLanguage)
        case .critical: return String(localized: "Crit", bundle: .appLanguage)
        @unknown default: return "—"
        }
    }

    private func thermalColor(for state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal:  return DesignTokens.Colors.Status.active
        case .fair:     return DesignTokens.Colors.Status.caution
        case .serious:  return DesignTokens.Colors.Status.warning
        case .critical: return DesignTokens.Colors.Status.danger
        @unknown default: return DesignTokens.Colors.textTertiary
        }
    }

    /// Activity Monitor–style thresholds (50 / 80).
    private func usageColor(for percent: Double) -> Color {
        if percent >= 80 { return DesignTokens.Colors.Status.danger }
        if percent >= 50 { return DesignTokens.Colors.Status.warning }
        return DesignTokens.Colors.Status.active
    }

    /// Color only on the dot; value stays `.primary` for contrast on pale glass.
    private func performanceItem(tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .animation(.easeInOut(duration: 0.25), value: tint)
                .accessibilityHidden(true)

            Text(verbatim: label)
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(.secondary)

            Text(verbatim: value)
                .font(DesignTokens.Typography.metricEmphasized)
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label) \(value)"))
    }

    private var footer: some View {
        HStack(spacing: MenuBarMetrics.controlSpacing) {
            Button(action: invokeManageWindow) {
                HStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3")
                        .font(DesignTokens.Typography.bodyEmphasized)
                    Text("Manage…")
                        .font(DesignTokens.Typography.bodyEmphasized)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .adaptiveGlassButton(.prominent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .help(Text("Manage — open the LiveWallpaper settings window"))
            .accessibilityLabel(Text("Manage wallpapers"))

            GlassIconButton("gearshape", action: invokeOpenSettings)
                .help(Text("Open General Settings"))
                .accessibilityLabel(Text("Open General Settings"))

            GlassIconButton("arrow.clockwise") { screenManager.reloadAllScreens() }
                .help(Text("Reload all wallpapers"))
                .accessibilityLabel(Text("Reload all wallpapers"))

            GlassIconButton("power", tint: DesignTokens.Colors.Status.danger) {
                NSApp.terminate(nil)
            }
            .help(Text("Quit LiveWallpaper"))
            .accessibilityLabel(Text("Quit LiveWallpaper"))
        }
        .frame(maxWidth: .infinity)
    }

    private func displaySubtitleAttributed(
        for screen: Screen,
        summary: WallpaperSessionSummary
    ) -> AttributedString {
        let source = displaySource(for: screen, summary: summary)

        guard let typeText = wallpaperTypeText(for: summary.wallpaperType) else {
            return AttributedString(source.isEmpty
                ? String(localized: "Not configured", bundle: .appLanguage)
                : source)
        }

        var attributed = AttributedString(typeText)
        attributed.font = Font.system(size: 11, weight: .semibold)
        attributed.foregroundColor = Color.primary

        if !source.isEmpty {
            var separator = AttributedString(" · ")
            separator.foregroundColor = Color.secondary.opacity(0.65)
            attributed.append(separator)

            var sourceText = AttributedString(source)
            sourceText.font = Font.system(size: 11)
            sourceText.foregroundColor = Color.secondary
            attributed.append(sourceText)
        }

        return attributed
    }

    private func displaySubtitleText(
        for screen: Screen,
        summary: WallpaperSessionSummary
    ) -> String {
        let source = displaySource(for: screen, summary: summary)

        guard let typeText = wallpaperTypeText(for: summary.wallpaperType) else {
            return source.isEmpty
                ? String(localized: "Not configured", bundle: .appLanguage)
                : source
        }

        guard !source.isEmpty else { return typeText }
        return "\(typeText), \(source)"
    }

    private func displaySource(for screen: Screen, summary: WallpaperSessionSummary) -> String {
        // A system suspension outranks the wallpaper's name here: the name is
        // already visible elsewhere, while "why did it stop" is the question
        // the user actually has, and the play button cannot answer it.
        if summary.activity == .policySuspended,
           let reason = SuspendReasonText.localized(
               for: screenManager.suspendReasonsByScreen[screen.id] ?? []
           ) {
            return reason
        }

        if summary.wallpaperType == .video,
           let name = screenManager.currentVideoDisplayName(for: screen),
           !name.isEmpty {
            return name
        }

        if let name = screenManager.wallpaperDisplayName(for: screen), !name.isEmpty {
            return name
        }

        if let message = summary.subtitle, !message.isEmpty {
            return message
        }

        return ""
    }

    private func wallpaperTypeText(for type: WallpaperType?) -> String? {
        switch type {
        case .video:
            return String(localized: "Video", bundle: .appLanguage)
        case .html:
            return String(localized: "Web", bundle: .appLanguage)
        case .scene:
            return String(localized: "Scene", bundle: .appLanguage)
        case nil:
            return nil
        }
    }

    private func displayVisualState(for activity: WallpaperSessionActivity) -> DisplayVisualState {
        switch activity {
        case .active:
            return .active
        case .paused:
            return .paused
        case .policySuspended:
            return .policySuspended
        case .restoring:
            return .restoring
        case .off:
            return .off
        case .error:
            return .error
        case .inactive:
            return .inactive
        }
    }

    private func canStepPlaylist(for screen: Screen) -> Bool {
        guard let config = screenManager.getConfiguration(for: screen),
              config.wallpaperMode == .playlist,
              config.savedVideoBookmarkData != nil
        else {
            return false
        }

        return 1 + (config.playlistBookmarks ?? []).count > 1
    }

    /// Effective-audio binding: stays in sync with the inspector's audio row, which keeps
    /// mute and level as separate states and splits by type the same way (video/scene share
    /// `muted`+`videoVolume`; HTML owns `muteAudio`+`audioVolume` inside its own config).
    private func audioVolumeBinding(for screen: Screen) -> Binding<Double>? {
        guard let config = screenManager.getConfiguration(for: screen) else { return nil }

        switch config.wallpaperType {
        case .video:
            guard config.hasConfiguredVideoSource else { return nil }
            return sessionAudioBinding(for: screen, fallback: config)
        case .scene:
            return sessionAudioBinding(for: screen, fallback: config)
        case .html:
            guard config.htmlConfig != nil else { return nil }
            return htmlAudioBinding(for: screen)
        }
    }

    private func sessionAudioBinding(
        for screen: Screen,
        fallback: ScreenConfiguration
    ) -> Binding<Double> {
        Binding(
            get: {
                let current = screenManager.getConfiguration(for: screen) ?? fallback
                return current.muted ? 0 : current.videoVolume
            },
            set: { newValue in
                let clampedValue = min(max(newValue, 0), 1)
                let current = screenManager.getConfiguration(for: screen) ?? fallback

                if clampedValue <= 0.001 {
                    if !current.muted {
                        screenManager.updateMuted(true, for: screen)
                    }
                    return
                }

                if current.muted {
                    screenManager.updateMuted(false, for: screen)
                }
                screenManager.updateVideoVolume(clampedValue, for: screen)
            }
        )
    }

    private func htmlAudioBinding(for screen: Screen) -> Binding<Double> {
        Binding(
            get: {
                guard let html = screenManager.getConfiguration(for: screen)?.htmlConfig else { return 0 }
                return html.muteAudio ? 0 : html.audioVolume
            },
            set: { newValue in
                guard var html = screenManager.getConfiguration(for: screen)?.htmlConfig else { return }
                let clampedValue = min(max(newValue, 0), 1)

                if clampedValue <= 0.001 {
                    guard !html.muteAudio else { return }
                    html.muteAudio = true
                } else {
                    html.muteAudio = false
                    html.audioVolume = HTMLConfig.clampedAudioVolume(clampedValue)
                }
                screenManager.updateHTMLConfig(html, for: screen)
            }
        )
    }

    private func invokeManageWindow() {
        dismiss()
        if let screen = screenManager.screens.first {
            openSettingsForScreen(screen.id)
        } else {
            openSettings()
        }
    }

    private func invokeOpenScreenSettings(_ id: CGDirectDisplayID) {
        dismiss()
        openSettingsForScreen(id)
    }

    private func invokeOpenSettings() {
        dismiss()
        openSettings()
    }

    private func invokeAddWallpaper(_ screenID: CGDirectDisplayID?) {
        dismiss()
        openSettingsAndAddWallpaper(screenID)
    }

}

/// Fixed spacing / padding metrics for the menu-bar popover.
private enum MenuBarMetrics {
    static let popoverWidth: CGFloat = 300
    static let outerPadding: CGFloat = 10
    static let componentSpacing: CGFloat = 8
    static let controlSpacing: CGFloat = 7
    static let rowPaddingHorizontal: CGFloat = 10
    static let rowPaddingVertical: CGFloat = 8
}

private enum DisplayVisualState: Equatable {
    case active
    case paused
    case off
    case error
    case inactive
    /// Held down by system policy rather than by the user.
    case policySuspended
    /// Rebuilding after a deep hibernate.
    case restoring

    var tint: Color {
        switch self {
        case .active:   return DesignTokens.Colors.Status.active
        case .paused, .policySuspended: return DesignTokens.Colors.Status.warning
        case .restoring: return DesignTokens.Colors.Status.active
        case .off:      return .secondary
        case .error:    return DesignTokens.Colors.Status.danger
        case .inactive: return .secondary
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .active:
            return String(localized: "active", bundle: .appLanguage)
        case .paused:
            return String(localized: "paused", bundle: .appLanguage)
        case .policySuspended:
            return String(localized: "Paused by system", bundle: .appLanguage)
        case .restoring:
            return String(localized: "Restoring", bundle: .appLanguage)
        case .off:
            return String(localized: "off", bundle: .appLanguage)
        case .error:
            return String(localized: "error", bundle: .appLanguage)
        case .inactive:
            return String(localized: "idle", bundle: .appLanguage)
        }
    }
}

/// Outer Liquid Glass shell wrapping the popover.
private struct MenuBarOuterShell: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .adaptiveGlassSurface(.roundedRectangle(22))
                .background(MenuBarWindowChromeClearer())
        } else {
            content
        }
    }
}

private struct MenuBarDisplayRow: View {
    let title: String
    let subtitle: AttributedString
    let subtitleAccessibilityText: String
    let iconName: String
    let visualState: DisplayVisualState
    let isPlaying: Bool
    let supportsPlayback: Bool
    let canStepPlaylist: Bool
    /// Keys the volume slider's pending commit to this display (`CoalescedSlider` owner).
    let screenID: AnyHashable
    let audioVolume: Binding<Double>?
    /// Non-nil only while this display has no wallpaper assigned.
    let addAction: (() -> Void)?
    let openAction: () -> Void
    let previousAction: () -> Void
    let playbackAction: () -> Void
    let nextAction: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button(action: openAction) {
                    HStack(spacing: 8) {
                        DisplayIconTile(systemImage: iconName, state: visualState)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: title)
                                .font(DesignTokens.Typography.bodyEmphasized)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(subtitle)
                                .font(DesignTokens.Typography.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarPressFeedbackStyle())
                .help(Text("Open display settings"))
                .accessibilityLabel(Text("\(title), \(subtitleAccessibilityText), \(visualState.accessibilityLabel)"))
                .accessibilityElement(children: .combine)

                if let addAction {
                    GlassIconButton("plus", prominence: .prominent, size: .regular, action: addAction)
                        .accessibilityLabel(Text("Add wallpaper to this display"))
                } else if supportsPlayback {
                    HStack(spacing: 4) {
                        if canStepPlaylist {
                            GlassIconButton("chevron.left", size: .regular, action: previousAction)
                                .accessibilityLabel(Text("Previous wallpaper"))
                        }

                        GlassIconButton(
                            isPlaying ? "pause.fill" : "play.fill",
                            prominence: .prominent,
                            size: .regular,
                            action: playbackAction
                        )
                        .accessibilityLabel(Text(isPlaying ? "Pause wallpaper" : "Play wallpaper"))

                        if canStepPlaylist {
                            GlassIconButton("chevron.right", size: .regular, action: nextAction)
                                .accessibilityLabel(Text("Next wallpaper"))
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)

            if let audioVolume {
                VolumeControlRow(owner: screenID, audioVolume: audioVolume)
            }
        }
        .padding(.horizontal, MenuBarMetrics.rowPaddingHorizontal)
        .padding(.vertical, MenuBarMetrics.rowPaddingVertical)
        .frame(maxWidth: .infinity)
        // Flat inside the popover's own glass shell: a second glass layer here
        // would stack material on material, which the outer shell already provides.
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }
}

private struct DisplayIconTile: View {
    let systemImage: String
    let state: DisplayVisualState

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(state.tint)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
            )
            .accessibilityHidden(true)
    }
}

private struct VolumeControlRow: View {
    let owner: AnyHashable
    let audioVolume: Binding<Double>

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: volumeIcon(for: audioVolume.wrappedValue))
                .font(DesignTokens.Typography.metric.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            CoalescedSlider(
                value: audioVolume.wrappedValue,
                in: 0 ... 1,
                owner: owner,
                controlSize: .mini,
                sizing: .flexible(minimum: 0, maximum: .infinity),
                accessibilityLabel: Text("Wallpaper volume"),
                accessibilityValue: { Text("\(volumePercent($0)) percent") },
                write: { audioVolume.wrappedValue = $0 },
                readout: { live in
                    Text(verbatim: "\(volumePercent(live))%")
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                        .monospacedDigit()
                }
            )
            .tint(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func volumePercent(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 100).rounded())
    }

    private func volumeIcon(for value: Double) -> String {
        switch value {
        case ..<0.01:
            return "speaker.slash.fill"
        case ..<0.5:
            return "speaker.wave.1.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

/// Adds a subtle press cue (scale + dim) to every menu-bar button that doesn't already go through `.adaptiveGlassButton` (which delivers its own native press feedback).
private struct MenuBarPressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Removes the macOS 26 menu-bar popover chrome so wallpaper remains visible through Liquid Glass.
private struct MenuBarWindowChromeClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.stripChrome(anchoredAt: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.stripChrome(anchoredAt: nsView) }
    }

    private static func stripChrome(anchoredAt anchor: NSView) {
        guard let window = anchor.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear

        // The chrome is a sibling of our content inside the window's frame view; the previous
        // recursive walk started at `contentView` and only searched our own SwiftUI subtree —
        // what it missed drew a second rounded backdrop under the glass shell (a non-concentric
        // arc at the four corners). Matched by position, not class: everything outside `contentView` is chrome, however AppKit backs the popover.
        guard let content = window.contentView, let frameView = content.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
        frameView.layer?.borderWidth = 0
        for sibling in frameView.subviews where sibling !== content {
            sibling.isHidden = true
        }
    }
}
