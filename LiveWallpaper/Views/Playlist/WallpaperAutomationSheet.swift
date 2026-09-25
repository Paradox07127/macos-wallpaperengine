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
    @Environment(ScreenManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var queue: [WallpaperQueueEntry] = []
    @State private var slots: [ScheduleSlot] = []
    @State private var mode: WallpaperMode = .playlist
    @State private var savedMode: WallpaperMode = .playlist
    @State private var rotation = 0
    @State private var shuffle = false
    @State private var fallback: WallpaperQueueEntry?
    @State private var derivedFallback: WallpaperQueueEntry?
    @State private var shownBeforeTrial: ScreenConfiguration?
    @State private var search = ""
    @State private var picking = false
    @State private var pickTarget: PickTarget = .queue
    @State private var added: [LibraryItem.ID: WallpaperQueueEntry.ID] = [:]
    @State private var error: String?

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
        return mode == .playlist ? "Save and Use Playlist" : "Save and Use Daily Schedule"
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

    /// 0 and 24 both mean a midnight end; the end picker lists 1–24, so a stored 0 must read as 24.
    static func endHourBinding(_ hour: Binding<Int>) -> Binding<Int> {
        Binding(get: { hour.wrappedValue == 0 ? 24 : hour.wrappedValue }, set: { hour.wrappedValue = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: mode == .playlist ? "list.bullet" : "clock")
                    .font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Playlist & Schedule").font(.headline)
                    Text(verbatim: screen.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Playback Mode", selection: $mode) {
                    Label("Playlist", systemImage: "list.bullet").tag(WallpaperMode.playlist)
                    Label("Daily Schedule", systemImage: "clock").tag(WallpaperMode.schedule)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 270)
            }
            .padding(24)
            Divider()
            Group {
                if mode == .playlist {
                    queuePage
                } else {
                    schedulePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.18), value: mode)
            Divider()
            HStack {
                if let error {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") {
                    Self.cancelTrial(restoring: shownBeforeTrial, manager: manager, screen: screen)
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Button(saveTitle) { save(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(mode == .schedule && (problem != nil || slotWithoutWallpaper != nil))
            }
            .padding(20)
        }
        .frame(width: 820, height: 600)
        .background(DesignTokens.Colors.pageBackground)
        .onAppear(perform: load)
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

    private var queuePage: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Plays in order, then repeats", systemImage: "repeat")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Toggle("Shuffle", isOn: $shuffle).toggleStyle(.switch).controlSize(.small)
                Picker("Rotate", selection: $rotation) {
                    Text("Manual").tag(0)
                    ForEach([1, 5, 15, 30, 60, 120], id: \.self) { value in
                        Text("Every \(value) min").tag(value)
                    }
                }.frame(width: 180)
                addButton { pickTarget = .queue; added = [:]; picking = true }
            }
            if queue.isEmpty {
                ContentUnavailableView("Your playlist is empty", systemImage: "list.bullet", description: Text("Add wallpapers from your library to play them in sequence."))
            } else {
                List {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 14) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                            entryLabel(entry)
                            Spacer()
                            icon("play.fill", "Preview on This Display") {
                                Self.startTrial(entry, shownBeforeTrial: &shownBeforeTrial, manager: manager, screen: screen)
                            }
                            icon("arrow.up", "Move Up") { move(index, by: -1) }.disabled(index == 0)
                            icon("arrow.down", "Move Down") { move(index, by: 1) }.disabled(index == queue.count - 1)
                            icon("minus", "Remove") { queue.remove(at: index) }
                        }
                        .padding(.vertical, 6)
                        .listRowSeparator(.hidden)
                        .accessibilityElement(children: .contain)
                    }
                    .onMove { from, to in queue.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .background(DesignTokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
            }
        }
        .padding(24)
    }

    private var schedulePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Repeats every day", systemImage: "arrow.clockwise")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                addButton { addSlot() }.disabled(SchedulePolicy.findFreeRange(in: slots, minHours: 1) == nil)
            }
            timeline
            if let problem {
                Group {
                    switch problem {
                    case let .noLength(id):
                        Label("Time slot \(rangeText(for: id)) starts and ends at the same hour. Choose a different end time.", systemImage: "exclamationmark.triangle")
                    case let .overlap(first, second):
                        Label("Time slots \(rangeText(for: first)) and \(rangeText(for: second)) overlap.", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption).foregroundStyle(.orange)
            } else if let id = slotWithoutWallpaper {
                Label(
                    String(
                        localized: "Time slot \(rangeText(for: id)) has no wallpaper yet. Choose one to save the schedule.", bundle: .appLanguage,
                        comment: "Playlist and schedule panel: why Save is unavailable while a time slot has no wallpaper. Placeholder is the slot's hours, like 06:00–12:00."
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($slots) { $slot in
                        HStack(spacing: 12) {
                            Circle().fill(slotColor(slot.id)).frame(width: 8, height: 8)
                            hourPicker("Start", hour: $slot.startHour, hours: 0 ..< 24)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            hourPicker("End", hour: Self.endHourBinding($slot.endHour), hours: 1 ..< 25)
                            Button {
                                pickTarget = .slot(slot.id); picking = true
                            } label: {
                                if let entry = slot.wallpaper {
                                    entryLabel(entry)
                                } else {
                                    Label("Choose Wallpaper", systemImage: "plus")
                                }
                            }
                            .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                            icon("minus", "Remove") { slots.removeAll { $0.id == slot.id } }
                        }
                        .padding(12)
                        .background(DesignTokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
                    }
                }
            }
            if SchedulePolicy.findFreeRange(in: slots, minHours: 1) != nil, let entry = fallback ?? derivedFallback {
                HStack(spacing: 12) {
                    Text("Unscheduled Hours")
                    Button {
                        pickTarget = .fallback; picking = true
                    } label: {
                        entryLabel(entry)
                    }
                    .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(DesignTokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
            }
        }
        .padding(24)
    }

    private var timeline: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.sm).fill(.quaternary)
                    ForEach(slots) { slot in
                        ForEach(Array(slot.timelineSegments().enumerated()), id: \.offset) { _, segment in
                            segmentBar(segment, color: slotColor(slot.id), width: proxy.size.width)
                        }
                    }
                }
            }.frame(height: 38)
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text(verbatim: String(format: "%02d:00", hour)).font(.caption.monospacedDigit())
                    if hour != 24 {
                        Spacer()
                    }
                }
            }.foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("24-hour repeating schedule"))
    }

    private func segmentBar(_ segment: ScheduleSlot.TimelineSegment, color: Color, width: CGFloat) -> some View {
        let barWidth: CGFloat = max(1, width * CGFloat(segment.end - segment.start) / 24 - 2)
        let offset: CGFloat = width * CGFloat(segment.start) / 24
        return RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
            .fill(color.opacity(0.75))
            .frame(width: barWidth)
            .offset(x: offset)
    }

    private var wallpaperPicker: some View {
        VStack(spacing: 12) {
            TextField("Search wallpapers", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
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
                                Text(verbatim: item.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer()
                                if isPicked(item) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                } else {
                                    Image(systemName: "plus").foregroundStyle(.secondary)
                                }
                            }.padding(10).contentShape(Rectangle())
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
                    Button("Done") { picking = false }.buttonStyle(.borderedProminent)
                } else {
                    Button("Choose Video", action: chooseVideoFiles)
                    Spacer()
                }
            }
        }
        .padding(16).frame(width: 440, height: 400)
    }

    private func entryLabel(_ entry: WallpaperQueueEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.symbol).font(.title3)
                .frame(width: 42, height: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
            Text(verbatim: entry.displayTitle).lineLimit(2).multilineTextAlignment(.leading)
        }
    }

    private func hourPicker(_ label: LocalizedStringKey, hour: Binding<Int>, hours: Range<Int>) -> some View {
        Picker(label, selection: hour) {
            ForEach(hours, id: \.self) { value in Text(verbatim: String(format: "%02d:00", value)).tag(value) }
        }.labelsHidden().frame(width: 80).help(Text(label))
    }

    private func icon(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24) }
            .buttonStyle(.borderless).help(Text(label)).accessibilityLabel(Text(label))
    }

    private func addButton(action: @escaping () -> Void) -> some View {
        GlassIconButton("plus", size: .regular, action: action).help(Text("Add Wallpaper")).accessibilityLabel(Text("Add Wallpaper"))
    }

    private func slotColor(_ id: UUID) -> Color {
        let palette: [Color] = [.blue, .teal, .indigo, .orange, .purple, .mint]
        return palette[(slots.firstIndex(where: { $0.id == id }) ?? 0) % palette.count]
    }

    private func move(_ index: Int, by offset: Int) {
        guard queue.indices.contains(index + offset) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { queue.swapAt(index, index + offset) }
    }

    private func addSlot() {
        guard let range = SchedulePolicy.findFreeRange(in: slots, minHours: 1) else { return }
        let end = min(range.start + 6, range.end)
        slots.append(ScheduleSlot(startHour: range.start, endHour: end > 24 ? end - 24 : end, label: ""))
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
        let sceneID = config.activeWallpaper.sceneDescriptor?.workshopID
        let item = library.items.first { item in
            switch item.source {
            case let .bookmark(bookmark):
                return bookmark.content == config.activeWallpaper
                    || (sceneID != nil && bookmark.content.sceneDescriptor?.workshopID == sceneID)
            case let .aerial(asset):
                return library.aerial(asset, matches: config.activeWallpaper)
            #if !LITE_BUILD
            case let .workshop(entry):
                return entry.origin.workshopID == (sceneID ?? config.wpeOrigin?.workshopID)
            #endif
            }
        }
        return WallpaperQueueEntry(title: item?.title ?? manager.wallpaperDisplayName(for: screen) ?? "", content: config.activeWallpaper, origin: config.wpeOrigin)
    }

    private func load() {
        guard let config = manager.getConfiguration(for: screen) else { return }
        mode = config.wallpaperMode
        savedMode = config.wallpaperMode
        queue = config.effectiveWallpaperQueue
        if config.wallpaperQueue == nil, config.wallpaperType != .video {
            queue.insert(currentEntry ?? WallpaperQueueEntry(title: "", content: config.activeWallpaper, origin: config.wpeOrigin), at: 0)
        }
        slots = (config.scheduleSlots ?? []).map { slot in
            var migrated = slot
            if migrated.wallpaper == nil, let bookmark = migrated.videoBookmarkData {
                migrated.wallpaper = WallpaperQueueEntry(title: "", content: .video(bookmarkData: bookmark))
                migrated.videoBookmarkData = nil
            }
            return migrated
        }
        rotation = config.playlistRotationMinutes ?? 0
        shuffle = config.shufflePlaylist
        fallback = config.scheduleFallback
        derivedFallback = currentEntry.map { SchedulePolicy.initialFallback(for: config, current: $0) }
    }

    private func save() {
        manager.updateWallpaperAutomation(
            queue: queue, slots: slots, fallback: fallback ?? (mode == .schedule ? derivedFallback : nil), mode: mode,
            rotationMinutes: rotation > 0 ? rotation : nil, shuffle: shuffle, for: screen
        )
    }
}
