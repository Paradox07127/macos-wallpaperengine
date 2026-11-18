import AppKit
import LiveWallpaperCore
import SwiftUI

/// The Edit Desk window's canvas. `frosted` swaps the flat fill for the desktop blurred behind the
/// window (Liquid Glass on macOS 26+); Reduce Transparency and Increase Contrast keep the flat fill, which is what both settings ask for.
struct EditDeskBackdrop: View {
    let frosted: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if frosted, !reduceTransparency, contrast != .increased {
                if AdaptiveGlass.isAvailable {
                    // The half-strength canvas under the glass keeps text on the page legible over a busy desktop.
                    Color.clear.adaptiveGlassScrimmed(
                        cornerRadius: 0, scrim: DesignTokens.EditDesk.Colors.background.opacity(0.5)
                    )
                } else {
                    BehindWindowBlur()
                }
            } else {
                DesignTokens.EditDesk.Colors.background
            }
        }
        .ignoresSafeArea()
    }
}

/// The overview's and the library's dot texture, drawn by `HomePage` over the window's canvas.
struct EditDeskDotGrid: View {
    /// Read per frame in `body`, as `EditDeskShelfScrim` does, so a moving gesture invalidates this view alone.
    let stage: EditDeskStageModel

    /// Under the grid's top the dots go over the flight's last stretch, so the grid takes over on the bare canvas.
    static func gridOpacity(_ progress: Double) -> Double {
        1 - HomeHints.ramp(progress, from: 1.6, to: 2)
    }

    /// Shared with `EditDeskRipples`, so both leave together as the library comes in.
    static func fadeMask(_ progress: Double) -> some View {
        VStack(spacing: 0) {
            Color.black.frame(height: StageGeometry.gridTop)
            Color.black.opacity(gridOpacity(progress))
        }
    }

    var body: some View {
        Image(nsImage: Self.dotTile)
            .resizable(resizingMode: .tile)
            .mask { Self.fadeMask(stage.progress) }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A SwiftUI layer rather than the stage's own `backgroundColor`: an opaque stage would force
    /// every piece of chrome above the shelf cards.
    private static let dotTile = NSImage(size: CGSize(width: 24, height: 24), flipped: true) { _ in
        NSColor(DesignTokens.EditDesk.Colors.dotGrid).setFill()
        NSBezierPath(ovalIn: CGRect(x: 11, y: 11, width: 2, height: 2)).fill()
        return true
    }
}

/// A damped wave on a square grid that the pointer pokes, in the stage's coordinates (top-left origin).
@MainActor @Observable
final class EditDeskRippleField {
    private static let spacing: CGFloat = 8
    private static let stepInterval: TimeInterval = 1.0 / 60
    private static let maxStepsPerAdvance = 4
    private static let damping: Float = 0.972
    /// Pokes along a pointer path are this far apart at most, so a fast swipe still leaves an unbroken trail.
    private static let trailStep: CGFloat = 12
    private static let hoverStrength: Float = 0.12
    private static let dragStrength: Float = 0.9
    private static let pressStrength: Float = 3
    private static let kernel: [Float] = (0 ..< 25).map { index in
        let dx = Float(index % 5 - 2), dy = Float(index / 5 - 2)
        return exp(-(dx * dx + dy * dy) / 2)
    }

    /// False once the water has gone flat; the ripple layer's timeline pauses on it.
    private(set) var isActive = false
    /// True only while the ripple layer is mounted; pokes are dropped otherwise.
    @ObservationIgnored var enabled = false {
        didSet {
            guard !enabled else { return }
            endTrail()
            settle()
        }
    }

    @ObservationIgnored private var columns = 0
    @ObservationIgnored private var rows = 0
    @ObservationIgnored private var current: [Float] = []
    @ObservationIgnored private var previous: [Float] = []
    @ObservationIgnored private var lastPoint: CGPoint?
    /// Reference-date seconds the simulation has been stepped up to.
    @ObservationIgnored private var clock: TimeInterval = 0

