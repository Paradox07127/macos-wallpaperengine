import AppKit
import Darwin
import LiveWallpaperCore
import Observation
import os
import QuartzCore
import SwiftUI

func arg(_ key: String, _ fallback: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: "--" + key), i + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[i + 1]
}

@MainActor enum Metrics {
    static var ready: Set<String> = []
    static var cardBodies = 0
    static var frames = 0
    static var hostsCreated = 0
    static var hostsBound = 0
    static var clicks = 0
    static var clickTimes: [Double] = []
    static var hoverTimes: [Double] = []
    static func hoverChanged(_ value: Bool) { if value { hoverTimes.append(CACurrentMediaTime()) } }
}

actor ProbeAssets {
    static let shared = ProbeAssets()
    var files: [String: URL] = [:]
    var requests = 0
    var bytes = 0
    func register(_ files: [String: URL]) {
        self.files = files
    }

    func fetch(_ url: URL) -> Data? {
        requests += 1
        guard let path = files[url.lastPathComponent], let data = try? Data(contentsOf: path) else { return nil }
        bytes += data.count
        return data
    }
}

@MainActor func makeProbeLoader() -> WorkshopPreviewImageLoader {
    let fetch: WorkshopPreviewByteFetch = { @Sendable url in await ProbeAssets.shared.fetch(url) }
    return WorkshopPreviewImageLoader(diskCache: WorkshopPreviewDiskCache(directoryURL: URL(fileURLWithPath: arg("cache", "/private/tmp/workflow-cache"))), fetch: fetch)
}

@MainActor func allViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allViews)
}

func quantile(_ a: [Double], _ p: Double) -> Double {
    let a = a.sorted(); return a.isEmpty ? 0 : a[min(a.count - 1, Int((Double(a.count - 1) * p).rounded()))]
}

func usage() -> (Double, Int64) {
    var r = rusage(); getrusage(RUSAGE_SELF, &r); return (Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6, Int64(r.ru_maxrss))
}

func resident() -> UInt64 {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size); let code = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }; return code == KERN_SUCCESS ? info.resident_size : 0
}

@MainActor func loadLibrary(mode: String, count: Int) async throws -> (Library, [String: Any]) {
    let corpus = URL(fileURLWithPath: arg("corpus", "/Users/taijial/Library/Application Support/Steam/steamapps/workshop/content/431960"))
    let folders = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
    var source: [(WorkshopQueryItem, WPEHistoryEntry)] = []
    var files: [String: URL] = [:]
    for folder in folders {
        guard let id = UInt64(folder.lastPathComponent),
              let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let previewName = json["preview"] as? String else { continue }
        let preview = folder.appendingPathComponent(previewName)
        guard FileManager.default.fileExists(atPath: preview.path) else { continue }
        let key = "\(id).\(preview.pathExtension)"
        files[key] = preview
        var tags = json["tags"] as? [String] ?? []; tags.append(json["type"] as? String ?? "scene")
        let item = WorkshopQueryItem(id: id, rawTitle: json["title"] as? String, shortDescription: "", creatorID: nil,
                                     previewImageURL: URL(string: "https://steamuserimages-a.akamaihd.net/ugc/" + key),
                                     fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil, rating: nil, tags: tags,
                                     visibility: .public, isBanned: false,
                                     steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!)
        let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let entry = WPEHistoryEntry(origin: WPEOrigin(workshopID: String(id), title: item.title,
                                    originalType: WPEType(rawValue: (json["type"] as? String ?? "unknown").lowercased()) ?? .unknown,
                                    sourceFolderBookmark: bookmark, cacheRelativePath: nil, previewFileName: previewName,
                                    entryFile: json["file"] as? String), importedAt: Date(timeIntervalSince1970: 0))
        source.append((item, entry))
    }
    guard !source.isEmpty else { throw NSError(domain: "WorkflowProbe", code: 1) }
    let library = Library()
    library.cards = (0 ..< count).map { index in
        let (s, entry) = source[index % source.count]
        let item = WorkshopQueryItem(id: UInt64(index + 1), rawTitle: s.rawTitle, shortDescription: s.shortDescription,
                                    creatorID: nil, previewImageURL: s.previewImageURL, fileSizeBytes: nil,
                                    timeUpdated: nil, subscriptionCount: nil, rating: nil, tags: s.tags,
                                    visibility: s.visibility, isBanned: false, steamCommunityURL: s.steamCommunityURL)
        return CardState(item: item, entry: mode == "installed" ? entry : nil)
    }
    library.byID = Dictionary(uniqueKeysWithValues: library.cards.map { ($0.id, $0) })
    await ProbeAssets.shared.register(files)
    return (library, ["sourceItems": source.count, "items": count, "uniquePreviews": Set(library.cards.map(\.previewKey)).count,
                      "cycled": count > source.count, "gifFiles": files.values.filter { $0.pathExtension.lowercased() == "gif" }.count])
}

