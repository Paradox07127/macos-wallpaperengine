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
        return try snapshot(of: window, size: size)
    }

    /// One calibrated frame of a host window built by `capture`.
    @MainActor
    private func snapshot(of window: NSWindow, size: CGSize) throws -> Frame {
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

    /// Two calibrated frames `gap` seconds apart of the same host window.
    @MainActor
    private func captureTwice(
        _ build: (NSView) -> Void, size: CGSize, settle: TimeInterval, gap: TimeInterval
    ) throws -> (Frame, Frame) {
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
        let marker = CALayer()
        marker.frame = CGRect(x: 0, y: size.height - Self.markerSide,
                              width: Self.markerSide, height: Self.markerSide)
        marker.backgroundColor = NSColor.white.cgColor
        view.layer?.addSublayer(marker)

        build(view)
        window.contentView = view
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let first = try snapshot(of: window, size: size)
        RunLoop.current.run(until: Date().addingTimeInterval(gap))
        let second = try snapshot(of: window, size: size)
        return (first, second)
    }

    // MARK: - Measurements

    /// One connected lit region: centroid plus the angle of its long axis,
    /// measured from screen-down towards the right (folded into −π/2…π/2).
    private struct Streak {
        let x: Double
        let y: Double
        let pixels: Int
        let axis: Double
    }

    /// Every lit region of at least `minPixels` in the frame, right of the marker.
    private func streaks(in frame: Frame, minPixels: Int = 40) -> [Streak] {
        var seen = [Bool](repeating: false, count: frame.width * frame.height)
        var found: [Streak] = []
        for start in seen.indices where !seen[start] {
            let sx = start % frame.width, sy = start / frame.width
            guard sx >= frame.firstDataColumn, frame.lit(sx, sy) else { continue }
            var stack = [start]
            seen[start] = true
            var xs: [Double] = [], ys: [Double] = []
            while let index = stack.popLast() {
                let x = index % frame.width, y = index / frame.width
                xs.append(Double(x)); ys.append(Double(y))
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= frame.firstDataColumn, ny >= 0, nx < frame.width, ny < frame.height else { continue }
                    let next = ny * frame.width + nx
                    if !seen[next], frame.lit(nx, ny) {
                        seen[next] = true
                        stack.append(next)
                    }
                }
            }
            guard xs.count >= minPixels else { continue }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for i in xs.indices {
                let dx = xs[i] - mx, dy = ys[i] - my
                sxx += dx * dx; syy += dy * dy; sxy += dx * dy
            }
            // Major eigenvector of the covariance, as an angle from +x; then from down.
            let axis = .pi / 2 - 0.5 * atan2(2 * sxy, sxx - syy)
            found.append(Streak(x: mx, y: my, pixels: xs.count, axis: folded(axis)))
        }
        return found
    }

    /// Angle from screen-down towards the right, folded like `Streak.axis`.
    private func folded(_ angle: Double) -> Double {
        var a = angle
        while a > .pi / 2 {
            a -= .pi
        }
        while a <= -.pi / 2 {
            a += .pi
        }
        return a
    }

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
        // The farthest rain band is included on purpose (-1 = last): it is the
        // one a per-band slip between texture and heading breaks first.
        let subjects: [(ParticleEffect, CGFloat, Int)] = [
            (.rain, 0.5, 0), (.rain, -0.5, 0), (.rain, 0.5, -1), (.meteors, 0, 0),
        ]

        for (effect, tilt, requested) in subjects {
            let all = probe.debugCells(for: effect, tilt: tilt)
            let index = requested < 0 ? all.count - 1 : requested
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

    /// A streak must move along its own axis on the emitter the app really
    /// runs — its shape, mode, position and size — not on a `.point` stand-in.
    ///
    /// Every heading measurement above flies the cells from a `.point`, and on
    /// macOS 27 (26A5425a) that is exactly the case that hides the bug: a
    /// `.line` emitter launched every drop 90° off its `emissionLongitude`, so
    /// vertical streaks slid sideways along the top edge and leaning ones
    /// crossed their own path (measured 2026-09-05: shape 28.7°, motion −61°).
    /// Sparse rain, two frames 40 ms apart, each streak matched to its nearest
    /// self in the second frame: the long axis and the displacement must agree,
    /// and both must agree with the wind.
    @MainActor
    func testRainStreaksTravelAlongTheirOwnAxis() throws {
        for tilt in [0.5, 0, -0.5] as [CGFloat] {
            let (first, second) = try captureTwice({ view in
                let overlay = ParticleOverlayView(frame: view.bounds)
                view.addSubview(overlay)
                overlay.setEffect(.rain, density: 0.12, tiltRadians: tilt)
            }, size: CGSize(width: 900, height: 600), settle: 3, gap: 0.04)

            let before = streaks(in: first), after = streaks(in: second)
            var axes: [Double] = [], motions: [Double] = []
            for streak in before {
                // Nearest region in the second frame, in any direction: a drop
                // that has moved less than 3 px or more than 130 px is not this one.
                let match = after.min { lhs, rhs in
                    hypot(lhs.x - streak.x, lhs.y - streak.y) < hypot(rhs.x - streak.x, rhs.y - streak.y)
                }
                guard let match else { continue }
                let dx = match.x - streak.x, dy = match.y - streak.y
                let distance = hypot(dx, dy)
                guard distance > 3, distance < 130 else { continue }
                axes.append(streak.axis)
                motions.append(atan2(dx, dy))
            }
            XCTAssertGreaterThanOrEqual(axes.count, 2, "tilt \(tilt): tracked no streaks across the two frames")
            guard !axes.isEmpty else { continue }

            let medianAxis = axes.sorted()[axes.count / 2]
            let medianMotion = motions.sorted()[motions.count / 2]
            XCTAssertEqual(
                medianAxis, folded(medianMotion), accuracy: 0.12,
                "tilt \(tilt): streaks are drawn at \(medianAxis) rad but travel at \(medianMotion) rad"
            )
            XCTAssertEqual(
                medianMotion, Double(tilt), accuracy: 0.12,
                "tilt \(tilt): rain travels at \(medianMotion) rad from straight down, not with the wind"
            )
        }
    }

    /// Snow's sideways flutter has to blow the way the wind does: over a 15 s
    /// fall a constant push to the right overpowers any leftward heading the
    /// wind gave at birth, so an easterly still ended with the snow going east.
    @MainActor
    func testSnowFlutterFollowsTheWind() {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        for tilt in [0.4, -0.4] as [CGFloat] {
            for (index, cell) in probe.debugCells(for: .snow, tilt: tilt).enumerated() {
                XCTAssertEqual(
                    cell.xAcceleration < 0, tilt < 0,
                    "snow band \(index) at tilt \(tilt) accelerates sideways at \(cell.xAcceleration)"
                )
            }
        }
    }

    /// The flutter and rising fields are volumes too, not three sheets: every
    /// band behind the nearest is smaller, slower and no brighter, and there
    /// are more of them — the same perspective law the rain follows.
    @MainActor
    func testFieldEffectsHaveDepthBands() throws {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        for effect in [ParticleEffect.snow, .sakura, .fallingLeaves, .bubbles, .embers] {
            let cells = probe.debugCells(for: effect, tilt: 0) // near → far
            XCTAssertGreaterThanOrEqual(cells.count, 4, "\(effect) has \(cells.count) bands, which reads as sheets")
            let sizes = try cells.map { cell -> Double in
                // swiftlint:disable:next force_cast
                let sprite = try XCTUnwrap(cell.contents as! CGImage?)
                return Double(max(sprite.width, sprite.height)) * Double(cell.scale)
            }
            for index in cells.indices.dropFirst() {
                XCTAssertLessThan(sizes[index], sizes[index - 1], "\(effect) band \(index) is not smaller than the one in front")
                XCTAssertLessThan(
                    cells[index].velocity, cells[index - 1].velocity,
                    "\(effect) band \(index) is not slower than the one in front"
                )
                XCTAssertLessThanOrEqual(
                    cells[index].color?.alpha ?? 0, cells[index - 1].color?.alpha ?? 0,
                    "\(effect) band \(index) is brighter than the one in front"
                )
                XCTAssertGreaterThan(
                    cells[index].birthRate, cells[index - 1].birthRate,
                    "\(effect) band \(index) is not denser than the one in front"
                )
            }
        }
    }

    /// Petals, leaves and flakes lean with the wind like the rain does, and the
    /// petals and leaves tumble harder in it — and the other way round in an
    /// easterly than in a westerly. Before this they ignored the wind entirely
    /// while `leansIntoWind` promised otherwise.
    @MainActor
    func testFlutterEffectsLeanAndTumbleWithTheWind() {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let tilt: CGFloat = 0.45
        for effect in [ParticleEffect.sakura, .fallingLeaves, .snow] {
            let calm = probe.debugCells(for: effect, tilt: 0)
            let westerly = probe.debugCells(for: effect, tilt: tilt)
            let easterly = probe.debugCells(for: effect, tilt: -tilt)
            XCTAssertEqual(calm.count, westerly.count)
            for (index, cell) in westerly.enumerated() {
                XCTAssertEqual(
                    Double(cell.emissionLongitude), -.pi / 2 + Double(tilt), accuracy: 1e-6,
                    "\(effect) band \(index) does not lean with the wind"
                )
                XCTAssertGreaterThan(cell.xAcceleration, 0, "\(effect) band \(index) drifts against a westerly")
                XCTAssertLessThan(easterly[index].xAcceleration, 0, "\(effect) band \(index) drifts against an easterly")
            }
            guard effect != .snow else { continue } // a flake is round; nothing to see it spin by
            for index in calm.indices {
                let calmTumble = abs(calm[index].spin) + calm[index].spinRange
                let windyTumble = abs(westerly[index].spin) + westerly[index].spinRange
                XCTAssertGreaterThan(windyTumble, calmTumble * 1.5, "\(effect) band \(index) does not tumble harder in wind")
                XCTAssertLessThan(
                    westerly[index].spin * easterly[index].spin, 0,
                    "\(effect) band \(index) rolls the same way in a westerly and an easterly"
                )
            }
        }
    }

    /// Every depth band shares one lean.
    ///
    /// Drops of every size in one patch of sky fall in the same direction
    /// (Garg & Nayar, CVPR 2004 §3.1: "within a local region, drops fall more
    /// or less in the same direction"), and perspective keeps a straight
    /// path's on-screen angle the same at every distance. Deriving each band's
    /// lean from its own on-screen speed slanted the small far drops ~17°
    /// steeper than the big near ones, so the field visibly drifted one way
    /// while the streaks the eye picks out pointed another.
    @MainActor
    func testEveryRainDepthBandSharesOneLean() {
        let tilt: CGFloat = 0.4
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let cells = probe.debugCells(for: .rain, tilt: tilt)
        XCTAssertGreaterThanOrEqual(cells.count, 3)
        for (index, cell) in cells.enumerated() {
            XCTAssertEqual(
                Double(cell.emissionLongitude), -.pi / 2 + Double(tilt), accuracy: 1e-6,
                "band \(index) leans \(Double(cell.emissionLongitude) + .pi / 2), not the field's \(tilt)"
            )
            // A streak's angle is baked in, so any spread in heading is a
            // drop drawn pointing off its own path.
            XCTAssertEqual(cell.emissionRange, 0, accuracy: 1e-6, "band \(index) sprays its heading")
        }
    }

    /// Depth is perspective, applied to every visible quantity at once: the
    /// near band is faster, longer, brighter and sparser, and each band behind
    /// it is slower, shorter, fainter and denser. Streak length is speed × one
    /// exposure, so the same exposure must fall out of every band — a band
    /// with its own arbitrary length is what reads as a sprite sheet.
    @MainActor
    func testRainDepthBandsScaleWithDistance() throws {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let cells = probe.debugCells(for: .rain, tilt: 0) // near → far
        XCTAssertGreaterThanOrEqual(cells.count, 4, "fewer than four depth bands reads as sheets")

        let speeds = cells.map { Double($0.velocity) }
        // `as? CGImage` from `Any?` is a compile error ("will always succeed"), so the
        // force cast the rest of this file uses is the only spelling left.
        // swiftlint:disable:next force_cast
        let lengths = try cells.map { try Double(XCTUnwrap($0.contents as! CGImage?).height) }
        let alphas = cells.map { Double($0.color?.alpha ?? 0) }
        for index in cells.indices.dropFirst() {
            XCTAssertLessThan(speeds[index], speeds[index - 1], "band \(index) is not slower than the one in front")
            XCTAssertLessThan(lengths[index], lengths[index - 1], "band \(index) is not shorter than the one in front")
            XCTAssertLessThan(alphas[index], alphas[index - 1], "band \(index) is not fainter than the one in front")
            XCTAssertGreaterThan(
                cells[index].birthRate, cells[index - 1].birthRate,
                "band \(index) is not denser than the one in front — far drops outnumber near ones"
            )
        }

        let exposures = zip(lengths, speeds).map { $0 / $1 }
        for (index, exposure) in exposures.enumerated() {
            XCTAssertEqual(
                exposure, exposures[0], accuracy: exposures[0] * 0.1,
                "band \(index) is blurred over \(exposure)s, the near band over \(exposures[0])s"
            )
        }

        // A drop must reach the bottom of a tall display before its lifetime
        // ends; one that dies mid-air pops out of existence in plain view.
        for (index, cell) in cells.enumerated() {
            let shortestLife = Double(cell.lifetime - cell.lifetimeRange)
            XCTAssertGreaterThanOrEqual(
                Double(cell.velocity) * shortestLife, 1700,
                "band \(index) travels only \(Double(cell.velocity) * shortestLife) pt before it dies"
            )
        }
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
