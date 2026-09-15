import AppKit
import LiveWallpaperCore
import Metal
import QuartzCore
import XCTest
@testable import LiveWallpaper

/// `CAEmitterCell` has no per-particle stretch, so the lean lives in two unlinked
/// places: the angle baked into the streak bitmap, and the cell's
/// `emissionLongitude`. Nothing links them.
final class ParticleTiltAlignmentTests: XCTestCase {

    // MARK: - Capture harness

    /// A grayscale capture of the layer tree, rows normalised so row 0 is the top of
    /// what the user sees — calibrated in-frame by a marker, not assumed.
    private struct Frame {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        /// First column past the calibration marker. Derived from the capture, not
        /// hardcoded: the marker is sized in points, the capture in backing pixels.
        let firstDataColumn: Int

        func lit(_ x: Int, _ y: Int) -> Bool { pixels[y * width + x] > 24 }
    }

    private struct MarkerNotFound: Error, CustomStringConvertible {
        var description: String {
            "calibration marker not found — the offscreen capture is empty"
        }
    }

    private static let markerSide: CGFloat = 16
    /// Backing pixels per point. Fixed rather than read off a display: nothing here
    /// reaches a screen, and every pixel threshold below is written at 2x.
    private static let captureScale: CGFloat = 2

    /// Renders a detached layer tree into a texture. There is no window, so nothing
    /// appears on screen, nothing can occlude the capture, a locked screen cannot
    /// black it out, and animation time is stepped by hand instead of waited out.
    @MainActor
    private final class OffscreenStage {
        private let texture: MTLTexture
        private let renderer: CARenderer
        private var now = CACurrentMediaTime()

        init(size: CGSize, build: (NSView) -> Void) throws {
            let scale = ParticleTiltAlignmentTests.captureScale
            let side = ParticleTiltAlignmentTests.markerSide

            let host = NSView(frame: NSRect(origin: .zero, size: size))
            host.wantsLayer = true
            let root = try XCTUnwrap(host.layer, "the host view has no backing layer")
            root.backgroundColor = NSColor.black.cgColor
            root.contentsScale = scale

            build(host)

            // Outside a window AppKit never parents a subview's layer, so the tree
            // handed to CARenderer would otherwise hold nothing but the marker.
            for sub in host.subviews {
                if let layer = sub.layer, layer.superlayer !== root {
                    layer.frame = sub.frame
                    root.addSublayer(layer)
                }
            }

            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: Int(size.width * scale), height: Int(size.height * scale),
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .shared
            texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor), "no texture")

            // CARenderer maps a layer point onto a texture pixel 1:1 — `contentsScale`
            // does not enter into it — so a 2x capture needs the tree scaled up inside
            // a container sized in backing pixels. Without this the whole scene lands
            // in one corner and the rest of the capture is black.
            let container = CALayer()
            container.frame = CGRect(x: 0, y: 0,
                                     width: size.width * scale, height: size.height * scale)
            container.backgroundColor = NSColor.black.cgColor
            root.anchorPoint = .zero
            root.position = .zero
            root.transform = CATransform3DMakeScale(scale, scale, 1)
            container.addSublayer(root)

            renderer = CARenderer(mtlTexture: texture)
            renderer.layer = container
            renderer.bounds = container.bounds

            // Calibration marker at the view's top-left in AppKit's y-up space, added
            // last so it is never covered: a full-bounds layer under test sits above
            // whatever was added before it, clear background or not.
            let marker = CALayer()
            marker.frame = CGRect(x: 0, y: size.height - side, width: side, height: side)
            marker.backgroundColor = NSColor.white.cgColor
            root.addSublayer(marker)

