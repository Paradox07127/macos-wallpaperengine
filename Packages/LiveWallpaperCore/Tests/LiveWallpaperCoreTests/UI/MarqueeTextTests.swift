import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Multiline title marquee", .serialized)
@MainActor
struct MarqueeTextTests {
    @MainActor
    private final class Model: ObservableObject {
        @Published var active = false
    }

    private struct CardTitle: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText("FIRST LINE\nSECOND LINE\nTHIRD LINE\nFOURTH LINE\nFIFTH LINE",
                            lineLimit: model.active ? 2 : 1, isActive: model.active)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 190)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 210, height: 150, alignment: .topLeading)
            .background(.black)
            .animation(.easeOut(duration: 0.15), value: model.active)
        }
    }

    @MainActor
    private struct Fixture {
        let model = Model()
        let host: NSHostingView<CardTitle>
        let window: NSWindow

        init() {
            _ = NSApplication.shared
            host = NSHostingView(rootView: CardTitle(model: model))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 210, height: 150),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
        }

        func pixels() throws -> [UInt8] {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return pixels
        }
    }

    private static func hasText(_ pixels: [UInt8]) -> Bool {
        stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 200 }.count > 100
    }

    @Test("Expanding to two lines preserves the title during the reading pause, then scrolls")
    func startsAtTopBeforeScrolling() async throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        try await Task.sleep(for: .milliseconds(150))
        fixture.model.active = true
        try await Task.sleep(for: .milliseconds(350))
        let paused = try fixture.pixels()
        let visibleWhilePaused = Self.hasText(paused)
        #expect(visibleWhilePaused, "The title disappeared before its reading pause ended")
        try await Task.sleep(for: .milliseconds(900))
        let scrolling = try fixture.pixels()
        let visibleWhileScrolling = Self.hasText(scrolling)
        let titleMoved = scrolling != paused
        #expect(visibleWhileScrolling, "The first scroll leg left the title window empty")
        #expect(titleMoved, "The overflowing title never began scrolling")
    }

    @Test("Leaving and reentering hover cancels the old scroll and starts at the top")
    func reentryRestartsReadingPause() async throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        try await Task.sleep(for: .milliseconds(150))
        fixture.model.active = true
        try await Task.sleep(for: .milliseconds(350))
        let firstPause = try fixture.pixels()
        try await Task.sleep(for: .milliseconds(900))
        fixture.model.active = false
        try await Task.sleep(for: .milliseconds(200))
        fixture.model.active = true
        try await Task.sleep(for: .milliseconds(350))
        let reentryAtTop = try fixture.pixels() == firstPause
        #expect(reentryAtTop, "A previous scroll offset leaked into the new hover")
    }
}
