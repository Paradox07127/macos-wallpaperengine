import AppKit
import LiveWallpaperCore
import QuartzCore
import XCTest
@testable import LiveWallpaper

/// A leaning raindrop must point where it is going.
///
/// `CAEmitterCell` has no per-particle stretch, so the lean lives in two
/// unrelated places — the angle baked into the streak bitmap, and the cell's
/// `emissionLongitude`. Nothing links them, and the two coordinate systems
/// (Core Graphics y-up, Core Animation emission angles) are easy to get
/// crossed. Both are measured off the screen rather than reasoned about.
final class ParticleTiltAlignmentTests: XCTestCase {

    // MARK: - Capture harness

    /// A grayscale screen capture of `view`, rows normalised so row 0 is the
    /// top of what the user sees.
    ///
    /// The normalisation is calibrated in-frame rather than assumed: the host
    /// paints a marker at its own top-left, and whichever end of the buffer it
    /// lands in defines "top". Getting that backwards would invert every
    /// conclusion below.
    private struct Frame {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        /// First column past the calibration marker. Derived from the capture,
        /// not hardcoded: the marker is sized in points and the capture is in
        /// backing pixels, so a fixed column left the marker in frame on a
        /// Retina display and every "measurement" below was really measuring
        /// the marker.
        let firstDataColumn: Int

        func lit(_ x: Int, _ y: Int) -> Bool { pixels[y * width + x] > 24 }
    }

    private static let markerSide: CGFloat = 16

    @MainActor
    private func capture(
        _ build: (NSView) -> Void, size: CGSize, settle: TimeInterval
    ) throws -> Frame {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width, height: size.height
        )

        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        window.isOpaque = true
        window.backgroundColor = .black
        defer { window.orderOut(nil) }

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        // Calibration marker at the view's top-left in AppKit's y-up space.
        let marker = CALayer()
        marker.frame = CGRect(x: 0, y: size.height - Self.markerSide,
                              width: Self.markerSide, height: Self.markerSide)
        marker.backgroundColor = NSColor.white.cgColor
        view.layer?.addSublayer(marker)

        build(view)
        window.contentView = view
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        // This window's own backing store, not the screen region it occupies.
        // `.optionOnScreenOnly` over a rect captures whatever is in front —
        // during a full run other suites put their own windows up and these
        // measurements failed at random while passing in isolation.
        let shot = try XCTUnwrap(
            CGWindowListCreateImage(
                .null, [.optionIncludingWindow], CGWindowID(window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]),
            "window capture returned nil"
        )

