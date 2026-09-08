import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor @Suite("Process application icons")
struct ProcessAppIconTests {
    @Test("App identity comes from the actual PID and absent processes have none")
    func identityUsesPID() {
        #expect(ProcessAppIdentity.bundleID(forPID: NSRunningApplication.current.processIdentifier)
            == NSRunningApplication.current.bundleIdentifier)
        #expect(ProcessAppIdentity.bundleID(forPID: -1) == nil)
    }

    @Test("Repeated redraws reuse icons and negative lookups; unidentified rows do no lookup")
    func cacheBoundsLookups() {
        var lookups = 0
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let cache = ProcessAppIconCache { bundleID in
            lookups += 1
            return bundleID == "fixture.app" ? icon : nil
        }
        for _ in 0 ..< 20 {
            #expect(cache.icon(bundleID: "fixture.app") === icon)
            #expect(cache.icon(bundleID: "fixture.missing") == nil)
            #expect(cache.icon(bundleID: nil) == nil)
        }
        #expect(lookups == 2)
    }

    @Test("Processes render real app icons alongside plain daemon rows at the standard size")
    func renderProcesses() throws {
        #expect(ProcessAppIconCache.shared.icon(bundleID: "not.an.installed.application") == nil)
        _ = try #require(ProcessAppIconCache.shared.icon(bundleID: "com.apple.finder"))
        let samples = [
            MonitorProcessSample(name: "Finder", cpuPercent: 12, memBytes: 100_000_000, pid: 2345, bundleID: "com.apple.finder", processCount: 2, memoryMetric: "footprint"),
            MonitorProcessSample(name: "kernel_task", cpuPercent: 10, memBytes: 200_000_000, pid: 1, memoryMetric: "resident"),
            MonitorProcessSample(name: "Terminal", cpuPercent: 5, memBytes: 30_000_000, pid: 89234, bundleID: "com.apple.Terminal", processCount: 5, memoryMetric: "footprint"),
            MonitorProcessSample(name: "node", cpuPercent: 2, memBytes: 20_000_000, pid: 99081, memoryMetric: "footprint"),
        ]
        for size in [MonitorWidgetSize.medium, .large] {
            let context = MonitorWidgetContext(snapshot: MonitorSnapshot(system: MonitorSystemSnapshot(topProcesses: samples)),
                                               history: MonitorHistorySnapshot(), placement: MonitorWidgetPlacement(kind: .processes, size: size),
                                               isEditing: false, reduceMotion: true, now: Date())
            let content = ProcessesWidgetView(context: context).frame(width: 356, height: size == .large ? 356 : 170)
                .padding(16).background(Design.boardWash)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("process-widget-resources-\(size.rawValue).png")
            try data.write(to: url)
            print("Process icons visual QA: \(url.path)")
        }
    }
}
