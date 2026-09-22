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
    @State private var rotation = 0
    @State private var shuffle = false
    @State private var search = ""
    @State private var picking = false
    @State private var pickingSlot: UUID?
    @State private var error: String?

    private var hasConflict: Bool {
        slots.contains { !SchedulePolicy.conflicts(slot: $0, against: slots).isEmpty || $0.startHour == $0.endHour }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: mode == .playlist ? "list.bullet" : "clock")
                    .font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Queue & Schedule").font(.headline)
                    Text(verbatim: screen.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Playback Mode", selection: $mode) {
                    Label("Queue", systemImage: "list.bullet").tag(WallpaperMode.playlist)
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
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(mode == .schedule && (hasConflict || slots.contains { $0.wallpaper == nil && $0.videoBookmarkData == nil }))
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
        .popover(isPresented: $picking, arrowEdge: .bottom) { wallpaperPicker }
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
                addButton { pickingSlot = nil; picking = true }
            }
            if queue.isEmpty {
                ContentUnavailableView("Your queue is empty", systemImage: "list.bullet", description: Text("Add wallpapers from your library to play them in sequence."))
            } else {
                List {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 14) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                            entryLabel(entry)
                            Spacer()
                            icon("play.fill", "Play") { save(); manager.playPlaylistEntry(at: index, for: screen) }
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
            if hasConflict {
                Label("Time ranges must not overlap", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($slots) { $slot in
                        HStack(spacing: 12) {
                            Circle().fill(slotColor(slot.id)).frame(width: 8, height: 8)
                            hourPicker("Start", hour: $slot.startHour, hours: 0 ..< 24)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            hourPicker("End", hour: $slot.endHour, hours: 1 ..< 25)
                            Button {
                                pickingSlot = slot.id; picking = true
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
            Text("Unscheduled hours use the wallpaper selected before the schedule starts.")
                .font(.caption).foregroundStyle(.secondary)
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
                            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                                .fill(slotColor(slot.id).opacity(0.75))
                                .frame(width: max(1, proxy.size.width * CGFloat(segment.end - segment.start) / 24 - 2))
                                .offset(x: proxy.size.width * CGFloat(segment.start) / 24)
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

    private var wallpaperPicker: some View {
        VStack(spacing: 12) {
            TextField("Search wallpapers", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.items.filter { $0.isSupported && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { item in
                        Button {
                            guard let entry = WallpaperQueueEntry.libraryItem(item) else {
                                error = String(localized: "This wallpaper is unavailable. Reimport it from the library.", bundle: .appLanguage)
                                picking = false
                                return
                            }
                            if let id = pickingSlot, let index = slots.firstIndex(where: { $0.id == id }) {
                                slots[index].wallpaper = entry
                                slots[index].videoBookmarkData = nil
                                slots[index].label = entry.title
                            } else {
                                queue.append(entry)
                            }
                            error = nil; picking = false
                        } label: {
                            HStack {
                                Image(systemName: item.kind == .scene ? "cube.transparent" : item.kind == .web ? "globe" : "film")
                                    .frame(width: 24).foregroundStyle(.tint)
                                Text(verbatim: item.title).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "plus").foregroundStyle(.secondary)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16).frame(width: 440, height: 360)
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

    private var currentEntry: WallpaperQueueEntry? {
        guard let config = manager.getConfiguration(for: screen) else { return nil }
        let sceneID = config.activeWallpaper.sceneDescriptor?.workshopID
        let item = library.items.first { item in
            switch item.source {
            case let .bookmark(bookmark):
                return bookmark.content == config.activeWallpaper
                    || (sceneID != nil && bookmark.content.sceneDescriptor?.workshopID == sceneID)
            case let .aerial(asset):
                return asset.bookmarkData == config.activeWallpaper.activeVideoBookmarkData
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
    }

    private func save() {
        manager.updateWallpaperAutomation(
            queue: queue, slots: slots, mode: mode,
            rotationMinutes: rotation > 0 ? rotation : nil, shuffle: shuffle, for: screen
        )
    }
}
