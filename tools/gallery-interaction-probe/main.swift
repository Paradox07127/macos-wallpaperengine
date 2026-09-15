import AppKit
import SwiftUI
import LiveWallpaperCore
import QuartzCore
import os

func arg(_ key: String, _ fallback: String) -> String {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--" + key), i + 1 < a.count else { return fallback }
    return a[i + 1]
}
struct Record: Identifiable {
    let id: Int
    let bookmark: WallpaperBookmark
    let scheme: ScreenScheme
    let aerial: AerialAsset
    let poster: URL
}
@MainActor @Observable final class Model {
    var mode = arg("mode", "bookmarks")
    var filter = false
    var visible = true
    var selected: Int?
    var renaming: Int?
    var draft = ""
    var records: [Record] = []
    var shown: [Record] { filter ? records.filter { $0.id % 2 == 0 } : records }
}
struct Gallery: View {
    @Bindable var model: Model
    let export = WallpaperExportService()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.mode).font(.headline)
                    #if GALLERY_INPUT_CHECKS
                    .frame(width: 72)
                    #endif
                Button("Filter") { model.filter.toggle() }
                Button("Leave / Return") { model.visible.toggle() }
                Button("Rename first") { model.renaming = model.renaming == nil ? 0 : nil }
            }.padding()
            if model.visible {
                ScrollView {
                    LazyVGrid(columns: DesignTokens.LibraryGrid.columns(for: .medium, aspect: .wide), spacing: DesignTokens.LibraryGrid.spacing) {
                        ForEach(model.shown) { r in tile(r) }
                    }.libraryGridPadding()
                }
            } else { Color.clear }
        }.environment(export)
    }
    @ViewBuilder func tile(_ r: Record) -> some View {
        switch model.mode {
        case "bookmarks", "mixed":
            BookmarkTile(bookmark: r.bookmark, screens: [], isRenaming: model.renaming == r.id, renameDraft: $model.draft, onApply: { _ in }, onApplyToAll: {}, onStartRename: { model.renaming = r.id }, onCommitRename: { model.renaming = nil }, onCancelRename: { model.renaming = nil }, onDelete: {})
        case "schemes":
            SchemeTile(scheme: r.scheme, screens: [], isRenaming: model.renaming == r.id, renameDraft: $model.draft, onApply: { _ in }, onStartRename: { model.renaming = r.id }, onCommitRename: { model.renaming = nil }, onCancelRename: { model.renaming = nil }, onDelete: {}, onReplace: { _ in })
        case "aerials":
            ThumbnailCard(asset: r.aerial, screens: [], onApply: { _ in }, onApplyToAll: {})
        case "candidates":
            SystemWallpaperCandidateTile(candidate: SystemWallpaperCandidate(id: String(r.id), title: r.bookmark.label, source: .bookmark(r.bookmark)), isSelected: model.selected == r.id, onToggle: { model.selected = r.id })
        default:
            SystemWallpaperTile(item: SystemWallpaperManifest.Item(id: String(r.id), title: r.bookmark.label, fileName: "fixture.mp4", thumbnailFileName: nil, addedAt: Date(timeIntervalSince1970: 0)), thumbnailURL: r.poster, videoURL: nil, isInUse: model.selected == r.id, onRemove: {})
        }
    }
}
@MainActor func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
@MainActor func run() async throws {
    #if GALLERY_INPUT_CHECKS
    UserDefaults.standard.setVolatileDomain([AppLanguagePreference.storageKey: "en"], forName: UserDefaults.argumentDomain)
    #endif
    let model = Model()
    let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GALLERY_FIXTURES"]!)
    let inventory = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: fixtures.appendingPathComponent("inventory.json")))
    let video = fixtures.appendingPathComponent("fixture.mp4")
    let videoBookmark = try video.bookmarkData(options: .minimalBookmark)
    let html = fixtures.appendingPathComponent("fixture.html")
    let htmlBookmark = try html.bookmarkData(options: .minimalBookmark)
    for i in 0 ..< Int(arg("count", "120"))! {
        let item = inventory[i % inventory.count]
        let poster = URL(fileURLWithPath: item["preview"]!)
        let cover = model.mode == "mixed" && i % 3 != 0 ? nil : item["cover"]
        let content: WallpaperContent = model.mode == "mixed" && i % 3 == 1 ? .html(source: .file(bookmarkData: htmlBookmark), config: .default) : .video(bookmarkData: videoBookmark)
        let b = WallpaperBookmark(label: item["title"]!, content: content, coverFileName: cover)
        let scheme = ScreenScheme(name: b.label, configuration: ScreenConfiguration(screenID: 0, wallpaper: content), overlay: .default, coverFileName: cover)
        let a = AerialAsset(id: String(i), url: video, displayName: b.label, category: "Fixture", fileSize: Int64(i), bookmarkData: videoBookmark)
        model.records.append(Record(id: i, bookmark: b, scheme: scheme, aerial: a, poster: poster))
    }
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 960, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Gallery Probe — " + model.mode
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = arg("operation", "sequence") != "idle"
    let host = NSHostingView(rootView: Gallery(model: model)); host.sizingOptions = []; window.contentView = host
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    #if GALLERY_INPUT_CHECKS
    let checks = try await runInputChecks(window: window, model: model)
    try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg("output", "/tmp/gallery-input.json")))
    try await Task.sleep(for: .seconds(Double(arg("input-hold", "0")) ?? 0))
    NSApp.terminate(nil)
    return
    #endif
    let signposter = OSSignposter(subsystem: "com.loomscreen.gallery-probe", category: "interaction")
    var phases: [[String: Any]] = []
    let startThermal = ProcessInfo.processInfo.thermalState.rawValue
    if arg("hold", "") != "" {
        while !FileManager.default.fileExists(atPath: arg("hold", "")) { try await Task.sleep(for: .milliseconds(100)) }
    }
    let operations = arg("operation", "sequence") == "idle" ? ["idle"] : ["cold", "scroll", "filter", "filtered-scroll", "restore", "return", "warm-scroll", "select", "resize"]
    for phase in operations {
        let interval = signposter.beginInterval("phase", "\(phase)")
        if phase == "filter" { model.filter = true }
        if phase == "restore" { model.filter = false }
        if phase == "return" { model.visible = false; try await Task.sleep(for: .milliseconds(150)); model.visible = true }
        var submissions: [Double] = [], gaps: [Double] = []
        var previous = CACurrentMediaTime()
        let steps = phase == "idle" ? Int(arg("idle-seconds", "120"))! * 60 : Int(arg("steps", "120"))!
        for i in 0 ..< steps {
            let now = CACurrentMediaTime(); gaps.append((now - previous) * 1000); previous = now
            let start = CACurrentMediaTime()
            if phase.contains("scroll"), let scroll = views(host).compactMap({ $0 as? NSScrollView }).first {
                let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height)
                let t = Double(i % 60) / 59
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * (i / 60 % 2 == 0 ? t : 1 - t)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if phase == "select", i % 15 == 0 { model.selected = i % model.records.count }
            if phase == "resize", i % 30 == 0 { window.setContentSize(NSSize(width: i % 60 == 0 ? 880 : 960, height: 720)) }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            submissions.append((CACurrentMediaTime() - start) * 1000)
            try await Task.sleep(for: .milliseconds(16))
        }
        signposter.endInterval("phase", interval)
        phases.append(["phase": phase, "submissionMs": submissions, "mainActorGapMs": gaps])
    }
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg("output", "/tmp/gallery.json") + ".png"))
    }
    let report: [String: Any] = ["mode": model.mode, "records": model.records.count, "uniquePosters": inventory.count, "videoFiles": 1, "htmlFiles": 1, "thermalStart": startThermal, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue, "phases": phases]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg("output", "/tmp/gallery.json")))
    NSApp.terminate(nil)
}
NSApplication.shared.setActivationPolicy(.regular)
Task { @MainActor in
    do { try await run() } catch { fputs("\(error)\n", stderr); exit(1) }
}
NSApplication.shared.run()