    init(size: CGSize) {
        resize(to: size)
    }

    func resize(to size: CGSize) {
        columns = Int((size.width / Self.spacing).rounded(.up)) + 1
        rows = Int((size.height / Self.spacing).rounded(.up)) + 1
        settle()
    }

    func hover(at point: CGPoint) {
        trail(to: point, strength: Self.hoverStrength)
    }

    func press(at point: CGPoint) {
        guard enabled else { return }
        deposit(at: point, strength: Self.pressStrength)
        lastPoint = point
        wake()
    }

    func drag(to point: CGPoint) {
        trail(to: point, strength: Self.dragStrength)
    }

    func endTrail() {
        lastPoint = nil
    }

    /// Nearest grid point's height; `point` past the grid's far edge reads the edge.
    func height(at point: CGPoint) -> Float {
        let column = min(columns - 1, Int((point.x / Self.spacing).rounded()))
        let row = min(rows - 1, Int((point.y / Self.spacing).rounded()))
        return current[row * columns + column]
    }

    /// Steps at a fixed 60Hz for the time that has passed, whatever the display's refresh rate.
    func advance(to time: TimeInterval) {
        guard isActive else { return }
        let due = Int((time - clock) / Self.stepInterval)
        guard due > 0 else { return }
        clock = due > Self.maxStepsPerAdvance ? time : clock + Double(due) * Self.stepInterval
        for _ in 0 ..< min(due, Self.maxStepsPerAdvance) {
            step()
        }
        if current.allSatisfy({ abs($0) < 0.01 }) {
            settle()
        }
    }

    private func trail(to point: CGPoint, strength: Float) {
        guard enabled else { return }
        if let lastPoint {
            let steps = max(1, Int((hypot(point.x - lastPoint.x, point.y - lastPoint.y) / Self.trailStep).rounded(.up)))
            for index in 1 ... steps {
                let t = CGFloat(index) / CGFloat(steps)
                deposit(at: CGPoint(x: lastPoint.x + (point.x - lastPoint.x) * t, y: lastPoint.y + (point.y - lastPoint.y) * t), strength: strength)
            }
        } else {
            deposit(at: point, strength: strength)
        }
        lastPoint = point
        wake()
    }

    private func deposit(at point: CGPoint, strength: Float) {
        let column = Int((point.x / Self.spacing).rounded()), row = Int((point.y / Self.spacing).rounded())
        for dy in -2 ... 2 {
            for dx in -2 ... 2 {
                let r = row + dy, c = column + dx
                // The border stays at rest: the step never writes it.
                guard r > 0, r < rows - 1, c > 0, c < columns - 1 else { continue }
                current[r * columns + c] += strength * Self.kernel[(dy + 2) * 5 + dx + 2]
            }
        }
    }

    private func step() {
        let columns = columns, rows = rows
        current.withUnsafeBufferPointer { now in
            previous.withUnsafeMutableBufferPointer { next in
                for row in 1 ..< rows - 1 {
                    for k in row * columns + 1 ..< (row + 1) * columns - 1 {
                        next[k] = ((now[k - 1] + now[k + 1] + now[k - columns] + now[k + columns]) / 2 - next[k]) * Self.damping
                    }
                }
            }
        }
        swap(&current, &previous)
    }

    private func wake() {
        guard !isActive else { return }
        clock = Date.timeIntervalSinceReferenceDate
        isActive = true
    }

    private func settle() {
        current = Array(repeating: 0, count: columns * rows)
        previous = current
        if isActive {
            isActive = false
        }
    }
}

/// The home page's character water over the dot grid: glyphs only where the field is disturbed.
struct EditDeskRipples: View {
    let stage: EditDeskStageModel

    private static let density = Array(" .·:-=+*#%@")
    private static let cell = CGSize(width: 9, height: 14)

    @State private var pressing = false