        let width = shot.width, height = shot.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw XCTSkip("no context") }
        ctx.draw(shot, in: CGRect(x: 0, y: 0, width: width, height: height))

        let band = max(Int(Self.markerSide) * height / Int(size.height) / 2, 3)
        let strip = max(Int(Self.markerSide) * width / Int(size.width) / 2, 3)
        func brightness(rows: Range<Int>) -> Int {
            rows.reduce(0) { sum, y in
                sum + (0..<strip).reduce(0) { $0 + Int(pixels[y * width + $1]) }
            }
        }
        let headIsMarker = brightness(rows: 0..<band) > brightness(rows: (height - band)..<height)
        XCTAssertNotEqual(
            brightness(rows: 0..<band), brightness(rows: (height - band)..<height),
            "calibration marker not found — the capture is not showing the host view"
        )
        if !headIsMarker {
            var flipped = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                let src = (height - 1 - y) * width
                for x in 0..<width { flipped[y * width + x] = pixels[src + x] }
            }
            pixels = flipped
        }
        return Frame(
            pixels: pixels, width: width, height: height,
            firstDataColumn: min(strip * 3, width - 1)
        )
    }

    // MARK: - Measurements

    /// Mean x of the lit pixels in the top and the bottom fifth of the lit
    /// area. Bottom minus top is positive when the shape leans down-and-right.
    private func downwardLean(_ frame: Frame) -> Double? {
        var rows: [(y: Int, sumX: Double, count: Double)] = []
        for y in 0..<frame.height {
            var sumX = 0.0, count = 0.0
            for x in frame.firstDataColumn..<frame.width where frame.lit(x, y) {
                sumX += Double(x); count += 1
            }
            if count > 0 { rows.append((y, sumX, count)) }
        }
        guard let first = rows.first?.y, let last = rows.last?.y, last - first > 8 else { return nil }
        let span = Double(last - first)
        func centroid(_ keep: (Int) -> Bool) -> Double? {
            let picked = rows.filter { keep($0.y) }
            let total = picked.reduce(0) { $0 + $1.count }
            guard total > 0 else { return nil }
            return picked.reduce(0) { $0 + $1.sumX } / total
        }
        guard let top = centroid({ Double($0 - first) < span * 0.2 }),
              let bottom = centroid({ Double($0 - first) > span * 0.8 })
        else { return nil }
        return bottom - top
    }

    /// Releases `cells` from a point and reports which way the plume leans.
    /// Positive means the particles travel down and to the right.
    @MainActor
    private func travelLean(of cells: [CAEmitterCell]) throws -> Double? {
        let frame = try capture({ view in
            let emitter = CAEmitterLayer()
            emitter.frame = view.bounds
            emitter.emitterShape = .point
            emitter.emitterMode = .points
            emitter.emitterPosition = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            emitter.emitterSize = .zero
            emitter.renderMode = .unordered
            emitter.emitterCells = cells
            // Meteors are deliberately rare; the heading is what is being
            // measured, so the plume is forced dense enough to see.
            emitter.birthRate = 40
            view.layer?.addSublayer(emitter)
        }, size: CGSize(width: 520, height: 520), settle: 0.5)
        return downwardLean(frame)
    }

    // MARK: - Tests

    /// The bitmap's lean and the cells' heading must agree in sign.
    ///
    /// Both come off the cells the app actually flies — the sprite is read
    /// back out of `contents` rather than rebuilt — so this covers every
    /// effect that bakes a direction into its texture.
    @MainActor
    func testStretchedSpritesPointTheWayTheParticleTravels() throws {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 520))
        // The far rain layer is included on purpose: it derives its own lean
        // from its own fall speed, so it is the one a per-layer slip breaks.
        let subjects: [(ParticleEffect, CGFloat, Int)] = [
            (.rain, 0.5, 0), (.rain, -0.5, 0), (.rain, 0.5, 2), (.meteors, 0, 0),
        ]

        for (effect, tilt, index) in subjects {
            let all = probe.debugCells(for: effect, tilt: tilt)
            XCTAssertGreaterThan(all.count, index, "\(effect) has no cell \(index)")
            let cells = [all[index]]
            let sprite = try XCTUnwrap(
                cells.first?.contents as! CGImage?, "\(effect) cell carries no texture"
            )

            let spriteFrame = try capture({ view in
                let layer = CALayer()
                layer.frame = CGRect(
                    x: (view.bounds.width - CGFloat(sprite.width)) / 2,
                    y: (view.bounds.height - CGFloat(sprite.height)) / 2,
                    width: CGFloat(sprite.width), height: CGFloat(sprite.height)
                )
                layer.contents = sprite
                view.layer?.addSublayer(layer)
            }, size: CGSize(width: 520, height: 520), settle: 0.35)
            let spriteLean = try XCTUnwrap(
                downwardLean(spriteFrame), "\(effect) sprite did not render on screen"
            )

            let travelLean = try XCTUnwrap(
                travelLean(of: cells), "\(effect) put no particles on screen"
            )

            XCTAssertGreaterThan(
                spriteLean * travelLean, 0,
                """
                \(effect) cell \(index) at tilt \(tilt): the sprite leans \
                \(spriteLean > 0 ? "right" : "left") (\(spriteLean)) while the particles \
                travel \(travelLean > 0 ? "right" : "left") (\(travelLean)) — it is drawn \
                pointing away from its own path
                """
            )
        }
    }

    /// Slow drops must lean further than fast ones in the same wind.
    ///
    /// `atan(wind / fallSpeed)` — the small drizzle-sized drops in the far
    /// layer fall at about a third of the speed of the big near ones, so they
    /// are pushed much further sideways. When every layer shared one angle the
    /// field slanted in lockstep, which is what made a light breeze read as a
    /// gale front rather than as rain.
    @MainActor
    func testSlowRainLayersLeanFurtherThanFastOnes() {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let cells = probe.debugCells(for: .rain, tilt: 0.4)
        XCTAssertEqual(cells.count, 3)

        let leans = cells.map { Double($0.emissionLongitude) + .pi / 2 }
        let speeds = cells.map { Double($0.velocity) }
        XCTAssertGreaterThan(speeds[0], speeds[2], "layers are not ordered fast to slow")
        XCTAssertGreaterThan(
            leans[2], leans[1],
            "the slow layer (\(speeds[2])) leans \(leans[2]), no more than the mid layer's \(leans[1])"
        )
        XCTAssertGreaterThan(
            leans[1], leans[0],
            "the mid layer leans \(leans[1]), no more than the fast layer's \(leans[0])"
        )
        // Still rain, not sleet: even the slowest layer stays off the horizontal.
        XCTAssertLessThan(leans[2], Double.pi / 3, "the slow layer is nearly horizontal")
    }

    /// With no wind there is no lean anywhere — the preset alone.
    @MainActor
    func testRainFallsStraightDownWithoutWind() {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        for cell in probe.debugCells(for: .rain, tilt: 0) {
            XCTAssertEqual(
                Double(cell.emissionLongitude), -.pi / 2, accuracy: 1e-6,
                "rain leans with no wind applied"
            )
        }
    }

    /// A westerly must push the rain to the right of the screen, and an
    /// easterly to the left.
    ///
    /// This is the one link the sprite/heading test above cannot see: it
    /// checks that the bitmap and the cells agree with *each other*, so a
    /// compass-to-screen mapping that is mirrored would keep them agreeing
    /// while blowing the rain the wrong way. Two bearings, opposite answers,
    /// measured off the screen — so a y-axis or handedness slip anywhere from
    /// `wind_direction_10m` to `emissionLongitude` shows up here.
    @MainActor
    func testWindBearingsPushRainTheWayTheCompassSays() throws {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 520))
        let magnitude = WeatherWindPolicy.tiltRadians(
            windSpeedKPH: 40, fallSpeedMPS: WeatherWindPolicy.FallSpeed.rain
        )
        XCTAssertGreaterThan(magnitude, 0.05, "no lean to measure")

        // Meteorological convention: the bearing is where the wind comes FROM.
        for (bearing, expected, name) in [(270.0, 1.0, "westerly"), (90.0, -1.0, "easterly")] {
            let tilt = magnitude * WeatherWindPolicy.horizontalBias(fromDegrees: bearing)
            XCTAssertEqual(
                (tilt > 0) ? 1.0 : -1.0, expected,
                "\(name) (\(bearing)°) resolved to the wrong sign before it ever reached the emitter"
            )
            let lean = try XCTUnwrap(
                travelLean(of: probe.debugCells(for: .rain, tilt: CGFloat(tilt))),
                "no rain on screen for the \(name)"
            )
            XCTAssertEqual(
                (lean > 0) ? 1.0 : -1.0, expected,
                """
                a \(name) (from \(bearing)°) should blow the rain \
                \(expected > 0 ? "right" : "left"), but it travelled \
                \(lean > 0 ? "right" : "left") (\(lean))
                """
            )
        }
    }

    /// Every effect has to be able to draw something.
    ///
    /// A preset that builds no cells, or a texture factory that returns nil,
    /// fails completely silently — the menu entry is there and picking it just
    /// turns the overlay off. Checked on the cells rather than on a capture:
    /// an on-screen version of this was flaky, because a sparse effect like
    /// bokeh may genuinely have emitted nothing yet when the shutter opens.
    @MainActor
    func testEveryEffectBuildsDrawableCells() throws {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        for effect in ParticleEffect.allCases where effect != .none {
            let cells = probe.debugCells(for: effect, tilt: 0.3)
            XCTAssertFalse(cells.isEmpty, "\(effect) builds no cells")
            for (index, cell) in cells.enumerated() {
                let sprite = cell.contents as! CGImage?
                XCTAssertNotNil(sprite, "\(effect) cell \(index) has no texture")
                XCTAssertGreaterThan(sprite?.width ?? 0, 1, "\(effect) cell \(index) texture is empty")
                XCTAssertGreaterThan(sprite?.height ?? 0, 1, "\(effect) cell \(index) texture is empty")
                XCTAssertGreaterThan(cell.birthRate, 0, "\(effect) cell \(index) never emits")
                XCTAssertGreaterThan(cell.lifetime, 0, "\(effect) cell \(index) dies at birth")
            }
        }
    }

    /// A stretched sprite's angle is baked in at birth and cannot follow, so
    /// the particle's heading must not swing during its life. Rain does not
    /// accelerate in the first place — a drop is already at terminal velocity.
    @MainActor
    func testStretchedSpriteHeadingHoldsForTheWholeLife() {
        let tilt: CGFloat = 0.5
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let cells = probe.debugCells(for: .rain, tilt: tilt)
            + probe.debugCells(for: .meteors, tilt: tilt)
        XCTAssertFalse(cells.isEmpty)

        for cell in cells {
            let speed = Double(cell.velocity)
            let life = Double(cell.lifetime)
            let birth = CGPoint(x: speed * sin(Double(tilt)), y: -speed * cos(Double(tilt)))
            let death = CGPoint(
                x: birth.x + Double(cell.xAcceleration) * life,
                y: birth.y + Double(cell.yAcceleration) * life
            )
            let birthAngle = atan2(birth.x, -birth.y)
            let deathAngle = atan2(death.x, -death.y)
            XCTAssertLessThan(
                abs(deathAngle - birthAngle), 0.09,
                """
                heading swings from \(birthAngle) rad to \(deathAngle) rad over \
                \(life)s — the baked streak angle is only right at birth
                """
            )
        }
    }
}
