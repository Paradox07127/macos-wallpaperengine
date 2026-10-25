import AppKit
import LiveWallpaperCore
import SwiftUI

@MainActor
extension WallpaperQueueEntry {
    static func libraryItem(_ item: LibraryItem) -> WallpaperQueueEntry? {
        guard item.isSupported else { return nil }
        switch item.source {
        case let .bookmark(bookmark):
            return WallpaperQueueEntry(title: item.title, content: bookmark.content, origin: bookmark.wpeOrigin)
        case let .aerial(asset):
            return WallpaperQueueEntry(title: item.title, content: .video(bookmarkData: asset.bookmarkData))
        #if !LITE_BUILD
        case let .workshop(entry):
            guard let content = WPECachedContentResolver().content(for: entry.origin) else { return nil }
            return WallpaperQueueEntry(title: item.title, content: content, origin: entry.origin)
        #endif
        }
    }

    static func videoFiles(
        _ urls: [URL], bookmark: (URL) -> Data? = { ResourceUtilities.createVideoBookmark(for: $0) }
    ) -> (entries: [WallpaperQueueEntry], failed: Int) {
        let entries = urls.compactMap { url in
            bookmark(url).map { WallpaperQueueEntry(title: url.lastPathComponent, content: .video(bookmarkData: $0)) }
        }
        return (entries, urls.count - entries.count)
    }

    var displayTitle: String {
        if !title.isEmpty {
            return title
        }
        if let title = origin?.title, !title.isEmpty {
            return title
        }
        if let data = content.activeVideoBookmarkData,
           let resolved = try? SecurityScopedBookmarkResolver.shared.resolve(data, target: .transient).get() {
            return resolved.url.deletingPathExtension().lastPathComponent
        }
        return String(localized: "Wallpaper", bundle: .appLanguage)
    }

    var symbol: String {
        switch content.wallpaperType {
        case .video: "film"
        case .html: "globe"
        case .scene: "cube.transparent"
        }
    }
}

/// A display's automation is edited as one draft; Save commits only valid, non-overlapping slots.
struct WallpaperAutomationSheet: View {
    let screen: Screen
    let library: SavedLibraryModel
    private let initialConfiguration: ScreenConfiguration?
    let presentation: DetailAutomationPresentation
    @Environment(ScreenManager.self) private var manager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var queue: [WallpaperQueueEntry] = []
    @State private var slots: [ScheduleSlot] = []
    @State private var mode: WallpaperMode = .playlist
    @State private var savedMode: WallpaperMode = .playlist
    @State private var autoAdvance = true
    @State private var rotation = ScreenConfiguration.defaultPlaylistRotationMinutes
    @State private var loops = true
    @State private var libraryRotation = 15
    @State private var shuffle = false
    @State private var excludedIDs: Set<LibraryItem.ID> = []
    @State private var fallback: WallpaperQueueEntry?
    @State private var derivedFallback: WallpaperQueueEntry?
    @State private var shownBeforeTrial: ScreenConfiguration?
    /// What the library picker page is choosing for; nil while the panel shows.
    @State private var picking: PickTarget?
    @State private var openedAt = Date()
    @State private var selectedSlotID: UUID?
    @State private var failures: [String: WallpaperAutomationFailure] = [:]
    @State private var error: String?
    @State private var playingEntryID: WallpaperQueueEntry.ID?
    @State private var insertedCurrentID: WallpaperQueueEntry.ID?
    /// The row "Preview on This Display" put on screen, and the display's automatic-switch serial at that moment.
    @State private var preview: (entryID: WallpaperQueueEntry.ID, switchSerial: Int?)?
    @State private var thumbnails = ShelfThumbnailCache()
    @State private var guide = PageGuideSession()
    /// The draft as `load()` left it; nil until then.
    @State private var loadedDraft: Draft?
    @State private var confirmingDiscard = false
    @State private var selectedQueueID: WallpaperQueueEntry.ID?
    @State private var hoveredQueueID: WallpaperQueueEntry.ID?
    @State private var hoveredSlotID: UUID?
    @State private var fallbackHovered = false
    /// Crate records and deck cards, keyed by `LibraryItem.id`; by entry id for an entry the library has no item for.
    @State private var artwork: [String: CGImage] = [:]
    @State private var deck = DeckSnapshot()
    /// The latest library shuffle serial the deck has already waited out; nil before any.
    @State private var handledShuffleSerial: Int?
    @State private var reshuffles = 0
    @Environment(\.displayScale) private var displayScale

    init(
        screen: Screen, library: SavedLibraryModel, initialConfiguration: ScreenConfiguration? = nil,
        presentation: DetailAutomationPresentation
    ) {
        self.screen = screen
        self.library = library
        self.initialConfiguration = initialConfiguration
        self.presentation = presentation
        _mode = State(initialValue: initialConfiguration?.wallpaperMode ?? .playlist)
        _savedMode = State(initialValue: initialConfiguration?.wallpaperMode ?? .playlist)
        _queue = State(initialValue: initialConfiguration?.effectiveWallpaperQueue ?? [])
        _slots = State(initialValue: initialConfiguration?.scheduleSlots ?? [])
        _failures = State(initialValue: initialConfiguration?.automationFailures ?? [:])
    }

    private enum PickTarget: Equatable {
        case queue, slot(UUID), fallback, exclusions
    }

    /// The edits Save would commit.
    private struct Draft: Equatable {
        let mode: WallpaperMode
        let queue: [WallpaperQueueEntry]
        let slots: [ScheduleSlot]
        let fallback: WallpaperQueueEntry?
        let autoAdvance: Bool
        let rotation: Int
        let loops: Bool
        let libraryRotation: Int
        let shuffle: Bool
        let excludedIDs: Set<String>
    }

    /// Cards without artwork; `deckCard` adds it when drawing, so a late thumbnail changes no card identity.
    private struct DeckSnapshot: Equatable {
        var current: ShuffleDeck.Card?
        var played: [ShuffleDeck.Card] = []
        var remaining = 0
    }

    private struct ArtworkRequest {
        let key: String
        let request: ShelfThumbnailCache.Request
    }

    private var draft: Draft {
        Draft(
            mode: mode, queue: queue, slots: slots, fallback: fallback,
            autoAdvance: autoAdvance, rotation: rotation, loops: loops, libraryRotation: libraryRotation, shuffle: shuffle,
            excludedIDs: excludedIDs
        )
    }

    private var problem: SchedulePolicy.SlotProblem? {
        SchedulePolicy.firstProblem(in: slots)
    }

    private var slotWithoutWallpaper: UUID? {
        slots.first { $0.wallpaper == nil && $0.videoBookmarkData == nil }?.id
    }

