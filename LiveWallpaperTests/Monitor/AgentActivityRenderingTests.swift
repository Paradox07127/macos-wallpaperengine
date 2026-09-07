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
        // Exercise the full row budget with additional hidden sessions, as on a
        // busy desktop; a four-session fixture cannot reveal footer overflow.
        for index in 4 ..< 53 {
            var session = sessions[3]
            session.id = "fixture-\(index)"
            sessions.append(session)
        }
        let snapshot = MonitorSnapshot(timestamp: now, agents: sessions)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AgentActivityVisualQA", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (size, factor, suffix) in [(MonitorWidgetSize.medium, 1.0, "m"), (.large, 1.0, "l"),
                                       (.large, 0.85, "l-small"), (.large, 1.5, "l-scaled")] {
            let geometry = MonitorBoardGeometry(boardSize: CGSize(width: 1440, height: 900), referenceWidth: 1440 / factor)
            let tile = geometry.renderRect(forRawRect: CGRect(origin: .zero, size: geometry.pixelSize(for: .fleet, size: size))).size
            let context = MonitorWidgetContext(snapshot: snapshot, history: MonitorHistorySnapshot(),
                                               placement: MonitorWidgetPlacement(kind: .fleet, size: size), isEditing: false,
                                               reduceMotion: true, now: Date(timeIntervalSince1970: now))
            let content = AgentSessionWidgetView(context: context).frame(width: tile.width, height: tile.height)
                .padding(16).background(Design.boardWash)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(abs(Double(image.width) - (tile.width + 32) * 2) <= 1)
            #expect(abs(Double(image.height) - (tile.height + 32) * 2) <= 1)
            try write(image, to: folder.appendingPathComponent("widget-\(suffix).png"))
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
