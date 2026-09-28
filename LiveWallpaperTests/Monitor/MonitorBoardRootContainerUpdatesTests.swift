import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Monitor root forwards live models", .serialized)
@MainActor
struct MonitorBoardRootContainerUpdatesTests {
    @Test("The mounted child receives data without a root replacement, history update or clock tick")
    func liveDataReachesTheMountedChild() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try #require(fixture.hasReadableCPU)
        let zero = try await fixture.capture()
        let zeroControl = try await fixture.capture()
        #expect(zero == zeroControl, "control: an unchanged suspended board must render identically")
        let history = fixture.data.historyStore.current

        // Fixed measurement time prevents a history publication from rescuing a lost data subscription.
        fixture.data.update(Self.snapshot(cpu: 0.9))
        #expect(fixture.data.historyStore.current == history)
        let ninety = try await fixture.capture()
        #expect(ninety != zero, "the actual CPU child did not change from 0% to 90%")
        let ninetyControl = try await fixture.capture()
        #expect(ninety == ninetyControl, "control: the 90% reading must settle to a stable image")

        fixture.data.update(Self.snapshot(cpu: 0.1))
        #expect(fixture.data.historyStore.current == history)
        let ten = try await fixture.capture()
        #expect(ten != ninety && ten != zero, "the actual CPU child did not render a distinct 10% reading")

        fixture.data.update(Self.snapshot(cpu: 0))
        #expect(fixture.data.historyStore.current == history)
        let restored = try await fixture.capture()
        #expect(zero == restored, "returning to 0% must restore the same pixels, not an unrelated redraw")
    }

    @Test("The mounted board receives placement changes and geometry proposals without a root replacement")
    func liveLayoutReachesTheMountedChild() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let shown = try await fixture.capture()
        #expect(fixture.model.boardSize == Fixture.initialSize)
        let shownControl = try await fixture.capture()
        #expect(shown == shownControl, "control: no changing layout or animation before the edit")

        var hidden = fixture.placement
        hidden.isHidden = true
        fixture.model.apply(configuration: MonitorBoardConfiguration(widgets: [hidden]))
        let removed = try await fixture.capture()
        #expect(removed != shown, "the same hosted board did not hide the widget")
        let removedControl = try await fixture.capture()
        #expect(removed == removedControl, "control: the empty board must remain stable")

        fixture.model.apply(configuration: MonitorBoardConfiguration(widgets: [fixture.placement]))
        let restored = try await fixture.capture()
        #expect(shown == restored, "showing the same widget must restore the same image")

        let resized = CGSize(width: 1000, height: 700)
        fixture.resize(to: resized)
        _ = try await fixture.capture()
        #expect(fixture.model.boardSize == resized, "GeometryReader must report the new proposal without root replacement")
    }

    private static func snapshot(cpu: Double) -> MonitorSnapshot {
        MonitorSnapshot(
            timestamp: 1_700_000_000,
            system: MonitorSystemSnapshot(cpuTotal: cpu, perCore: [cpu], sampledAt: 1_700_000_000)
        )
    }

    @MainActor
    private final class Fixture {
        static let initialSize = CGSize(width: 800, height: 600)
        let placement = MonitorWidgetPlacement(
            kind: .cpu, size: .small, x: 0.1, y: 0.2,
            options: ["showTrend": .bool(false), "showSensors": .bool(false)]
        )
        let model: InteractionModel
        let data = DataModel()
        private let window: ParkedTestWindow
        private let host: NSView

        init() {
            model = InteractionModel(configuration: MonitorBoardConfiguration(widgets: [placement]))
            data.update(MonitorBoardRootContainerUpdatesTests.snapshot(cpu: 0))
            // Like OverlayHiddenWidgetTests.Snapshot: an opaque backing makes cacheDisplay deterministic.
            let hosting = NSHostingView(rootView: MonitorBoardRootContainer(
                model: model, data: data, reduceMotion: true, suspended: true, forcesOpaquePanels: true
            )
            .background(Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)))
            .transaction { $0.disablesAnimations = true })
            hosting.frame = CGRect(origin: .zero, size: Self.initialSize)
            hosting.sizingOptions = []
            hosting.autoresizingMask = [.width, .height]
            host = hosting
            window = ParkedTestWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
                Issue.record("Refusing to order a fixture window that intersects a real display")
                return
            }
            window.parkOffScreen()
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        func resize(to size: CGSize) {
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
        }

        var hasReadableCPU: Bool {
            MonitorWidgetContext(
                snapshot: data.snapshot, history: data.historyStore.current, placement: placement,
                isEditing: false, reduceMotion: true, now: Date()
            ).readingsNotice == nil
        }

        /// Same parked-window/cacheDisplay path and settling interval as OverlayHiddenWidgetTests.Snapshot.cache.
        /// The host and root are never replaced, and the board's periodic timeline is suspended.
        func capture() async throws -> Pixels {
            let deadline = ContinuousClock.now + .milliseconds(700)
            while ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try Pixels(image: #require(bitmap.cgImage))
        }
    }

    /// Canonical initialized sRGB bytes, without bitmap padding or encoded-image metadata.
    /// Equality compares whole images, not chosen colors or a tolerance threshold.
    private struct Pixels: Equatable, CustomStringConvertible {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(image: CGImage) throws {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { raw in
                let context = try #require(CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            self.bytes = bytes
        }

        var description: String {
            "\(width)×\(height) cached sRGB image (\(bytes.count) bytes)"
        }
    }
}
