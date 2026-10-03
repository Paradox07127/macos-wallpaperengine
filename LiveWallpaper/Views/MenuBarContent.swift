import AppKit
import LiveWallpaperCore
import os
import SwiftUI

struct MenuBarContent: View {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.loomscreen.pro",
        category: "MenuBar"
    )

    let openSettings: () -> Void
    let openSettingsForScreen: (CGDirectDisplayID) -> Void
    /// The panorama with nothing selected — `openSettings` lands on General instead.
    let openHome: () -> Void
    /// `nil` targets whichever display the settings window lands on; a display ID
    /// aims the prompt at that display's row.
    let openSettingsAndAddWallpaper: (CGDirectDisplayID?) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.dismiss) private var dismiss

    @State private var ownsSystemMonitorLease = false
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
                    .font(DesignTokens.Typography.pageTitle)
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
                .help(Text("Enable wallpapers. The app keeps running when disabled."))
                .accessibilityLabel(Text("Enable wallpapers"))
                .accessibilityValue(isWallpaperEnabled ? Text("On") : Text("Off"))
                .accessibilityAddTraits(.isButton)
            }

            usageStrip
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var updateButton: some View {
        if updater.availableVersion != nil {
            Button {
                updater.checkForUpdates()
                dismiss()
            } label: {
                Label("Update", systemImage: "arrow.down.circle.fill")
                    .font(DesignTokens.Typography.captionEmphasized)
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
                    let attempt = screenManager.wallpaperLoads.attempt(for: screen)
                    let visualState = attempt.map { $0.phase == .failed ? DisplayVisualState.error : .loading }
                        ?? displayVisualState(for: summary.activity)
                    let spanned = isSpanned(screen)

                    MenuBarDisplayRow(
                        title: screen.name,
                        subtitle: displaySubtitleAttributed(for: screen, summary: summary),
                        subtitleAccessibilityText: displaySubtitleText(for: screen, summary: summary),
                        iconName: spanned ? "display.2" : WallpaperType.displaySymbolName(for: summary.wallpaperType),
                        isSpanned: spanned,
                        visualState: visualState,
                        intendsToPlay: screen.playbackController?.userIntendsToPlay == true,
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

        let items: [(label: String, icon: String, value: String, tint: Color)] = [
            ("CPU", "cpu", FormatUtils.formatPercent(cpuPercent.rounded()), usageColor(for: cpuPercent)),
            ("GPU", "square.3.layers.3d", gpuPercent.map { FormatUtils.formatPercent($0.rounded()) } ?? "-",
             gpuPercent.map { usageColor(for: $0) } ?? DesignTokens.Colors.textTertiary),
            ("RAM", "memorychip", FormatUtils.formatPercent(ramPercent.rounded()), usageColor(for: ramPercent)),
            ("THERM", "thermometer", thermalShortLabel(for: thermalState), thermalColor(for: thermalState)),
        ]

        return performanceStrip(items)
    }

    fileprivate func performanceStrip(_ items: [(label: String, icon: String, value: String, tint: Color)]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    performanceItem(tint: item.tint, systemImage: item.icon, label: item.label, value: item.value, showsLabel: index != 3)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            Grid(horizontalSpacing: DesignTokens.Spacing.md, verticalSpacing: DesignTokens.Spacing.xs) {
                ForEach(0 ..< 2) { row in
                    GridRow {
                        ForEach(0 ..< 2) { column in
                            let index = row * 2 + column
                            let item = items[index]
                            performanceItem(tint: item.tint, systemImage: item.icon, label: item.label, value: item.value, showsLabel: index != 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Thermal pressure has no percentage; its word stays readable at compact widths.
    private func thermalShortLabel(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return String(localized: "Normal", bundle: .appLanguage)
        case .fair: return String(localized: "Warm", bundle: .appLanguage)
        case .serious: return String(localized: "Hot", bundle: .appLanguage)
        case .critical: return String(localized: "Crit", bundle: .appLanguage)
        @unknown default: return "—"
        }
    }

    private func thermalColor(for state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: return DesignTokens.Colors.Status.active
        case .fair: return DesignTokens.Colors.Status.caution
        case .serious: return DesignTokens.Colors.Status.warning
        case .critical: return DesignTokens.Colors.Status.danger
        @unknown default: return DesignTokens.Colors.textTertiary
        }
    }

    /// Activity Monitor–style thresholds (50 / 80).
    private func usageColor(for percent: Double) -> Color {
        if percent >= 80 {
            return DesignTokens.Colors.Status.danger
        }
        if percent >= 50 {
            return DesignTokens.Colors.Status.warning
        }
        return DesignTokens.Colors.Status.active
    }

    private func performanceItem(tint: Color, systemImage: String, label: String, value: String, showsLabel: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            if showsLabel {
                Text(verbatim: label)
                    .font(DesignTokens.Typography.captionEmphasized)
                    .foregroundStyle(.secondary)
            }

            Text(verbatim: value)
                .font(DesignTokens.Typography.metricEmphasized)
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(Text("\(label) \(value)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label) \(value)"))
    }

    private var footer: some View {
        HStack(spacing: MenuBarMetrics.controlSpacing) {
            Button(action: invokeManageWindow) {
                HStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3")
                        .font(DesignTokens.Typography.bodyEmphasized)
                    Text("Manage")
                        .font(DesignTokens.Typography.bodyEmphasized)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .adaptiveGlassButton(.prominent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("Manage wallpapers"))

            GlassIconButton("gearshape", action: invokeOpenSettings)
                .help(Text("Open General Settings"))
                .accessibilityLabel(Text("Open General Settings"))

            GlassIconButton("arrow.clockwise") { screenManager.reloadAllScreens() }
                .disabled(isWallpaperSwitchDisabled)
                .help(Text("Reload all wallpapers"))
                .accessibilityLabel(Text("Reload all wallpapers"))

            GlassIconButton("power", tint: DesignTokens.Colors.Status.danger) {
                NSApp.terminate(nil)
            }
            .help(Text("Quit \(BundleIdentity.productDisplayName)"))
            .accessibilityLabel(Text("Quit \(BundleIdentity.productDisplayName)"))
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
        if let attempt = screenManager.wallpaperLoads.attempt(for: screen), attempt.phase != .failed {
            return String(localized: "Loading…", bundle: .appLanguage)
        }
        if let failure = screenManager.wallpaperLoads.attempt(for: screen)?.failure {
            return String(localized: "Last wallpaper application failed", bundle: .appLanguage) + " · " + failure.title
        }
        if summary.activity == .restoring {
            return String(localized: "Restoring", bundle: .appLanguage)
        }
        // Show the suspension reason before wallpaper identity.
        if summary.activity == .policySuspended,
           let reason = SuspendReasonText.localized(
               for: screenManager.suspendReasonsByScreen[screen.id] ?? []
           ) {
            return reason
        }

        // Failure details also take precedence over wallpaper identity.
        if summary.activity == .error, let message = summary.subtitle, !message.isEmpty {
            return message
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
            String(localized: "Video", bundle: .appLanguage)
        case .html:
            String(localized: "Web", bundle: .appLanguage)
        case .scene:
            String(localized: "Scene", bundle: .appLanguage)
        case nil:
            nil
        }
    }

    private func displayVisualState(for activity: WallpaperSessionActivity) -> DisplayVisualState {
        switch activity {
        case .active:
            .active
        case .paused:
            .paused
        case .policySuspended:
            .policySuspended
        case .restoring:
            .restoring
        case .off:
            .off
        case .error:
            .error
        case .inactive:
            .inactive
        }
    }

    private func isSpanned(_ screen: Screen) -> Bool {
        guard let config = screenManager.getConfiguration(for: screen) else { return false }
        if config.activeWallpaper.wallpaperType == .scene, let group = config.sceneSpanGroupID {
            return screenManager.screens.filter {
                guard let peer = screenManager.getConfiguration(for: $0) else { return false }
                return peer.sceneSpanGroupID == group && peer.activeWallpaper.wallpaperType == .scene
            }.count > 1
        }
        return config.activeWallpaper.wallpaperType == .video
            && config.videoDisplayMode == .spanAllDisplays && screenManager.screens.count > 1
    }

    private func canStepPlaylist(for screen: Screen) -> Bool {
        featureCatalog.isEnabled(.playlists) && screenManager.getConfiguration(for: screen)?.canNavigatePlaylist == true
    }

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
        openHome()
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

enum MenuBarWallpaperStatus: Equatable {
    case notConfigured, playing, visible, mixed, paused, policySuspended, restoring, loading, off, error

    static func resolve(
        summaries: [WallpaperSessionSummary], globallyEnabled: Bool,
        hasFailedLoad: Bool = false, hasPendingLoad: Bool = false
    ) -> Self {
        let configured = summaries.filter(\.isConfigured)
        if !globallyEnabled, !configured.isEmpty {
            return .off
        }
        if hasFailedLoad || configured.contains(where: { $0.activity == .error }) {
            return .error
        }
        if hasPendingLoad {
            return .loading
        }
        guard !configured.isEmpty else { return .notConfigured }
        if configured.contains(where: { $0.activity == .active }) {
            if configured.contains(where: { $0.activity != .active }) {
                return .mixed
            }
            return configured.contains(where: \.supportsPlaybackControl) ? .playing : .visible
        }
        if configured.contains(where: { $0.activity == .restoring }) {
            return .restoring
        }
        if configured.allSatisfy({ $0.activity == .off }) {
            return .off
        }
        if configured.allSatisfy({ $0.activity == .policySuspended }) {
            return .policySuspended
        }
        return .paused
    }

    var symbol: String {
        switch self {
        case .notConfigured: "photo.on.rectangle"
        case .playing: "play.rectangle.fill"
        case .visible: "display.2"
        case .mixed: "playpause"
        case .paused: "pause.rectangle.fill"
        case .policySuspended: "pause.circle"
        case .restoring, .loading: "arrow.triangle.2.circlepath"
        case .off: "rectangle.slash"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .notConfigured: String(localized: "Not configured", bundle: .appLanguage)
        case .playing: String(localized: "Playing", bundle: .appLanguage)
        case .visible: String(localized: "active", bundle: .appLanguage)
        case .mixed: String(localized: "Mixed playback", bundle: .appLanguage)
        case .paused: String(localized: "Paused", bundle: .appLanguage)
        case .policySuspended: String(localized: "Paused by system", bundle: .appLanguage)
        case .restoring: String(localized: "Restoring", bundle: .appLanguage)
        case .loading: String(localized: "Loading…", bundle: .appLanguage)
        case .off: String(localized: "Off", bundle: .appLanguage)
        case .error: String(localized: "Error", bundle: .appLanguage)
        }
    }
}

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
    case loading

    var tint: Color {
        switch self {
        case .active: DesignTokens.Colors.Status.active
        case .paused, .policySuspended: DesignTokens.Colors.Status.warning
        case .restoring, .loading: DesignTokens.Colors.Status.info
        case .off: .secondary
        case .error: DesignTokens.Colors.Status.danger
        case .inactive: .secondary
        }
    }

    var symbol: String? {
        switch self {
        case .active, .inactive: nil
        case .paused: "pause.fill"
        case .policySuspended: "pause.circle.fill"
        case .restoring, .loading: "arrow.triangle.2.circlepath"
        case .off: "stop.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .active:
            String(localized: "active", bundle: .appLanguage)
        case .paused:
            String(localized: "paused", bundle: .appLanguage)
        case .policySuspended:
            String(localized: "Paused by system", bundle: .appLanguage)
        case .restoring:
            String(localized: "Restoring", bundle: .appLanguage)
        case .loading:
            String(localized: "Loading…", bundle: .appLanguage)
        case .off:
            String(localized: "off", bundle: .appLanguage)
        case .error:
            String(localized: "error", bundle: .appLanguage)
        case .inactive:
            String(localized: "idle", bundle: .appLanguage)
        }
    }
}

private struct MenuBarOuterShell: ViewModifier {
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
    var isSpanned = false
    let visualState: DisplayVisualState
    let intendsToPlay: Bool
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
                .accessibilityHint(isSpanned ? Text("Spans multiple displays") : Text("Open display settings"))

                // All four at `.regular`, all on plain glass: mixing sizes or tinting the two main ones `.prominent` would make a transport cluster read as three unrelated controls.
                if let addAction {
                    GlassIconButton("plus", size: .regular, action: addAction)
                        .accessibilityLabel(Text("Add wallpaper to this display"))
                } else if supportsPlayback {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if canStepPlaylist {
                            GlassIconButton("chevron.left", size: .regular, action: previousAction)
                                .accessibilityLabel(Text("Previous wallpaper"))
                        }

                        GlassIconButton(intendsToPlay ? "pause.fill" : "play.fill", size: .regular, action: playbackAction)
                            .accessibilityLabel(Text(intendsToPlay ? "Pause wallpaper" : "Play wallpaper"))

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
            .overlay(alignment: .bottomTrailing) {
                if let symbol = state.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(state.tint)
                        .frame(width: 12, height: 12)
                        .background(DesignTokens.Colors.surfaceRaised, in: Circle())
                }
            }
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
            "speaker.slash.fill"
        case ..<0.5:
            "speaker.wave.1.fill"
        default:
            "speaker.wave.2.fill"
        }
    }
}

/// For buttons that don't already go through `.adaptiveGlassButton` (which delivers its own native press feedback).
private struct MenuBarPressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MenuBarWindowChromeClearer: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.stripChrome(anchoredAt: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async { Self.stripChrome(anchoredAt: nsView) }
    }

    private static func stripChrome(anchoredAt anchor: NSView) {
        guard let window = anchor.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear

        // Chrome is a sibling of content inside the frame view; match by position, not class — everything outside `contentView` is chrome.
        guard let content = window.contentView, let frameView = content.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
        frameView.layer?.borderWidth = 0
        for sibling in frameView.subviews where sibling !== content {
            sibling.isHidden = true
        }
    }
}

#Preview("Menu bar · metrics and display states") {
    let menu = MenuBarContent(openSettings: {}, openSettingsForScreen: { _ in }, openHome: {}, openSettingsAndAddWallpaper: { _ in })
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        menu.performanceStrip([
            ("CPU", "cpu", "100%", DesignTokens.Colors.Status.danger),
            ("GPU", "square.3.layers.3d", "25%", DesignTokens.Colors.Status.active),
            ("RAM", "memorychip", "58%", DesignTokens.Colors.Status.warning),
            ("THERM", "thermometer", "Normal", DesignTokens.Colors.Status.active),
        ])
        MenuBarDisplayRow(
            title: "BenQ PD3205U", subtitle: AttributedString("Not configured"), subtitleAccessibilityText: "Not configured",
            iconName: "display", visualState: .inactive, intendsToPlay: false, supportsPlayback: false, canStepPlaylist: false,
            screenID: 1, audioVolume: nil, addAction: {}, openAction: {}, previousAction: {}, playbackAction: {}, nextAction: {}
        )
        MenuBarDisplayRow(
            title: "MPG321CX OLED", subtitle: AttributedString("Scene · Paused by system"), subtitleAccessibilityText: "Paused by system",
            iconName: "display.2", isSpanned: true, visualState: .policySuspended, intendsToPlay: true, supportsPlayback: true, canStepPlaylist: true,
            screenID: 2, audioVolume: .constant(0.5), addAction: nil, openAction: {}, previousAction: {}, playbackAction: {}, nextAction: {}
        )
        HStack(spacing: DesignTokens.Spacing.md) {
            ForEach(Array([MenuBarWallpaperStatus.mixed, .loading, .restoring, .policySuspended, .error, .off].enumerated()), id: \.offset) { _, state in
                Image(systemName: state.symbol).help(state.title)
            }
        }
    }
    .padding(MenuBarMetrics.outerPadding)
    .frame(width: MenuBarMetrics.popoverWidth)
    .background(DesignTokens.Colors.surfaceRaised)
}
