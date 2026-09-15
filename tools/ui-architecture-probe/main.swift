import AppKit
import Darwin
import LiveWallpaperCore
import os
import QuartzCore
import SwiftUI

enum ProbeConfig {
    static let args = CommandLine.arguments
    static func arg(_ key: String, _ fallback: String) -> String {
        guard let i = args.firstIndex(of: "--" + key), i + 1 < args.count else { return fallback }; return args[i + 1]
    }

    static let mode = arg("mode", "scene")
    static let variant = arg("variant", "current")
    static let cacheURL = URL(fileURLWithPath: arg("cache", "/private/tmp/lw-ui-probe-cache"))
    static let corpusURL = URL(fileURLWithPath: arg("corpus", "/Users/taijial/Library/Application Support/Steam/steamapps/workshop/content/431960"))
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
    return WorkshopPreviewImageLoader(diskCache: WorkshopPreviewDiskCache(directoryURL: ProbeConfig.cacheURL), fetch: fetch)
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

@MainActor func runProbe() async throws {
    let model = ProbeModel()
    let mode = ProbeConfig.mode; let variant = ProbeConfig.variant
    let allowedVariants = mode == "scene" ? ["current", "100", "200", "500", "1000", "continuous", "native", "quantized"] : ["current", "collection"]
    guard ["scene", "grid", "installed"].contains(mode), allowedVariants.contains(variant) else {
        throw NSError(domain: "UIProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown mode or variant"])
    }
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    let lang = ProbeConfig.arg("language", "en")
    UserDefaults.standard.setVolatileDomain([AppLanguagePreference.storageKey: lang], forName: UserDefaults.argumentDomain)
    var schema = WallpaperEngineProjectPropertySchema(properties: [])
    var dataInfo: [String: Any] = [:]
    if mode == "scene" {
        let scene = ProbeConfig.arg("scene", "3351072238")
        let url = ProbeConfig.corpusURL.appendingPathComponent(scene + "/project.json")
        let start = CACurrentMediaTime()
        schema = try WallpaperEngineProjectPropertySchema.parse(data: Data(contentsOf: url), preferredLanguages: [lang])
        model.values = schema.defaultValues
        let presentation = WPEProjectSettingsPresentation(schema: schema, overrides: [:], excludedKeys: ["schemecolor"])
        model.expanded = Set(presentation.sections.map(\.id))
        let properties = presentation.sections.flatMap(\.properties)
        dataInfo = ["scene": scene, "project": url.path, "properties": properties.count, "sliders": properties.filter { $0.type == .slider }.count, "sections": presentation.sections.count, "parsePresentationMs": (CACurrentMediaTime() - start) * 1000]
    } else {
        let folders = try FileManager.default.contentsOfDirectory(at: ProbeConfig.corpusURL, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var files: [String: URL] = [:]
        var sourceItems: [WorkshopQueryItem] = []
        var sourceEntries: [UInt64: WPEHistoryEntry] = [:]
        for folder in folders {
            guard let id = UInt64(folder.lastPathComponent), let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let preview = folder.appendingPathComponent(json["preview"] as? String ?? "preview.jpg")
            let key = String(id) + "." + preview.pathExtension
            let exists = FileManager.default.fileExists(atPath: preview.path)
            if exists {
                files[key] = preview
            }
            var tags = json["tags"] as? [String] ?? []
            tags.append(json["type"] as? String ?? "scene")
            if mode == "installed" {
                let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                let origin = WPEOrigin(workshopID: String(id), title: json["title"] as? String ?? String(id), originalType: WPEType(rawValue: (json["type"] as? String ?? "unknown").lowercased()) ?? .unknown, sourceFolderBookmark: bookmark, cacheRelativePath: nil, previewFileName: json["preview"] as? String, entryFile: json["file"] as? String)
                sourceEntries[id] = WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: 0))
            }
            sourceItems.append(WorkshopQueryItem(id: id, rawTitle: json["title"] as? String, shortDescription: "", creatorID: nil, previewImageURL: exists ? URL(string: "https://steamuserimages-a.akamaihd.net/ugc/" + key) : nil, fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil, rating: nil, tags: tags, visibility: .public, isBanned: false, steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!))
        }
        guard !sourceItems.isEmpty else { throw NSError(domain: "UIProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "No project.json corpus entries found"]) }
        await ProbeAssets.shared.register(files)
        let count = Int(ProbeConfig.arg("count", "0")) ?? 0
        model.items = count == 0 ? sourceItems : (0 ..< count).map { i in
            let s = sourceItems[i % sourceItems.count]
            return WorkshopQueryItem(id: UInt64(i + 1), rawTitle: s.rawTitle, shortDescription: s.shortDescription, creatorID: nil, previewImageURL: s.previewImageURL, fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil, rating: nil, tags: s.tags, visibility: s.visibility, isBanned: false, steamCommunityURL: s.steamCommunityURL)
        }
        if mode == "installed" {
            for (index, item) in model.items.enumerated() {
                model.installed[item.id] = sourceEntries[sourceItems[index % sourceItems.count].id]
            }
        }
        dataInfo = ["realItems": sourceItems.count, "items": model.items.count, "previewFiles": files.count, "gifFiles": files.values.filter { $0.pathExtension.lowercased() == "gif" }.count, "expandedByCyclingRealItems": count > sourceItems.count, "uniquePreviewURLs": Set(model.items.compactMap(\.previewImageURL)).count]
    }
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: mode == "scene" ? 520 : 900, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.ignoresMouseEvents = !["hover", "idle"].contains(ProbeConfig.arg("operation", "scroll"))
    window.title = "Loomscreen UI Probe — \(mode) / \(variant)"
    window.isReleasedWhenClosed = false
    var collection: CollectionHost?
    let openStart = CACurrentMediaTime()
    if mode != "scene", variant == "collection" {
        let c = CollectionHost(model: model, reduceMotion: reduce); collection = c; window.contentView = c.scroll
    } else {
        let content: AnyView = mode == "scene" ? AnyView(SceneProbeView(model: model, schema: schema, variant: variant)) : AnyView(GridProbeView(model: model, reduceMotion: reduce))
        let host = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: lang)))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: mode == "scene" ? 520 : 900, height: 760)
        window.contentView = host
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.contentView!.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    let firstLayout = (CACurrentMediaTime() - openStart) * 1000
    try await Task.sleep(for: .seconds(Double(ProbeConfig.arg("warmup", "2")) ?? 2))
    var scroll: NSScrollView! = allViews(window.contentView!).compactMap { $0 as? NSScrollView }.first
    guard scroll != nil else { fatalError("Missing scroll host") }
    guard (scroll.documentView?.frame.width ?? 0) > 100 else { fatalError("Invalid probe geometry") }
    if let outputIndex = ProbeConfig.args.firstIndex(of: "--screenshot"), outputIndex + 1 < ProbeConfig.args.count,
       let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ProbeConfig.args[outputIndex + 1]))
    }
    let steps = ProbeConfig.arg("operation", "scroll") == "state-sequence" ? 0 : (Int(ProbeConfig.arg("steps", "300")) ?? 300)
    let operation = ProbeConfig.arg("operation", "scroll")
    let originalItems = model.items
    let sliders = WPEProjectSettingsPresentation(schema: schema, overrides: model.values, excludedKeys: ["schemecolor"]).sections.flatMap(\.properties).filter { $0.type == .slider }
    var samples: [Double] = []; var intervals: [Double] = []; var positions: [Double] = []
    let cpuStart = usage().0; let wallStart = CACurrentMediaTime(); var last = wallStart
    let rssBefore = resident(); var peak = rssBefore
    let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
    let signposter = OSSignposter(subsystem: "com.loomscreen.ui-probe", category: "UIProbe")
    var statePhases: [[String: Any]] = []
    if operation == "state-sequence" {
        statePhases = try await runSceneStateSequence(window: window, scroll: scroll, model: model, schema: schema)
        samples = statePhases.flatMap { $0["samples"] as? [Double] ?? [] }
        peak = statePhases.compactMap { $0["rssPeakSampled"] as? UInt64 }.max() ?? peak
    }
    for i in 0 ..< steps {
        let begin = CACurrentMediaTime(); intervals.append((begin - last) * 1000); last = begin
        let sign = signposter.beginInterval("layout-display")
        autoreleasepool {
            let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height)
            let fraction = Double(i % 100) / 99
            let y = maxY * (i / 100 % 2 == 0 ? fraction : 1 - fraction)
            switch operation {
            case "idle": break
            case "resize": window.setContentSize(NSSize(width: (mode == "scene" ? 520 : 900) + (i % 40 < 20 ? 80 : 0), height: 760)); collection?.collection.collectionViewLayout?.invalidateLayout()
            case "filter": model.items = i % 2 == 0 ? originalItems.filter { $0.id % 2 == 0 } : originalItems; collection?.reload()
            case "select": if !model.items.isEmpty {
                    let id = model.items[i % model.items.count].id; if let collection {
                        collection.select(id)
                    } else {
                        model.selected = id
                    }
                }
            case "edit": if let p = sliders.first {
                    let r = PropertyValueLogic.sliderRange(for: p); model.binding(p).wrappedValue = r.lowerBound + (r.upperBound - r.lowerBound) * fraction
                }
            case "collapse": let sections = WPEProjectSettingsPresentation(schema: schema, overrides: model.values).sections; model.expanded = i % 2 == 0 ? [] : Set(sections.map(\.id))
            default: scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            }
            window.contentView!.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            positions.append(scroll.contentView.bounds.origin.y)
        }
        signposter.endInterval("layout-display", sign)
        samples.append((CACurrentMediaTime() - begin) * 1000); peak = max(peak, resident())
        try await Task.sleep(for: .milliseconds(16))
    }
    let cpuEnd = usage(); let wall = CACurrentMediaTime() - wallStart
    let rssAfter = resident()
    let finalSize = scroll.documentView?.frame.size ?? .zero
    let nativeCount = allViews(window.contentView!).filter { $0 is NSSlider }.count
    window.contentView = nil; window.close(); collection = nil; scroll = nil
    LocalImageCacheRegistry.shared.purgeAll()
    try await Task.sleep(for: .seconds(2))
    var result: [String: Any] = await ["mode": mode, "variant": variant, "operation": operation, "samples": samples, "sampleCount": samples.count, "layoutDisplayMs": ["p50": quantile(samples, 0.5), "p95": quantile(samples, 0.95), "p99": quantile(samples, 0.99)], "timerIntervalsMs": intervals, "over16_67msLayoutSamples": samples.filter { $0 > 1000 / 60 }.count, "hitches": NSNull(), "cpuSeconds": cpuEnd.0 - cpuStart, "wallSeconds": wall, "firstLayoutMs": firstLayout, "rssBefore": rssBefore, "rssPeakSampled": peak, "rssAfter": rssAfter, "rssAfterClosePurge": resident(), "maxRssProcess": cpuEnd.1, "thermalStart": thermalStart, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue, "os": ProcessInfo.processInfo.operatingSystemVersionString, "pid": ProcessInfo.processInfo.processIdentifier, "nativeSlidersMaterialized": nativeCount, "docWidth": finalSize.width, "docHeight": finalSize.height, "positions": positions, "data": dataInfo, "language": lang, "reduceMotion": reduce, "reduceTransparency": reduceTransparency, "configurationTouched": false, "renderSessionIncluded": false, "pointerPolicy": "ignored except hover scenario", "imageCache": WPEImageCacheMeter.shared.report() ?? "none", "fetchRequests": ProbeAssets.shared.requests, "fetchBytes": ProbeAssets.shared.bytes, "screen": NSScreen.main.map { ["width": $0.frame.width, "height": $0.frame.height, "scale": $0.backingScaleFactor, "maximumFPS": Double($0.maximumFramesPerSecond)] } ?? [:]]
    result["statePhases"] = statePhases
    result["timestamp"] = ISO8601DateFormatter().string(from: Date())
    let output = ProbeConfig.arg("output", "/private/tmp/ui-probe-result.json")
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    print("RESULT \(output) p50=\(quantile(samples, 0.5)) p95=\(quantile(samples, 0.95)) count=\(samples.count)")
    NSApp.terminate(nil)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
Task { @MainActor in
    do { try await runProbe() } catch { print("Probe failed: \(error)"); exit(1) }
}

app.run()
