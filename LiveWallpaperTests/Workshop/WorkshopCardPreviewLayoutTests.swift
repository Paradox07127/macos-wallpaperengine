#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import SwiftUI
import Testing

@MainActor
@Suite("Workshop card preview bounds", .serialized)
struct WorkshopCardPreviewLayoutTests {
    private final class Probe {
        var size: CGSize?
    }

    @Test(arguments: [CGSize(width: 40, height: 4000), CGSize(width: 4000, height: 40), CGSize(width: 4000, height: 4000)])
    func largeArtworkCannotEnlargeSquare(sourceSize: CGSize) async throws {
        let image = NSImage(size: sourceSize)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 255, count: 16)
        image.addRepresentation(bitmap)
        let probe = Probe()
        let root = ScrollView {
            LazyVGrid(columns: [GridItem(.fixed(186))]) {
                WorkshopCardPreview {
                    Image(nsImage: image).resizable().scaledToFill()
                }
                .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { probe.size = $0 })
            }
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(2)
        while probe.size == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        let size = try #require(probe.size)
        #expect(abs(size.width - 186) < 0.5)
        #expect(abs(size.height - 186) < 0.5)
    }
}
#endif
