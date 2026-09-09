import SwiftUI

struct Sparkline: View {
    /// Timestamped samples; `nil` values are gaps, not zeroes.
    var points: [MonitorHistoryPoint]
    /// X is `(t - window.start) / window.length`, so the same instant lands at
    /// the same place whatever the sampling rate.
    var window: MonitorChartWindow
    var domain: ClosedRange<Double>?
    /// When true (and the domain is 0…1-like), colour the stroke by load band at
    /// each sample; otherwise use `lineColor`.
    var bandColored: Bool = false
    var lineColor: Color = Design.signalAmber
    var showArea: Bool = true
    var guides: [Double] = []
    var lineWidth: CGFloat = 1.6

    /// Draw paths in one Canvas pass. Keep the endpoint dot outside Canvas so its glow is not clipped.
    /// Read GeometryReader size directly so the dot is present on the first frame.
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let (lo, hi) = resolvedDomain()
            let span = max(hi - lo, .ulpOfOne)
            // Nothing at all for an empty series — not even the baseline, which
            // is what the previous `if let pts = points(...)` gate produced.
            let runs = drawableRuns(in: size, lo: lo, span: span)
            guard !runs.isEmpty else { return }

            draw(baselinePath(w: size.width, h: size.height), in: &context)
            drawGuides(in: &context, w: size.width, h: size.height, lo: lo, span: span)

            if showArea {
                for pts in runs where pts.count >= 2 {
                    context.fill(
                        areaPath(pts, height: size.height),
                        with: .linearGradient(
                            Gradient(colors: [areaColor().opacity(0.26), areaColor().opacity(0)]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)
                        )
                    )
                }
            }

