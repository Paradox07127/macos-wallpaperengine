import SwiftUI

struct MirroredAreaChart: View {
    var up: [MonitorHistoryPoint]
    var down: [MonitorHistoryPoint]
    /// X is `(t - window.start) / window.length`, and a step wider than the
    /// window's tolerance breaks the path instead of being bridged.
    var window: MonitorChartWindow
    var upColor: Color = Design.signalSteel
    var downColor: Color = Design.signalSage
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, mid = h / 2
            let scale = sharedMax()
            let upRuns = runs(up, width: w, mid: mid, up: true, scale: scale)
            let downRuns = runs(down, width: w, mid: mid, up: false, scale: scale)

            if !upRuns.isEmpty || !downRuns.isEmpty {
                ZStack {
                    band(upRuns, mid: mid, color: upColor, up: true)
                    band(downRuns, mid: mid, color: downColor, up: false)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: mid))
                        p.addLine(to: CGPoint(x: w, y: mid))
                    }
                    .stroke(Design.hairlineHi.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
    }

    @ViewBuilder
    private func band(_ runs: [[CGPoint]], mid: CGFloat, color: Color, up: Bool) -> some View {
        ForEach(Array(runs.enumerated()), id: \.offset) { item in
            if item.element.count >= 2 {
                area(item.element, mid: mid).fill(gradient(color, up: up))
                line(item.element).stroke(color, style: stroke)
            } else if let only = item.element.first {
                // Lone sample: a dot, never a line reaching across the gap.
                Circle().fill(color).frame(width: lineWidth * 2, height: lineWidth * 2)
                    .position(only)
            }
        }
        dot(runs.last?.last, color: color)
    }

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineJoin: .round) }

    private func sharedMax() -> Double {
        let m = max(peak(up), peak(down), .ulpOfOne)
        return m * 1.15   // headroom, matching the mock
    }

    private func peak(_ points: [MonitorHistoryPoint]) -> Double {
        points.compactMap(\.value).max() ?? 0
    }

    private func runs(
        _ points: [MonitorHistoryPoint], width: CGFloat, mid: CGFloat, up: Bool, scale: Double
    ) -> [[CGPoint]] {
        guard width > 0 else { return [] }
        let extent = mid - 2
        return ChartTimeAxis.runs(points, tolerance: window.tolerance).map { range in
            points[range].map { point in
                let f = CGFloat(min(1, max(0, (point.value ?? 0) / scale)))
                return CGPoint(
                    x: ChartTimeAxis.x(point.time, in: window, width: width),
                    y: up ? mid - f * extent : mid + f * extent
                )
            }
        }
    }

    private func line(_ pts: [CGPoint]) -> Path {
        var p = Path(); p.addLines(pts); return p
    }

    private func area(_ pts: [CGPoint], mid: CGFloat) -> Path {
        var p = Path()
        guard let first = pts.first, let last = pts.last else { return p }
        p.move(to: CGPoint(x: first.x, y: mid))
        for point in pts { p.addLine(to: point) }
        p.addLine(to: CGPoint(x: last.x, y: mid))
        p.closeSubpath()
        return p
    }

    private func gradient(_ color: Color, up: Bool) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.5), color.opacity(0)],
            startPoint: up ? .bottom : .top,
            endPoint: up ? .top : .bottom
        )
    }

    @ViewBuilder
    private func dot(_ point: CGPoint?, color: Color) -> some View {
        if let point {
            Circle().fill(color).frame(width: 6, height: 6).position(point)
                .shadow(color: color.opacity(0.6), radius: 3)
        }
    }
}

#Preview("Mirrored area") {
    let now = Date().timeIntervalSince1970
    MirroredAreaChart(
        up: .evenlySpaced([3.1, 4.2, 5.5, 6.8, nil, 4.1, 6.3, 8.1, 7.2, 5.4], endingAt: now),
        down: .evenlySpaced([0.4, 0.6, 0.9, 0.7, nil, 0.8, 1.1, 0.9, 0.6, 0.5], endingAt: now),
        window: MonitorChartWindow(reference: now, seconds: 12, interval: 1)
    )
    .frame(width: 260, height: 64)
    .padding(24)
    .background(Design.boardWash)
}
