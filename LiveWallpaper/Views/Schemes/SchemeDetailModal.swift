import AppKit
import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// Which scheme the Schemes page's detail modal shows, and the grid's order its ← → walk.
@MainActor
@Observable
final class SchemeDetailPresenter {
    /// nil closes the modal.
    var presentedID: UUID?
    /// The grid's schemes as filtered and sorted.
    var run: [ScreenScheme] = []
    /// The library's apply behind its confirmation; set by `SchemeLibraryView`, which owns that dialog.
    @ObservationIgnored var requestApply: (ScreenScheme, Screen) -> Void = { _, _ in }

    var presented: ScreenScheme? {
        presentedID.flatMap { id in run.first { $0.id == id } }
    }

    /// nil when there is no scheme `offset` steps from the shown one.
    func neighbour(_ offset: Int) -> (() -> Void)? {
        guard let index = run.firstIndex(where: { $0.id == presentedID }), run.indices.contains(index + offset) else {
            return nil
        }
        let id = run[index + offset].id
        return { self.presentedID = id }
    }
}

/// One scheme, read only: its facts and preview on the left, what it would set on the right, apply at the bottom.
@MainActor
struct SchemeDetailModal: View {
    let scheme: ScreenScheme
    let targets: [ModalDisplayTarget]
    /// The page's own size; the chrome places the panel in it.
    let windowSize: CGSize
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    let applyTo: @MainActor (CGDirectDisplayID) -> Void
    let onDismiss: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var artwork: CGImage?
    @State private var location = LibraryContentLocation.unknown

    private var locale: Locale {
        AppLanguagePreference.current.locale
    }

    var body: some View {
        EditDeskModalChrome(
            windowSize: windowSize,
            title: scheme.name,
            actions: headerActions,
            onDismiss: onDismiss,
            onTargetShortcut: applyToShortcut,
            onPrevious: onPrevious,
            onNext: onNext
        ) { _ in
            WallpaperDetailLayout(
                facts: SchemeDetailRows.facts(for: scheme, now: Date(), locale: locale),
                previewSize: previewSize,
                preview: { preview },
                sidebar: { sidebar },
                status: { EmptyView() },
                buttons: { ModalDisplayButtons(targets: targets, canApply: location.isAvailable, applyTo: applyTo) }
            )
            .id(scheme.id)
        }
        .task(id: TileContentKey(id: scheme.id, coverFileName: scheme.coverFileName, version: scheme.updatedAt)) {
            await load()
        }
    }

    private var headerActions: [ModalHeaderAction] {
        guard let url = location.revealURL else { return [] }
        return [ModalHeaderAction(kind: .showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([url]) }]
    }

    private func applyToShortcut(_ index: Int) {
        guard location.isAvailable, let target = ModalKeyMap.target(forShortcut: index, in: targets) else { return }
        applyTo(target.id)
    }

    private func load() async {
        artwork = nil
        location = .unknown
        let resolved = await SchemeArtwork.location(for: scheme)
        guard !Task.isCancelled else { return }
        location = resolved
        let image = await SchemeArtwork.image(for: scheme)
        guard !Task.isCancelled else { return }
        artwork = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Preview

    private var previewSize: CGSize {
        guard let artwork else { return ModalGeometry.previewSize }
        return ModalGeometry.previewFit(pixels: CGSize(width: artwork.width, height: artwork.height), scale: displayScale).size
    }

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panelLarge, style: .continuous)
    }

    private var preview: some View {
        ZStack {
            DesignTokens.Colors.surfaceSunken
            if let artwork {
                Image(decorative: artwork, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: scheme.iconName)
                    .font(DesignTokens.EditDesk.Typography.modalTitle)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
            }
        }
        .clipShape(previewShape)
        .overlay(previewShape.strokeBorder(DesignTokens.EditDesk.Colors.strokeBadge, lineWidth: 1))
        .accessibilityHidden(true)
    }

    // MARK: Right column

    private var sidebar: some View {
        ForEach(SchemeDetailRows.make(for: scheme, locale: locale)) { section in
            WallpaperDetailSection(title: Text(verbatim: section.title)) {
                if section.kind == .wallpaper, !location.isAvailable {
                    InlineNoticeBanner(
                        tint: DesignTokens.Colors.Status.danger,
                        symbol: "exclamationmark.triangle",
                        title: Text("This wallpaper's file is missing")
                    )
                }
                SchemeDetailRowGrid(rows: section.rows)
            }
        }
    }
}

