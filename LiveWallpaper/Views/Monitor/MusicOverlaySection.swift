import AppKit
import LiveWallpaperCore
import SwiftUI

// MARK: - Pure board edits (unit-tested)

/// Board mutations the Music page performs. All persistence still flows through
/// `ScreenManager.setMonitorOverlayBoard`; these only compute the next board.
enum MusicOverlayBoardEditor {
    /// Mirrors the schema's reference cell pitch (194×206 on a 1512×982 board);
    /// those constants are internal to LiveWallpaperCore, so footprint math on
    /// the normalized board restates them here.
    private static let cellWidth = 194.0 / 1512.0
    private static let cellHeight = 206.0 / 982.0

    static let defaultSize: MonitorWidgetSize = .medium

    static func hasNowPlaying(_ board: MonitorBoardConfiguration) -> Bool {
        board.widgets.contains { $0.kind == .nowPlaying }
    }

    static func nowPlayingPlacement(in board: MonitorBoardConfiguration) -> MonitorWidgetPlacement? {
        board.widgets.first { $0.kind == .nowPlaying }
    }

    /// Normalized width/height the widget covers on the reference board.
    static func normalizedFootprint(for kind: MonitorWidgetKind, size: MonitorWidgetSize) -> CGSize {
        let cells = kind.cellSize(for: size)
        return CGSize(
            width: Double(cells.columns) * cellWidth,
            height: Double(cells.rows) * cellHeight
        )
    }

    static func normalizedRect(of placement: MonitorWidgetPlacement) -> CGRect {
        let footprint = normalizedFootprint(for: placement.kind, size: placement.size)
        return CGRect(x: placement.x, y: placement.y, width: footprint.width, height: footprint.height)
    }

    static func addingNowPlaying(
        to board: MonitorBoardConfiguration,
        size: MonitorWidgetSize = defaultSize,
        options: [String: MonitorWidgetOptionValue] = [:]
    ) -> MonitorBoardConfiguration {
        guard !hasNowPlaying(board) else { return board }
        let footprint = normalizedFootprint(for: .nowPlaying, size: size)
        let origin = firstFreeOrigin(footprint: footprint, avoiding: board.widgets)
        var next = board
        next.widgets.append(MonitorWidgetPlacement(
            kind: .nowPlaying, size: size, x: origin.x, y: origin.y, options: options
        ))
        return next
    }

    // MARK: Nine-up anchors

    /// The nine grid positions the Position control offers. Anything else is a
    /// custom spot the user dragged to, which no button claims.
    enum Anchor: String, CaseIterable, Hashable {
        case topLeading, top, topTrailing
        case leading, center, trailing
        case bottomLeading, bottom, bottomTrailing
    }

    /// Wide enough to survive the rounding a drag leaves behind, far narrower
    /// than the gap between two neighbouring anchors at any allowed size.
    static let anchorTolerance = 0.02

    /// Normalized origin of `anchor` for a Now Playing layer of `size`. A layer
    /// wider than the board would otherwise produce a negative origin.
    static func anchorOrigin(_ anchor: Anchor, size: MonitorWidgetSize) -> CGPoint {
        let footprint = normalizedFootprint(for: .nowPlaying, size: size)
        let freeX = max(0, 1 - footprint.width)
        let freeY = max(0, 1 - footprint.height)
        let x: Double = switch anchor {
        case .topLeading, .leading, .bottomLeading: 0
        case .top, .center, .bottom: freeX / 2
        case .topTrailing, .trailing, .bottomTrailing: freeX
        }
        let y: Double = switch anchor {
        case .topLeading, .top, .topTrailing: 0
        case .leading, .center, .trailing: freeY / 2
        case .bottomLeading, .bottom, .bottomTrailing: freeY
        }
        return CGPoint(x: x, y: y)
    }

    /// Which anchor this placement sits on, or nil for a dragged position.
    static func anchor(of placement: MonitorWidgetPlacement) -> Anchor? {
        Anchor.allCases.first { candidate in
            let origin = anchorOrigin(candidate, size: placement.size)
            return abs(origin.x - placement.x) <= anchorTolerance
                && abs(origin.y - placement.y) <= anchorTolerance
        }
    }

