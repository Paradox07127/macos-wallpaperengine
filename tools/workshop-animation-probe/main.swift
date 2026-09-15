import AppKit
import SwiftUI
import Observation
import LiveWallpaperCore
import Darwin
import QuartzCore

func arg(_ name: String, _ fallback: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: "--" + name), i + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[i + 1]
}
@MainActor enum AnimationMetrics {
    static var bodyEvaluations = 0
    static var frames = 0
    static var frameTimes: [String: [Double]] = [:]
}
actor ProbeAssets {
    static let shared = ProbeAssets()
    var source: URL?
    func configure(_ url: URL) { source = url }
    func fetch() -> Data? { source.flatMap { try? Data(contentsOf: $0) } }
}
@MainActor func makeProbeLoader() -> WorkshopPreviewImageLoader {
    let fetch: WorkshopPreviewByteFetch = { _ in await ProbeAssets.shared.fetch() }
    let cache = URL(fileURLWithPath: arg("cache", "/private/tmp/lw-animation-probe-cache"))
    return WorkshopPreviewImageLoader(diskCache: WorkshopPreviewDiskCache(directoryURL: cache), fetch: fetch)
}
@MainActor @Observable final class Model {
    var active = false
    var presented = true
}
struct Root: View {
    let model: Model
    let mode: String
    let source: URL
    let count: Int
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(200)), count: 4), spacing: 8) {
            ForEach(0 ..< count, id: \.self) { i in
                if mode == "online" {
                    AnimatedGIFThumbnail(url: URL(string: "https://steamuserimages-a.akamaihd.net/ugc/probe-\(i).gif"), playbackMode: model.active ? .autoPlay : .hoverToPlay, previewSize: .tile)
                        .frame(width: 200, height: 200)
                        .environment(\.inspectorContentIsVisible, model.presented)
                } else {
                    WPEPreviewView(imageURL: source, playbackMode: model.active ? .autoPlay : .staticPoster, previewSize: .tile)
                        .frame(width: 200, height: 200)
                        .environment(\.inspectorContentIsVisible, model.presented)
                }
            }
        }.padding(12)
    }
}
func cpuSeconds() -> Double {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
}
@MainActor func run() async throws {
    let source = URL(fileURLWithPath: arg("gif", "/Users/taijial/Library/Application Support/Steam/steamapps/workshop/content/431960/2370927443/preview.gif"))
    await ProbeAssets.shared.configure(source)
    let mode = arg("mode", "online"), count = Int(arg("count", "1"))!
    let model = Model()
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 850, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: Root(model: model, mode: mode, source: source, count: count))
    window.contentView = host; window.title = "Gallery Probe – GIF " + mode
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .seconds(2))
    var results: [[String: Any]] = []
    for phase in ["static", "playing", "hidden-host", "resumed"] {
        model.active = phase != "static"
        model.presented = phase != "hidden-host"
        try await Task.sleep(for: .milliseconds(250))
        AnimationMetrics.bodyEvaluations = 0; AnimationMetrics.frames = 0; AnimationMetrics.frameTimes = [:]
        let cpu = cpuSeconds(), start = CACurrentMediaTime(), thermal = ProcessInfo.processInfo.thermalState.rawValue
        var gaps: [Double] = []
        while CACurrentMediaTime() - start < Double(arg("seconds", "3"))! {
            let t = CACurrentMediaTime(); try await Task.sleep(for: .milliseconds(16)); gaps.append((CACurrentMediaTime() - t) * 1000)
        }
        results.append(["phase": phase, "seconds": CACurrentMediaTime() - start, "cpuSeconds": cpuSeconds() - cpu, "bodyEvaluations": AnimationMetrics.bodyEvaluations, "frames": AnimationMetrics.frames, "frameTimes": AnimationMetrics.frameTimes, "mainActorGapMs": gaps, "thermalBefore": thermal, "thermalAfter": ProcessInfo.processInfo.thermalState.rawValue])
    }
    try JSONSerialization.data(withJSONObject: ["mode": mode, "count": count, "source": source.path, "results": results], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: arg("output", "/private/tmp/animation.json")))
    print(results.map { ["phase": $0["phase"]!, "bodies": $0["bodyEvaluations"]!, "frames": $0["frames"]!] })
    NSApp.terminate(nil)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
Task { @MainActor in do { try await run() } catch { print(error); exit(1) } }
app.run()