            // The tree only reaches the render server once a transaction commits.
            CATransaction.begin()
            root.setNeedsDisplay()
            root.displayIfNeeded()
            root.layoutIfNeeded()
            CATransaction.commit()
            CATransaction.flush()

        }

        /// Steps animation time in 60 Hz increments, landing exactly on the target so
        /// a caller's `gap` is the interval it asked for rather than a rounded one.
        ///
        /// `pumpingRunLoop` also spends the wall clock: `MeteorShower` schedules its
        /// launches on a `Timer`, which a purely simulated clock never fires.
        func advance(by seconds: TimeInterval, pumpingRunLoop: Bool = false) {
            let target = now + seconds
            while now < target {
                now = min(now + 1.0 / 60.0, target)
                if pumpingRunLoop {
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60.0))
                    now = CACurrentMediaTime()
                }
                renderer.beginFrame(atTime: now, timeStamp: nil)
                renderer.addUpdate(renderer.bounds)
                renderer.render()
                renderer.endFrame()
                CATransaction.flush()
            }
        }

        func image() throws -> CGImage {
            let width = texture.width, height = texture.height
            var bgra = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bgra, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bgra) as CFData))
            // `bgra8Unorm` on a little-endian host is byteOrder32Little + alpha first.
            return try XCTUnwrap(CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ))
        }
    }

    @MainActor
    private func capture(
        _ build: (NSView) -> Void, size: CGSize, settle: TimeInterval
    ) throws -> Frame {
        let stage = try OffscreenStage(size: size, build: build)
        stage.advance(by: settle)
        return try frame(from: stage, size: size)
    }

    @MainActor
    private func captureTwice(
        _ build: (NSView) -> Void, size: CGSize, settle: TimeInterval, gap: TimeInterval
    ) throws -> (Frame, Frame) {
        let frames = try captureSeries(build, size: size, settle: settle, gap: gap, count: 2)
        return (frames[0], frames[1])
    }

    /// Up to `count` calibrated frames `gap` seconds apart, stopping at the first
    /// frame `isEnough` accepts.
    @MainActor
    private func captureSeries(
        _ build: (NSView) -> Void, size: CGSize, settle: TimeInterval, gap: TimeInterval, count: Int,
        onWallClock: Bool = false,
        until isEnough: (Frame) -> Bool = { _ in false }
    ) throws -> [Frame] {
        let stage = try OffscreenStage(size: size, build: build)
        stage.advance(by: settle, pumpingRunLoop: onWallClock)
        var frames = try [frame(from: stage, size: size)]
        for _ in 1 ..< max(count, 1) where !isEnough(frames[frames.count - 1]) {
            stage.advance(by: gap, pumpingRunLoop: onWallClock)
            try frames.append(frame(from: stage, size: size))
        }
        return frames
    }

    /// The marker fixes which end of the capture is the top; nothing here assumes the
    /// texture's row order.
    @MainActor
    private func frame(from stage: OffscreenStage, size: CGSize) throws -> Frame {
        let shot = try stage.image()
        let width = shot.width, height = shot.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw XCTSkip("no context") }
        ctx.draw(shot, in: CGRect(x: 0, y: 0, width: width, height: height))

        let side = Int(Self.markerSide)
        let band = max(side * height / Int(size.height) / 2, 3)
        let strip = max(side * width / Int(size.width) / 2, 3)
        func brightness(rows: Range<Int>) -> Int {
            rows.reduce(0) { sum, y in
                sum + (0..<strip).reduce(0) { $0 + Int(pixels[y * width + $1]) }
            }
        }
        let head = brightness(rows: 0 ..< band)
        let tail = brightness(rows: (height - band) ..< height)
        guard head != tail else { throw MarkerNotFound() }
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

    // MARK: - Measurements

    /// One connected lit region: centroid plus the angle of its long axis,
    /// measured from screen-down towards the right (folded into −π/2…π/2).
    private struct Streak {
        let x: Double
        let y: Double
        let pixels: Int
        let axis: Double
    }

    /// Lit regions right of the calibration marker only.
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

    @MainActor
    func testStretchedSpritesPointTheWayTheParticleTravels() throws {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 520))
        // The farthest rain band is included on purpose (-1 = last): a per-band slip
        // between texture and heading breaks it first. Meteors are absent on purpose:
        // their sprite bakes no angle to keep in step with.
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

            // Measured outside the unwrap on purpose: `XCTUnwrap` records a throw as a
            // failure, which would turn the locked-screen skip red.
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

    /// Must run on the emitter the app really uses, not a `.point` stand-in: the
    /// `.point` case is exactly the one that hides a `.line` emitter launching every
    /// drop 90° off its `emissionLongitude`.
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

    /// Over a 15 s fall a constant sideways push overpowers any heading the wind
    /// gave at birth.
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

    /// `CAEmitterCell.alphaSpeed` is one straight line, so an emitted particle can
    /// only get dimmer — hence the keyframed envelope.
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

    /// On macOS 27 a `CAEmitterCell` carrying sub-cells has the whole bounding box of
    /// its own sprite filled in by the compositor; a round nucleus leaves almost no
    /// box to fill. It only shows against a dark sky, so it is measured on screen.
    @MainActor
    func testMeteorsDoNotFillTheirSpriteBox() throws {
        let lit: (Frame) -> Bool = { Self.histogram(of: $0).lit > 400 }
        let frames = try captureSeries({ view in
            let overlay = ParticleOverlayView(frame: view.bounds)
            view.addSubview(overlay)
            overlay.setEffect(.meteors, density: 3, tiltRadians: 0)
        }, size: CGSize(width: 800, height: 600), settle: 1.8, gap: 0.4, count: 20,
           onWallClock: true, until: lit)

        var sawAMeteor = false
        for (index, frame) in frames.enumerated() {
            let (histogram, background, lit) = Self.histogram(of: frame)
            if lit > 400 {
                sawAMeteor = true
            }
            // A flat plateau: pixels sharing one exact value. Real particles are gradients,
            // so a clean frame's largest plateau is a couple of hundred pixels.
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

    /// Drops of every size in one patch of sky fall in the same direction (Garg &
    /// Nayar, CVPR 2004 §3.1), and perspective keeps a straight path's on-screen
    /// angle the same at every distance.
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

    /// Streak length is speed × one exposure, so the same exposure must fall out of
    /// every band.
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

    /// Not covered by the sprite/heading test above: that one only checks the bitmap
    /// and the cells agree with *each other*, so a mirrored compass-to-screen mapping
    /// would keep them agreeing while blowing the rain the wrong way.
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

    /// Checked on the cells rather than on a capture: a sparse effect like bokeh may
    /// genuinely have emitted nothing yet when the shutter opens.
    @MainActor
    func testEveryEffectBuildsDrawableCells() throws {
        let probe = ParticleOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        // Meteors are excluded because they are not emitted: `MeteorShower` flies one
        // sprite per meteor on its own layer, and its sprite is checked separately.
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

    /// A stretched sprite's angle is baked in at birth and cannot follow, so the
    /// heading must not swing during its life; rain is already at terminal velocity.
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
