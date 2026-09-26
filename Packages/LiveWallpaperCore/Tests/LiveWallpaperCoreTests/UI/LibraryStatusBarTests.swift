import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Library status bar rule")
@MainActor
struct LibraryStatusBarTests {
    private static let width = 400
    private static let height = 40

    /// How far the bar's top row stands out from a row inside its top padding (sum of |ΔR|+|ΔG|+|ΔB|,
    /// averaged over the bar's left end, clear of the centred count).
    private static func topRowContrast(windowPaintsCanvas: Bool, colorScheme: ColorScheme) throws -> Double {
        let content = ZStack(alignment: .top) {
            Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
            LibraryStatusBar(summary: Text(verbatim: "12 items"))
        }
        .frame(width: CGFloat(width), height: CGFloat(height))
        .environment(\.windowPaintsCanvas, windowPaintsCanvas)
        .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the renderer produced no image")
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        /// `y` counts from the image's top: the context's first row in memory is its top row.
        func channel(_ x: Int, _ y: Int, _ c: Int) -> Double {
            Double(pixels[(y * width + x) * 4 + c])
        }
        let columns = 0 ..< 60
        let total = columns.reduce(0.0) { sum, x in
            sum + (0 ..< 3).reduce(0.0) { $0 + abs(channel(x, 0, $1) - channel(x, 3, $1)) }
        }
        return total / Double(columns.count)
    }

    @Test("The rule above the count is drawn only outside a canvas-painting window", arguments: [ColorScheme.light, .dark])
    func ruleFollowsTheCanvas(colorScheme: ColorScheme) throws {
        let oldWindow = try Self.topRowContrast(windowPaintsCanvas: false, colorScheme: colorScheme)
        #expect(oldWindow > 10, "control: the old window's status bar shows no rule above the count (\(oldWindow))")
        let editDesk = try Self.topRowContrast(windowPaintsCanvas: true, colorScheme: colorScheme)
        #expect(editDesk < 3, "the Edit Desk's status bar still draws a rule above the count (\(editDesk))")
    }
}
