import AppKit
import LiveWallpaperCore
import XCTest
@testable import LiveWallpaper

/// Nothing in the type system notices a dry edge, and neither does a screenshot
/// unless someone looks at the far edge — so it is measured on screen.
final class RainCoverageTests: XCTestCase {

    /// Fraction of pixels in each horizontal third that carry a particle.
    @MainActor
    private func coverageByThird(
        effect: ParticleEffect, tilt: CGFloat, settle: TimeInterval, density: CGFloat = 1.8
    ) throws -> [Double] {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        try CaptureEnvironment.requireUnlockedScreen()
        let size = CGSize(width: 700, height: 460)
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)

        // One opaque host, not a transparent overlay: the capture reads this window's
        // own backing store, so the black has to be inside it.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        // Above ordinary windows, not at the wallpaper's level: an occluded window
        // stops updating its backing store and the capture comes back black.
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .black
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        let view = ParticleOverlayView(frame: host.bounds)
        host.addSubview(view)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        view.setEffect(effect, density: density, tiltRadians: tilt)
        // The field has to fill before it can be measured: a short settle
        // reports a hole that is only "these have not arrived yet".
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        // This window's own backing store, not the screen region it occupies: a region
        // capture reads whatever is in front.
        let capture = CGWindowListCreateImage(
            .null,
            [.optionIncludingWindow],
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        )
        let image = try XCTUnwrap(capture, "window capture returned nil")

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
        // Guarding against a missing wedge, not policing a gradient: the downwind third
        // legitimately sits at 34-35% of the busiest, so 0.15 is an order of magnitude
        // away, not a percent.
        let busiest = thirds.max() ?? 0
        for (index, share) in thirds.enumerated() {
            XCTAssertGreaterThan(share, busiest * 0.15, "third \(index) starved: \(thirds)")
        }
    }

    @MainActor
    func testHeavierRainIsVisiblyDenserThanLight() throws {
        // `density` is the emitter's birth rate (ParticleOverlayView.setEffect), so the two
        // runs differ by 4.5x in drops emitted. Compared against each other, not against a
        // fixed number: absolute coverage moves with panel size and settle time.
        let heavy = try coverageByThird(effect: .rain, tilt: 0, settle: 4, density: 1.8).reduce(0, +)
        let light = try coverageByThird(effect: .rain, tilt: 0, settle: 4, density: 0.4).reduce(0, +)
        XCTAssertGreaterThan(heavy, 0.01, "no rain rendered at all")
        XCTAssertGreaterThan(light, 0, "the light run rendered nothing, so the comparison is vacuous")
        XCTAssertGreaterThan(heavy, light * 1.3,
                             "heavy \(heavy) is not visibly denser than light \(light)")
    }
}
