import AppKit
import Foundation
@testable import LiveWallpaper
import SwiftUI
import Testing

@MainActor
@Suite("System wallpaper tile geometry", .serialized)
struct SystemWallpaperTileGeometryTests {
    private final class SizeProbe {
        var size: CGSize?
    }

    @Test(arguments: [CGSize(width: 80, height: 80), CGSize(width: 40, height: 80), CGSize(width: 80, height: 45)])
    func loadedArtworkKeepsWideTile(size: CGSize) async throws {
        guard #available(macOS 26.0, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tile-aspect-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.bitmapData?.initialize(repeating: 128, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let data = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try data.write(to: url)
        let image = await SystemWallpaperThumbnails.image(for: url)
        try #require(image != nil)
        let probe = SizeProbe()
        let item = SystemWallpaperManifest.Item(id: UUID().uuidString, title: "Fixture", fileName: "fixture.mp4", addedAt: Date())
        let root = ScrollView {
            LazyVGrid(columns: [GridItem(.fixed(240))]) {
                SystemWallpaperTile(item: item, thumbnailURL: url, videoURL: nil, isInUse: false, onRemove: {})
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.size = $0 }
            }
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        let measured = try #require(probe.size)
        #expect(abs(measured.width - 240) < 0.5)
        #expect(abs(measured.height - 135) < 0.5)
    }
}
