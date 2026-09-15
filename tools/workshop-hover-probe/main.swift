import AppKit
import Darwin
import LiveWallpaperCore
import Observation
import QuartzCore
import SwiftUI

func arg(_ key: String, _ fallback: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: "--" + key), i + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[i + 1]
}

@MainActor enum AnimationMetrics {
    static var cardBodies = 0
    static var frames = 0
    static var hoverTransitions = 0
}

extension EnvironmentValues {
    @Entry var probeHovered: Bool = false
}

actor ProbeAssets {
    static let shared = ProbeAssets()
    func fetch() -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: arg("gif", "/Users/taijial/Library/Application Support/Steam/steamapps/workshop/content/431960/2370927443/preview.gif")))
    }
}

@MainActor func makeProbeLoader() -> WorkshopPreviewImageLoader {
    let fetch: WorkshopPreviewByteFetch = { _ in await ProbeAssets.shared.fetch() }
    return WorkshopPreviewImageLoader(diskCache: WorkshopPreviewDiskCache(directoryURL: URL(fileURLWithPath: arg("cache", "/private/tmp/lw-hover-probe-cache"))), fetch: fetch)
}

@MainActor @Observable final class Model { var hovered = false }
struct Root: View {
    let model: Model
    let item: WorkshopQueryItem
    let entry: WPEHistoryEntry
    let mode: String
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(200)), count: 4), spacing: 12) {
            ForEach(0 ..< 8) { i in
                Group {
                    if mode == "online" {
                        BrowseCard(item: item, cardPreferences: GalleryCardPreferences(), reduceMotion: false)
                    } else {
                        HistoryRow(entry: entry, isActive: false, onRemove: {}, onBookmark: {})
                    }
                }
                .frame(width: 200, height: 200)
                .environment(\.probeHovered, i == 0 && model.hovered)
                .environment(\.inspectorContentIsVisible, arg("playback", "true") == "true")
            }
        }.padding(16)
    }
}

func cpu() -> Double {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
}

@MainActor func run() async throws {
    let gif = URL(fileURLWithPath: arg("gif", "/Users/taijial/Library/Application Support/Steam/steamapps/workshop/content/431960/2370927443/preview.gif"))
    let bookmark = try gif.deletingLastPathComponent().bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    let title = "Lofi Cafe — A long Workshop scene title that expands into a second line"
    let item = WorkshopQueryItem(id: 2_370_927_443, rawTitle: title, shortDescription: "", creatorID: nil, previewImageURL: URL(string: "https://steamuserimages-a.akamaihd.net/ugc/hover.gif"), fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil, rating: nil, tags: ["scene"], visibility: .public, isBanned: false, steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=2370927443")!)
    let entry = WPEHistoryEntry(origin: WPEOrigin(workshopID: "2370927443", title: title, originalType: .scene, sourceFolderBookmark: bookmark, cacheRelativePath: nil, previewFileName: gif.lastPathComponent), importedAt: Date(timeIntervalSince1970: 0))
    let mode = arg("mode", "installed"), model = Model()
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 860, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: Root(model: model, item: item, entry: entry, mode: mode))
    host.sizingOptions = []; window.contentView = host; window.title = "Workshop Hover Probe"
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .seconds(2))
    var samples: [Double] = [], gaps: [Double] = []
    AnimationMetrics.cardBodies = 0; AnimationMetrics.frames = 0; AnimationMetrics.hoverTransitions = 0
    let start = CACurrentMediaTime(), cpuStart = cpu(), thermal = ProcessInfo.processInfo.thermalState.rawValue
    var last = start
    for step in 0 ..< 360 {
        let begin = CACurrentMediaTime(); gaps.append((begin - last) * 1000); last = begin
        if step % 20 == 0 {
            model.hovered.toggle()
        }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        samples.append((CACurrentMediaTime() - begin) * 1000)
        try await Task.sleep(for: .milliseconds(16))
    }
    let result: [String: Any] = ["mode": mode, "playback": arg("playback", "true"), "samples": samples, "gaps": gaps, "cpuSeconds": cpu() - cpuStart, "seconds": CACurrentMediaTime() - start, "frames": AnimationMetrics.frames, "cardBodies": AnimationMetrics.cardBodies, "hoverTransitions": AnimationMetrics.hoverTransitions, "thermalStart": thermal, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue, "input": "controlled settled-hover state; no physical pointer or scroll"]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg("output", "/private/tmp/hover.json")))
    print("transitions", AnimationMetrics.hoverTransitions, "frames", AnimationMetrics.frames)
    window.contentView = nil; window.close(); NSApp.terminate(nil)
}

let app = NSApplication.shared; app.setActivationPolicy(.regular)
Task { @MainActor in do { try await run() } catch { print(error); exit(1) } }
app.run()
