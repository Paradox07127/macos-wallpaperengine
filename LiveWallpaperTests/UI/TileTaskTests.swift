import AppKit
import Foundation
@testable import LiveWallpaper
import Observation
import SwiftUI
import Testing

@MainActor
@Suite("Tile task", .serialized)
struct TileTaskTests {
    @Observable
    final class RunLog {
        var runs: [Int] = []
        var completed: [Int] = []
    }

    private struct ProbeTile: View {
        let index: Int
        let log: RunLog
        let guarded: Bool
        let holdMilliseconds: Int

        var body: some View {
            let tile = Color.blue.frame(height: 90)
            if guarded {
                tile.tileTask(id: index) { await load() }
            } else {
                tile.task(id: index) { await load() }
            }
        }

        private func load() async {
            log.runs.append(index)
            try? await Task.sleep(for: .milliseconds(holdMilliseconds))
            if !Task.isCancelled {
                log.completed.append(index)
            }
        }
    }

    private struct ProbeGrid: View {
        let log: RunLog
        let guarded: Bool
        let holdMilliseconds: Int

        var body: some View {
            ScrollView {
                LazyVGrid(columns: [GridItem(.fixed(90)), GridItem(.fixed(90))], spacing: 10) {
                    ForEach(0 ..< 16, id: \.self) { index in
                        ProbeTile(index: index, log: log, guarded: guarded, holdMilliseconds: holdMilliseconds)
                    }
                }
            }
            .frame(width: 200, height: 200)
        }
    }

    @MainActor
    private final class Harness {
        let log = RunLog()
        let window: NSWindow
        let host: NSHostingView<ProbeGrid>

        init(guarded: Bool, holdMilliseconds: Int = 0) {
            host = NSHostingView(rootView: ProbeGrid(log: log, guarded: guarded, holdMilliseconds: holdMilliseconds))
            host.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
        }

        func close() {
            window.close()
        }

        func runs(of index: Int) -> Int {
            log.runs.filter { $0 == index }.count
        }

        private var scroll: NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView {
                    return scroll
                }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(host)
        }

        /// Fraction of the scrollable height; 1 puts the last row on screen.
        func scroll(to fraction: CGFloat) async throws {
            let scroll = try #require(self.scroll)
            let maxY = (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height
            #expect(maxY > 300, "The probe grid must extend several viewports past the first row")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    private static func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Control: a plain task(id:) re-runs when the tile scrolls back into view")
    func plainTaskRerunsOnReappearance() async throws {
        let harness = Harness(guarded: false)
        defer { harness.close() }
        await Self.waitUntil { harness.runs(of: 0) == 1 }
        try await harness.scroll(to: 1)
        try await harness.scroll(to: 0)
        await Self.waitUntil { harness.runs(of: 0) >= 2 }
        #expect(harness.runs(of: 0) >= 2, "The harness must observe SwiftUI's re-run, or the guarded test proves nothing")
    }

    @Test("tileTask runs once per id across scrolling away and back")
    func tileTaskRunsOncePerID() async throws {
        let harness = Harness(guarded: true)
        defer { harness.close() }
        await Self.waitUntil { harness.runs(of: 0) == 1 }
        try await harness.scroll(to: 1)
        try await harness.scroll(to: 0)
        try await harness.scroll(to: 1)
        try await harness.scroll(to: 0)
        #expect(harness.runs(of: 0) == 1)
        #expect(harness.runs(of: 15) == 1)
        #expect(Set(harness.log.runs).count == harness.log.runs.count, "No tile may load twice")
    }

    @Test("A load cancelled by scrolling away runs again on the next appearance")
    func cancelledLoadRunsAgain() async throws {
        let harness = Harness(guarded: true, holdMilliseconds: 800)
        defer { harness.close() }
        await Self.waitUntil { harness.log.completed.contains(0) }
        try await harness.scroll(to: 1)
        await Self.waitUntil { harness.runs(of: 15) == 1 }
        // Back before the 800 ms hold elapses: the bottom row's loads are cancelled.
        try await harness.scroll(to: 0)
        #expect(!harness.log.completed.contains(15))
        try await harness.scroll(to: 1)
        await Self.waitUntil { harness.runs(of: 15) == 2 }
        #expect(harness.runs(of: 15) == 2)
        #expect(harness.runs(of: 0) == 1, "A load that completed must not be repeated")
    }

    /// Every gallery tile that clears its artwork before an async reload.
    private static let tiles = [
        "LiveWallpaper/Views/Aerials/ThumbnailCard.swift",
        "LiveWallpaper/Views/Bookmarks/LibraryView.swift",
        "LiveWallpaper/Views/Schemes/SchemeLibraryView.swift",
        "LiveWallpaper/Views/SystemWallpaper/SystemWallpaperLibraryView.swift",
        "LiveWallpaper/Views/SystemWallpaper/SystemWallpaperCandidate.swift",
    ]

    @Test("Gallery tiles load through tileTask, never a bare task(id:)")
    func galleryTilesUseTileTask() throws {
        for path in Self.tiles {
            let source = try RepositoryRoot.source(path)
            let guarded = source.contains(".tileTask(id:")
            let bare = source.contains(".task(id:")
            #expect(guarded, Comment(rawValue: "\(path) does not load through tileTask"))
            #expect(!bare, Comment(rawValue: "\(path) still has a task(id:) that re-runs on re-appearance"))
        }
    }
}