    private var canSave: Bool {
        !(mode == .schedule && (problem != nil || slotWithoutWallpaper != nil))
    }

    private var saveTitle: LocalizedStringKey {
        if mode == savedMode {
            return "Save"
        }
        switch mode {
        case .playlist: return "Save and Use Playlist"
        case .schedule: return "Save and Use Daily Schedule"
        case .libraryShuffle: return "Save and Use Library Shuffle"
        }
    }

    static func startTrial(
        _ entry: WallpaperQueueEntry, shownBeforeTrial: inout ScreenConfiguration?, manager: ScreenManager, screen: Screen
    ) {
        if shownBeforeTrial == nil {
            shownBeforeTrial = manager.getConfiguration(for: screen)
        }
        manager.previewWallpaperQueueEntry(entry, for: screen)
    }

    static func cancelTrial(restoring shownBeforeTrial: ScreenConfiguration?, manager: ScreenManager, screen: Screen) {
        guard let shownBeforeTrial else { return }
        // The whole configuration, not just the content: a trial also rewrites the remembered page, scene and scene edits.
        manager.beginExplicitWallpaperSelection(for: screen)
        manager.restoreProposedWallpaperSession(for: screen, configuration: shownBeforeTrial)
    }

    /// A playlist step or schedule switch since the preview began has put another wallpaper on the display.
    static func endTrialIfSwitched(
        _ preview: inout (entryID: WallpaperQueueEntry.ID, switchSerial: Int?)?, shownBeforeTrial: inout ScreenConfiguration?, currentSerial: Int?
    ) {
        guard let started = preview, currentSerial != started.switchSerial else { return }
        preview = nil
        shownBeforeTrial = nil
    }

    static func clockDate(minute: Int) -> Date {
        clockCalendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minute / 60, minute: minute % 60)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// An end set to 00:00 is stored as 1440: the slot ends at midnight.
    static func timeBinding(_ minute: Binding<Int>, isEnd: Bool) -> Binding<Date> {
        Binding(get: { clockDate(minute: minute.wrappedValue % 1440) }, set: { date in
            let value = SchedulePolicy.minuteOfDay(date, calendar: clockCalendar)
            minute.wrappedValue = isEnd && value == 0 ? 1440 : value
        })
    }

    private static var clockCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// In library order. IDs with no item are hidden, not dropped: the library may still be loading.
    static func excludedItems(_ ids: Set<LibraryItem.ID>, in items: [LibraryItem]) -> [LibraryItem] {
        items.filter { ids.contains($0.id) }
    }

    static func presetSlot(_ preset: Preset, in slots: [ScheduleSlot]) -> ScheduleSlot? {
        preset.conflicts(with: slots) ? nil : preset.makeSlot()
    }

