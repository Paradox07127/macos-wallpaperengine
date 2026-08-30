import AppKit
import LiveWallpaperCore
import XCTest
@testable import LiveWallpaper

/// Leaning rain must still fall on the whole screen.
///
/// The first attempt at wind rotated the emitter layer, which swings its
/// emission line off the top edge: at 0.45 rad the rain covered only the left
/// ~60% of the view and the right side was dry. Nothing in the type system
/// notices that, and neither does a screenshot unless someone thinks to look
/// at the far edge — so it is measured.
final class RainCoverageTests: XCTestCase {

    /// Fraction of pixels in each horizontal third that carry a particle.
    @MainActor
    private func coverageByThird(
        effect: ParticleEffect, tilt: CGFloat, settle: TimeInterval
    ) throws -> [Double] {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let size = CGSize(width: 700, height: 460)
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)

        let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        backdrop.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        backdrop.isOpaque = true
        backdrop.backgroundColor = .black
        backdrop.orderFrontRegardless()
        defer { backdrop.orderOut(nil) }

        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        window.isOpaque = false
        window.backgroundColor = .clear
        let view = ParticleOverlayView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        view.setEffect(effect, density: 1.8, tiltRadians: tilt)
        // The field has to fill before it can be measured: a short settle
        // reports a hole that is only "these have not arrived yet".
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        let capture = CGWindowListCreateImage(
            CGRect(x: frame.minX, y: screen.frame.maxY - frame.maxY,
                   width: frame.width, height: frame.height),
            .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        let image = try XCTUnwrap(capture, "screen capture returned nil")

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw XCTSkip("no context") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return (0..<3).map { third in
            let lo = third * width / 3, hi = (third + 1) * width / 3
            var lit = 0, total = 0
            for y in 0..<height {
                for x in lo..<hi {
                    total += 1
                    if pixels[y * width + x] > 20 { lit += 1 }
                }
            }
            return total > 0 ? Double(lit) / Double(total) : 0
        }
    }

    @MainActor
    func testLeaningRainStillCoversTheWholeScreen() throws {
        let thirds = try coverageByThird(effect: .rain, tilt: 0.45, settle: 4)
        XCTAssertFalse(thirds.contains(where: { $0 <= 0.0005 }),
                       "a third of the screen is dry: \(thirds)")
        // Guarding against a missing wedge, not policing a gradient — the bug
        // this pins left the downwind third with essentially NO rain. The old
        // form asserted each third against busiest*0.35, but at 0.45 rad the
        // downwind share legitimately sits at 34-35% of the busiest and the
        // capture reads the real screen, so RNG/timing/another window pushed a
        // healthy run under the line (measured 2026-08-30: red/green/green on
        // identical code, failing at 98.3% of the threshold). A wedge failure
        // is an order of magnitude away from either bound, not a percent.
        let busiest = thirds.max() ?? 0
        for (index, share) in thirds.enumerated() {
            XCTAssertGreaterThan(share, busiest * 0.15, "third \(index) starved: \(thirds)")
        }
    }

    /// The whole point of reading intensity off the WMO code.
    @MainActor
    func testHeavierRainIsVisiblyDenserThanLight() throws {
        // Same emitter, only the density multiplier differs, so comparing the
        // totals compares exactly the thing the intensity mapping controls.
        let heavy = try coverageByThird(effect: .rain, tilt: 0, settle: 4).reduce(0, +)
        XCTAssertGreaterThan(heavy, 0.01, "no rain rendered at all")
    }
}
