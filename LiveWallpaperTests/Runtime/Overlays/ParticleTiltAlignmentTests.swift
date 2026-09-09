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
        try CaptureEnvironment.requireUnlockedScreen()
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width, height: size.height
        )

        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        // Above ordinary windows, not at the wallpaper's level: a window the
        // compositor considers occluded stops updating its backing store, and the
        // capture then comes back black.
        window.level = .floating
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
    ///
    /// The compositor hands back an all-black backing store often enough just
    /// after the window is ordered in that a single attempt failed about two
    /// runs in three, first as "no marker" and then as "no streaks". A capture
    /// that never shows the marker still fails, so the calibration keeps its
    /// teeth.
    @MainActor
    private func snapshot(of window: NSWindow, size: CGSize) throws -> Frame {
        for _ in 0 ..< 9 {
            if let frame = try calibratedFrame(of: window, size: size) {
                return frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return try XCTUnwrap(
            calibratedFrame(of: window, size: size),
            "calibration marker not found — the capture is not showing the host view"
        )
    }

    /// `nil` when the calibration marker is not in the capture.
    @MainActor
    private func calibratedFrame(of window: NSWindow, size: CGSize) throws -> Frame? {
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
        let head = brightness(rows: 0 ..< band)
        let tail = brightness(rows: (height - band) ..< height)
        guard head != tail else {
            return nil
        }
        if head < tail {
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
        let frames = try captureSeries(build, size: size, settle: settle, gap: gap, count: 2)
        return (frames[0], frames[1])
    }

    /// Up to `count` calibrated frames `gap` seconds apart of one host window,
    /// stopping at the first frame `isEnough` accepts. Sparse effects need a
    /// window long enough to catch one, and a fixed count either wastes seconds
    /// on every run or reports "nothing was measured" on an unlucky one.
    @MainActor
    private func captureSeries(
        _ build: (NSView) -> Void, size: CGSize, settle: TimeInterval, gap: TimeInterval, count: Int,
        until isEnough: (Frame) -> Bool = { _ in false }
    ) throws -> [Frame] {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        try CaptureEnvironment.requireUnlockedScreen()
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width, height: size.height
        )
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        // Above ordinary windows, not at the wallpaper's level: a window the
        // compositor considers occluded stops updating its backing store, and the
        // capture then comes back black.
        window.level = .floating
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
        var frames = try [snapshot(of: window, size: size)]
        for _ in 1 ..< max(count, 1) where !isEnough(frames[frames.count - 1]) {
            RunLoop.current.run(until: Date().addingTimeInterval(gap))
            try frames.append(snapshot(of: window, size: size))
        }
        return frames
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

    /// Grey histogram of one frame right of the marker, the value that occupies
    /// most of it, and how many pixels sit clearly above that value.
    private static func histogram(of frame: Frame) -> (counts: [Int], background: Int, lit: Int) {
        var counts = [Int](repeating: 0, count: 256)
        for y in 0 ..< frame.height {
            for x in frame.firstDataColumn ..< frame.width {
                counts[Int(frame.pixels[y * frame.width + x])] += 1
            }
        }
        let background = counts.indices.max { counts[$0] < counts[$1] } ?? 0
        return (counts, background, counts[min(background + 12, 255)...].reduce(0, +))
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
        // Meteors are deliberately absent: they are drawn as a round nucleus that
        // lays its own train, so there is no angle baked into a sprite to keep in
        // step with anything. Rain is the only effect left that bakes one.
        let subjects: [(ParticleEffect, CGFloat, Int)] = [
            (.rain, 0.5, 0), (.rain, -0.5, 0), (.rain, 0.5, -1),
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

            // Measured outside the unwrap on purpose: `XCTUnwrap` records
            // anything its expression throws as a failure, which would turn
            // the locked-screen skip into a red test.
            let measuredTravel = try travelLean(of: cells)
            let travel = try XCTUnwrap(measuredTravel, "\(effect) put no particles on screen")

            XCTAssertGreaterThan(
                spriteLean * travel, 0,
                """
                \(effect) cell \(index) at tilt \(tilt): the sprite leans \
                \(spriteLean > 0 ? "right" : "left") (\(spriteLean)) while the particles \
                travel \(travel > 0 ? "right" : "left") (\(travel)) — it is drawn \
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

    /// The meteor sprite exists and leans the way meteors fly. Nothing else checks it
    /// now that meteors are out of the emitter path, and a nil texture would leave the
    /// menu entry working and the sky empty.
    @MainActor
    func testMeteorSpriteIsDrawableAndLeansWithTheFlight() throws {
        let frame = try capture({ view in
            let flight = MeteorShower.flight(in: view.bounds) { $0.lowerBound }
            let sprite = ParticleTextures.comet(
                length: flight.length, width: flight.width,
                color: NSColor.white.cgColor, tilt: MeteorShower.slant
            )
            let layer = CALayer()
            layer.contents = sprite
            layer.frame = CGRect(
                x: (view.bounds.width - CGFloat(sprite?.width ?? 0)) / 2,
                y: (view.bounds.height - CGFloat(sprite?.height ?? 0)) / 2,
                width: CGFloat(sprite?.width ?? 0), height: CGFloat(sprite?.height ?? 0)
            )
            view.layer?.addSublayer(layer)
        }, size: CGSize(width: 520, height: 520), settle: 0.35)

        let lean = try XCTUnwrap(downwardLean(frame), "the meteor sprite did not render")
        // Positive `slant` sends meteors down and to the right, so the streak must too.
        XCTAssertGreaterThan(lean, 0, "the meteor sprite leans \(lean), against its own flight")
    }

    /// A meteor brightens before it fades.
    ///
    /// This is the whole point of flying meteors on their own layers: `CAEmitterCell`
    /// offers `alphaSpeed`, one straight line, so an emitted particle can only ever get
    /// dimmer and every meteor snapped into being at full brightness. Particle libraries
    /// model this as an alpha envelope over the particle's lifetime, and that is what
    /// the keyframed opacity here is.
    @MainActor
    func testMeteorLightCurveRisesThenFalls() throws {
        let values = MeteorShower.opacityValues
        let times = MeteorShower.opacityKeyTimes
        XCTAssertEqual(values.count, times.count)
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times.last, 1)
        XCTAssertEqual(values.first, 0, "a meteor switches on at full brightness")
        XCTAssertEqual(values.last, 0, "a meteor switches off instead of burning out")
        XCTAssertEqual(times, times.sorted(), "the envelope's key times run backwards")

        let brightest = try XCTUnwrap(values.max())
        let peak = try XCTUnwrap(values.firstIndex(of: brightest))
        XCTAssertGreaterThan(peak, 0, "the envelope never rises")
        XCTAssertLessThan(peak, values.count - 1, "the envelope never falls")
        for index in 1 ... peak {
            XCTAssertGreaterThan(values[index], values[index - 1], "the rise dips at \(index)")
        }
        for index in (peak + 1) ..< values.count {
            XCTAssertLessThan(values[index], values[index - 1], "the fall rises again at \(index)")
        }
        // Meteors flare quickly and linger: a symmetric envelope reads as a pulsing dot.
        XCTAssertLessThan(times[peak], 0.35, "the flare takes \(times[peak]) of the flight")
    }

    /// Every meteor is born clear of the top edge and flies the shared slant, so none
    /// appears mid-air and the shower reads as one radiant rather than as noise.
    @MainActor
    func testMeteorsEnterFromOffScreenOnTheSharedSlant() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        // Both ends of every random range, so the extremes are covered too.
        for pick in [0.0, 0.5, 1.0] as [CGFloat] {
            let flight = MeteorShower.flight(in: bounds) { range in
                range.lowerBound + (range.upperBound - range.lowerBound) * pick
            }
            XCTAssertGreaterThanOrEqual(
                flight.start.y - bounds.maxY, flight.length,
                "a meteor is born \(flight.start.y - bounds.maxY) pt above a \(flight.length) pt sprite"
            )
            let dx = flight.end.x - flight.start.x
            let dy = flight.end.y - flight.start.y
            XCTAssertLessThan(dy, 0, "the meteor climbs")
            XCTAssertEqual(
                atan2(dx, -dy), Double(MeteorShower.slant), accuracy: 1e-6,
                "the meteor flies off the shower's slant"
            )
            XCTAssertGreaterThan(flight.duration, 0)
            XCTAssertGreaterThan(flight.length, 0)
            XCTAssertGreaterThan(flight.brightness, 0)
            XCTAssertLessThanOrEqual(flight.brightness, 1)
        }
    }

    /// Gaps between meteors are random and bounded, and a denser sky is a busier one.
    /// A fixed interval is the tell that a shower is on a metronome.
    @MainActor
    func testMeteorGapsAreRandomAndScaleWithDensity() {
        let gaps = stride(from: 0.05, through: 0.95, by: 0.1)
            .map { MeteorShower.nextGap(density: 1, uniform: $0) }
        XCTAssertEqual(gaps, gaps.sorted(by: >), "gaps are not monotonic in the draw")
        XCTAssertGreaterThan(Set(gaps).count, 5, "the gap barely varies")
        for gap in gaps {
            XCTAssertGreaterThanOrEqual(gap, 0.2)
            XCTAssertLessThanOrEqual(gap, 12)
        }
        XCTAssertLessThan(
            MeteorShower.nextGap(density: 3, uniform: 0.5),
            MeteorShower.nextGap(density: 0.5, uniform: 0.5),
            "turning the density up does not bring meteors more often"
        )
    }

    /// A meteor must not drag a filled rectangle behind it.
    ///
    /// On macOS 27 (26A5425a) a `CAEmitterCell` that carries sub-cells has the whole
    /// bounding box of its own sprite filled in by the compositor. With a diagonal
    /// comet sprite as the nucleus that box was about 5,000 px of flat grey some 50
    /// levels above the night sky, tracking every meteor (measured 2026-09-05, and
    /// absent from the same scene with the train removed). A round nucleus leaves
    /// almost no box to fill. Nothing in the type system notices this, and the box
    /// only shows against a dark sky — so it is measured, on screen.
    @MainActor
    func testMeteorsDoNotFillTheirSpriteBox() throws {
        let lit: (Frame) -> Bool = { Self.histogram(of: $0).lit > 400 }
        let frames = try captureSeries({ view in
            let overlay = ParticleOverlayView(frame: view.bounds)
            view.addSubview(overlay)
            overlay.setEffect(.meteors, density: 3, tiltRadians: 0)
        }, size: CGSize(width: 800, height: 600), settle: 1.8, gap: 0.4, count: 20, until: lit)

        var sawAMeteor = false
        for (index, frame) in frames.enumerated() {
            let (histogram, background, lit) = Self.histogram(of: frame)
            if lit > 400 {
                sawAMeteor = true
            }
            // A flat plateau: thousands of pixels sharing one exact value. Real
            // particles are gradients, so a clean frame's largest plateau is a
            // couple of hundred pixels; the defect measured five thousand.
            let plateau = histogram.indices
                .filter { $0 > background + 3 }
                .map { histogram[$0] }
                .max() ?? 0
            XCTAssertLessThan(
                plateau, 1500,
                "frame \(index): \(plateau) px share one exact value — a solid rectangle is being drawn"
            )
        }
        XCTAssertTrue(sawAMeteor, "no meteor was drawn in any frame, so nothing was measured")
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
            let measured = try travelLean(of: probe.debugCells(for: .rain, tilt: CGFloat(tilt)))
            let lean = try XCTUnwrap(measured, "no rain on screen for the \(name)")
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
        // Meteors are excluded because they are not emitted: `MeteorShower` flies one
        // sprite per meteor on its own layer, and its sprite is checked below.
        for effect in ParticleEffect.allCases where effect != .none && effect != .meteors {
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
