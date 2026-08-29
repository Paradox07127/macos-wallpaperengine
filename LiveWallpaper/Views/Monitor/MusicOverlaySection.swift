import AppKit
import LiveWallpaperCore
import SwiftUI

// MARK: - Section

/// The Music overlay as one section of the Overlays tab — a sibling of the
/// Weather and Monitor pages. It edits the display's own
/// `MusicOverlayConfiguration`; the Monitor board is a separate module and this
/// page never touches it.
struct MusicOverlaySection: View {
    let screen: Screen
    let screenManager: ScreenManager

    @AppStorage("Music.AppearanceExpanded") private var isAppearanceExpanded = true
    @AppStorage("Music.TypographyExpanded") private var isTypographyExpanded = true
    @AppStorage("Music.ElementsExpanded") private var isElementsExpanded = true
    @AppStorage("Music.LyricsExpanded") private var isLyricsExpanded = false
    @AppStorage("Music.PlaybackExpanded") private var isPlaybackExpanded = true
    @AppStorage("Music.EffectsExpanded") private var isEffectsExpanded = false

    private var overlay: MonitorOverlayConfiguration {
        screenManager.monitorOverlay(for: screen)
    }

    /// Whether this display's wallpaper has a still frame to preview against.
    var backdropAvailable: Bool = false

    private var music: MusicOverlayConfiguration { overlay.music }

    private var isOn: Bool { music.enabled }

    /// Every DIY control is dead while the layer is off, exactly as the
    /// Style / Size / Position rows above them.
    private var isEditable: Bool { isOn }

    private var options: NowPlayingOptions {
        NowPlayingOptions(music.options)
    }

    var body: some View {
        VStack(spacing: 12) {
            controlCard
            appearanceCard
            typographyCard
            elementsCard
            lyricsCard
            playbackCard
            effectsCard
        }
    }

    // MARK: Option plumbing

    private func update(_ transform: (MusicOverlayConfiguration) -> MusicOverlayConfiguration) {
        let current = screenManager.monitorOverlay(for: screen).music
        let next = transform(current)
        guard next != current else { return }
        screenManager.setMusicOverlay(next, for: screen)
    }

    private func updateOptions(_ transform: @escaping (inout NowPlayingOptions) -> Void) {
        update { MusicOverlayLayout.settingOptions(on: $0, transform) }
    }

