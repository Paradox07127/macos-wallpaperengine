import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Content-column background")
@MainActor
struct PageBackgroundTests {
    /// The centre pixel of a 20pt square that paints the content-column background over magenta.
    private static func centre() throws -> (r: Int, g: Int, b: Int) {
        let content = ZStack {
            Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
            Color.clear.frame(width: 20, height: 20).contentColumnBackground()
        }
        .frame(width: 20, height: 20)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the renderer produced no image")
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -10, y: -10, width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    @Test("A content column stays solid over the window canvas")
    func contentColumnStaysSolid() throws {
        let pixel = try Self.centre()
        #expect(!(pixel.r > 235 && pixel.g < 25 && pixel.b > 235), "the content column let the canvas through: \(pixel)")
    }
}