    static func settingAnchor(
        _ anchor: Anchor, on board: MonitorBoardConfiguration
    ) -> MonitorBoardConfiguration {
        mutatingNowPlaying(board) { placement in
            var next = placement
            let origin = anchorOrigin(anchor, size: placement.size)
            next.x = origin.x
            next.y = origin.y
            return next
        }
    }

    /// Drag landing spot from the inspector preview; already clamped by the caller.
    static func settingOrigin(
        x: Double, y: Double, on board: MonitorBoardConfiguration
    ) -> MonitorBoardConfiguration {
        mutatingNowPlaying(board) { placement in
            var next = placement
            next.x = x
            next.y = y
            return next
        }
    }

    static func settingStyle(
        _ style: NowPlayingWidgetView.Style, on board: MonitorBoardConfiguration
    ) -> MonitorBoardConfiguration {
        settingOptions(on: board) { $0.style = style }
    }

    /// Every DIY control funnels through here, so the drop-on-default rule and
    /// the clamping live in exactly one place.
    static func settingOptions(
        on board: MonitorBoardConfiguration,
        _ transform: (inout NowPlayingOptions) -> Void
    ) -> MonitorBoardConfiguration {
        mutatingNowPlaying(board) { MonitorWidgetDraft.settingNowPlayingOptions(on: $0, transform) }
    }

    /// Growing a widget can push it off the board or onto a neighbour, so the
    /// new footprint is clamped and, if it still collides, re-placed by
    /// first-fit — the drag-time editor refits for the same reason.
    static func settingSize(
        _ size: MonitorWidgetSize, on board: MonitorBoardConfiguration
    ) -> MonitorBoardConfiguration {
        let others = board.widgets.filter { $0.kind != .nowPlaying }.map(normalizedRect(of:))
        return mutatingNowPlaying(board) { placement in
            var next = placement
            next.size = size
            let footprint = normalizedFootprint(for: next.kind, size: size)
            next.x = min(max(next.x, 0), max(0, 1 - footprint.width))
            next.y = min(max(next.y, 0), max(0, 1 - footprint.height))
            let rect = CGRect(x: next.x, y: next.y, width: footprint.width, height: footprint.height)
                .insetBy(dx: 1e-6, dy: 1e-6)
            if others.contains(where: { $0.intersects(rect) }) {
                let origin = firstFreeOrigin(footprint: footprint, avoiding: board.widgets.filter {
                    $0.kind != .nowPlaying
                })
                next.x = origin.x
                next.y = origin.y
            }
            return next
        }
    }

    private static func mutatingNowPlaying(
        _ board: MonitorBoardConfiguration,
        _ mutate: (MonitorWidgetPlacement) -> MonitorWidgetPlacement
    ) -> MonitorBoardConfiguration {
        guard let index = board.widgets.firstIndex(where: { $0.kind == .nowPlaying }) else { return board }
        var next = board
        next.widgets[index] = mutate(next.widgets[index])
        return next
    }

    /// First-fit scan on the reference grid, left→right then top→bottom. The
    /// default system widgets pack the bottom rows, so a new Music layer
    /// normally lands in the empty upper board. Full board falls back to (0, 0).
    private static func firstFreeOrigin(
        footprint: CGSize, avoiding widgets: [MonitorWidgetPlacement]
    ) -> (x: Double, y: Double) {
        let occupied = widgets.map(normalizedRect(of:))
        var y = 0.0
        while y + footprint.height <= 1.0 + 1e-9 {
            var x = 0.0
            while x + footprint.width <= 1.0 + 1e-9 {
                // Inset so rects that merely share an edge don't count as overlap.
                let candidate = CGRect(x: x, y: y, width: footprint.width, height: footprint.height)
                    .insetBy(dx: 1e-6, dy: 1e-6)
                if !occupied.contains(where: { $0.intersects(candidate) }) {
                    return (x, y)
                }
                x += cellWidth
            }
            y += cellHeight
        }
        return (0, 0)
    }
}

// MARK: - Section