    private func optionBinding<Value>(
        _ keyPath: WritableKeyPath<NowPlayingOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { value in updateOptions { $0[keyPath: keyPath] = value } }
        )
    }

    private var controlCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                showOnThisDisplayRow
                Divider()
                layerRow
                Divider()
                styleRow
                Divider()
                sizeRow
                Divider()
                positionRow
                Divider()
                OverlayBackdropRow(available: backdropAvailable)
                #if !LITE_BUILD
                // Keyed to the switch, not the live tap: demand-driven capture is
                // legitimately idle while music is paused, and that's not a
                // condition the user needs to fix in Settings.
                if !SettingsManager.shared.loadGlobalSettings().audioResponseEnabled {
                    Text("Audio-reactive visuals need Audio Response turned on in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #endif
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var showOnThisDisplayRow: some View {
        SettingRow(
            icon: isOn ? "music.note" : "music.note.list",
            iconColor: isOn ? DesignTokens.Colors.Status.active : .secondary,
            title: "Show on This Display",
            info: "Now Playing art floats over whatever wallpaper this display is playing"
        ) {
            Toggle("", isOn: showBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Show Music on this display"))
        }
    }

    /// The Music module's own switch — it never touches `enabled`, which is the
    /// Monitor board's. Turning off keeps the configuration, so style, size and
    /// position all survive a round trip through off.
    private var showBinding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { screenManager.setMusicOverlayEnabled($0, for: screen) }
        )
    }

    private var layerRow: some View {
        SettingRow(
            icon: "square.stack.3d.up",
            iconColor: .blue,
            title: "Layer",
            info: "Desktop keeps the layer under your windows; On Top floats it above everything"
        ) {
            Picker("", selection: Binding(
                get: { music.level },
                set: { screenManager.setMusicOverlayLevel($0, for: screen) }
            )) {
                Text("Desktop").tag(MonitorOverlayLevel.desktop)
                Text("On Top").tag(MonitorOverlayLevel.front)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!isOn)
            .accessibilityLabel(Text("Music layer"))
        }
    }

    private var styleRow: some View {
        SettingRow(
            icon: "paintpalette",
            iconColor: .purple,
            title: "Style"
        ) {
            Picker("", selection: styleBinding) {
                Text("Poster").tag(NowPlayingWidgetView.Style.poster)
                Text("Vinyl").tag(NowPlayingWidgetView.Style.vinyl)
                Text("Aurora").tag(NowPlayingWidgetView.Style.aurora)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!isOn)
            .accessibilityLabel(Text("Style"))
        }
    }

    private var styleBinding: Binding<NowPlayingWidgetView.Style> {
        Binding(
            get: { NowPlayingWidgetView.style(music.options) },
            set: { style in updateOptions { $0.style = style } }
        )
    }

    private var sizeRow: some View {
        SettingRow(
            icon: "arrow.up.left.and.arrow.down.right",
            iconColor: .blue,
            title: "Size"
        ) {
            Picker("", selection: sizeBinding) {
                ForEach(MusicOverlaySize.allCases, id: \.self) { size in
                    Text(Self.sizeLabel(size)).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!isOn)
            .accessibilityLabel(Text("Widget size"))
        }
    }

    private var sizeBinding: Binding<MusicOverlaySize> {
        Binding(
            get: { music.size },
            set: { size in update { MusicOverlayLayout.setting(size: size, on: $0) } }
        )
    }

    private static func sizeLabel(_ size: MusicOverlaySize) -> LocalizedStringKey {
        switch size {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    // MARK: Position

    private var positionRow: some View {
        SettingRow(
            icon: "square.grid.3x3",
            iconColor: .teal,
            title: "Position",
            info: "Pick a spot, or drag the layer around in the preview"
        ) {
            anchorGrid
                .disabled(!isOn)
        }
    }

    private static let anchorRows: [[MusicOverlayLayout.Anchor]] = [
        [.topLeading, .top, .topTrailing],
        [.leading, .center, .trailing],
        [.bottomLeading, .bottom, .bottomTrailing],
    ]

    /// No button is lit once the layer has been dragged off the nine spots —
    /// lighting the nearest one would misreport where the layer actually is.
    private var anchorGrid: some View {
        let current = MusicOverlayLayout.anchor(of: music)
        return VStack(spacing: 3) {
            ForEach(Self.anchorRows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(row, id: \.self) { anchor in
                        anchorButton(anchor, isCurrent: anchor == current)
                    }
                }
            }
        }
        .accessibilityLabel(Text("Position"))
    }

    private func anchorButton(
        _ anchor: MusicOverlayLayout.Anchor, isCurrent: Bool
    ) -> some View {
        Button {
            update { MusicOverlayLayout.setting(anchor: anchor, on: $0) }
        } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.25))
                .frame(width: 13, height: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Self.anchorLabel(anchor)))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private static func anchorLabel(
        _ anchor: MusicOverlayLayout.Anchor
    ) -> LocalizedStringKey {
        switch anchor {
        case .topLeading: "Top left"
        case .top: "Top center"
        case .topTrailing: "Top right"
        case .leading: "Middle left"
        case .center: "Center"
        case .trailing: "Middle right"
        case .bottomLeading: "Bottom left"
        case .bottom: "Bottom center"
        case .bottomTrailing: "Bottom right"
        }
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        GroupBox {
            CollapsibleSection(
                title: "Appearance",
                systemImage: "paintbrush",
                isExpanded: $isAppearanceExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    accentRow
                    if options.accentSource == .custom {
                        Divider()
                        accentColorRow
                    }
                    Divider()
                    MusicOptionSlider(
                        icon: "circle.lefthalf.filled",
                        iconColor: .indigo,
                        title: "Opacity",
                        range: NowPlayingOptions.Limits.opacity,
                        value: options.opacity,
                        format: Self.percent
                    ) { value in updateOptions { $0.opacity = value } }
                    Divider()
                    MusicOptionSlider(
                        icon: "sun.max",
                        iconColor: .orange,
                        title: "Text brightness",
                        range: NowPlayingOptions.Limits.textBrightness,
                        value: options.textBrightness,
                        format: Self.percent
                    ) { value in updateOptions { $0.textBrightness = value } }
                }
                .disabled(!isEditable)
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var accentRow: some View {
        SettingRow(
            icon: "eyedropper",
            iconColor: .pink,
            title: "Accent",
            info: "Tint the progress line and glow from the cover, or pick your own color"
        ) {
            Picker("", selection: optionBinding(\.accentSource)) {
                Text("Album art").tag(NowPlayingOptions.AccentSource.albumArt)
                Text("Custom color").tag(NowPlayingOptions.AccentSource.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Accent"))
        }
    }

    private var accentColorRow: some View {
        SettingRow(icon: "paintpalette", iconColor: .pink, title: "Color") {
            ColorPicker("", selection: customAccentBinding, supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(Text("Color"))
        }
    }

    /// The catalog stores `#RRGGBB`; the picker hands back whatever color space
    /// the system panel was in, so it is converted to sRGB before writing.
    private var customAccentBinding: Binding<Color> {
        Binding(
            get: {
                NowPlayingOptions.accentColor(fromHex: options.customAccentHex ?? "")?.color
                    ?? Design.signalAmber
            },
            set: { color in
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let hex = NowPlayingOptions.hexString(for: NowPlayingAccentColor(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent)
                ))
                updateOptions { $0.customAccentHex = hex }
            }
        )
    }

    // MARK: Typography

    private var typographyCard: some View {
        GroupBox {
            CollapsibleSection(
                title: "Typography",
                // Not `textformat`: SF Symbols ships localized variants of it,
                // so it renders as the words 格式 / 書式 / Аа rather than a
                // glyph — and it follows the *system* language, which need not
                // be the one the app is running in. Abstract rules have no
                // locale to disagree with.
                systemImage: "text.alignleft",
                isExpanded: $isTypographyExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    titleFontRow
                    Divider()
                    alignmentRow
                    Divider()
                    MusicOptionSlider(
                        icon: "textformat.size",
                        iconColor: .teal,
                        title: "Title size",
                        range: NowPlayingOptions.Limits.titleScale,
                        value: options.titleScale,
                        format: Self.multiplier
                    ) { value in updateOptions { $0.titleScale = value } }
                    Divider()
                    marqueeRow
                }
                .disabled(!isEditable)
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    /// Four segments do not fit beside a title at the inspector's min width, so
    /// this picker takes its own full-width line — the refresh-rate row on the
    /// Monitor page splits the same way for the same reason.
    private var titleFontRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(icon: "character.book.closed", iconColor: .indigo, title: "Title font") {
                EmptyView()
            }
            Picker("", selection: Binding(
                get: { options.resolvedTitleFont },
                set: { font in updateOptions { $0.titleFont = font } }
            )) {
                Text("Serif").tag(NowPlayingOptions.TitleFont.serif)
                Text("Rounded").tag(NowPlayingOptions.TitleFont.rounded)
                Text("Mono").tag(NowPlayingOptions.TitleFont.monospaced)
                Text("System").tag(NowPlayingOptions.TitleFont.system)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Title font"))
        }
    }

    private var alignmentRow: some View {
        SettingRow(icon: "text.alignleft", iconColor: .blue, title: "Alignment") {
            Picker("", selection: Binding(
                get: { options.resolvedAlignment },
                set: { value in updateOptions { $0.alignment = value } }
            )) {
                Text("Left").tag(NowPlayingOptions.Alignment.leading)
                Text("Center").tag(NowPlayingOptions.Alignment.center)
                Text("Right").tag(NowPlayingOptions.Alignment.trailing)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Alignment"))
        }
    }

    private var marqueeRow: some View {
        SettingRow(
            icon: "arrow.left.arrow.right",
            iconColor: .purple,
            title: "Marquee",
            info: "Titles too long for the layer scroll sideways instead of being trimmed"
        ) {
            Toggle("", isOn: optionBinding(\.marquee))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Marquee"))
        }
    }

    // MARK: Elements

    private var elementsCard: some View {
        GroupBox {
            CollapsibleSection(
                title: "Elements",
                systemImage: "square.stack.3d.down.right",
                isExpanded: $isElementsExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    elementToggle(icon: "photo", color: .pink, title: "Artwork", binding: optionBinding(\.showArtwork))
                    Divider()
                    elementToggle(icon: "person.wave.2", color: .orange, title: "Artist", binding: optionBinding(\.showArtist))
                    Divider()
                    elementToggle(icon: "square.stack", color: .yellow, title: "Album", binding: optionBinding(\.showAlbum))
                    Divider()
                    elementToggle(icon: "timeline.selection", color: .green, title: "Progress", binding: optionBinding(\.showProgress))
                    Divider()
                    artworkShapeRow
                    Divider()
                    MusicOptionSlider(
                        icon: "shadow",
                        iconColor: .gray,
                        title: "Artwork shadow",
                        range: NowPlayingOptions.Limits.artworkShadow,
                        value: options.artworkShadow,
                        format: Self.percent
                    ) { value in updateOptions { $0.artworkShadow = value } }
                    Divider()
                    MusicOptionSlider(
                        icon: "arrow.up.left.and.arrow.down.right",
                        iconColor: .blue,
                        title: "Artwork size",
                        range: NowPlayingOptions.Limits.artworkScale,
                        value: options.artworkScale,
                        format: Self.multiplier
                    ) { value in updateOptions { $0.artworkScale = value } }
                }
                .disabled(!isEditable)
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private func elementToggle(
        icon: String, color: Color, title: LocalizedStringKey, binding: Binding<Bool>
    ) -> some View {
        SettingRow(icon: icon, iconColor: color, title: title) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text(title))
        }
    }

    /// Full-width line for the same reason as the font picker: "Rounded
    /// corners" spelled out does not fit beside a title.
    private var artworkShapeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(icon: "square.on.circle", iconColor: .purple, title: "Artwork shape") {
                EmptyView()
            }
            Picker("", selection: optionBinding(\.artworkShape)) {
                Text("Rounded corners").tag(NowPlayingOptions.ArtworkShape.rounded)
                Text("Circle").tag(NowPlayingOptions.ArtworkShape.circle)
                Text("Square").tag(NowPlayingOptions.ArtworkShape.square)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Artwork shape"))
        }
    }

    // MARK: Lyrics

    private var lyricsCard: some View {
        GroupBox {
            CollapsibleSection(
                title: "Lyrics",
                systemImage: "quote.bubble",
                isExpanded: $isLyricsExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    elementToggle(
                        icon: "text.quote", color: .pink, title: "Show lyrics",
                        binding: optionBinding(\.showLyrics)
                    )
                    Divider()
                    lyricsLinesRow
                    Text("Lyrics come from LRCLIB, a public lyrics service, and need an internet connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!isEditable)
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var lyricsLinesRow: some View {
        SettingRow(
            icon: "list.bullet",
            iconColor: .teal,
            title: "Lyric lines",
            info: "Three lines put the previous and next line around the current one, on large layers"
        ) {
            Picker("", selection: optionBinding(\.lyricsLines)) {
                Text("1 line").tag(1)
                Text("3 lines").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!options.showLyrics)
            .accessibilityLabel(Text("Lyric lines"))
        }
    }

    // MARK: Playback

    private var playbackCard: some View {
        GroupBox {
            CollapsibleSection(
                title: "Playback",
                systemImage: "playpause",
                isExpanded: $isPlaybackExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    elementToggle(
                        icon: "playpause.circle", color: .green, title: "Transport controls",
                        binding: optionBinding(\.showControls)
                    )
                    Divider()
                    elementToggle(
                        icon: "hand.draw", color: .blue, title: "Drag progress to seek",
                        binding: optionBinding(\.seekOnProgressDrag)
                    )
                    MusicPlaybackPermissionCaption()
                }
                .disabled(!isEditable)
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    // MARK: Effects

    /// Lite ships no capture pipeline, so there is nothing here to dial.
    @ViewBuilder
    private var effectsCard: some View {
        #if !LITE_BUILD
        GroupBox {
            CollapsibleSection(
                title: "Effects",
                systemImage: "waveform",
                isExpanded: $isEffectsExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    audioReactiveRow
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        MusicOptionSlider(
                            icon: "dial.medium",
                            iconColor: .green,
                            title: "Intensity",
                            range: NowPlayingOptions.Limits.audioIntensity,
                            value: options.audioIntensity,
                            format: Self.multiplier
                        ) { value in updateOptions { $0.audioIntensity = value } }
                        Divider()
                        elementToggle(
                            icon: "rays", color: .yellow, title: "Pulse",
                            binding: optionBinding(\.effectPulse)
                        )
                        Divider()
                        elementToggle(
                            icon: "camera.filters", color: .cyan, title: "Color split",
                            binding: optionBinding(\.effectChromatic)
                        )
                        Divider()
                        elementToggle(
                            icon: "waveform.path.ecg", color: .red, title: "Shake",
                            binding: optionBinding(\.effectShake)
                        )
                        Divider()
                        elementToggle(
                            icon: "sparkles", color: .purple, title: "Particles",
                            binding: optionBinding(\.effectParticles)
                        )
                        Divider()
                        elementToggle(
                            icon: "circle.circle", color: .blue, title: "Ripples",
                            binding: optionBinding(\.effectRipple)
                        )
                        Divider()
                        MusicOptionSlider(
                            icon: "metronome",
                            iconColor: .orange,
                            title: "Beat sensitivity",
                            range: NowPlayingOptions.Limits.beatSensitivity,
                            value: options.beatSensitivity,
                            format: Self.multiplier
                        ) { value in updateOptions { $0.beatSensitivity = value } }
                    }
                    .disabled(!options.audioReactive)
                }
                .disabled(!isEditable)
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        #endif
    }

    private var audioReactiveRow: some View {
        SettingRow(
            icon: "waveform",
            iconColor: .green,
            title: "Audio reactive",
            info: "Spectrum, glow and particles follow whatever is playing out loud"
        ) {
            Toggle("", isOn: optionBinding(\.audioReactive))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Audio reactive"))
        }
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func multiplier(_ value: Double) -> String {
        String(format: "%.2f×", value)
    }

}

// MARK: - Option slider

/// Inspector slider that commits on release rather than on every tick: each
/// commit rewrites the whole settings blob, which is why the preview's drag
/// also only persists in `onEnded`.
private struct MusicOptionSlider: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let range: ClosedRange<Double>
    let value: Double
    let format: (Double) -> String
    let commit: (Double) -> Void

    /// Non-nil only while a drag is in flight.
    @State private var draft: Double?

    var body: some View {
        let live = draft ?? value
        SettingRow(icon: icon, iconColor: iconColor, title: title) {
            HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                Slider(
                    value: Binding(get: { live }, set: { draft = $0 }),
                    in: range,
                    onEditingChanged: { editing in
                        guard !editing else { return }
                        if let draft { commit(draft) }
                        draft = nil
                    }
                )
                .controlSize(.small)
                .frame(minWidth: 56, maxWidth: DesignTokens.Inspector.sliderWidth)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(verbatim: format(live)))
                Text(verbatim: format(live))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.secondary)
                    .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
            }
        }
    }
}

// MARK: - Playback permission caption

/// Polled for the same reason as the status badge: the controller's state only
/// moves when the wallpaper layer actually sends something, and re-reading an
/// in-memory enum every 2 s is cheaper than threading an observation up here.
/// The probe on appear reads the current Automation grant without prompting.
private struct MusicPlaybackPermissionCaption: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            caption
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            await NowPlayingController.shared.refreshAuthorization(
                for: NowPlayingMonitor.shared.currentState.playerBundleID
            )
        }
    }

    @ViewBuilder
    private var caption: some View {
        if NowPlayingController.shared.authorization(
            for: NowPlayingMonitor.shared.currentState.playerBundleID
        ) == .denied {
            Text("Control was denied. Turn it back on in System Settings → Privacy & Security → Automation.")
        } else {
            Text("Controls fade in when the pointer is over the layer. They only take clicks inside the layer itself — the rest of the desktop keeps working — and need a one-time permission the first time you use them.")
        }
    }
}

// MARK: - Status badge

struct MusicStatusBadge: View {
    let state: MonitorNowPlayingState

    /// Floating over the preview means dark glass, not inspector chrome: the
    /// text has to read against whatever wallpaper is behind it.
    var onGlass = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                switch state.phase {
                case .playing, .paused:
                    Text(verbatim: trackLine)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if state.phase == .playing {
                        Text("Playing")
                            .font(.caption2)
                            .foregroundStyle(secondaryStyle)
                    } else {
                        Text("Paused")
                            .font(.caption2)
                            .foregroundStyle(secondaryStyle)
                    }
                case .awaitingFirstEvent:
                    Text("Waiting for the player to update")
                        .font(.footnote)
                        .foregroundStyle(secondaryStyle)
                case .noPlayer:
                    Text("Nothing is playing")
                        .font(.footnote)
                        .foregroundStyle(secondaryStyle)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .foregroundStyle(onGlass ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .accessibilityElement(children: .combine)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var secondaryStyle: AnyShapeStyle {
        onGlass ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary)
    }

    private var trackLine: String {
        if let artist = state.artist, !artist.isEmpty {
            return "\(state.title) — \(artist)"
        }
        return state.title
    }

    private var icon: String {
        switch state.phase {
        case .playing: return "music.note"
        case .paused: return "pause.circle"
        case .awaitingFirstEvent: return "hourglass"
        case .noPlayer: return "music.note.list"
        }
    }

    private var iconColor: Color {
        state.phase == .playing ? DesignTokens.Colors.Status.active : .secondary
    }
}
