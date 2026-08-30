import SwiftUI

struct Sparkline: View {
    var values: [Double]
    var domain: ClosedRange<Double>?
    /// When true (and the domain is 0…1-like), colour the stroke by load band at
    /// each sample; otherwise use `lineColor`.
    var bandColored: Bool = false
    var lineColor: Color = Design.signalAmber
    var showArea: Bool = true
    var guides: [Double] = []
    var lineWidth: CGFloat = 1.6

    /// Paths in one immediate-mode pass instead of a `ZStack` of `Path`s, a guide `ForEach`, and a gradient — every monitor
    /// widget rebuilt that tree on its sample tick (`CPUStackChart` here already draws this way). The endpoint dot stays a
    /// real view at `x == width`, its glow deliberately spilling past the sparkline's bounds — `Canvas` clips to its frame,
    /// so drawing the dot there would shave off half of it and its shadow. Reads size from a `GeometryReader`, not
    /// `onGeometryChange` into `@State`: the state round-trip costs a pass, so the dot was missing from the sparkline's first
    /// frame.
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let (lo, hi) = resolvedDomain()
            let span = max(hi - lo, .ulpOfOne)
            // Nothing at all for an empty series — not even the baseline, which
            // is what the previous `if let pts = points(...)` gate produced.
            guard let pts = points(in: size, lo: lo, span: span), !pts.isEmpty else { return }

            draw(baselinePath(w: size.width, h: size.height), in: &context)
            drawGuides(in: &context, w: size.width, h: size.height, lo: lo, span: span)

            if showArea, pts.count >= 2 {
                context.fill(
                    areaPath(pts, height: size.height),
                    with: .linearGradient(
                        Gradient(colors: [areaColor().opacity(0.26), areaColor().opacity(0)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }

            if pts.count >= 2 {
                context.stroke(
                    linePath(pts),
                    with: lineShading(width: size.width),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
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
           let last = points(in: size, lo: lo, span: span)?.last {
            Circle()
                .fill(nowColor())
                .frame(width: 6, height: 6)
                .position(last)
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

    private func resolvedDomain() -> (Double, Double) {
        if let domain { return (domain.lowerBound, domain.upperBound) }
        guard let lo = values.min(), let hi = values.max() else { return (0, 1) }
        if hi == lo { return (lo - 0.5, hi + 0.5) }
        let pad = (hi - lo) * 0.12
        return (lo, hi + pad)
    }

    private func points(in size: CGSize, lo: Double, span: Double) -> [CGPoint]? {
        guard !values.isEmpty else { return nil }
        let n = values.count
        let h = size.height
        if n == 1 {
            let y = h - CGFloat((values[0] - lo) / span) * h
            return [CGPoint(x: size.width, y: y)]
        }
        return values.enumerated().map { i, v in
            let x = CGFloat(i) / CGFloat(n - 1) * size.width
            let y = h - CGFloat((v - lo) / span) * h
            return CGPoint(x: x, y: min(h, max(0, y)))
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        return p
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

    private var lastFraction: Double { values.last ?? 0 }

    private func areaColor() -> Color {
        bandColored ? Design.loadBandColor(lastFraction) : lineColor
    }

    private func nowColor() -> Color {
        bandColored ? Design.loadBandColor(lastFraction) : lineColor
    }

    /// Band-coloured mode uses a horizontal gradient keyed to each sample's band;
    /// otherwise a solid stroke.
    private func lineShading(width: CGFloat) -> GraphicsContext.Shading {
        guard bandColored, values.count >= 2 else { return .color(lineColor) }
        let stops = values.enumerated().map { index, value -> Gradient.Stop in
            Gradient.Stop(
                color: Design.loadBandColor(value),
                location: CGFloat(index) / CGFloat(values.count - 1)
            )
        }
        return .linearGradient(
            Gradient(stops: stops),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: width, y: 0)
        )
    }
}

#Preview("Sparkline") {
    VStack(spacing: 20) {
        Sparkline(values: [0.2, 0.35, 0.28, 0.55, 0.72, 0.68, 0.9, 0.84],
                  domain: 0...1, bandColored: true, guides: [0.4, 0.8])
            .frame(width: 260, height: 60)

        Sparkline(values: [12, 18, 14, 22, 31, 26, 20, 24].map(Double.init),
                  lineColor: Design.signalSteel)
            .frame(width: 260, height: 60)

        Sparkline(values: [], domain: 0...1)
            .frame(width: 260, height: 40)
            // `verbatim:` or SwiftUI reads the literal as a LocalizedStringKey and the
            // extractor lands a bogus `empty` key in the catalog, failing coverage.
            .overlay(Text(verbatim: "empty").font(Design.captionFont(size: 11))
                .foregroundStyle(Design.inkFaint))
    }
    .padding(24)
    .background(Design.boardWash)
}