/// The Music overlay as one section of the Overlays tab — a sibling of the
/// Weather and Monitor pages. It edits the Now Playing placement on the same
/// monitor board the Monitor page manages, through the same ScreenManager API.
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

    private var placement: MonitorWidgetPlacement? {
        MusicOverlayBoardEditor.nowPlayingPlacement(in: overlay.board)
    }

    private var isOn: Bool { overlay.musicEnabled }

    /// Every DIY control is dead while the layer is off or absent, exactly as
    /// the Style / Size / Position rows above them.
    private var isEditable: Bool { isOn && placement != nil }

    private var options: NowPlayingOptions {
        NowPlayingOptions(placement?.options ?? [:])
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

    private func updateOptions(_ transform: @escaping (inout NowPlayingOptions) -> Void) {
        let board = screenManager.monitorOverlay(for: screen).board
        let next = MusicOverlayBoardEditor.settingOptions(on: board, transform)
        if next != board {
            screenManager.setMonitorOverlayBoard(next, for: screen)
        }
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
    /// Monitor board's. Turning off keeps the placement, so style, size and
    /// position all survive a round trip through off.
    private var showBinding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { on in
                if on {
                    let board = screenManager.monitorOverlay(for: screen).board
                    let next = MusicOverlayBoardEditor.addingNowPlaying(to: board)
                    if next != board {
                        screenManager.setMonitorOverlayBoard(next, for: screen)
                    }
                }
                screenManager.setMusicOverlayEnabled(on, for: screen)
            }
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
                get: { overlay.musicLevel },
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
            .disabled(!isOn || placement == nil)
            .accessibilityLabel(Text("Style"))
        }
    }

    private var styleBinding: Binding<NowPlayingWidgetView.Style> {
        Binding(
            get: { placement.map { NowPlayingWidgetView.style($0.options) } ?? .poster },
            set: { style in
                let board = screenManager.monitorOverlay(for: screen).board
                let next = MusicOverlayBoardEditor.settingStyle(style, on: board)
                if next != board {
                    screenManager.setMonitorOverlayBoard(next, for: screen)
                }
            }
        )
    }

    private var sizeRow: some View {
        SettingRow(
            icon: "arrow.up.left.and.arrow.down.right",
            iconColor: .blue,
            title: "Size"
        ) {
            Picker("", selection: sizeBinding) {
                ForEach(MonitorWidgetKind.nowPlaying.allowedSizes, id: \.self) { size in
                    Text(WidgetSettingsPopover.sizeLabel(size)).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!isOn || placement == nil)
            .accessibilityLabel(Text("Widget size"))
        }
    }

    private var sizeBinding: Binding<MonitorWidgetSize> {
        Binding(
            get: { placement?.size ?? MusicOverlayBoardEditor.defaultSize },
            set: { size in
                let board = screenManager.monitorOverlay(for: screen).board
                let next = MusicOverlayBoardEditor.settingSize(size, on: board)
                if next != board {
                    screenManager.setMonitorOverlayBoard(next, for: screen)
                }
            }
        )
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
                .disabled(!isOn || placement == nil)
        }
    }

    private static let anchorRows: [[MusicOverlayBoardEditor.Anchor]] = [
        [.topLeading, .top, .topTrailing],
        [.leading, .center, .trailing],
        [.bottomLeading, .bottom, .bottomTrailing],
    ]

    /// No button is lit once the layer has been dragged off the nine spots —
    /// lighting the nearest one would misreport where the layer actually is.
    private var anchorGrid: some View {
        let current = placement.flatMap(MusicOverlayBoardEditor.anchor(of:))
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
        _ anchor: MusicOverlayBoardEditor.Anchor, isCurrent: Bool
    ) -> some View {
        Button {
            let board = screenManager.monitorOverlay(for: screen).board
            let next = MusicOverlayBoardEditor.settingAnchor(anchor, on: board)
            if next != board {
                screenManager.setMonitorOverlayBoard(next, for: screen)
            }
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
        _ anchor: MusicOverlayBoardEditor.Anchor
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
                systemImage: "textformat",
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
