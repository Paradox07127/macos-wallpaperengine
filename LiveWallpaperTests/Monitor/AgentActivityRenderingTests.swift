import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor @Suite("Agent activity rendering")
struct AgentActivityRenderingTests {
    @Test("M/L widgets and activity panel render representative session states")
    func renderSurfaces() throws {
        let now = 1_800_000_000.0
        var sessions: [MonitorAgentSessionState] = []
        for (index, phase) in [MonitorAgentPhase.waitingForApproval, .executing, .responding, .completed].enumerated() {
            var session = MonitorAgentSessionState(id: "fixture-\(index)", provider: index == 0 ? .codex : .claude,
                                                   projectName: "LiveWallpaper", status: index == 0 ? .needsInput : (index == 3 ? .idle : .running),
                                                   model: "Model", gitBranch: "codex/session-monitor", lastEventAt: now - 3, processAlive: true)
            session.title = ["Review session monitoring", "Optimize extraction", "Audit tool events", "Completed review"][index]
            session.phase = phase
            session.turnStartedAt = now - 138
            session.waitSince = now - 42
            session.recentEventTimes = (0 ..< 20).map { now - Double($0) * 5 }
            session.tokens = .init(input: index == 0 ? 15234 : 1234, output: 5678, cacheRead: 12000)
            if index == 2 {
                session.parentSessionID = "fixture-1"
            }
            session.recentTools = [MonitorAgentToolEvent(name: "shell", at: now - 20, ok: false,
                                                         id: "tool", completedAt: now - 16, durationSeconds: 4)]
            sessions.append(session)
        }
        let snapshot = MonitorSnapshot(timestamp: now, agents: sessions)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentActivityVisualQA", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (size, height) in [(MonitorWidgetSize.medium, 170.0), (.large, 376.0)] {
            let context = MonitorWidgetContext(snapshot: snapshot, history: MonitorHistorySnapshot(),
                                               placement: MonitorWidgetPlacement(kind: .fleet, size: size), isEditing: false,
                                               reduceMotion: true, now: Date(timeIntervalSince1970: now))
            let content = AgentSessionWidgetView(context: context).frame(width: 364, height: height)
                .padding(16).background(Design.boardWash)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == 792)
            try write(image, to: folder.appendingPathComponent("widget-\(size.rawValue).png"))
        }
        let host = NSHostingView(rootView: AgentActivityPanel(snapshot: snapshot, observesLiveSources: false).environment(\.locale, Locale(identifier: "zh-Hans")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 620)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("activity-panel.png"))
        print("Agent activity visual QA: \(folder.path)")
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
