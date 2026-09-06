import LiveWallpaperCore
import SwiftUI

enum WeatherWidgetOptions {
    static let showCaptionKey = "showCaption"
    static let showCaptionDefault = true

    static func showsCaption(_ placement: MonitorWidgetPlacement) -> Bool {
        placement.options[showCaptionKey]?.boolValue ?? showCaptionDefault
    }
}

/// The local sky as a picture, not a readout: a gradient for the weather and
/// the hour, clouds, rain or snow leaning with the real wind, fog, stars, the
/// odd lightning strike. One small caption names the condition and the place.
struct WeatherWidgetView: View {
    let context: MonitorWidgetContext

    @Environment(\.monitorWeather) private var weather
    @Environment(\.monitorSuspended) private var suspended

    private var scene: WeatherScene? {
        guard let weather, let condition = weather.currentCondition else { return nil }
        return WeatherScene.make(
            condition: condition,
            isDaylight: weather.currentIsDaylight,
            intensity: weather.currentIntensity,
            wind: weather.currentWind
        )
    }

    var body: some View {
        GeometryReader { geo in
            let rows = context.placement.kind.cellSize(for: context.placement.size).rows
            let scale = Design.TypeScale(cellHeight: geo.size.height / CGFloat(max(rows, 1)))
            ZStack(alignment: .topLeading) {
                if let scene {
                    WeatherSceneCanvas(scene: scene, paused: context.reduceMotion || suspended)
                } else {
                    noSky(scale: scale)
                }
                VStack(alignment: .leading) {
                    header(scale: scale)
                    Spacer(minLength: 0)
                    if WeatherWidgetOptions.showsCaption(context.placement) {
                        caption(scale: scale)
                    }
                }
                .padding(.horizontal, Design.contentInsetH)
                .padding(.vertical, Design.contentInsetV)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .monitorPanelChrome()
        }
    }

    /// Same type and tracking as every other tile's header, in white because
    /// it sits on a sky rather than on the panel material.
    private func header(scale: Design.TypeScale) -> some View {
        let size = scale.label + 1
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: WidgetFactory.icon(.weather))
                .font(Design.labelFont(size: size))
            Text(verbatim: WidgetFactory.displayName(.weather).uppercased())
                .font(Design.labelFont(size: size))
                .tracking(Design.labelTracking(size: size))
        }
        .foregroundStyle(.white.opacity(0.72))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func caption(scale: Design.TypeScale) -> some View {
        if let weather, let condition = weather.currentCondition {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: condition.localizedTitle)
                    .font(Design.subFont(size: scale.sub))
                    .foregroundStyle(.white.opacity(0.92))
                if let place = weather.activeLocationLabel {
                    Text(verbatim: place)
                        .font(Design.captionFont(size: scale.caption))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(
                "Weather status: \(condition.localizedTitle)",
                comment: "Weather badge a11y label. The placeholder is the current condition or location status."
            ))
        }
    }

    /// No condition yet: the panel material and the reason, so an empty tile
    /// is never mistaken for a clear sky.
    private func noSky(scale: Design.TypeScale) -> some View {
        VStack(spacing: 6) {
            Image(systemName: WidgetFactory.icon(.weather))
                .font(.system(size: scale.hero * 0.6, weight: .regular))
                .foregroundStyle(Design.inkFaint)
            Text(verbatim: weather?.locationStatus.localizedTitle ?? WidgetFactory.displayName(.weather))
                .font(Design.captionFont(size: scale.caption))
                .foregroundStyle(Design.inkMuted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Design.contentInsetH)
    }
}

// MARK: - Canvas

/// Redraws only as often as the scene needs, and not at all while the board is
/// suspended or the user asked for reduced motion (the picture stays; it just
/// stops moving). Every particle is a pure function of its index and the clock,
/// so there is no simulation state to keep or to fall behind.
private struct WeatherSceneCanvas: View {
    let scene: WeatherScene
    let paused: Bool
    @State private var epoch = Date()