@MainActor final class Session {
    let window: NSWindow
    let library: Library
    var collection: CollectionHost?
    var scroll: NSScrollView!
    let preheater = Preheater()
    let variant: String
    private var materializedIDs: Set<UInt64> = []
    init(library: Library, variant: String) {
        self.library = library
        self.variant = variant
        if variant == "windowed" {
            materializedIDs = Set(library.cards.prefix(16).map(\.id))
            for card in library.cards { card.materialized = materializedIDs.contains(card.id) }
        }
        window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.title = "Workshop workflow — \(variant)"
        if variant == "collection" {
            let host = CollectionHost(library: library); collection = host; window.contentView = host.scroll
        } else {
            let host = NSHostingView(rootView: SwiftGrid(library: library, eager: variant != "lazy"))
            host.sizingOptions = []; window.contentView = host
        }
    }
    func show() {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        flush()
        scroll = allViews(window.contentView!).compactMap { $0 as? NSScrollView }.first
    }
    func flush() { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush() }
    func move(to y: CGFloat) {
        updateVisibility(y: y)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView); flush()
        let geometry = Geometry(width: scroll.contentSize.width)
        let first = min(library.cards.count, (Int((y + scroll.contentSize.height) / geometry.pitch) + 1) * geometry.columns)
        let end = min(library.cards.count, first + geometry.columns * 2)
        preheater.update(library.cards[first ..< end])
    }
    func updateVisibility(y: CGFloat) {
        guard variant == "windowed", let scroll else { return }
        let g = Geometry(width: scroll.contentSize.width)
        let first = min(library.cards.count, max(0, Int(y / g.pitch) - 1) * g.columns)
        let end = min(library.cards.count, (Int((y + scroll.contentSize.height) / g.pitch) + 2) * g.columns)
        let desired = Set(library.cards[first ..< max(first, end)].map(\.id))
        for id in materializedIDs.subtracting(desired) { library.byID[id]?.materialized = false }
        for id in desired.subtracting(materializedIDs) { library.byID[id]?.materialized = true }
        materializedIDs = desired
    }
    func reload() { collection?.reload(); updateVisibility(y: 0); flush() }
    func resize(_ width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 600))
        collection?.collection.collectionViewLayout?.invalidateLayout(); flush()
        updateVisibility(y: scroll.contentView.bounds.minY); flush()
    }
    func point(column: Int) -> CGPoint {
        let g = Geometry(width: scroll.contentSize.width)
        let local = NSPoint(x: g.inset + g.side * 0.5 + CGFloat(column) * g.pitch,
                            y: window.contentLayoutRect.height - DesignTokens.LibraryGrid.verticalPadding - g.side * 0.4)
        let screen = window.convertPoint(toScreen: local)
        return CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
    }
    func close() { preheater.cancel(); window.contentView = nil; collection = nil; scroll = nil; window.close() }
}