            for pts in runs where pts.count >= 2 {
                context.stroke(
                    linePath(pts),
                    with: lineShading(width: size.width),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }

            // A sample with no drawable neighbour is a point. Reaching to the
            // next one would invent the line across the gap that isolated it.
            for pts in runs where pts.count == 1 {
                context.fill(dotPath(at: pts[0]), with: .color(areaColor()))
            }
        }
        .overlay {
            GeometryReader { proxy in endpointDot(in: proxy.size) }
        }
    }

    @ViewBuilder
    private func endpointDot(in size: CGSize) -> some View {
        let (lo, hi) = resolvedDomain()
        let span = max(hi - lo, .ulpOfOne)
        if size.width > 0,
           let newest = points.last(where: { $0.value != nil }),
           let value = newest.value {
            Circle()
                .fill(nowColor())
                .frame(width: 6, height: 6)
                .position(
                    x: ChartTimeAxis.x(newest.time, in: window, width: size.width),
                    y: y(value, height: size.height, lo: lo, span: span)
                )
                .shadow(color: nowColor().opacity(0.6), radius: 3)
        }
    }

    private func draw(_ path: Path, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(Design.hairline.opacity(0.45)), lineWidth: 1)
    }

    private func drawGuides(
        in context: inout GraphicsContext,
        w: CGFloat,
        h: CGFloat,
        lo: Double,
        span: Double
    ) {
        guard !guides.isEmpty else { return }
        let shading = GraphicsContext.Shading.color(Design.hairlineHi.opacity(0.3))
        let style = StrokeStyle(lineWidth: 1, dash: [3, 3])
        for guide in guides {
            let y = h - CGFloat((guide - lo) / span) * h
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: w, y: y))
            context.stroke(path, with: shading, style: style)
        }
    }

    private func baselinePath(w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h - 1))
        path.addLine(to: CGPoint(x: w, y: h - 1))
        return path
    }

    // MARK: - Geometry

    private var presentValues: [Double] {
        points.compactMap(\.value)
    }

    private func resolvedDomain() -> (Double, Double) {
        if let domain {
            return (domain.lowerBound, domain.upperBound)
        }
        guard let lo = presentValues.min(), let hi = presentValues.max() else { return (0, 1) }
        if hi == lo {
            return (lo - 0.5, hi + 0.5)
        }
        let pad = (hi - lo) * 0.12
        return (lo, hi + pad)
    }

    private func y(_ value: Double, height: CGFloat, lo: Double, span: Double) -> CGFloat {
        let raw = height - CGFloat((value - lo) / span) * height
        return min(height, max(0, raw))
    }

    private func drawableRuns(in size: CGSize, lo: Double, span: Double) -> [[CGPoint]] {
        guard size.width > 0 else { return [] }
        return ChartTimeAxis.runs(points, tolerance: window.tolerance).map { range in
            points[range].map { point in
                CGPoint(
                    x: ChartTimeAxis.x(point.time, in: window, width: size.width),
                    y: y(point.value ?? 0, height: size.height, lo: lo, span: span)
                )
            }
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        return p
    }

    private func dotPath(at point: CGPoint) -> Path {
        Path(ellipseIn: CGRect(x: point.x - lineWidth, y: point.y - lineWidth,
                               width: lineWidth * 2, height: lineWidth * 2))
    }

    private func areaPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = Path()
        guard let first = pts.first, let last = pts.last else { return p }
        p.move(to: CGPoint(x: first.x, y: height))
        for point in pts { p.addLine(to: point) }
        p.addLine(to: CGPoint(x: last.x, y: height))
        p.closeSubpath()
        return p
    }

    // MARK: - Colour

    private var lastFraction: Double {
        presentValues.last ?? 0
    }

    private func areaColor() -> Color {
        bandColored ? Design.loadBandColor(lastFraction) : lineColor
    }

    private func nowColor() -> Color {
        bandColored ? Design.loadBandColor(lastFraction) : lineColor
    }

    /// Band-coloured mode uses a horizontal gradient keyed to each sample's band
    /// at its own time position; otherwise a solid stroke.
    private func lineShading(width: CGFloat) -> GraphicsContext.Shading {
        let real = points.compactMap { point in point.value.map { (point.time, $0) } }
        guard bandColored, real.count >= 2 else { return .color(lineColor) }
        let stops = real.map { time, value in
            Gradient.Stop(
                color: Design.loadBandColor(value),
                location: CGFloat(min(1, max(0, window.fraction(of: time))))
            )
        }
        return .linearGradient(
            Gradient(stops: stops),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: width, y: 0)
        )
    }
}

extension [MonitorHistoryPoint] {
    static func evenlySpaced(
        _ values: [Double?], endingAt reference: Double, every step: Double = 1
    ) -> [MonitorHistoryPoint] {
        values.enumerated().map { index, value in
            MonitorHistoryPoint(
                time: reference - Double(values.count - 1 - index) * step, value: value
            )
        }
    }
}

#Preview("Sparkline") {
    let now = Date().timeIntervalSince1970
    let window = MonitorChartWindow(reference: now, seconds: 10, interval: 1)
    VStack(spacing: 20) {
        Sparkline(points: .evenlySpaced([0.2, 0.35, 0.28, 0.55, 0.72, 0.68, 0.9, 0.84], endingAt: now),
                  window: window, domain: 0 ... 1, bandColored: true, guides: [0.4, 0.8])
            .frame(width: 260, height: 60)

        Sparkline(points: .evenlySpaced([12, 18, nil, 22, 31, 26, 20, 24], endingAt: now),
                  window: window, lineColor: Design.signalSteel)
            .frame(width: 260, height: 60)

        Sparkline(points: [], window: window, domain: 0 ... 1)
            .frame(width: 260, height: 40)
            // `verbatim:` or SwiftUI reads the literal as a LocalizedStringKey and the
            // extractor lands a bogus `empty` key in the catalog, failing coverage.
            .overlay(Text(verbatim: "empty").font(Design.captionFont(size: 11))
                .foregroundStyle(Design.inkFaint))
    }
    .padding(24)
    .background(Design.boardWash)
}
