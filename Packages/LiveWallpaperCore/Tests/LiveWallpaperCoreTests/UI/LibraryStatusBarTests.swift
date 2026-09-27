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
    /// averaged over the bar's left end, clear of the centred count). `ruled` puts a `Divider()` above the bar.
    private static func topRowContrast(ruled: Bool, colorScheme: ColorScheme) throws -> Double {
        let content = ZStack(alignment: .top) {
            Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
            VStack(spacing: 0) {
                if ruled {
                    Divider()
                }
                LibraryStatusBar(summary: Text(verbatim: "12 items"))
            }
        }
        .frame(width: CGFloat(width), height: CGFloat(height))
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

    @Test("The status bar draws no rule above the count", arguments: [ColorScheme.light, .dark])
    func noRuleAboveTheCount(colorScheme: ColorScheme) throws {
        let ruled = try Self.topRowContrast(ruled: true, colorScheme: colorScheme)
        #expect(ruled > 10, "control: the measurement misses a Divider above the bar (\(ruled))")
        let bare = try Self.topRowContrast(ruled: false, colorScheme: colorScheme)
        #expect(bare < 3, "the status bar draws a rule above the count (\(bare))")
    }
}