    private var interval: TimeInterval {
        switch scene.motion {
        case .still: 1
        case .drifting: 1 / 12
        case .falling: 1 / 30
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: paused || scene.motion == .still)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                WeatherScenePainter(scene: scene, size: size, time: timeline.date.timeIntervalSince(epoch))
                    .draw(in: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct WeatherScenePainter {
    let scene: WeatherScene
    let size: CGSize
    let time: TimeInterval

    private var w: CGFloat {
        size.width
    }

    private var h: CGFloat {
        size.height
    }

    private var m: CGFloat {
        min(size.width, size.height)
    }

    /// Tile-relative pace: a 300 pt tall tile runs at unit speed.
    private var pace: CGFloat {
        min(max(h / 300, 0.5), 1.2)
    }

    func draw(in context: inout GraphicsContext) {
        drawSky(&context)
        if scene.sun {
            drawSun(&context)
        }
        if scene.moon {
            drawMoon(&context)
        }
        if scene.stars {
            drawStars(&context)
        }
        if scene.cloudCover > 0 {
            drawClouds(&context)
        }
        switch scene.precipitation {
        case .rain: drawRain(&context)
        case .snow: drawSnow(&context)
        case .none: break
        }
        if scene.lightning {
            drawLightning(&context)
        }
        if scene.fog > 0 {
            drawFog(&context)
        }
    }

    // MARK: Deterministic per-particle constants

    /// A stable number in 0..<1 for particle `index` and purpose `salt`, so the
    /// same drop is in the same place on every redraw (splitmix64 finaliser).
    static func unit(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15
        x &+= UInt64(bitPattern: Int64(salt)) &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 31
        x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 29
        return Double(x >> 11) / Double(1 << 53)
    }

    private func unit(_ index: Int, _ salt: Int) -> CGFloat {
        CGFloat(Self.unit(index, salt))
    }

    private func color(_ stop: WeatherScene.SkyStop, alpha: Double = 1) -> Color {
        Design.oklch(stop.l, stop.c, stop.h, alpha: alpha)
    }

    // MARK: Sky and lights

    private func drawSky(_ context: inout GraphicsContext) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [color(scene.skyTop), color(scene.skyBottom)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
            )
        )
    }

    private func drawSun(_ context: inout GraphicsContext) {
        let center = CGPoint(x: w * 0.78, y: h * 0.26)
        let glow = Design.oklch(0.96, 0.08, 85)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - m * 0.55, y: center.y - m * 0.55, width: m * 1.1, height: m * 1.1)),
            with: .radialGradient(
                Gradient(colors: [glow.opacity(0.55), glow.opacity(0)]),
                center: center, startRadius: 0, endRadius: m * 0.55
            )
        )
        let r = m * 0.085
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
            with: .color(Design.oklch(0.98, 0.05, 90))
        )
    }

    private func drawMoon(_ context: inout GraphicsContext) {
        let center = CGPoint(x: w * 0.76, y: h * 0.24)
        let glow = Design.oklch(0.92, 0.03, 250)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - m * 0.35, y: center.y - m * 0.35, width: m * 0.7, height: m * 0.7)),
            with: .radialGradient(
                Gradient(colors: [glow.opacity(0.22), glow.opacity(0)]),
                center: center, startRadius: 0, endRadius: m * 0.35
            )
        )
        let r = m * 0.065
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
            with: .color(Design.oklch(0.95, 0.02, 90))
        )
    }

    private func drawStars(_ context: inout GraphicsContext) {
        let count = 20 + Int(w * h / 2200)
        for index in 0 ..< count {
            let x = unit(index, 1) * w
            let y = unit(index, 2) * h * 0.7
            let radius = 0.5 + unit(index, 3) * 0.9
            // Each star twinkles on its own period and phase.
            let twinkle = 0.5 + 0.5 * sin(time * (0.6 + Double(unit(index, 4)) * 1.4) + Double(unit(index, 5)) * .pi * 2)
            let alpha = 0.35 + 0.6 * twinkle
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(alpha))
            )
        }
    }

    // MARK: Clouds and fog

    private func drawClouds(_ context: inout GraphicsContext) {
        let count = 2 + Int(scene.cloudCover * 4)
        let light = scene.isDaylight ? 1.0 : 0.55
        let l = (0.30 + 0.67 * scene.cloudBrightness) * light
        let fill = Design.oklch(l, 0.008, 240, alpha: 0.45 + 0.35 * scene.cloudCover)
        let drift = (6 + 14 * CGFloat(scene.wind)) * pace
        for index in 0 ..< count {
            let width = m * (0.45 + 0.35 * unit(index, 11))
            let height = width * 0.36
            let span = w + width
            let speed = drift * (0.5 + unit(index, 12))
            let x = ((unit(index, 13) * span + CGFloat(time) * speed).truncatingRemainder(dividingBy: span)) - width
            let y = h * (0.06 + 0.4 * unit(index, 14))
            context.fill(cloudPath(x: x, y: y, width: width, height: height, seed: index), with: .color(fill))
        }
    }

    /// A flat base with three domes; one path, so overlaps do not double up.
    private func cloudPath(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, seed: Int) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: x, y: y + height * 0.4, width: width, height: height * 0.6))
        let domes: [(CGFloat, CGFloat)] = [(0.12, 0.62), (0.38, 0.9), (0.62, 0.72)]
        for (offset, scale) in domes {
            let d = height * scale * (0.9 + 0.2 * unit(seed, 15 + Int(offset * 100)))
            path.addEllipse(in: CGRect(x: x + width * offset, y: y + height - d, width: d * 1.15, height: d))
        }
        return path
    }

    /// Each wisp is a circle with a radial falloff, drawn through a context
    /// squashed to the wisp's aspect: a radial gradient clipped by a flat
    /// ellipse ends in a hard edge where the ellipse cuts it off.
    private func drawFog(_ context: inout GraphicsContext) {
        let alpha = (scene.isDaylight ? 0.28 : 0.16) * scene.fog
        for index in 0 ..< 5 {
            let width = w * 1.1
            let height = h * (0.28 + 0.2 * unit(index, 21))
            let sway = w * 0.12 * sin(time * (0.05 + Double(unit(index, 22)) * 0.06) + Double(unit(index, 23)) * .pi * 2)
            let center = CGPoint(x: w * 0.5 + sway, y: h * (0.1 + 0.75 * unit(index, 24)))
            var squashed = context
            squashed.translateBy(x: center.x, y: center.y)
            squashed.scaleBy(x: 1, y: height / width)
            let radius = width / 2
            squashed.fill(
                Path(ellipseIn: CGRect(x: -radius, y: -radius, width: width, height: width)),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(alpha), .white.opacity(0)]),
                    center: .zero, startRadius: 0, endRadius: radius
                )
            )
        }
    }

    // MARK: Precipitation

    /// Same depth law as the full-screen rain: three bands, everything by 1/z,
    /// one lean shared by all of them.
    private func drawRain(_ context: inout GraphicsContext) {
        let count = Int(scene.precipitationRate * Double(w * h) / 10000 * 12)
        guard count > 0 else { return }
        let lean = CGFloat(scene.lean)
        let nearSpeed: CGFloat = 420 * pace
        let exposure: CGFloat = 0.04
        let bands: [(z: CGFloat, share: Double)] = [(1.0, 0.2), (1.6, 0.32), (2.6, 0.48)]
        var first = 0
        for band in bands {
            let n = max(1, Int(Double(count) * band.share))
            let speed = nearSpeed / band.z
            let length = speed * exposure
            let width = max(1.7 / band.z, 0.6)
            let alpha = 0.75 / pow(Double(band.z), 0.7)
            let margin = h * abs(tan(lean)) + length
            let span = w + 2 * margin
            let travel = h + 2 * length
            var path = Path()
            for index in first ..< (first + n) {
                let progress = (unit(index, 31) + CGFloat(time) * speed / travel).truncatingRemainder(dividingBy: 1)
                let y = progress * travel - length
                var x = unit(index, 32) * span - margin + tan(lean) * (y + length)
                x = ((x + margin).truncatingRemainder(dividingBy: span) + span).truncatingRemainder(dividingBy: span) - margin
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x - length * sin(lean), y: y - length * cos(lean)))
            }
            context.stroke(path, with: .color(.white.opacity(alpha)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            first += n
        }
    }

    private func drawSnow(_ context: inout GraphicsContext) {
        let count = Int(scene.precipitationRate * Double(w * h) / 10000 * 7)
        guard count > 0 else { return }
        let lean = CGFloat(scene.lean)
        let bands: [(z: CGFloat, share: Double)] = [(1.0, 0.25), (1.5, 0.35), (2.3, 0.4)]
        var first = 0
        for band in bands {
            let n = max(1, Int(Double(count) * band.share))
            let radius = 2.6 / band.z * max(pace, 0.7)
            let speed = 38 * pace / band.z
            let sway = 7 / band.z
            let alpha = 0.9 / pow(Double(band.z), 0.5)
            let margin = h * abs(tan(lean)) + sway + radius
            let span = w + 2 * margin
            let travel = h + 2 * radius
            for index in first ..< (first + n) {
                let progress = (unit(index, 41) + CGFloat(time) * speed / travel).truncatingRemainder(dividingBy: 1)
                let y = progress * travel - radius
                let wobble = sway * sin(CGFloat(time) * (0.8 + unit(index, 42)) + unit(index, 43) * .pi * 2)
                var x = unit(index, 44) * span - margin + tan(lean) * (y + radius) + wobble
                x = ((x + margin).truncatingRemainder(dividingBy: span) + span).truncatingRemainder(dividingBy: span) - margin
                let halo = radius * 1.8
                context.fill(
                    Path(ellipseIn: CGRect(x: x - halo, y: y - halo, width: halo * 2, height: halo * 2)),
                    with: .color(.white.opacity(alpha * 0.25))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(.white.opacity(alpha))
                )
            }
            first += n
        }
    }

    // MARK: Lightning

    /// One strike every `period` seconds at a seeded moment inside it; each
    /// flash is two pulses, the return stroke right after the first. Only some
    /// strikes show a bolt — the rest is sheet lightning behind the cloud.
    static let lightningPeriod: TimeInterval = 8

    static func lightningFlash(at time: TimeInterval) -> (brightness: Double, strike: Int) {
        let current = Int(floor(time / lightningPeriod))
        var best: (Double, Int) = (0, current)
        for strike in [current - 1, current] {
            let at = Double(strike) * lightningPeriod + 0.5 + 5 * unit(strike, 51)
            let dt = time - at
            guard dt >= 0 else { continue }
            let brightness = exp(-pow(dt / 0.07, 2)) + 0.7 * exp(-pow((dt - 0.18) / 0.09, 2))
            if brightness > best.0 {
                best = (brightness, strike)
            }
        }
        return best
    }

    private func drawLightning(_ context: inout GraphicsContext) {
        let (brightness, strike) = Self.lightningFlash(at: time)
        guard brightness > 0.02 else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.4 * brightness)))
        guard unit(strike, 52) > 0.35 else { return }

        var path = Path()
        var point = CGPoint(x: w * (0.2 + 0.6 * unit(strike, 53)), y: h * 0.15)
        let endY = h * (0.6 + 0.25 * unit(strike, 54))
        let segments = 9
        path.move(to: point)
        for segment in 1 ... segments {
            point.x += (unit(strike, 60 + segment) - 0.5) * w * 0.11
            point.y += (endY - h * 0.15) / CGFloat(segments)
            path.addLine(to: point)
        }
        let bolt = Design.oklch(0.97, 0.03, 260)
        context.stroke(path, with: .color(bolt.opacity(0.35 * brightness)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(bolt.opacity(min(1, 0.95 * brightness))), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }
}