func mouse(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

@MainActor func cacheStats() -> [[String: Any]] {
    WPEImageCacheKind.allCases.map { kind in
        let s = WPEImageCacheMeter.shared.stats(for: kind)
        return ["kind": kind.label, "bytes": s.liveBytes, "count": s.liveCount, "inserted": s.inserted,
                "evicted": s.evicted, "duplicateInserts": s.duplicateInserts, "unattributedEvictions": s.unattributedEvictions]
    }
}

@MainActor func waitReady(_ keys: Set<String>, session: Session) async throws -> Bool {
    let deadline = CACurrentMediaTime() + 8
    while !keys.isSubset(of: Metrics.ready), CACurrentMediaTime() < deadline {
        try await Task.sleep(for: .milliseconds(10)); session.flush()
    }
    return keys.isSubset(of: Metrics.ready)
}

@MainActor func run() async throws {
    let variant = arg("variant", "lazy"), mode = arg("mode", "installed")
    guard ["lazy", "eager", "windowed", "collection"].contains(variant), ["installed", "online"].contains(mode) else {
        throw NSError(domain: "WorkflowProbe", code: 2)
    }
    let (library, corpus) = try await loadLibrary(mode: mode, count: Int(arg("count", "50")) ?? 50)
    let original = library.cards
    let savedPointer = CGEvent(source: nil)?.location ?? .zero
    defer { mouse(.mouseMoved, at: savedPointer) }
    mouse(.mouseMoved, at: CGPoint(x: 20, y: 20))
    // Attach-only trace runs wait here; standalone runs begin immediately.
    let waitFile = arg("wait-file", "")
    if !waitFile.isEmpty {
        print("READY \(getpid())"); fflush(stdout)
        while !FileManager.default.fileExists(atPath: waitFile) { try await Task.sleep(for: .milliseconds(100)) }
    }
    let coolDeadline = CACurrentMediaTime() + 600
    while ProcessInfo.processInfo.thermalState != .nominal, CACurrentMediaTime() < coolDeadline {
        try await Task.sleep(for: .seconds(2))
    }
    guard ProcessInfo.processInfo.thermalState == .nominal else {
        print("THERMAL_NOT_READY"); exit(3)
    }
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    let cpuStart = usage().0, start = CACurrentMediaTime()
    var phases: [[String: Any]] = [], errors: [String] = []
    var peak = resident(), cachePeak = 0
    let signposter = OSSignposter(subsystem: "com.loomscreen.workflow-probe", category: "Workflow")
    func phase(_ name: String, _ work: () async throws -> [String: Any]) async throws {
        let t = CACurrentMediaTime(), c = usage().0, bodies = Metrics.cardBodies
        let sign = signposter.beginInterval("phase", "\(name)")
        var data = try await work()
        signposter.endInterval("phase", sign)
        data["name"] = name; data["cpuSeconds"] = usage().0 - c; data["wallMs"] = (CACurrentMediaTime() - t) * 1000
        data["cardBodies"] = Metrics.cardBodies - bodies; data["rss"] = resident(); data["caches"] = cacheStats()
        peak = max(peak, resident())
        cachePeak = max(cachePeak, WPEImageCacheKind.allCases.reduce(0) { $0 + WPEImageCacheMeter.shared.stats(for: $1).liveBytes })
        phases.append(data)
    }
    var session: Session!
    let expected = Set(original.prefix(12).map(\.previewKey))
    try await phase("cold-open") {
        let t = CACurrentMediaTime()
        session = Session(library: library, variant: variant); session.show()
        let layout = (CACurrentMediaTime() - t) * 1000
        let ready = try await waitReady(expected, session: session)
        if !ready { errors.append("cold viewport previews missing: \(expected.subtracting(Metrics.ready))") }
        return ["firstLayoutMs": layout, "viewportReady": ready, "viewportReadyMs": (CACurrentMediaTime() - t) * 1000]
    }
    try await phase("short-scroll") {
        var samples: [Double] = [], positions: [Double] = [], peakRSS = resident()
        let extent = min(1000, max(0, session.scroll.documentView!.frame.height - session.scroll.contentSize.height))
        for step in 0 ..< 96 {
            let fraction = CGFloat(step < 48 ? step : 95 - step) / 47
            let t = CACurrentMediaTime()
            session.move(to: extent * fraction)
            samples.append((CACurrentMediaTime() - t) * 1000)
            positions.append(session.scroll.contentView.bounds.minY); peakRSS = max(peakRSS, resident())
            try await Task.sleep(for: .milliseconds(16))
        }
        if (positions.max() ?? 0) < extent - 1 { errors.append("scroll did not reach expected extent") }
        peak = max(peak, peakRSS)
        return ["submissionMs": samples, "submissionP95Ms": quantile(samples, 0.95), "positions": positions, "extent": extent, "rssPeak": peakRSS]
    }
    session.preheater.cancel()
    try await phase("hover-click") {
        var hoverLatency: [Double] = [], clickLatency: [Double] = []
        let initialFrames = Metrics.frames
        for column in 0 ..< 3 {
            let before = Metrics.hoverTimes.count, t = CACurrentMediaTime()
            mouse(.mouseMoved, at: session.point(column: column))
            try await Task.sleep(for: .milliseconds(550)); session.flush()
            if Metrics.hoverTimes.count > before { hoverLatency.append((Metrics.hoverTimes[before] - t) * 1000) }
            else { errors.append("hover \(column) not delivered") }
            let clicks = Metrics.clicks
            mouse(.leftMouseDown, at: session.point(column: column))
            try await Task.sleep(for: .milliseconds(20))
            let clickStart = CACurrentMediaTime()
            mouse(.leftMouseUp, at: session.point(column: column))
            try await Task.sleep(for: .milliseconds(120)); session.flush()
            if Metrics.clicks == clicks + 1, library.selectedID == original[column].id {
                clickLatency.append((Metrics.clickTimes.last! - clickStart) * 1000)
            } else { errors.append("click \(column) did not select expected ID") }
        }
        mouse(.mouseMoved, at: CGPoint(x: 20, y: 20))
        try await Task.sleep(for: .milliseconds(100))
        return ["hoverCallbackMs": hoverLatency, "clickCallbackMs": clickLatency, "animationFrames": Metrics.frames - initialFrames]
    }
    try await phase("filter-restore") {
        var samples: [Double] = []
        for filtered in [true, false] {
            let t = CACurrentMediaTime()
            library.cards = filtered ? original.filter { $0.id.isMultiple(of: 2) } : original
            session.reload()
            try await Task.sleep(for: .milliseconds(150)); session.flush()
            samples.append((CACurrentMediaTime() - t) * 1000)
        }
        if library.cards.map(\.id) != original.map(\.id) { errors.append("filter restore lost items") }
        return ["settleMs": samples]
    }
    try await phase("inspector-width") {
        var samples: [Double] = [], columns: [Int] = []
        for width: CGFloat in [620, 900] {
            let t = CACurrentMediaTime(); session.resize(width)
            samples.append((CACurrentMediaTime() - t) * 1000)
            columns.append(Geometry(width: session.scroll.contentSize.width).columns)
            try await Task.sleep(for: .milliseconds(150)); session.flush()
        }
        if columns != [2, 4] { errors.append("unexpected responsive columns \(columns)") }
        return ["submissionMs": samples, "columns": columns, "detailContentIncluded": false]
    }
    try await Task.sleep(for: .seconds(Double(arg("inspect-seconds", "0")) ?? 0))
    let inspectFile = arg("inspect-file", "")
    if !inspectFile.isEmpty {
        print("INSPECT \(getpid())"); fflush(stdout)
        while !FileManager.default.fileExists(atPath: inspectFile) { try await Task.sleep(for: .milliseconds(100)) }
    }
    if arg("screenshot", "") != "", let view = session.window.contentView,
       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg("screenshot", "")))
    }
    session.close(); session = nil
    try await Task.sleep(for: .milliseconds(250))
    Metrics.ready.removeAll()
    try await phase("warm-return") {
        let t = CACurrentMediaTime()
        session = Session(library: library, variant: variant); session.show()
        let layout = (CACurrentMediaTime() - t) * 1000
        let ready = try await waitReady(expected, session: session)
        if !ready { errors.append("warm viewport previews missing") }
        return ["firstLayoutMs": layout, "viewportReady": ready, "viewportReadyMs": (CACurrentMediaTime() - t) * 1000]
    }
    let measuredCPU = usage().0 - cpuStart, measuredWall = CACurrentMediaTime() - start
    let cachesBeforeClose = cacheStats()
    session.close(); session = nil
    try await Task.sleep(for: .milliseconds(250))
    let stoppedFrames = Metrics.frames
    LocalImageCacheRegistry.shared.purgeAll()
    try await Task.sleep(for: .milliseconds(350))
    if Metrics.frames != stoppedFrames { errors.append("frames continued after close") }
    let disk = WorkshopPreviewDiskCache(directoryURL: URL(fileURLWithPath: arg("cache", "/private/tmp/workflow-cache")))
    let result: [String: Any] = ["variant": variant, "mode": mode, "corpus": corpus,
        "phases": phases, "cpuSeconds": measuredCPU, "wallSeconds": measuredWall,
        "rssPeakSampled": peak, "rssAfterClosePurge": resident(), "cachePeakSampledBytes": cachePeak,
        "cachesBeforeClose": cachesBeforeClose, "cachesAfterPurge": cacheStats(), "diskCacheBytes": await disk.sizeBytes(),
        "cardBodies": Metrics.cardBodies, "hostsCreated": Metrics.hostsCreated, "hostsBound": Metrics.hostsBound,
        "frames": Metrics.frames, "errors": errors, "pid": getpid(), "thermalStart": thermal,
        "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
        "timestamp": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        "preheat": arg("preheat", "on"), "configurationTouched": false, "renderSessionIncluded": false,
        "input": "CGEvent hover/click; programmatic fixed-distance scroll; width-only inspector simulation",
        "screen": NSScreen.main.map { ["width": $0.frame.width, "height": $0.frame.height, "scale": $0.backingScaleFactor, "maximumFPS": Double($0.maximumFramesPerSecond)] } ?? [:],
        "fetchRequests": await ProbeAssets.shared.requests, "fetchBytes": await ProbeAssets.shared.bytes]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg("output", "/private/tmp/workflow-result.json")))
    print("RESULT \(variant) \(mode) CPU \(measuredCPU) errors \(errors)")
    mouse(.mouseMoved, at: savedPointer)
    if !errors.isEmpty { exit(2) }
    NSApp.terminate(nil)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
Task { @MainActor in do { try await run() } catch { print("FAILED", error); exit(1) } }
app.run()