/// A section's label / value rows, drawn like `WallpaperFactGrid`'s.
private struct SchemeDetailRowGrid: View {
    let rows: [SchemeDetailRows.Row]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Spacing.md, verticalSpacing: DesignTokens.Spacing.sm) {
            ForEach(rows) { row in
                GridRow {
                    Text(verbatim: row.label)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .gridColumnAlignment(.leading)
                    Text(verbatim: row.value)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(DesignTokens.EditDesk.Typography.chip)
    }
}

/// What the scheme detail modal lists, already localized. A section with no rows is left out.
@MainActor
enum SchemeDetailRows {
    struct Row: Equatable, Identifiable {
        enum Key: Equatable {
            case name, webAddress, type
            case scaling, playbackSpeed, volume, colorSpace, frameRate, sceneSettings, mouseInteraction, javaScript, interaction
            case mode, timeSlots, fallback, playlist, shuffle, rotation
            case clock, music, board
            case lockScreen, clickCapture
        }

        let key: Key
        let label: String
        let value: String

        var id: Key {
            key
        }
    }

    struct Section: Equatable, Identifiable {
        enum Kind: Equatable { case wallpaper, playback, automation, widgets, other }

        let kind: Kind
        let rows: [Row]

        var id: Kind {
            kind
        }

        var title: String {
            switch kind {
            case .wallpaper: String(localized: "Wallpaper", bundle: .appLanguage)
            case .playback:
                String(localized: "Picture & Playback", bundle: .appLanguage, comment: "Scheme detail section: how the wallpaper is fitted and played.")
            case .automation:
                String(localized: "Automation", bundle: .appLanguage, comment: "Scheme detail section: the display's playlist or daily schedule.")
            case .widgets: String(localized: "Widgets", bundle: .appLanguage)
            case .other:
                String(localized: "Other Settings", bundle: .appLanguage, comment: "Scheme detail section: the scheme's remaining switches that are on.")
            }
        }
    }

    static func make(for scheme: ScreenScheme, locale: Locale) -> [Section] {
        let configuration = scheme.configuration
        return [
            Section(kind: .wallpaper, rows: wallpaperRows(configuration)),
            Section(kind: .playback, rows: playbackRows(configuration, locale: locale)),
            Section(kind: .automation, rows: automationRows(configuration, locale: locale)),
            Section(kind: .widgets, rows: widgetRows(scheme.overlay)),
            Section(kind: .other, rows: otherRows(configuration)),
        ].filter { !$0.rows.isEmpty }
    }

    /// The rows under the preview.
    static func facts(for scheme: ScreenScheme, now: Date, locale: Locale) -> [WallpaperFact] {
        var facts = [WallpaperFact(kind: .type, value: typeName(scheme.configuration.wallpaperType))]
        if let source = scheme.sourceDisplayName, !source.isEmpty {
            facts.append(WallpaperFact(kind: .capturedFrom, value: source))
        }
        facts.append(WallpaperFact(
            kind: .saved, value: WallpaperFacts.dateText(scheme.createdAt, locale: locale),
            help: WallpaperFacts.relativeText(scheme.createdAt, now: now, locale: locale)
        ))
        // Saving writes the cover a moment later, and that moves `updatedAt` as well.
        if !Calendar.current.isDate(scheme.updatedAt, inSameDayAs: scheme.createdAt) {
            facts.append(WallpaperFact(
                kind: .updated, value: WallpaperFacts.dateText(scheme.updatedAt, locale: locale),
                help: WallpaperFacts.relativeText(scheme.updatedAt, now: now, locale: locale)
            ))
        }
        return facts.sorted { $0.kind < $1.kind }
    }

    // MARK: Sections

    private static func wallpaperRows(_ configuration: ScreenConfiguration) -> [Row] {
        var rows: [Row] = []
        if let name = contentName(configuration) {
            rows.append(Row(key: .name, label: String(localized: "Name", bundle: .appLanguage), value: name))
        }
        if case let .html(.url(url), _) = configuration.activeWallpaper {
            rows.append(Row(key: .webAddress, label: WallpaperFact.Kind.webAddress.label, value: url.absoluteString))
        }
        rows.append(Row(key: .type, label: WallpaperFact.Kind.type.label, value: typeName(configuration.wallpaperType)))
        return rows
    }

    private static func playbackRows(_ configuration: ScreenConfiguration, locale: Locale) -> [Row] {
        switch configuration.activeWallpaper {
        case .video:
            return [
                scalingRow(configuration.fitMode),
                Row(
                    key: .playbackSpeed, label: String(localized: "Playback speed", bundle: .appLanguage),
                    value: PlaybackControls.speedLabel(configuration.playbackSpeed)
                ),
                volumeRow(muted: configuration.muted, level: configuration.videoVolume, locale: locale),
                Row(key: .colorSpace, label: String(localized: "Color Space", bundle: .appLanguage), value: colorSpaceName(configuration.videoColorSpace)),
            ]
        case let .scene(descriptor):
            var rows = [
                scalingRow(configuration.fitMode),
                Row(key: .frameRate, label: String(localized: "Frame rate limit", bundle: .appLanguage), value: configuration.frameRateLimit.title),
            ]
            if !descriptor.propertyOverrides.isEmpty {
                rows.append(Row(
                    key: .sceneSettings, label: String(localized: "Scene Custom Settings", bundle: .appLanguage),
                    value: customizedText(descriptor, locale: locale)
                ))
            }
            rows.append(Row(
                key: .mouseInteraction, label: String(localized: "Mouse Interaction", bundle: .appLanguage),
                value: onOff(configuration.sceneMouseInteractionEnabled)
            ))
            return rows
        case let .html(_, config):
            return [
                Row(key: .javaScript, label: String(localized: "JavaScript", bundle: .appLanguage), value: onOff(config.allowJavaScript)),
                Row(key: .interaction, label: String(localized: "Interaction", bundle: .appLanguage), value: onOff(config.allowMouseInteraction)),
                volumeRow(muted: config.muteAudio, level: config.audioVolume, locale: locale),
            ]
        }
    }

    private static func automationRows(_ configuration: ScreenConfiguration, locale: Locale) -> [Row] {
        if configuration.wallpaperMode == .libraryShuffle {
            let minutes = configuration.libraryShuffleRotationMinutes
            return [
                modeRow(String(localized: "Library Shuffle", bundle: .appLanguage)),
                Row(
                    key: .rotation, label: String(localized: "Rotation interval", bundle: .appLanguage),
                    value: String(localized: "Every \(minutes) min", bundle: .appLanguage, locale: locale)
                ),
            ]
        }
        if configuration.wallpaperMode == .schedule {
            var rows = [
                modeRow(String(localized: "Daily Schedule", bundle: .appLanguage)),
                Row(
                    key: .timeSlots,
                    label: String(localized: "Time Slots", bundle: .appLanguage, comment: "Scheme detail row: how many time slots the daily schedule has."),
                    value: (configuration.scheduleSlots?.count ?? 0).formatted(.number.locale(locale))
                ),
            ]
            if let fallback = configuration.scheduleFallback?.title, !fallback.isEmpty {
                rows.append(Row(key: .fallback, label: String(localized: "Unscheduled Hours", bundle: .appLanguage), value: fallback))
            }
            return rows
        }
        guard configuration.canNavigatePlaylist else {
            return [modeRow(String(localized: "Single Wallpaper", bundle: .appLanguage, comment: "Scheme detail value: the display shows one wallpaper, with no playlist or schedule."))]
        }
        let count = configuration.effectiveWallpaperQueue.count
        var rows = [
            modeRow(String(localized: "Playlist", bundle: .appLanguage)),
            Row(
                key: .playlist, label: String(localized: "Playlist", bundle: .appLanguage),
                value: String(localized: "\(count) wallpapers", bundle: .appLanguage, locale: AppLanguagePreference.current.locale)
            ),
            Row(key: .shuffle, label: String(localized: "Shuffle", bundle: .appLanguage), value: onOff(configuration.shufflePlaylist)),
        ]
        if let minutes = configuration.playlistRotationMinutes, minutes > 0 {
            rows.append(Row(
                key: .rotation, label: String(localized: "Rotation interval", bundle: .appLanguage),
                value: String(localized: "Every \(minutes) min", bundle: .appLanguage, locale: locale)
            ))
        }
        return rows
    }

    private static func widgetRows(_ overlay: MonitorOverlayConfiguration) -> [Row] {
        var rows: [Row] = []
        if overlay.clock.enabled {
            rows.append(Row(key: .clock, label: String(localized: "Clock", bundle: .appLanguage), value: layerName(overlay.clock.level)))
        }
        if overlay.music.enabled {
            rows.append(Row(key: .music, label: String(localized: "Music", bundle: .appLanguage), value: layerName(overlay.music.level)))
        }
        if overlay.enabled {
            rows.append(Row(
                key: .board,
                label: String(localized: "Board", bundle: .appLanguage, comment: "Scheme detail row: the widget board over the wallpaper; its value is the layer it sits on."),
                value: layerName(overlay.level)
            ))
        }
        return rows
    }

    /// Only the switches that are on, and only where the wallpaper's type reads them.
    private static func otherRows(_ configuration: ScreenConfiguration) -> [Row] {
        let on = String(localized: "On", bundle: .appLanguage)
        var rows: [Row] = []
        if configuration.wallpaperType == .video, configuration.setAsLockScreen {
            rows.append(Row(key: .lockScreen, label: String(localized: "On Lock", bundle: .appLanguage), value: on))
        }
        if configuration.wallpaperType == .scene, configuration.sceneClickCaptureEnabled {
            rows.append(Row(key: .clickCapture, label: String(localized: "Interaction", bundle: .appLanguage), value: on))
        }
        return rows
    }

    // MARK: Values

    /// A video's `wpeOrigin` can outlive the scene it was set for, so only a scene takes its name from it.
    private static func contentName(_ configuration: ScreenConfiguration) -> String? {
        switch configuration.activeWallpaper {
        case .scene:
            configuration.wpeOrigin.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
        case let .video(bookmark, _), let .html(.file(bookmark), _):
            bookmarkName(bookmark)
        case let .html(.folder(bookmark, index), _):
            bookmarkName(bookmark).map { "\($0)/\(index)" }
        case .html(.inline, _):
            String(localized: "Inline web content", bundle: .appLanguage)
        case .html(.url, _):
            nil
        }
    }

    /// Read from the bookmark's own bytes: resolving it would reach the disk on every redraw.
    private static func bookmarkName(_ data: Data) -> String? {
        URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: data)?.name
    }

    private static func typeName(_ type: WallpaperType) -> String {
        switch type {
        case .video: String(localized: "Video", bundle: .appLanguage)
        case .html: String(localized: "Web", bundle: .appLanguage)
        case .scene: String(localized: "Scene", bundle: .appLanguage)
        }
    }

    private static func scalingRow(_ mode: VideoFitMode) -> Row {
        let value = switch mode {
        case .aspectFill: String(localized: "Fill", bundle: .appLanguage)
        case .aspectFit: String(localized: "Fit", bundle: .appLanguage)
        case .stretch: String(localized: "Stretch", bundle: .appLanguage)
        case .center: String(localized: "Center", bundle: .appLanguage)
        }
        return Row(key: .scaling, label: String(localized: "Scaling", bundle: .appLanguage), value: value)
    }

    private static func volumeRow(muted: Bool, level: Double, locale: Locale) -> Row {
        Row(
            key: .volume, label: String(localized: "Volume", bundle: .appLanguage),
            value: muted
                ? String(localized: "Muted", bundle: .appLanguage)
                : level.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        )
    }

    private static func colorSpaceName(_ space: VideoColorSpace) -> String {
        switch space {
        case .auto: String(localized: "Auto", bundle: .appLanguage)
        case .sRGB: String(localized: "sRGB", bundle: .appLanguage)
        case .displayP3: String(localized: "Display P3", bundle: .appLanguage)
        case .rec2020HDR: String(localized: "Rec.2020 HDR", bundle: .appLanguage)
        case .forceSDR: String(localized: "Force SDR", bundle: .appLanguage)
        }
    }

    /// Overrides count against the preset when one is applied, else against the scene's defaults.
    private static func customizedText(_ descriptor: SceneDescriptor, locale: Locale) -> String {
        let count = descriptor.propertyOverrides.count
        return descriptor.presetID == nil
            ? String(localized: "\(count) changed from the scene's defaults", bundle: .appLanguage, locale: locale)
            : String(localized: "\(count) changed since this preset", bundle: .appLanguage, locale: locale)
    }

    private static func modeRow(_ value: String) -> Row {
        Row(key: .mode, label: String(localized: "Mode", bundle: .appLanguage), value: value)
    }

    private static func onOff(_ isOn: Bool) -> String {
        isOn ? String(localized: "On", bundle: .appLanguage) : String(localized: "Off", bundle: .appLanguage)
    }

    private static func layerName(_ level: MonitorOverlayLevel) -> String {
        switch level {
        case .desktop: String(localized: "Desktop", bundle: .appLanguage)
        case .front: String(localized: "On Top", bundle: .appLanguage)
        }
    }
}
