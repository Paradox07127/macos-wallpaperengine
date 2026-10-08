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
    let size: CGSize
    private let initialConfiguration: ScreenConfiguration?
    @Environment(ScreenManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var queue: [WallpaperQueueEntry] = []
    @State private var slots: [ScheduleSlot] = []
    @State private var mode: WallpaperMode = .playlist
    @State private var savedMode: WallpaperMode = .playlist
    @State private var rotation = 0
    @State private var libraryRotation = 15
    @State private var shuffle = false
    @State private var fallback: WallpaperQueueEntry?
    @State private var derivedFallback: WallpaperQueueEntry?
    @State private var shownBeforeTrial: ScreenConfiguration?
    @State private var search = ""
    @State private var picking = false
    @State private var openedAt = Date()
    @State private var selectedSlotID: UUID?
    @State private var failures: [String: WallpaperAutomationFailure] = [:]
    @State private var pickTarget: PickTarget = .queue
    @State private var added: [LibraryItem.ID: WallpaperQueueEntry.ID] = [:]
    @State private var error: String?
    @State private var playingEntryID: WallpaperQueueEntry.ID?
    @State private var insertedCurrentID: WallpaperQueueEntry.ID?
    /// The row "Preview on This Display" put on screen, and the display's automatic-switch serial at that moment.
    @State private var preview: (entryID: WallpaperQueueEntry.ID, switchSerial: Int?)?
    @State private var thumbnails = ShelfThumbnailCache()
    @State private var guide = PageGuideSession()

    init(screen: Screen, library: SavedLibraryModel, size: CGSize, initialConfiguration: ScreenConfiguration? = nil) {
        self.screen = screen
        self.library = library
        self.size = size
        self.initialConfiguration = initialConfiguration
        _mode = State(initialValue: initialConfiguration?.wallpaperMode ?? .playlist)
        _savedMode = State(initialValue: initialConfiguration?.wallpaperMode ?? .playlist)
        _queue = State(initialValue: initialConfiguration?.effectiveWallpaperQueue ?? [])
        _slots = State(initialValue: initialConfiguration?.scheduleSlots ?? [])
        _failures = State(initialValue: initialConfiguration?.automationFailures ?? [:])
    }

    private enum PickTarget: Equatable {
        case queue, slot(UUID), fallback
    }

    private var problem: SchedulePolicy.SlotProblem? {
        SchedulePolicy.firstProblem(in: slots)
    }

    private var slotWithoutWallpaper: UUID? {
        slots.first { $0.wallpaper == nil && $0.videoBookmarkData == nil }?.id
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

    private var headerSubtitle: LocalizedStringKey {
        guard let config = manager.getConfiguration(for: screen) ?? initialConfiguration else {
            return LocalizedStringKey(screen.name)
        }
        return "\(screen.name) · Currently: \(Text(Self.modeName(config)))"
    }

    /// A playlist-mode display with nothing to step through is not running a playlist.
    private static func modeName(_ config: ScreenConfiguration) -> LocalizedStringKey {
        switch config.wallpaperMode {
        case .playlist where !config.canNavigatePlaylist: "Single Wallpaper"
        case .playlist: "Playlist"
        case .schedule: "Daily Schedule"
        case .libraryShuffle: "Library Shuffle"
        }
    }

    static func togglePick(
        _ item: LibraryItem, queue: inout [WallpaperQueueEntry], added: inout [LibraryItem.ID: WallpaperQueueEntry.ID]
    ) -> Bool {
        if let id = added[item.id], let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
            added[item.id] = nil
            return true
        }
        guard let entry = WallpaperQueueEntry.libraryItem(item) else { return false }
        queue.append(entry)
        added[item.id] = entry.id
        return true
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

    /// 0 and 24 both mean a midnight end; the end picker lists 1–24, so a stored 0 must read as 24.
    static func endHourBinding(_ hour: Binding<Int>) -> Binding<Int> {
        Binding(get: { hour.wrappedValue == 0 ? 24 : hour.wrappedValue }, set: { hour.wrappedValue = $0 })
    }

    static func presetSlot(_ preset: Preset, in slots: [ScheduleSlot]) -> ScheduleSlot? {
        preset.conflicts(with: slots) ? nil : preset.makeSlot()
    }

    /// nil when the new hours are empty or overlap another slot: the timeline then drops the drag.
    static func retimed(_ slots: [ScheduleSlot], id: UUID, start: Int, end: Int) -> [ScheduleSlot]? {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return nil }
        var retimed = slots
        retimed[index].startHour = start
        retimed[index].endHour = end
        guard !SchedulePolicy.hourRanges(for: retimed[index]).isEmpty else { return nil }
        return SchedulePolicy.conflicts(slot: retimed[index], against: retimed).isEmpty ? retimed : nil
    }

    static func insertedSlot(atHour hour: Int, in slots: [ScheduleSlot]) -> ScheduleSlot? {
        let label = Preset.suggestion(forStartHour: hour).labelKey
        for length in [2, 1] {
            let end = hour + length
            let slot = ScheduleSlot(startHour: hour, endHour: end > 24 ? end - 24 : end, label: label)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                SteamSheetHeader(
                    icon: "clock.arrow.circlepath",
                    title: "Wallpaper Automation",
                    iconTint: DesignTokens.Colors.accent,
                    subtitle: headerSubtitle
                )
                PageGuideButton(context: .automation)
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.lg)

            GlassSegmentedPicker(
                selection: $mode,
                values: WallpaperMode.allCases,
                shell: .flat
            ) { mode, _ in
                switch mode {
                case .playlist:
                    Label("Playlist", systemImage: "play.rectangle.on.rectangle")
                        .font(DesignTokens.Typography.body)
                case .schedule:
                    Label("Daily Schedule", systemImage: "clock")
                        .font(DesignTokens.Typography.body)
                case .libraryShuffle:
                    Label("Library Shuffle", systemImage: "shuffle")
                        .font(DesignTokens.Typography.body)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Playback Mode"))
            .pageGuideTarget(.automationModes)
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.lg)

            Group {
                switch mode {
                case .playlist: queuePage
                case .schedule: schedulePage
                case .libraryShuffle: libraryShufflePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.18), value: mode)

            SheetFooterBar(
                primaryTitle: saveTitle,
                primaryAction: { save(); dismiss() },
                primaryDisabled: mode == .schedule && (problem != nil || slotWithoutWallpaper != nil),
                cancelTitle: "Cancel",
                cancelAction: {
                    preview = nil
                    Self.cancelTrial(restoring: shownBeforeTrial, manager: manager, screen: screen)
                    dismiss()
                },
                leading: {
                    if let error {
                        Text(verbatim: error)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.Status.danger)
                            .lineLimit(2)
                    }
                }
            )
            .pageGuideTarget(.automationFooter)
            // The guide panel's Return / Escape shortcuts would otherwise compete with Save / Cancel.
            .disabled(guide.context != nil)
        }
        .environment(guide)
        .frame(width: size.width, height: size.height)
        .overlayPreferenceValue(PageGuideAnchorKey.self) { PageGuideHost(session: guide, anchors: $0) }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            guard notification.userInfo?["screenID"] as? CGDirectDisplayID == screen.id else { return }
            Self.endTrialIfSwitched(
                &preview, shownBeforeTrial: &shownBeforeTrial,
                currentSerial: manager.automaticSwitchMark(for: screen.displayFingerprint)?.serial
            )
            failures = manager.getConfiguration(for: screen)?.automationFailures ?? [:]
            playingEntryID = Self.nowPlayingEntryID(
                in: manager.getConfiguration(for: screen), insertedCurrent: insertedCurrentID, previewing: preview?.entryID
            )
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
        .appLanguagePopover(isPresented: $picking, arrowEdge: .bottom) { wallpaperPicker }
    }

    private var libraryShufflePage: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Text("Automatically picks a random wallpaper from your entire library. New imports join automatically; unavailable wallpapers are skipped. The same wallpaper never plays twice in a row.")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingRow(icon: "arrow.triangle.2.circlepath", iconColor: DesignTokens.Colors.accent, title: "Rotate") {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            if savedMode == .libraryShuffle {
                                Button("Next Random Wallpaper") { manager.advanceLibraryShuffle(for: screen) }
                                    .buttonStyle(.bordered)
                            }
                            Picker("Rotate", selection: $libraryRotation) {
                                ForEach(Array(Set([1, 5, 15, 30, 60, 120, libraryRotation])).sorted(), id: \.self) { value in
                                    Text("Every \(value) min").tag(value)
                                }
                            }
                            .labelsHidden()
                        }
                        .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
            skippedSources
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    @ViewBuilder
    private var skippedSources: some View {
        if !failures.isEmpty {
            let rows = VStack(spacing: DesignTokens.Spacing.md) {
                ForEach(failures.values.sorted { $0.failedAt > $1.failedAt }, id: \.entry.id, content: skippedRow)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    if failures.count > 6 {
                        ScrollView { rows }.frame(maxHeight: 280)
                    } else {
                        rows
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Skipped wallpapers")
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    private func skippedRow(for failure: WallpaperAutomationFailure) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: Self.skipSymbol(failure.reason))
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .frame(width: DesignTokens.iconButtonDiameter(.regular))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(verbatim: Self.rowTitle(for: failure.entry, in: library)).lineLimit(1)
                if let reason = failure.reason {
                    Text(Self.skipReason(reason)).font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DesignTokens.Spacing.sm)
            Button("Enable Again") { manager.clearAutomationFailure(failure.entry.id, for: screen) }
                .buttonStyle(.bordered)
        }
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
        VStack(spacing: DesignTokens.Spacing.lg) {
            HStack {
                Label(shuffle ? "Shuffle" : "Plays in order, then repeats", systemImage: shuffle ? "shuffle" : "repeat")
                    .font(DesignTokens.Typography.subheadline).foregroundStyle(.secondary)
                Spacer()
                Toggle("Shuffle", isOn: $shuffle).toggleStyle(.switch).controlSize(.small)
                Picker("Rotate", selection: $rotation) {
                    Text("Manual").tag(0)
                    ForEach([1, 5, 15, 30, 60, 120], id: \.self) { value in
                        Text("Every \(value) min").tag(value)
                    }
                }.frame(width: 180)
                addButton("Add Wallpaper") { pickTarget = .queue; added = [:]; picking = true }
            }
            if queue.isEmpty {
                IllustratedEmptyState(
                    symbol: "list.bullet",
                    title: "Your playlist is empty",
                    message: "Add wallpapers from your library to play them in sequence.",
                    primary: EmptyStateButtonAction("Add Wallpaper") { pickTarget = .queue; added = [:]; picking = true }
                )
            } else {
                List {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: DesignTokens.Spacing.cardInset) {
                            if entry.id == playingEntryID {
                                Image(systemName: "waveform")
                                    .foregroundStyle(DesignTokens.EditDesk.Colors.nowPlayingGlyph)
                                    .frame(width: 22)
                                    .accessibilityHidden(true)
                            } else {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                            }
                            QueueEntryLabel(
                                entry: entry, title: Self.rowTitle(for: entry, in: library), isPlaying: entry.id == playingEntryID,
                                thumbnails: thumbnails
                            ) {
                                thumbnailRequest(for: entry)
                            }
                            failureBadge(entry)
                            Spacer()
                            icon("play.fill", "Preview on This Display") {
                                preview = (entry.id, manager.automaticSwitchMark(for: screen.displayFingerprint)?.serial)
                                Self.startTrial(entry, shownBeforeTrial: &shownBeforeTrial, manager: manager, screen: screen)
                            }
                            icon("minus", "Remove") { queue.remove(at: index) }
                        }
                        .padding(DesignTokens.Spacing.md)
                        .background(DesignTokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.lg))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityElement(children: .contain)
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
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    private var schedulePage: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack {
                    Label("24-hour schedule", systemImage: "clock")
                        .font(DesignTokens.Typography.sectionTitle)
                    Spacer()
                    NativeMenuButton { presetMenu } label: {
                        Image(systemName: "plus")
                            .font(DesignTokens.Typography.body)
                            .frame(width: DesignTokens.iconButtonDiameter(.regular), height: DesignTokens.iconButtonDiameter(.regular))
                            .adaptiveGlassSurface(.capsule, interactive: true)
                    }
                    .help(Text("Add schedule slot"))
                    .accessibilityLabel(Text("Add schedule slot"))
                    .disabled(SchedulePolicy.findFreeRange(in: slots, minHours: 1) == nil)
                }
                timeline.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            scheduleInspector
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.top, DesignTokens.Spacing.md)
        .padding(.bottom, DesignTokens.Spacing.md)
    }

    private var scheduleInspector: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            slotEditor
            if SchedulePolicy.findFreeRange(in: slots, minHours: 1) != nil, let entry = fallback ?? derivedFallback {
                unscheduledHoursSection(entry: entry)
            }
            validationSection
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private var slotEditor: some View {
        if let index = slots.firstIndex(where: { $0.id == selectedSlotID }) {
            let slot = slots[index]
            GroupBox("Time Slot") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    HStack {
                        hourPicker("Start", hour: $slots[index].startHour, hours: 0 ..< 24)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        hourPicker("End", hour: Self.endHourBinding($slots[index].endHour), hours: 1 ..< 25)
                    }
                    Button {
                        pickTarget = .slot(slot.id)
                        picking = true
                    } label: {
                        if let entry = slot.wallpaper {
                            QueueEntryLabel(entry: entry, title: Self.rowTitle(for: entry, in: library), isPlaying: false, thumbnails: thumbnails) {
                                thumbnailRequest(for: entry)
                            }
                            .id(entry.id)
                        } else {
                            Label("Choose Wallpaper", systemImage: "plus")
                        }
                    }
                    .buttonStyle(.plain)
                    if let entry = slot.wallpaper {
                        failureBadge(entry)
                    }
                    Button(role: .destructive) {
                        slots.removeAll { $0.id == slot.id }
                        selectedSlotID = slots.first?.id
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        } else {
            GroupBox("Select a time slot") {
                Text("Choose a wallpaper around the clock to edit its hours.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    private func unscheduledHoursSection(entry: WallpaperQueueEntry) -> some View {
        GroupBox("Unscheduled Hours") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Button {
                    pickTarget = .fallback
                    picking = true
                } label: {
                    entryLabel(entry)
                }
                .buttonStyle(.plain)
                failureBadge(entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
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
            onInsert: { hour in
                if let slot = Self.insertedSlot(atHour: hour, in: slots) {
                    slots.append(slot)
                    selectedSlotID = slot.id
                    error = nil
                }
            },
            thumbnail: { slot in
                AnyView(ScheduleSlotThumbnail(entry: slot.wallpaper, thumbnails: thumbnails) { slot.wallpaper.map(thumbnailRequest) })
            }
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

    private var wallpaperPicker: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            LibrarySearchField(text: $search, prompt: "Search wallpapers")
            ScrollView {
                LazyVStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(library.items.filter { $0.isSupported && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { item in
                        Button {
                            if pickTarget == .queue, Self.togglePick(item, queue: &queue, added: &added) {
                                error = nil
                                return
                            }
                            guard pickTarget != .queue, let entry = WallpaperQueueEntry.libraryItem(item) else {
                                error = String(localized: "This wallpaper is unavailable. Reimport it from the library.", bundle: .appLanguage)
                                picking = false
                                return
                            }
                            if case let .slot(id) = pickTarget {
                                assign(entry, toSlot: id)
                            } else {
                                fallback = entry
                            }
                            error = nil; picking = false
                        } label: {
                            HStack {
                                Image(systemName: item.kind == .scene ? "cube.transparent" : item.kind == .web ? "globe" : "film")
                                    .frame(width: 24).foregroundStyle(.tint)
                                Text(verbatim: item.title.translatedWallpaperName).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer()
                                if isPicked(item) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                } else {
                                    Image(systemName: "plus").foregroundStyle(.secondary)
                                }
                            }.padding(DesignTokens.Spacing.md).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isPicked(item) ? .isSelected : [])
                    }
                }
            }
            HStack {
                if pickTarget == .queue {
                    Button("Choose Videos", action: chooseVideoFiles)
                    Spacer()
                    Text("\(added.values.count(where: { id in queue.contains { $0.id == id } })) selected")
                        .font(DesignTokens.Typography.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Done") { picking = false }.buttonStyle(.borderedProminent)
                } else {
                    Button("Choose Video", action: chooseVideoFiles)
                    Spacer()
                }
            }
        }
        .padding(DesignTokens.Spacing.lg).frame(width: 440, height: 400)
    }

    private func entryLabel(_ entry: WallpaperQueueEntry) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: entry.symbol).font(DesignTokens.Typography.sectionTitle)
                .frame(width: 42, height: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
            Text(verbatim: Self.rowTitle(for: entry, in: library)).lineLimit(2).multilineTextAlignment(.leading)
        }
    }

    private func hourPicker(_ label: LocalizedStringKey, hour: Binding<Int>, hours: Range<Int>) -> some View {
        Picker(label, selection: hour) {
            ForEach(hours, id: \.self) { value in Text(verbatim: String(format: "%02d:00", value)).tag(value) }
        }.labelsHidden().frame(width: 80).help(Text(label))
    }

    private func icon(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private func addButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        GlassIconButton("plus", size: .regular, action: action).help(Text(title)).accessibilityLabel(Text(title))
    }

    private func move(_ index: Int, by offset: Int) {
        guard queue.indices.contains(index + offset) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { queue.swapAt(index, index + offset) }
    }

    private func addSlot() {
        guard let range = SchedulePolicy.findFreeRange(in: slots, minHours: 1) else { return }
        let end = min(range.start + 6, range.end)
        let slot = ScheduleSlot(startHour: range.start, endHour: end > 24 ? end - 24 : end, label: "")
        slots.append(slot)
        selectedSlotID = slot.id
    }

    private func assign(_ entry: WallpaperQueueEntry, toSlot id: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[index].wallpaper = entry
        slots[index].videoBookmarkData = nil
        slots[index].label = entry.title
    }

    private func isPicked(_ item: LibraryItem) -> Bool {
        guard pickTarget == .queue, let id = added[item.id] else { return false }
        return queue.contains { $0.id == id }
    }

    private func rangeText(for id: UUID) -> String {
        slots.first { $0.id == id }.map { String(format: "%02d:00–%02d:00", $0.startHour, $0.endHour) } ?? ""
    }

    private func chooseVideoFiles() {
        let target = pickTarget
        picking = false
        // App-modal: even on the next turn the closing popover can still be the key window, and a sheet on it would be cancelled with it.
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = target == .queue
            panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
            panel.prompt = target == .queue ? L10n.Panel.addVideos : L10n.Panel.setVideo
            if panel.runModal() == .OK {
                let chosen = WallpaperQueueEntry.videoFiles(panel.urls)
                error = chosen.failed > 0
                    ? String(
                        localized: "Couldn't add \(chosen.failed) of the selected videos.", bundle: .appLanguage,
                        comment: "Playlist and schedule panel: some chosen video files could not be bookmarked. Placeholder is how many."
                    )
                    : nil
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
                }
            }
        }
    }

    private var currentEntry: WallpaperQueueEntry? {
        guard let config = manager.getConfiguration(for: screen) else { return nil }
        var entry = WallpaperQueueEntry(title: "", content: config.activeWallpaper, origin: config.wpeOrigin)
        entry.title = Self.matchingItem(entry, in: library)?.title ?? manager.wallpaperDisplayName(for: screen) ?? ""
        return entry
    }

    private static func matchingItem(_ entry: WallpaperQueueEntry, in library: SavedLibraryModel) -> LibraryItem? {
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
        selectedSlotID = slots.first { $0.containsHour(Calendar.current.component(.hour, from: openedAt)) }?.id ?? slots.first?.id
        rotation = config.playlistRotationMinutes ?? 0
        libraryRotation = max(1, config.libraryShuffleRotationMinutes)
        shuffle = config.shufflePlaylist
        fallback = config.scheduleFallback
        derivedFallback = currentEntry.map { SchedulePolicy.initialFallback(for: config, current: $0) }
    }

    private func save() {
        manager.updateWallpaperAutomation(
            queue: queue, slots: slots, fallback: fallback ?? (mode == .schedule ? derivedFallback : nil), mode: mode,
            rotationMinutes: rotation > 0 ? rotation : nil, shuffle: shuffle,
            libraryShuffleRotationMinutes: libraryRotation, previewedEntryID: preview?.entryID, for: screen
        )
    }
}

private struct QueueEntryLabel: View {
    private static let thumbnailSize = CGSize(width: 80, height: 45)
    let entry: WallpaperQueueEntry
    let title: String
    let isPlaying: Bool
    let thumbnails: ShelfThumbnailCache
    let request: @MainActor () -> ShelfThumbnailCache.Request
    @State private var image: CGImage?
    @State private var subtitle = ""
    @Environment(\.displayScale) private var scale

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            thumbnail
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
                .accessibilityHidden(true)
                .task(id: entry.id) {
                    let pixelSize = CGSize(width: Self.thumbnailSize.width * scale, height: Self.thumbnailSize.height * scale)
                    image = await thumbnails.image(request(), pixelSize: pixelSize, scale: scale)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).lineLimit(2).multilineTextAlignment(.leading)
                if isPlaying {
                    Text("Now playing")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.EditDesk.Colors.nowPlayingGlyph)
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
                // The folder of a Workshop video is its numeric ID, which belongs in the item's details.
                subtitle = RowMetadata(resolution: metadata.resolution, duration: metadata.duration, folder: nil).subtitle
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
