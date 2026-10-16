import AppKit
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Persistent desktop picture regression", .serialized)
@MainActor
struct DesktopPicturePersistenceRegressionTests {
    @Test("Refreshing the same display installs a new persistent PNG URL")
    func refreshUsesPersistentUniqueURLs() async throws {
        let screen = try #require(NSScreen.screens.first)
        let screenID = CGDirectDisplayID.random(in: 0xF000_0000 ... 0xFFFF_FFFE)
        var installed: [URL] = []
        defer {
            for url in installed {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let context = try #require(CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        for _ in 0 ..< 2 {
            let result = await DesktopPictureFrameExtractor.applyFrame(
                { image }, screenID: screenID, nsScreen: screen,
                install: { url, _ in installed.append(url) }
            )
            #expect(result == .captured)
        }
        #expect(Set(installed).count == 2, "Each refresh must have a fresh URL to bypass macOS image caching")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWallpaper/DesktopPictures", isDirectory: true)
        #expect(installed.allSatisfy { $0.deletingLastPathComponent() == support }, "Installed images must outlive temporary-directory cleanup")
    }
}
