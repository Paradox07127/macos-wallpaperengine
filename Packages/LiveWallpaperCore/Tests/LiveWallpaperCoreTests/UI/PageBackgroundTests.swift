import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Page and content-column backgrounds")
@MainActor
struct PageBackgroundTests {
    private enum Fill {
        case page, contentColumn
    }

    /// The centre pixel of a 20pt square that paints `fill` over magenta.
    private static func centre(_ fill: Fill, windowPaintsCanvas: Bool) throws -> (r: Int, g: Int, b: Int) {
        let square = Color.clear.frame(width: 20, height: 20)
        let content = ZStack {
            Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
            switch fill {
            case .page: square.pageBackground()
            case .contentColumn: square.contentColumnBackground()
            }
        }
        .frame(width: 20, height: 20)
        .environment(\.windowPaintsCanvas, windowPaintsCanvas)
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

    private static func isMagenta(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
        pixel.r > 235 && pixel.g < 25 && pixel.b > 235
    }

    @Test("A page paints its own background outside a canvas-painting window")
    func pagePaintsByDefault() throws {
        let pixel = try Self.centre(.page, windowPaintsCanvas: false)
        #expect(!Self.isMagenta(pixel), "the page left its background clear in a window that paints none: \(pixel)")
    }

    @Test("A page stays clear where the window root paints the canvas")
    func pageLeavesTheWindowCanvasShowing() throws {
        let pixel = try Self.centre(.page, windowPaintsCanvas: true)
        #expect(Self.isMagenta(pixel), "the page painted over the window's canvas: \(pixel)")
    }

    @Test("A content column stays solid in both windows", arguments: [false, true])
    func contentColumnStaysSolid(windowPaintsCanvas: Bool) throws {
        let pixel = try Self.centre(.contentColumn, windowPaintsCanvas: windowPaintsCanvas)
        #expect(!Self.isMagenta(pixel), "the content column let the canvas through: \(pixel)")
    }
}