    /// nil when the new times are empty or overlap another slot: the timeline then drops the drag.
    static func retimed(_ slots: [ScheduleSlot], id: UUID, start: Int, end: Int) -> [ScheduleSlot]? {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return nil }
        var retimed = slots
        retimed[index].startMinute = start
        retimed[index].endMinute = end
        guard !SchedulePolicy.minuteRanges(for: retimed[index]).isEmpty else { return nil }
        return SchedulePolicy.conflicts(slot: retimed[index], against: retimed).isEmpty ? retimed : nil
    }

    static func insertedSlot(atMinute minute: Int, in slots: [ScheduleSlot]) -> ScheduleSlot? {
        let label = Preset.suggestion(forStartHour: minute / 60).labelKey
        for length in [120, 60, 30] {
            let end = minute + length
            let slot = ScheduleSlot(startMinute: minute, endMinute: end > 1440 ? end - 1440 : end, label: label)
            if SchedulePolicy.conflicts(slot: slot, against: slots).isEmpty {
                return slot
            }
        }
        return nil
    }

    /// The library card's title for the same wallpaper; the entry's own title only when the library has no match.
    static func rowTitle(for entry: WallpaperQueueEntry, in library: SavedLibraryModel) -> String {
        matchingItem(entry, in: library)?.title.translatedWallpaperName ?? entry.displayTitle
    }

    /// A Workshop video's folder is its numeric ID, so only local videos name theirs.
    static func rowSubtitle(_ metadata: RowMetadata, for entry: WallpaperQueueEntry) -> String {
        guard entry.origin != nil else { return metadata.subtitle }
        return RowMetadata(resolution: metadata.resolution, duration: metadata.duration, folder: nil).subtitle
    }

    /// By the cursor, not by content: editing a playing scene's properties changes its content but not its row.
    static func nowPlayingEntryID(
        in configuration: ScreenConfiguration?, insertedCurrent: WallpaperQueueEntry.ID?, previewing: WallpaperQueueEntry.ID?
    ) -> WallpaperQueueEntry.ID? {
        if let previewing {
            return previewing
        }
        if let insertedCurrent {
            return insertedCurrent
        }
        guard let configuration, configuration.wallpaperMode == .playlist else { return nil }
        let queue = configuration.effectiveWallpaperQueue
        let cursor = configuration.playlistCursorIndex ?? 0
        return queue.indices.contains(cursor) ? queue[cursor].id : nil
    }

    /// A shuffle draw commits before its history lands; refreshing on that commit would split the draw in two,
    /// and ShuffleDeck animates a draw only when current and played change in one update.
    static func revisionRefresh(after mark: AutomaticSwitchMark?, handledSerial: Int?) -> (refreshes: Bool, handledSerial: Int?) {
        guard let mark, mark.source == .libraryShuffle, mark.serial != handledSerial else { return (true, handledSerial) }
        return (false, mark.serial)
    }

    static func deckRemaining(libraryIDs: [LibraryItem.ID], excludedIDs: Set<LibraryItem.ID>, currentID: String?, playedIDs: [String]) -> Int {
        let played = Set(playedIDs)
        return max(0, libraryIDs.filter { !excludedIDs.contains($0) && $0 != currentID && !played.contains($0) }.count)
    }

    static func slotListOrder(_ slots: [ScheduleSlot]) -> [ScheduleSlot] {
        slots.sorted { $0.startMinute < $1.startMinute }
    }

    /// Same wrap rule as `ScheduleSlot.containsMinute`; an end of 1440 ends at midnight and does not cross it.
    static func crossesMidnight(_ slot: ScheduleSlot) -> Bool {
        slot.endMinute < slot.startMinute
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .opacity(presentation.entered ? 1 : 0)
                // Above the page, whose content can reach up into the title bar strip and take the bar's clicks.
                .zIndex(1)
            GeometryReader { proxy in
                ZStack {
                    if let picking {
                        libraryPicker(for: picking, width: proxy.size.width)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        panel
                    }
                }
                .animation(DesignTokens.motion(reduceMotion, DesignTokens.Motion.disclosure), value: picking)
                .offset(x: presentation.entered || reduceMotion ? 0 : proxy.size.width)
                .opacity(presentation.entered ? 1 : 0)
            }
            .clipped()
        }
        .allowsHitTesting(presentation.entered)
        .environment(guide)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayPreferenceValue(PageGuideAnchorKey.self) { PageGuideHost(session: guide, anchors: $0) }
        // On the container, not `panel`: the panel reappears after each pick, and reloading then would drop the draft.
        .onAppear(perform: load)
        .onChange(of: screen.configurationRevision) {
            let mark = manager.automaticSwitchMark(for: screen.displayFingerprint)
            Self.endTrialIfSwitched(&preview, shownBeforeTrial: &shownBeforeTrial, currentSerial: mark?.serial)
            failures = manager.getConfiguration(for: screen)?.automationFailures ?? [:]
            playingEntryID = Self.nowPlayingEntryID(
                in: manager.getConfiguration(for: screen), insertedCurrent: insertedCurrentID, previewing: preview?.entryID
            )
            let decision = Self.revisionRefresh(after: mark, handledSerial: handledShuffleSerial)
            handledShuffleSerial = decision.handledSerial
            if decision.refreshes {
                refreshDeck()
            }
        }
        .onChange(of: manager.libraryShuffleDeck(for: screen)) { refreshDeck() }
        .task(id: missingArtwork.map(\.key)) {
            var loaded: [String: CGImage] = [:]
            // The crate's centred record is the largest picture either the crate or the deck draws.
            let pixelSize = CGSize(width: PlaylistCrate.cardSize.width * displayScale, height: PlaylistCrate.cardSize.height * displayScale)
            for wanted in missingArtwork {
                if let image = await thumbnails.image(wanted.request, pixelSize: pixelSize, scale: displayScale) {
                    loaded[wanted.key] = image
                }
            }
            artwork.merge(loaded) { _, new in new }
        }
        .onChange(of: mode) { _, mode in
            guard mode == .schedule, slots.isEmpty else { return }
            let fallback = currentEntry
            slots = ScheduleSlot.defaultSlots.map {
                var slot = $0
                slot.wallpaper = fallback
                return slot
            }
        }
        .alert("Discard changes to wallpaper automation?", isPresented: $confirmingDiscard) {
            if canSave {
                Button("Save", action: saveAndClose).keyboardShortcut(.defaultAction)
            }
            Button("Discard Changes", role: .destructive, action: discardAndClose)
            Button("Keep Editing", role: .cancel) {}
                .keyboardShortcut(canSave ? nil : .defaultAction)
        }
    }

    private var panel: some View {
        Group {
            switch mode {
            case .playlist: queuePage
            case .schedule: schedulePage
            case .libraryShuffle: libraryShufflePage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(DesignTokens.motion(reduceMotion, DesignTokens.Motion.disclosure), value: mode)
    }

    private func pageLayout(@ViewBuilder art: () -> some View, @ViewBuilder column: () -> some View) -> some View {
        HStack(spacing: 0) {
            art()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            column()
                .frame(width: DesignTokens.Inspector.compactWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentColumnBackground()
        }
    }

    private func artArea(
        title: LocalizedStringKey, caption: Text, hint: LocalizedStringKey, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                    .font(DesignTokens.Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                caption
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(hint)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(DesignTokens.Spacing.xl)
    }

    private func columnScroll(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                content()
            }
            .padding(DesignTokens.Spacing.lg)
        }
    }

    private func rowHighlight(selected: Bool, hovered: Bool, tint: Color = DesignTokens.Colors.accent) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
            .fill(tint.opacity(selected ? DesignTokens.Opacity.selectedFill : DesignTokens.Opacity.hoverFill))
            .opacity(selected || hovered ? 1 : 0)
    }

    private func sectionHeader(
        _ title: LocalizedStringKey,
        count: Int? = nil,
        actionTitle: LocalizedStringKey? = nil,
        actionIcon: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(title)
            if let count {
                StatusChip(text: Text(count, format: .number), tint: .secondary)
            }
            if let actionTitle, let action {
                Spacer(minLength: DesignTokens.Spacing.sm)
                Button(action: action) {
                    if let actionIcon {
                        Label(actionTitle, systemImage: actionIcon)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// The modes sit centred between two equal halves; the library picker brings its own footer, so it hides them and Save.
    private var topBar: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.md) {
                // Clears the window's traffic lights, as the detail's own bar does.
                Color.clear.frame(width: 68)
                GlassToolbarGroup {
                    GlassToolbarItem("chevron.left", action: requestClose)
                        .help(backLabel)
                        .accessibilityLabel(backLabel)
                }
                breadcrumb
                Spacer(minLength: DesignTokens.Spacing.sm).background(WindowDragRegion())
            }
            .frame(maxWidth: .infinity)
            if picking == nil {
                modePicker
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                Spacer(minLength: DesignTokens.Spacing.sm).background(WindowDragRegion())
                if picking == nil {
                    PageGuideButton(context: .automation)
                    if let error {
                        Text(verbatim: error)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.Status.danger)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Button("Cancel", action: requestClose)
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.cancelAction)
                        Button(action: saveAndClose) { Text(saveTitle) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSave)
                    }
                    .fixedSize()
                    .pageGuideTarget(.automationFooter)
                    // The guide panel's Return / Escape shortcuts would otherwise compete with Save / Cancel.
                    .disabled(guide.context != nil)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .frame(height: DetailGeometry.topBarHeight)
        .accessibilityElement(children: .contain)
    }

    private var backLabel: Text {
        picking == nil ? Text("Back to \(screen.name)") : Text("Back to Wallpaper Automation")
    }

    private var breadcrumb: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(action: requestClose) {
                Text(verbatim: screen.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(backLabel)
            breadcrumbChevron
            if let picking {
                Button {
                    self.picking = nil
                } label: {
                    Text("Wallpaper Automation").lineLimit(1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                breadcrumbChevron
                Text(pickPurpose(for: picking).title)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text("Wallpaper Automation")
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .font(DesignTokens.Typography.body)
    }

    private var breadcrumbChevron: some View {
        Image(systemName: "chevron.right")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var modePicker: some View {
        GlassSegmentedPicker(selection: $mode, values: WallpaperMode.allCases, shell: .editDesk) { mode, _ in
            Text(Self.modeTitle(mode))
                .font(DesignTokens.EditDesk.Typography.navItem)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Playback Mode"))
        .fixedSize()
        .pageGuideTarget(.automationModes)
        .detailSegmentsMorph(in: presentation.segments, isSource: presentation.entered)
    }

    private static func modeTitle(_ mode: WallpaperMode) -> LocalizedStringKey {
        switch mode {
        case .playlist: "Playlist"
        case .schedule: "Daily Schedule"
        case .libraryShuffle: "Library Shuffle"
        }
    }

    private func saveAndClose() {
        save()
        presentation.close()
    }

    private func requestClose() {
        if picking != nil {
            picking = nil
        } else if guide.context != nil {
            // Back and the breadcrumb stay live while the guide is open; they belong to the guide then.
            guide.close()
        } else if draft == loadedDraft {
            discardAndClose()
        } else {
            confirmingDiscard = true
        }
    }

    /// Takes any "Preview on This Display" trial back off the desktop before closing.
    private func discardAndClose() {
        preview = nil
        Self.cancelTrial(restoring: shownBeforeTrial, manager: manager, screen: screen)
        presentation.close()
    }

    private var libraryShufflePage: some View {
        pageLayout {
            artArea(
                title: "Library Shuffle", caption: Text("\(library.items.count) wallpapers"),
                hint: "Click the deck to draw the next wallpaper."
            ) {
                ShrinkToFit {
                    VStack(spacing: DesignTokens.Spacing.md) {
                        shuffleDeck
                            .disabled(savedMode != .libraryShuffle)
                        Group {
                            if savedMode == .libraryShuffle {
                                Text("\(deck.remaining) left · \(deck.played.count) played")
                                    .monospacedDigit()
                            } else {
                                Text("Save to start library shuffle.")
                            }
                        }
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        } column: {
            columnScroll {
                GroupBox {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        SettingRow(icon: "arrow.triangle.2.circlepath", iconColor: DesignTokens.Colors.accent, title: "Rotate") {
                            Picker("Rotate", selection: $libraryRotation) {
                                ForEach(Array(Set([1, 5, 15, 30, 60, 120, libraryRotation])).sorted(), id: \.self) { value in
                                    Text("Every \(value) min").tag(value)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Text("Automatically picks a random wallpaper from your entire library. New imports join automatically; unavailable wallpapers are skipped. The same wallpaper never plays twice in a row.")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Playback")
                }
                .groupBoxStyle(ContainerGroupBoxStyle())
                excludedWallpapers
                skippedSources
            }
        }
    }

    private var shuffleDeck: some View {
        ShuffleDeck(
            current: deck.current.map(deckCard),
            played: deck.played.map(deckCard),
            remaining: deck.remaining,
            reshuffles: reshuffles,
            onDraw: { manager.advanceLibraryShuffle(for: screen) },
            onRewind: deck.played.isEmpty ? nil : { manager.regressLibraryShuffle(for: screen) },
            onReshuffle: {
                manager.reshuffleLibrary(for: screen)
                refreshDeck()
                reshuffles += 1
            }
        )
    }

    private func deckCard(_ card: ShuffleDeck.Card) -> ShuffleDeck.Card {
        ShuffleDeck.Card(id: card.id, title: card.title, image: artwork[card.id])
    }

    private func refreshDeck() {
        guard let config = manager.getConfiguration(for: screen) else {
            deck = DeckSnapshot()
            return
        }
        let showing = Self.currentEntry(for: config, in: library, displayName: manager.wallpaperDisplayName(for: screen))
        let current = ShuffleDeck.Card(
            id: Self.matchingItem(showing, in: library)?.id ?? Self.contentID(config.activeWallpaper),
            title: Self.rowTitle(for: showing, in: library), image: nil
        )
        let played = manager.libraryShuffleDeck(for: screen).played.map { entry in
            ShuffleDeck.Card(id: entry.id, title: entry.title.isEmpty ? Self.rowTitle(for: entry, in: library) : entry.title, image: nil)
        }
        deck = DeckSnapshot(
            current: current, played: played,
            remaining: Self.deckRemaining(
                libraryIDs: library.items.map(\.id), excludedIDs: Set(config.libraryShuffleExcludedIDs),
                currentID: current.id, playedIDs: played.map(\.id)
            )
        )
    }

    /// Stable for the same content within a run, so a refresh of an unchanged display reads as no change.
    private static func contentID(_ content: WallpaperContent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return "content:\((try? encoder.encode(content))?.hashValue ?? 0)"
    }

    private var excludedWallpapers: some View {
        let items = Self.excludedItems(excludedIDs, in: library.items)
        let rows = VStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(items, content: excludedRow)
        }
        return GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Library shuffle never picks these wallpapers.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if items.count > 6 {
                    ScrollView { rows }.frame(maxHeight: 280)
                } else if !items.isEmpty {
                    rows
                }
                Button {
                    picking = .exclusions
                } label: {
                    Label("Choose from Library", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            sectionHeader("Excluded wallpapers", count: items.count)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private func excludedRow(for item: LibraryItem) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // No queue entry here: building one per redraw gives it a new ID and resolves Workshop bookmarks again.
            ScheduleSlotThumbnail(entry: nil, thumbnails: thumbnails) { item.thumbnail }
                .frame(width: 48, height: 27)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
                .accessibilityHidden(true)
            Text(verbatim: item.title.translatedWallpaperName)
                .font(DesignTokens.Typography.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DesignTokens.Spacing.xs)
            Button("Include Again") { excludedIDs.remove(item.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(DesignTokens.Spacing.xs)
        .background(DesignTokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
    }

    @ViewBuilder
    private var skippedSources: some View {
        if !failures.isEmpty {
            let rows = VStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(failures.values.sorted { $0.failedAt > $1.failedAt }, id: \.entry.id, content: skippedRow)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    if failures.count > 6 {
                        ScrollView { rows }.frame(maxHeight: 280)
                    } else {
                        rows
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text("Skipped wallpapers")
                    StatusChip(
                        text: Text(failures.count, format: .number),
                        tint: DesignTokens.Colors.Status.warning, systemImage: "exclamationmark.triangle.fill"
                    )
                }
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    private func skippedRow(for failure: WallpaperAutomationFailure) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: Self.skipSymbol(failure.reason))
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .frame(width: DesignTokens.iconButtonDiameter(.regular))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.rowTitle(for: failure.entry, in: library))
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                if let reason = failure.reason {
                    Text(Self.skipReason(reason)).font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DesignTokens.Spacing.xs)
            Button("Enable Again") { manager.clearAutomationFailure(failure.entry.id, for: screen) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(DesignTokens.Spacing.xs)
        .background(DesignTokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
    }

    private static func skipSymbol(_ reason: WallpaperAutomationFailure.Reason?) -> String {
        switch reason {
        case .sourceMissing: "questionmark.folder"
        case .timedOut: "clock.badge.exclamationmark"
        case .loadFailed, nil: "exclamationmark.triangle"
        }
    }

    private static func skipReason(_ reason: WallpaperAutomationFailure.Reason) -> LocalizedStringKey {
        switch reason {
        case .sourceMissing: "File is missing or can't be opened"
        case .loadFailed: "Couldn't load"
        case .timedOut: "Took too long to load"
        }
    }

    @ViewBuilder
    private func failureBadge(_ entry: WallpaperQueueEntry) -> some View {
        if failures[entry.id]?.entry.content == entry.content {
            Button { manager.clearAutomationFailure(entry.id, for: screen) } label: {
                Label("Skipped", systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.Status.warning)
            }
            .buttonStyle(.borderless)
            .help(Text("Failed twice. Click to enable this wallpaper again."))
        }
    }

    private var queuePage: some View {
        pageLayout {
            artArea(
                title: "Playlist", caption: Text("\(queue.count) wallpapers"),
                hint: "Click a record to select it, or drag it to reorder the queue."
            ) {
                if queue.isEmpty {
                    IllustratedEmptyState(
                        symbol: "list.bullet",
                        title: "Your playlist is empty",
                        message: "Add wallpapers from your library to play them in sequence.",
                        primary: EmptyStateButtonAction("Add Wallpaper") { picking = .queue }
                    )
                } else {
                    PlaylistCrate(
                        records: queue.map { entry in
                            PlaylistCrate.Record(
                                id: entry.id, title: Self.rowTitle(for: entry, in: library), image: artwork[artworkKey(for: entry)]
                            )
                        },
                        currentID: playingEntryID,
                        selectedID: $selectedQueueID,
                        onMove: { queue.move(fromOffsets: $0, toOffset: $1) }
                    )
                }
            }
        } column: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                if !queue.isEmpty {
                    queueList
                        .frame(maxHeight: .infinity)
                }
                playlistSettings
            }
            .padding(DesignTokens.Spacing.lg)
        }
    }

    private var playlistSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                let stopsAtEnd = !shuffle && autoAdvance && !loops
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: shuffle ? "shuffle" : stopsAtEnd ? "arrow.right" : "repeat")
                        .font(DesignTokens.Typography.caption)
                    Text(shuffle ? "Shuffle" : stopsAtEnd ? "Plays in order, then stops" : "Plays in order, then repeats")
                        .font(DesignTokens.Typography.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, DesignTokens.Spacing.xxs)

                SettingRow(icon: "arrow.triangle.2.circlepath", iconColor: DesignTokens.Colors.accent, title: "Rotate") {
                    Picker("Rotate", selection: $rotation) {
                        ForEach([1, 5, 15, 30, 60, 120], id: \.self) { value in
                            Text("Every \(value) min").tag(value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!autoAdvance)

                SettingRow(icon: "forward.fill", iconColor: DesignTokens.Colors.accent, title: "Auto-Advance") {
                    Toggle("Auto-Advance", isOn: $autoAdvance)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingRow(icon: "repeat", iconColor: DesignTokens.Colors.accent, title: "Loop") {
                    Toggle("Loop", isOn: $loops)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .disabled(!autoAdvance || shuffle)

                SettingRow(icon: "shuffle", iconColor: DesignTokens.Colors.accent, title: "Shuffle") {
                    Toggle("Shuffle", isOn: $shuffle)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Playback")
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    /// A `List`, not rows in the column's scroll view: `onMove` reorders only inside a `List`.
    private var queueList: some View {
        GroupBox {
            List {
                ForEach(Array(queue.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text(String(format: "%02d", index + 1))
                            .font(DesignTokens.Typography.metric)
                            .foregroundStyle(entry.id == selectedQueueID ? DesignTokens.Colors.accent : .secondary)
                        QueueEntryLabel(
                            entry: entry, title: Self.rowTitle(for: entry, in: library), isPlaying: entry.id == playingEntryID,
                            thumbnails: thumbnails, thumbnailSize: Self.queueThumbnailSize
                        ) {
                            thumbnailRequest(for: entry)
                        }
                        failureBadge(entry)
                        Spacer(minLength: 0)
                        icon("play.fill", "Preview on This Display") {
                            preview = (entry.id, manager.automaticSwitchMark(for: screen.displayFingerprint)?.serial)
                            Self.startTrial(entry, shownBeforeTrial: &shownBeforeTrial, manager: manager, screen: screen)
                        }
                        icon("trash", "Remove", tint: DesignTokens.Colors.Status.danger) { queue.remove(at: index) }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xs)
                    .padding(.vertical, DesignTokens.Spacing.xxs)
                    .background(rowHighlight(selected: entry.id == selectedQueueID, hovered: entry.id == hoveredQueueID))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedQueueID = entry.id }
                    .settledHover { inside in
                        hoveredQueueID = inside ? entry.id : (hoveredQueueID == entry.id ? nil : hoveredQueueID)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(entry.id == selectedQueueID ? .isSelected : [])
                    .contextMenu {
                        Button("Move Up", systemImage: "arrow.up") {
                            move(index, by: -1)
                        }
                        .disabled(index == 0)
                        Button("Move Down", systemImage: "arrow.down") {
                            move(index, by: 1)
                        }
                        .disabled(index == queue.count - 1)
                    }
                    .accessibilityAction(named: Text("Move Up")) {
                        if index > 0 {
                            move(index, by: -1)
                        }
                    }
                    .accessibilityAction(named: Text("Move Down")) {
                        if index < queue.count - 1 {
                            move(index, by: 1)
                        }
                    }
                }
                .onMove { from, to in queue.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } label: {
            sectionHeader("Queue", count: queue.count, actionTitle: "Add Wallpaper", actionIcon: "plus") {
                picking = .queue
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    /// 16:9, narrow enough that a row's title keeps room beside its buttons in the inspector-wide column.
    private static let queueThumbnailSize = CGSize(width: 48, height: 27)

    private func artworkKey(for entry: WallpaperQueueEntry) -> String {
        Self.matchingItem(entry, in: library)?.id ?? entry.id
    }

    private var missingArtwork: [ArtworkRequest] {
        let wanted: [ArtworkRequest] = switch mode {
        case .playlist:
            queue.map { ArtworkRequest(key: artworkKey(for: $0), request: thumbnailRequest(for: $0)) }
        case .libraryShuffle:
            deckArtwork
        case .schedule:
            []
        }
        return wanted.filter { artwork[$0.key] == nil }
    }

    private var deckArtwork: [ArtworkRequest] {
        var wanted = manager.libraryShuffleDeck(for: screen).played.compactMap { entry in
            Self.matchingItem(entry, in: library)?.thumbnail.map { ArtworkRequest(key: entry.id, request: $0) }
        }
        if let id = deck.current?.id, let request = library.items.first(where: { $0.id == id })?.thumbnail {
            wanted.append(ArtworkRequest(key: id, request: request))
        }
        return wanted
    }

    private var schedulePage: some View {
        pageLayout {
            artArea(
                title: "24-hour schedule", caption: Text("\(slots.count) time slots"),
                hint: "Click a slot to select it, then drag its ends to change its hours. Double-click an empty hour on the ring to add a slot."
            ) {
                timeline
            }
        } column: {
            columnScroll {
                slotList
                slotEditor
                validationSection
            }
        }
    }

    private var slotList: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                ForEach(Self.slotListOrder(slots), content: slotRow)
                if SchedulePolicy.findFreeRange(in: slots, minMinutes: 60) != nil, let entry = fallback ?? derivedFallback {
                    fallbackRow(entry: entry)
                }
                addSlotButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Time Slots")
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var addSlotButton: some View {
        Menu {
            presetMenu
        } label: {
            Label("Add schedule slot", systemImage: "plus")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(SchedulePolicy.findFreeRange(in: slots, minMinutes: 60) == nil)
    }

    private func slotColor(_ slot: ScheduleSlot) -> Color {
        let palette = Self.slotPalette
        return palette.isEmpty ? DesignTokens.Colors.accent : palette[(ScheduleDialStyle.number(slot, in: slots) - 1) % palette.count]
    }

    private func slotRow(_ slot: ScheduleSlot) -> some View {
        let color = slotColor(slot)
        let selected = slot.id == selectedSlotID
        return Button {
            selectedSlotID = slot.id
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 24)
                    .accessibilityHidden(true)

                Text(verbatim: slot.rangeText())
                    .font(DesignTokens.Typography.metric)
                    .frame(width: 72, alignment: .leading)

                ScheduleSlotThumbnail(entry: slot.wallpaper, thumbnails: thumbnails) {
                    slot.wallpaper.map(thumbnailRequest)
                }
                .frame(width: Self.queueThumbnailSize.width, height: Self.queueThumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
                .accessibilityHidden(true)

                Text(verbatim: slot.wallpaper.map { Self.rowTitle(for: $0, in: library) } ?? slot.localizedLabel)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DesignTokens.Spacing.xs)

                if Self.crossesMidnight(slot) {
                    StatusChip("Overnight", tint: .secondary)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(rowHighlight(selected: selected, hovered: slot.id == hoveredSlotID, tint: color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settledHover { inside in
            hoveredSlotID = inside ? slot.id : (hoveredSlotID == slot.id ? nil : hoveredSlotID)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func fallbackRow(entry: WallpaperQueueEntry) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            fallbackButton(entry: entry)
            failureBadge(entry)
        }
    }

    private func fallbackButton(entry: WallpaperQueueEntry) -> some View {
        Button {
            picking = .fallback
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Capsule()
                    .fill(.secondary.opacity(DesignTokens.Opacity.quietStroke))
                    .frame(width: 3, height: 24)
                    .accessibilityHidden(true)

                Text("Unscheduled Hours")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)

                ScheduleSlotThumbnail(entry: entry, thumbnails: thumbnails) {
                    thumbnailRequest(for: entry)
                }
                .frame(width: Self.queueThumbnailSize.width, height: Self.queueThumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
                .accessibilityHidden(true)

                Text(verbatim: Self.rowTitle(for: entry, in: library))
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DesignTokens.Spacing.xs)
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(rowHighlight(selected: false, hovered: fallbackHovered, tint: .secondary))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(DesignTokens.Opacity.quietStroke), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settledHover { fallbackHovered = $0 }
        .help(Text("Choose Fallback Wallpaper"))
    }

    private func dialNowPlayingTitle(now: Date) -> String? {
        let minute = SchedulePolicy.minuteOfDay(now, calendar: .current)
        if let slot = slots.first(where: { $0.containsMinute(minute) }) {
            return slot.wallpaper.map { Self.rowTitle(for: $0, in: library) }
        }
        return (fallback ?? derivedFallback).map { Self.rowTitle(for: $0, in: library) }
    }

    private var dialFallbackTitle: String? {
        guard SchedulePolicy.findFreeRange(in: slots, minMinutes: 60) != nil else { return nil }
        return (fallback ?? derivedFallback).map { Self.rowTitle(for: $0, in: library) }
    }

    @ViewBuilder
    private var slotEditor: some View {
        if let index = slots.firstIndex(where: { $0.id == selectedSlotID }) {
            let slot = slots[index]
            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text("Start")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                        DatePicker("Start", selection: Self.timeBinding($slots[index].startMinute, isEnd: false), displayedComponents: .hourAndMinute)
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                            .help(Text("Start"))

                        Image(systemName: "arrow.right")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)

                        Text("End")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                        DatePicker("End", selection: Self.timeBinding($slots[index].endMinute, isEnd: true), displayedComponents: .hourAndMinute)
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                            .help(Text("End"))
                    }

                    HStack(spacing: DesignTokens.Spacing.md) {
                        ScheduleSlotThumbnail(entry: slot.wallpaper, thumbnails: thumbnails) {
                            slot.wallpaper.map(thumbnailRequest)
                        }
                        .frame(width: 80, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
                        .accessibilityHidden(true)

                        if let entry = slot.wallpaper {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                Text(verbatim: Self.rowTitle(for: entry, in: library))
                                    .font(DesignTokens.Typography.bodyEmphasized)
                                    .lineLimit(2)
                                failureBadge(entry)
                            }
                        }
                        Spacer(minLength: DesignTokens.Spacing.xs)

                        Button("Choose Wallpaper") {
                            picking = .slot(slot.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(DesignTokens.Spacing.xs)
                    .background(DesignTokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            slots.removeAll { $0.id == slot.id }
                            selectedSlotID = slots.first?.id
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Circle()
                        .fill(slotColor(slot))
                        .frame(width: 8, height: 8)
                    Text("Slot Details")
                    Spacer()
                    Text(slotDurationText(slot))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                }
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        } else {
            GroupBox {
                Text("Choose a wallpaper around the clock to edit its hours.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DesignTokens.Spacing.xs)
            } label: {
                Text("Select a time slot")
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    private func slotDurationText(_ slot: ScheduleSlot) -> String {
        let end = slot.endMinute > slot.startMinute ? slot.endMinute : slot.endMinute + 1440
        return Duration.seconds((end - slot.startMinute) * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow).locale(AppLanguagePreference.current.locale))
    }

    @ViewBuilder
    private var validationSection: some View {
        if let problem {
            switch problem {
            case let .noLength(id):
                InlineNoticeBanner(
                    tint: DesignTokens.Colors.Status.warning,
                    symbol: "exclamationmark.triangle",
                    title: Text("Time slot \(rangeText(for: id)) starts and ends at the same hour. Choose a different end time."),
                    surface: .content
                )
            case let .overlap(first, second):
                InlineNoticeBanner(
                    tint: DesignTokens.Colors.Status.warning,
                    symbol: "exclamationmark.triangle",
                    title: Text("Time slots \(rangeText(for: first)) and \(rangeText(for: second)) overlap."),
                    surface: .content
                )
            }
        } else if let id = slotWithoutWallpaper {
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.warning,
                symbol: "exclamationmark.triangle",
                title: Text("Time slot \(rangeText(for: id)) has no wallpaper yet. Choose one to save the schedule."),
                surface: .content
            )
        }
    }

    private var timeline: some View {
        TimelineView(.everyMinute) { context in
            dial(now: context.date)
        }
    }

    private func dial(now: Date) -> some View {
        ScheduleDial(
            slots: slots, now: now, palette: Self.slotPalette, selectedID: $selectedSlotID,
            onRetimed: { id, start, end in
                if let retimed = Self.retimed(slots, id: id, start: start, end: end) {
                    slots = retimed
                    error = nil
                } else {
                    error = String(localized: "Time slots overlap. Choose different hours.", bundle: .appLanguage)
                }
            },
            onInsert: { minute in
                if let slot = Self.insertedSlot(atMinute: minute, in: slots) {
                    slots.append(slot)
                    selectedSlotID = slot.id
                    error = nil
                }
            },
            thumbnail: { slot in
                AnyView(ScheduleSlotThumbnail(entry: slot.wallpaper, thumbnails: thumbnails) { slot.wallpaper.map(thumbnailRequest) })
            },
            nowPlayingTitle: dialNowPlayingTitle(now: now),
            fallbackTitle: dialFallbackTitle
        )
    }

    @ViewBuilder
    private var presetMenu: some View {
        ForEach(Preset.allCases) { preset in
            let slot = Self.presetSlot(preset, in: slots)
            Button {
                if let slot {
                    slots.append(slot)
                    selectedSlotID = slot.id
                }
            } label: {
                let hours = String(format: "%02d:00–%02d:00", preset.hours.start, preset.hours.end)
                Label("\(preset.localized) · \(hours)", systemImage: preset.systemImage)
            }
            .disabled(slot == nil)
        }
        Button {
            addSlot()
        } label: {
            Label("Custom", systemImage: "slider.horizontal.below.rectangle")
        }
    }

    private static let slotPalette = ScheduleDialStyle.palette

    private func libraryPicker(for target: PickTarget, width: CGFloat) -> some View {
        AutomationLibraryPicker(
            library: library, thumbnails: thumbnails, purpose: pickPurpose(for: target), width: width,
            commit: { commitPick($0, to: target) },
            chooseVideos: { picked in
                commitPick(picked, to: target)
                chooseVideoFiles(for: target)
            },
            cancel: { picking = nil }
        )
    }

    private func pickPurpose(for target: PickTarget) -> AutomationLibraryPicker.Purpose {
        func itemID(_ entry: WallpaperQueueEntry?) -> LibraryItem.ID? {
            entry.flatMap { Self.matchingItem($0, in: library)?.id }
        }
        switch target {
        case .queue:
            return .playlist(inPlaylist: Set(queue.compactMap(itemID)))
        case let .slot(id):
            return .single(
                title: "Choose Wallpaper for \(rangeText(for: id))", current: itemID(slots.first { $0.id == id }?.wallpaper)
            )
        case .fallback:
            return .single(title: "Choose Fallback Wallpaper", current: itemID(fallback ?? derivedFallback))
        case .exclusions:
            return .exclude(excluded: excludedIDs)
        }
    }

    private func commitPick(_ ids: [LibraryItem.ID], to target: PickTarget) {
        if target == .exclusions {
            excludedIDs = Set(ids)
            picking = nil
            return
        }
        let picked = AutomationPickOrder.entries(for: ids, in: library.items)
        switch target {
        case .queue:
            queue.append(contentsOf: picked.entries)
        case let .slot(id):
            if let entry = picked.entries.first {
                assign(entry, toSlot: id)
            }
        case .fallback:
            if let entry = picked.entries.first {
                fallback = entry
            }
        case .exclusions:
            break
        }
        error = picked.unavailable > 0
            ? String(localized: "This wallpaper is unavailable. Reimport it from the library.", bundle: .appLanguage)
            : nil
        picking = nil
    }

    private func icon(
        _ symbol: String, _ label: LocalizedStringKey, tint: Color? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let tint {
                    Image(systemName: symbol).foregroundStyle(tint)
                } else {
                    Image(systemName: symbol)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private func move(_ index: Int, by offset: Int) {
        guard queue.indices.contains(index + offset) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { queue.swapAt(index, index + offset) }
    }

    private func addSlot() {
        guard let range = SchedulePolicy.findFreeRange(in: slots, minMinutes: 60) else { return }
        let end = min(range.start + 360, range.end)
        let slot = ScheduleSlot(startMinute: range.start, endMinute: end > 1440 ? end - 1440 : end, label: "")
        slots.append(slot)
        selectedSlotID = slot.id
    }

    private func assign(_ entry: WallpaperQueueEntry, toSlot id: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[index].wallpaper = entry
        slots[index].videoBookmarkData = nil
        slots[index].label = entry.title
    }

    private func rangeText(for id: UUID) -> String {
        slots.first { $0.id == id }.map { $0.rangeText() } ?? ""
    }

    private func chooseVideoFiles(for target: PickTarget) {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = target == .queue
            panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
            panel.prompt = target == .queue ? L10n.Panel.addVideos : L10n.Panel.setVideo
            if panel.runModal() == .OK {
                let chosen = WallpaperQueueEntry.videoFiles(panel.urls)
                // Only set, never cleared here: an unavailable library pick reported just before must stay visible.
                if chosen.failed > 0 {
                    error = String(
                        localized: "Couldn't add \(chosen.failed) of the selected videos.", bundle: .appLanguage,
                        comment: "Playlist and schedule panel: some chosen video files could not be bookmarked. Placeholder is how many."
                    )
                }
                switch target {
                case .queue:
                    queue.append(contentsOf: chosen.entries)
                case let .slot(id):
                    if let entry = chosen.entries.first {
                        assign(entry, toSlot: id)
                    }
                case .fallback:
                    if let entry = chosen.entries.first {
                        fallback = entry
                    }
                case .exclusions:
                    break
                }
            }
        }
    }

    private var currentEntry: WallpaperQueueEntry? {
        guard let config = manager.getConfiguration(for: screen) else { return nil }
        return Self.currentEntry(for: config, in: library, displayName: manager.wallpaperDisplayName(for: screen))
    }

    static func currentEntry(
        for config: ScreenConfiguration, in library: SavedLibraryModel, displayName: String?
    ) -> WallpaperQueueEntry {
        var entry = WallpaperQueueEntry(title: "", content: config.activeWallpaper, origin: config.wpeOrigin)
        entry.title = matchingItem(entry, in: library)?.title ?? config.wpeOrigin?.title ?? displayName ?? ""
        return entry
    }

    private static func matchingItem(_ entry: WallpaperQueueEntry, in library: SavedLibraryModel) -> LibraryItem? {
        // Saved scene variants share a Workshop ID, so an exact content match must win over the ID fallback.
        let exact = library.items.first { item in
            guard case let .bookmark(bookmark) = item.source else {
                return false
            }
            return bookmark.content == entry.content
        }
        if let exact {
            return exact
        }
        let sceneID = entry.content.sceneDescriptor?.workshopID
        return library.items.first { item in
            switch item.source {
            case let .bookmark(bookmark):
                return bookmark.content == entry.content
                    || (sceneID != nil && bookmark.content.sceneDescriptor?.workshopID == sceneID)
            case let .aerial(asset):
                return library.aerial(asset, matches: entry.content)
            #if !LITE_BUILD
            case let .workshop(project):
                return project.origin.workshopID == (sceneID ?? entry.origin?.workshopID)
            #endif
            }
        }
    }

    private func thumbnailRequest(for entry: WallpaperQueueEntry) -> ShelfThumbnailCache.Request {
        Self.matchingItem(entry, in: library)?.thumbnail
            ?? .bookmark(WallpaperBookmark(label: entry.title, content: entry.content, wpeOrigin: entry.origin))
    }

    private func load() {
        defer { loadedDraft = draft }
        guard let config = manager.getConfiguration(for: screen) ?? initialConfiguration else { return }
        mode = config.wallpaperMode
        savedMode = config.wallpaperMode
        queue = config.effectiveWallpaperQueue
        if config.wallpaperQueue == nil, config.wallpaperType != .video {
            let current = currentEntry ?? WallpaperQueueEntry(title: "", content: config.activeWallpaper, origin: config.wpeOrigin)
            queue.insert(current, at: 0)
            insertedCurrentID = current.id
        }
        playingEntryID = Self.nowPlayingEntryID(in: config, insertedCurrent: insertedCurrentID, previewing: preview?.entryID)
        slots = (config.scheduleSlots ?? []).map { slot in
            var migrated = slot
            if migrated.wallpaper == nil, let bookmark = migrated.videoBookmarkData {
                migrated.wallpaper = WallpaperQueueEntry(title: "", content: .video(bookmarkData: bookmark))
                migrated.videoBookmarkData = nil
            }
            return migrated
        }
        failures = config.automationFailures
        selectedSlotID = slots.first { $0.containsMinute(SchedulePolicy.minuteOfDay(openedAt, calendar: .current)) }?.id ?? slots.first?.id
        autoAdvance = config.playlistAutoAdvance
        rotation = config.playlistRotationMinutes ?? ScreenConfiguration.defaultPlaylistRotationMinutes
        loops = config.playlistLoops
        libraryRotation = max(1, config.libraryShuffleRotationMinutes)
        shuffle = config.shufflePlaylist
        excludedIDs = Set(config.libraryShuffleExcludedIDs)
        fallback = config.scheduleFallback
        derivedFallback = currentEntry.map { SchedulePolicy.initialFallback(for: config, current: $0) }
        handledShuffleSerial = manager.automaticSwitchMark(for: screen.displayFingerprint)?.serial
        refreshDeck()
    }

    private func save() {
        manager.updateWallpaperAutomation(
            queue: queue, slots: slots, fallback: fallback ?? (mode == .schedule ? derivedFallback : nil), mode: mode,
            rotationMinutes: rotation, autoAdvance: autoAdvance, loops: loops, shuffle: shuffle,
            libraryShuffleRotationMinutes: libraryRotation, libraryShuffleExcludedIDs: excludedIDs.sorted(), previewedEntryID: preview?.entryID, for: screen
        )
    }
}

private struct QueueEntryLabel: View {
    let entry: WallpaperQueueEntry
    let title: String
    let isPlaying: Bool
    let thumbnails: ShelfThumbnailCache
    var thumbnailSize = CGSize(width: 80, height: 45)
    let request: @MainActor () -> ShelfThumbnailCache.Request
    @State private var image: CGImage?
    @State private var subtitle = ""
    @Environment(\.displayScale) private var scale

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            thumbnail
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
                .accessibilityHidden(true)
                .task(id: entry.id) {
                    let pixelSize = CGSize(width: thumbnailSize.width * scale, height: thumbnailSize.height * scale)
                    image = await thumbnails.image(request(), pixelSize: pixelSize, scale: scale)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).lineLimit(2).multilineTextAlignment(.leading)
                if isPlaying {
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        Circle()
                            .fill(DesignTokens.EditDesk.Colors.nowPlayingGlyph)
                            .frame(width: 6, height: 6)
                        Text("Now playing")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.EditDesk.Colors.nowPlayingGlyph)
                    }
                    .lineLimit(1)
                } else if !subtitle.isEmpty {
                    Text(verbatim: subtitle).font(DesignTokens.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(isPlaying ? Text("Now playing") : Text(verbatim: ""))
            .task(id: entry.id) {
                guard case let .video(bookmarkData, .none) = entry.content else { return }
                let metadata = await MetadataService.shared.metadata(for: bookmarkData)
                subtitle = WallpaperAutomationSheet.rowSubtitle(metadata, for: entry)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
            Image(systemName: entry.symbol).font(DesignTokens.Typography.sectionTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
    }
}

private struct ScheduleSlotThumbnail: View {
    let entry: WallpaperQueueEntry?
    let thumbnails: ShelfThumbnailCache
    let request: () -> ShelfThumbnailCache.Request?
    @State private var image: CGImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: entry?.symbol ?? "photo").frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
            }
        }.task(id: entry?.id) {
            guard let request = request() else { image = nil; return }
            image = await thumbnails.image(request, pixelSize: CGSize(width: 92 * scale, height: 60 * scale), scale: scale)
        }
    }
}

/// Lays `content` out at its ideal size and scales it down, never up, until it fits the offered space.
private struct ShrinkToFit<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var ideal = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let scale = ideal.width > 0 && ideal.height > 0
                ? min(1, proxy.size.width / ideal.width, proxy.size.height / ideal.height)
                : 1
            content
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { ideal = $0 }
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
