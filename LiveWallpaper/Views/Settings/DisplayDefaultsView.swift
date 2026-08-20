import LiveWallpaperCore
import SwiftUI

private enum DisplayDefaultsKind {
    case video
    case html
    case scene
}

struct DisplayDefaultsView: View {
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(ScreenManager.self) private var screenManager
    @State private var displayDefaults = SettingsManager.shared.loadDisplayDefaults()
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    init(pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)) {
        _pendingSearchAnchor = pendingSearchAnchor
    }

    var body: some View {
        Form {
            arrangementSection
            if featureCatalog.capabilities.canRender(.video) {
                videoSection
            }
            if featureCatalog.capabilities.canRender(.html) {
                webSection
            }
            if featureCatalog.capabilities.canRender(.scene) {
                sceneSection
            }
        }
        .settingsFormChrome()
        .settingsSearchAnchorScroller(
            pendingSearchAnchor: $pendingSearchAnchor,
            anchors: [
                .displayDefaultsArrangement,
                .displayDefaultsVideo,
                .displayDefaultsWeb,
                .displayDefaultsScene
            ]
        )
    }

    /// Read-only mirror of the macOS arrangement: it answers "which panel is
    /// which" for every per-display control in the app, and hosts renaming.
    @ViewBuilder
    private var arrangementSection: some View {
        if !screenManager.screens.isEmpty {
            Section {
                DisplayArrangementMap(
                    items: screenManager.screens.map {
                        DisplayArrangementItem(id: $0.id, frame: $0.frame)
                    },
                    height: 150
                ) { item, size in
                    if let screen = screenManager.screens.first(where: { $0.id == item.id }) {
                        arrangementTile(screen, size: size)
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            } header: {
                SettingsSearchSectionHeader("Displays", anchor: .displayDefaultsArrangement)
            } footer: {
                Text("Mirrors your macOS display arrangement. Right-click a display to rename it.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func arrangementTile(_ screen: Screen, size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
            .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                    .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: DesignTokens.Card.strokeWidth)
            }
            .overlay {
                VStack(spacing: 2) {
                    Text(verbatim: screen.name)
                        .font(DesignTokens.Typography.caption)
                        .marqueeOnHover(truncationMode: .tail)
                    // Only the taller tiles have room for a second line.
                    if size.height >= 46 {
                        Text(verbatim: "\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                            .font(DesignTokens.Typography.metric)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xs)
            }
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
            .screenRenameMenu(for: screen)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(screen.name), \(Int(screen.frame.width)) by \(Int(screen.frame.height)) pixels", comment: "Arrangement map tile VoiceOver label: display name, then width and height in pixels."))
    }

    private var videoSection: some View {
        Section {
            audioRows(for: .video)
            frameRateRow(for: .video)
            scalingRow(for: .video, modes: VideoFitMode.videoModes)
            spanDisplaysRow
            colorSpaceRow
        } header: {
            SettingsSearchSectionHeader("Video", anchor: .displayDefaultsVideo)
        }
    }

    private var webSection: some View {
        Section {
            audioRows(for: .html)
            interactionRow(for: .html, subtitle: "Default pointer and click input")
        } header: {
            SettingsSearchSectionHeader("Web", anchor: .displayDefaultsWeb)
        }
    }

    private var sceneSection: some View {
        Section {
            audioRows(for: .scene)
            frameRateRow(for: .scene)
            scalingRow(for: .scene, modes: VideoFitMode.sceneModes)
            sceneInteractionRows
        } header: {
            SettingsSearchSectionHeader("Scene", anchor: .displayDefaultsScene)
        }
    }

    @ViewBuilder
    private func audioRows(for kind: DisplayDefaultsKind) -> some View {
        SettingRow(
            icon: "speaker.slash",
            iconColor: .blue,
            title: kind == .html ? "Mute audio" : "Mute",
            subtitle: "Default audio state"
        ) {
            Toggle("", isOn: playbackBinding(\.muted, for: kind))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(kind == .html ? "Mute audio by default" : "Mute by default"))
        }

        SettingRow(
            icon: "speaker.wave.2",
            iconColor: .blue,
            title: "Volume",
            subtitle: "Default output level"
        ) {
            HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                Slider(value: playbackBinding(\.videoVolume, for: kind), in: 0...1)
                    .controlSize(.small)
                    .frame(width: DesignTokens.Settings.sliderWidth)
                    .accessibilityLabel(Text("Default volume"))

                Text(verbatim: "\(Int((playback(for: kind).videoVolume * 100).rounded()))%")
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.secondary)
                    .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
            }
        }
    }

    private func frameRateRow(for kind: DisplayDefaultsKind) -> some View {
        SettingRow(
            icon: "gauge.with.dots.needle.bottom.50percent",
            iconColor: .teal,
            title: "Frame Rate",
            subtitle: "Default frame-rate cap"
        ) {
            Picker("", selection: playbackBinding(\.frameRateLimit, for: kind)) {
                ForEach(FrameRateLimit.allCases) { limit in
                    Text(limit.titleKey).tag(limit)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Default frame rate"))
        }
    }

    private func scalingRow(for kind: DisplayDefaultsKind, modes: [VideoFitMode]) -> some View {
        SettingRow(
            icon: "aspectratio",
            iconColor: .purple,
            title: "Scaling",
            subtitle: "Default display scaling"
        ) {
            Picker("", selection: playbackBinding(\.fitMode, for: kind)) {
                ForEach(modes) { mode in
                    Text(mode.titleKey).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Default scaling"))
        }
    }

    private var spanDisplaysRow: some View {
        SettingRow(
            icon: "rectangle.split.2x1",
            iconColor: .indigo,
            title: "Span Displays",
            subtitle: "Default multi-display video mode"
        ) {
            Toggle("", isOn: Binding(
                get: { displayDefaults.video.videoDisplayMode == .spanAllDisplays },
                set: { enabled in
                    displayDefaults.video.videoDisplayMode = enabled ? .spanAllDisplays : .perDisplay
                    SettingsManager.shared.saveDisplayDefaults(displayDefaults)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(Text("Span videos across displays by default"))
        }
    }

    private var colorSpaceRow: some View {
        SettingRow(
            icon: "circle.lefthalf.filled",
            iconColor: .pink,
            title: "Color Space",
            subtitle: "Default video color management"
        ) {
            Picker("", selection: playbackBinding(\.videoColorSpace, for: .video)) {
                ForEach(VideoColorSpace.allCases) { colorSpace in
                    Text(verbatim: colorSpace.titleKey).tag(colorSpace)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Default color space"))
        }
    }

    private var sceneInteractionRows: some View {
        Group {
            SettingRow(
                icon: "cursorarrow.rays",
                iconColor: .cyan,
                title: "Follow Cursor",
                subtitle: "Default passive cursor response"
            ) {
                Toggle("", isOn: playbackBinding(\.sceneMouseInteractionEnabled, for: .scene))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Follow cursor by default"))
            }

            interactionRow(for: .scene, subtitle: "Default pointer and click input")
        }
    }

    private func interactionRow(for kind: DisplayDefaultsKind, subtitle: LocalizedStringKey) -> some View {
        SettingRow(
            icon: "cursorarrow.click.2",
            iconColor: .orange,
            title: "Interaction",
            subtitle: subtitle
        ) {
            Toggle("", isOn: playbackBinding(\.interactiveInputEnabled, for: kind))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Interaction by default"))
        }
    }

    private func playbackBinding<Value>(
        _ keyPath: WritableKeyPath<DisplayPlaybackDefaults, Value>,
        for kind: DisplayDefaultsKind
    ) -> Binding<Value> {
        Binding(
            get: { playback(for: kind)[keyPath: keyPath] },
            set: { newValue in
                var next = playback(for: kind)
                next[keyPath: keyPath] = newValue
                setPlayback(next, for: kind)
            }
        )
    }

    private func playback(for kind: DisplayDefaultsKind) -> DisplayPlaybackDefaults {
        switch kind {
        case .video:
            displayDefaults.video
        case .html:
            displayDefaults.html
        case .scene:
            displayDefaults.scene
        }
    }

    private func setPlayback(_ playback: DisplayPlaybackDefaults, for kind: DisplayDefaultsKind) {
        switch kind {
        case .video:
            displayDefaults.video = playback
        case .html:
            displayDefaults.html = playback
        case .scene:
            displayDefaults.scene = playback
        }
        SettingsManager.shared.saveDisplayDefaults(displayDefaults)
    }
}