    var body: some View {
        let ripples = stage.ripples
        TimelineView(.animation(paused: !ripples.isActive)) { timeline in
            Canvas { context, size in
                ripples.advance(to: timeline.date.timeIntervalSinceReferenceDate)
                guard ripples.isActive else { return }
                let glyphs = Self.density.map {
                    context.resolve(
                        Text(verbatim: String($0))
                            .font(DesignTokens.EditDesk.Typography.metaMono)
                            .foregroundStyle(DesignTokens.EditDesk.Colors.rippleGlyph)
                    )
                }
                for row in 0 ..< Int(size.height / Self.cell.height) + 1 {
                    for column in 0 ..< Int(size.width / Self.cell.width) + 1 {
                        let center = CGPoint(
                            x: (CGFloat(column) + 0.5) * Self.cell.width, y: (CGFloat(row) + 0.5) * Self.cell.height
                        )
                        let height = abs(ripples.height(at: center))
                        guard height >= 0.03 else { continue }
                        context.opacity = Double(min(1, height * 1.3))
                        context.draw(glyphs[min(10, 1 + Int(height * 12))], at: center)
                    }
                }
            }
        }
        .mask { EditDeskDotGrid.fadeMask(stage.progress) }
        .ignoresSafeArea()
        // Hit only by presses on bare canvas: the stage passes those through, and every control sits above this layer.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if pressing {
                        ripples.drag(to: value.location)
                    } else {
                        pressing = true
                        ripples.press(at: value.location)
                    }
                }
                .onEnded { _ in
                    pressing = false
                    ripples.endTrail()
                }
        )
        .accessibilityHidden(true)
        .onAppear { ripples.enabled = true }
        .onDisappear { ripples.enabled = false }
    }
}

/// SCREENS S2: the shelf band darkens from transparent to scrim over the bottom 30%. Outside the
/// stage so the chip row can sit over it and still be under the cards.
struct EditDeskShelfScrim: View {
    /// Read per frame in `body` rather than handed in, so a moving gesture invalidates this view
    /// instead of the whole page.
    let stage: EditDeskStageModel

    /// The band's background, so it leads the chrome that sits over it; it leaves with the cards,
    /// so the grid takes over from a clear band.
    static func opacity(_ progress: Double) -> Double {
        HomeHints.ramp(progress, from: 0.05, to: 0.6) * (1 - HomeHints.ramp(progress, from: 1, to: 2))
    }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: DesignTokens.EditDesk.Colors.shelfScrim, location: 0.7),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: StageGeometry.shelfHeight)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .opacity(Self.opacity(stage.progress))
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Lights the shelf band while a Finder file over it would only join the library, in the look a
/// display takes for "drop to replace".
struct ShelfDropHighlight: View {
    /// Read per frame in `body`, as `EditDeskShelfScrim` does, so the band rides the rising shelf.
    let stage: EditDeskStageModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panelLarge)
        shape
            .fill(DesignTokens.EditDesk.Colors.dropHighlight)
            .overlay { shape.strokeBorder(DesignTokens.EditDesk.Colors.success, lineWidth: 2) }
            .shadow(color: DesignTokens.EditDesk.Colors.dropHighlightGlow, radius: 30)
            .overlay {
                Text("Add to Library")
                    .font(DesignTokens.EditDesk.Typography.dropLabel)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }
            .opacity(stage.shelfDropTargeted ? 1 : 0)
            // Inside the placement below, so only the fade animates: the band follows the shelf frame by frame.
            .animation(reduceMotion ? DesignTokens.Motion.reducedMotionFade : DesignTokens.Motion.feedback, value: stage.shelfDropTargeted)
            .frame(height: StageGeometry.cardSize.height + 2 * DesignTokens.EditDesk.Spacing.s12)
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.gutter)
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(y: StageGeometry.shelfRowTop(progress: stage.progress, windowSize: stage.stageSize) - DesignTokens.EditDesk.Spacing.s12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        view.state = .active
    }
}
