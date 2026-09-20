import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Pure geometry for the stage and shelf. Every rect is in window points with a top-left
/// origin, matching SCREENS.md; only `arrangement(frames:in:)` takes `NSScreen.frame` (y-up).
enum StageGeometry {
    // MARK: Window

    static let designWindow = CGSize(width: 1280, height: 820)
    static let minimumWindow = CGSize(width: 1040, height: 700)
    static let topBarHeight: CGFloat = 56
    static let progressRange: ClosedRange<Double> = 0 ... 2

    // MARK: Arrangement (S1)

    /// Points of `NSScreen.frame` per stage point before the cap applies.
    static let nominalDisplayScale: CGFloat = 1 / 4
    static let arrangementMaxSize = CGSize(width: 1180, height: 560)
    /// Clear space inserted between neighbouring displays. The row gap also has to clear the upper
    /// display's name row and the lower one's type badge, which is why it dwarfs the column gap.
    static let displayColumnGap: CGFloat = 28
    static let displayRowGap: CGFloat = 92
    /// Name rows hang further below the shells than badges rise above them; the arrangement sits
    /// this far above the stage midline so the whole composition reads as centred.
    static let arrangementBias: CGFloat = 20
    static let externalShellPadding: CGFloat = 8
    static let builtinShellPadding = NSEdgeInsets(top: 7, left: 7, bottom: 9, right: 7)
    /// How far the type badge rises above the shell's top edge.
    static let badgeOverhang: CGFloat = 10
    static let badgeHeight: CGFloat = 18
    /// Gap between the shell's bottom edge and the name row: stand + base for an external display,
    /// the keyboard line for a MacBook.
    static let externalStandDrop: CGFloat = 23
    static let builtinStandDrop: CGFloat = 3
    static let nameRowGap: CGFloat = 8
    static let nameRowHeight: CGFloat = 19

    static var externalNameDrop: CGFloat {
        externalStandDrop + nameRowGap + nameRowHeight
    }

    static var builtinNameDrop: CGFloat {
        builtinStandDrop + nameRowGap + nameRowHeight
    }

    // MARK: Shelf row (S2)

    static let cardSize = CGSize(width: 200, height: 112)
    /// Row top above the window bottom. SCREENS S2 puts it at 172 (= 648 in the design window);
    /// that left 60pt of dead air under the cards, so the shelf sits lower and tighter.
    static let cardRowBottomInset: CGFloat = 136
    static let cardRowMinLeading: CGFloat = 48
    /// Perspective distance for each shelf card's own projection. 1100 (the design comp's value)
    /// leaves a 200pt card with an 8% taper, which reads as flat; this is close enough for the
    /// card's far edge to foreshorten visibly.
    static let shelfPerspective: CGFloat = 500
    /// Cards the shelf shows at once; the band is this many slots wide. Also the settings default.
    static let shelfCapacity = 20
    /// Cover Flow parks anything further out than this; past it the cards are fully transparent.
    static let coverFlowReach = 6
    static let shelfHeight: CGFloat = 262
    /// Extra downward offset at p = 0 so the row starts below the window bottom.
    static let shelfHiddenOffset: CGFloat = 180
    /// The filter row rides above the card row rather than sitting at a fixed y: pinned to the
    /// window's top it slides into the shelf as soon as the window gets short.
    static let chipRowGap: CGFloat = 52
    static let chipRowTopFull: CGFloat = 70
    static let chipRowSwitchProgress: Double = 1.5
    /// Past this the SwiftUI library grid is mounted over the stage and owns the library.
    static let libraryHandoffProgress: Double = 1.8

    // MARK: Grid (S3)

    static let gridTop: CGFloat = 110
    static let cardAspectRatio: CGFloat = 16 / 9

    // MARK: Gesture and motion (MOTION 1–4, 7)

    /// Trackpad points per state. 320 made a brisk 600pt flick cover almost two states.
    static let scrollPointsPerProgress: CGFloat = 380
    /// A wheel notch arrives as 24 points, so the trackpad scale would need sixteen clicks.
    static let wheelPointsPerProgress: CGFloat = 110
    /// No phase to release on, so the wheel still snaps on silence.
    static let snapDelay: TimeInterval = 0.09
    static let scrollDeadZone: CGFloat = 16
    /// Release velocity is averaged over this window: the last event before the fingers leave is
    /// already decelerating, and launching the spring from it makes every landing crawl.
    static let velocityWindow: TimeInterval = 0.04
    /// States per second above which a flick carries to the next state whatever the distance.
    static let flickVelocity = 0.8
    /// A wheel burst this far into a state commits to it; below that it returns home.
    static let wheelCommit = 0.2
    /// Distance a slow drag has to cover before it commits to the next state.
    static let commitFraction = 0.45
    /// The state band gives at most this much — far too little for the next state's layout to show.
    static let stateWallGive = 0.04
    static let stateWallStiffness = 0.12
    static let rowStretch: CGFloat = 120
    static let rowStretchStiffness: CGFloat = 220
    static let dragThreshold: CGFloat = 6
    static let waveFalloff: CGFloat = 2.6
    /// How far off the half-open state the wave still runs. Wide enough to cover a settle tail and
    /// a gesture frozen just short of the state, narrow enough that it is gone by the grid.
    static let waveProgressBand = 0.08
    /// How far past the band's end a card takes to fade out; one crate slot.
    static let bandFade: CGFloat = 48
    /// Cards accept clicks only this close to the half-open rest state.
    static let cardTapMinimumProgress: Double = 0.95
    /// Seeded with the release velocity, so a flick lands fast and a slow drag settles slowly. The
    /// ~1% overshoot reads as an elastic detent; the 0.175-state bounce of the rubber-band version
    /// read as "the swipe went past and came back".
    static let snapSpring = SpringParameters(response: 0.38, dampingFraction: 0.83)
    static let rowSpring = SpringParameters(response: 0.36, dampingFraction: 0.85)

    // MARK: Types

    /// SwiftUI-style spring expressed in `CASpringAnimation` terms (mass fixed at 1).
    struct SpringParameters: Equatable, Sendable {
        var response: Double
        /// MOTION_SPEC lists only the response; the snap value stands in where it is silent.
        var dampingFraction: Double = 0.82

        var mass: Double {
            1
        }

        var stiffness: Double {
            pow(2 * .pi / response, 2)
        }

        var damping: Double {
            4 * .pi * dampingFraction / response
        }
    }

    /// Applied to the whole arrangement with the anchor at top-center.
    struct StageTransform: Equatable, Sendable {
        var translationY: CGFloat
        var scale: CGFloat
        var opacity: CGFloat
    }

    struct CardPlacement: Equatable, Sendable {
        var frame: CGRect
        var rotationYDegrees: CGFloat
        var opacity: CGFloat
        /// Container-space depth; negative recedes from the viewer.
        var translateZ: CGFloat = 0
        var scale: CGFloat = 1
        /// Alpha of the black overlay that fakes ambient falloff further back in the stack.
        var dim: CGFloat = 0
        /// Base `zPosition` before the hover spring adds its bump; monotonic in `index`.
        var depthOrder: CGFloat = 0
        var anchorX: CGFloat = 0
    }

    /// Per-style constants for the three shelf forms (Settings → Appearance → Shelf style).
    struct ShelfMetrics: Equatable, Sendable {
        var pitch: CGFloat
        var tiltDegrees: CGFloat
        var depthStep: CGFloat
        var dimStep: CGFloat
        var maxDim: CGFloat
        /// 0 pivots the card on its left edge, 0.5 on its centre.
        var anchorX: CGFloat
        var hoverLift: CGFloat
        var hoverDepth: CGFloat
        /// Added to the card's turn while hovered. `-tiltDegrees` brings the preview square to the
        /// viewer; Cover Flow leaves it at 0 because its focused card already faces front.
        var hoverTiltDegrees: CGFloat
    }

    /// `contentRects` are the screen-content rects, one per input frame in input order.
    struct Arrangement: Equatable, Sendable {
        var scale: CGFloat
        var contentRects: [CGRect]
    }

    // MARK: Progress

    static func clampProgress(_ progress: Double) -> Double {
        min(max(progress, progressRange.lowerBound), progressRange.upperBound)
    }

    /// `t1` covers hidden → half-open, `t2` half-open → full.
    static func progressSplit(_ progress: Double) -> (t1: Double, t2: Double) {
        let p = clampProgress(progress)
        return (min(p, 1), max(p - 1, 0))
    }

    static func snapTarget(for progress: Double) -> Int {
        Int(clampProgress(progress).rounded())
    }

    static func stageTransform(progress: Double) -> StageTransform {
        let (t1, t2) = progressSplit(progress)
        return StageTransform(
            translationY: CGFloat(-60 * t1 - 220 * t2),
            scale: CGFloat(1 - 0.18 * t1 - 0.3 * t2),
            opacity: CGFloat(1 - t2)
        )
    }

    static func chipRowTop(progress: Double, windowSize: CGSize) -> CGFloat {
        guard progress < chipRowSwitchProgress else { return chipRowTopFull }
        return max(topBarHeight + 8, windowSize.height - cardRowBottomInset - chipRowGap)
    }

    // MARK: Arrangement

    static func stageRect(windowSize: CGSize) -> CGRect {
        CGRect(x: 0, y: topBarHeight, width: windowSize.width, height: windowSize.height - topBarHeight)
    }

    static func arrangement(frames: [CGRect], in stageRect: CGRect) -> Arrangement {
        let union = frames.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return Arrangement(scale: nominalDisplayScale, contentRects: []) }
        let columnOffsets = separations(
            starts: frames.map(\.minX),
            spans: frames.map { ($0.minY, $0.maxY) },
            gap: displayColumnGap,
            alsoSeparate: { touchAtACorner(frames[$0], frames[$1]) }
        )
        // Rows run top-first, and `NSScreen.frame` is y-up, so the key is the negated top edge.
        let rowOffsets = separations(
            starts: frames.map { -$0.maxY },
            spans: frames.map { ($0.minX, $0.maxX) },
            gap: displayRowGap
        )
        let gapX = columnOffsets.max() ?? 0
        let gapY = rowOffsets.max() ?? 0
        // The ceiling is whichever is smaller: the design cap, or what this window can hold once
        // the badges above and the name rows below have their room.
        let room = CGSize(
            width: min(arrangementMaxSize.width, stageRect.width - 2 * cardRowMinLeading),
            height: min(arrangementMaxSize.height, stageRect.height - badgeOverhang - externalNameDrop - 48)
        )
        let scale = max(0.02, min(
            nominalDisplayScale,
            (room.width - gapX) / union.width,
            (room.height - gapY) / union.height
        ))
        let total = CGSize(width: union.width * scale + gapX, height: union.height * scale + gapY)
        let origin = CGPoint(
            x: stageRect.midX - total.width / 2,
            y: stageRect.midY - total.height / 2 - arrangementBias
        )
        let rects = frames.enumerated().map { index, frame in
            CGRect(
                x: origin.x + (frame.minX - union.minX) * scale + columnOffsets[index],
                y: origin.y + (union.maxY - frame.maxY) * scale + rowOffsets[index],
                width: frame.width * scale,
                height: frame.height * scale
            )
        }
        return Arrangement(scale: scale, contentRects: rects)
    }

    /// Two displays that meet only at a corner straddle no boundary on either axis, so neither pass
    /// opens a gap for them and their shells, badges and name rows run into each other.
    private static func touchAtACorner(_ a: CGRect, _ b: CGRect) -> Bool {
        (a.maxX == b.minX || b.maxX == a.minX) && (a.maxY == b.minY || b.maxY == a.minY)
    }

    /// Per-display offset along one axis. A gap opens at a boundary only when some pair straddling
    /// it also overlaps on the other axis, so a display parked diagonally is not pushed sideways.
    /// `alsoSeparate` adds pairs that need one anyway; widening the overlap test itself to include
    /// touching edges would instead push apart displays that already have a gap on the other axis.
    private static func separations(
        starts: [CGFloat], spans: [(CGFloat, CGFloat)], gap: CGFloat,
        alsoSeparate: (Int, Int) -> Bool = { _, _ in false }
    ) -> [CGFloat] {
        let ordered = Set(starts).sorted()
        let rank = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
        var gapAt = [CGFloat](repeating: 0, count: ordered.count)
        for a in starts.indices {
            for b in starts.indices {
                guard let first = rank[starts[a]], let second = rank[starts[b]], first < second else { continue }
                let overlaps = spans[a].0 < spans[b].1 && spans[b].0 < spans[a].1
                guard overlaps || alsoSeparate(a, b) else { continue }
                for boundary in (first + 1) ... second {
                    gapAt[boundary] = gap
                }
            }
        }
        var running: CGFloat = 0
        let offsets = gapAt.map { step -> CGFloat in
            running += step
            return running
        }
        return starts.map { offsets[rank[$0] ?? 0] }
    }

    /// Everything a display owns on the stage: the shell, the type badge poking above it and the
    /// stand plus name row under it. `arrangement` keeps these from touching between displays.
    static func occupiedRect(content: CGRect, isBuiltin: Bool) -> CGRect {
        let shell = shellRect(content: content, isBuiltin: isBuiltin)
        let drop = isBuiltin ? builtinNameDrop : externalNameDrop
        return CGRect(
            x: shell.minX, y: shell.minY - badgeOverhang,
            width: shell.width, height: shell.height + badgeOverhang + drop
        )
    }

    static func shellRect(content: CGRect, isBuiltin: Bool) -> CGRect {
        guard isBuiltin else { return content.insetBy(dx: -externalShellPadding, dy: -externalShellPadding) }
        let pad = builtinShellPadding
        return CGRect(
            x: content.minX - pad.left,
            y: content.minY - pad.top,
            width: content.width + pad.left + pad.right,
            height: content.height + pad.top + pad.bottom
        )
    }

    // MARK: Shelf and grid

    /// `tiltDegrees` is positive so the card's far edge goes away from the viewer: a Y rotation
    /// maps z' = −x·sinθ, so a negative angle would pull the right edge forward instead.
    static func metrics(for style: ShelfStyle) -> ShelfMetrics {
        switch style {
        case .folders:
            ShelfMetrics(
                pitch: 84, tiltDegrees: 40, depthStep: 0, dimStep: 0, maxDim: 0,
                anchorX: 0, hoverLift: -48, hoverDepth: 34, hoverTiltDegrees: -40
            )
        case .crate:
            ShelfMetrics(
                pitch: 48, tiltDegrees: 28, depthStep: 0, dimStep: 0, maxDim: 0,
                anchorX: 0, hoverLift: -54, hoverDepth: 36, hoverTiltDegrees: -28
            )
        case .coverFlow:
            ShelfMetrics(
                pitch: 110, tiltDegrees: 62, depthStep: 0, dimStep: 0.18, maxDim: 0.6,
                anchorX: 0.5, hoverLift: -16, hoverDepth: 20, hoverTiltDegrees: 0
            )
        }
    }

    /// Width the card covers on screen once it is turned away from the viewer, before the
    /// perspective divide; `hitRect` is the same edge after it.
    static func projectedCardWidth(_ style: ShelfStyle) -> CGFloat {
        cardSize.width * cos(metrics(for: style).tiltDegrees * .pi / 180)
    }

    /// Signed x offset from the focused slot. Continuous at the focus so a spring-driven focus
    /// index never makes the run jump.
    static func coverFlowOffset(index: Int, focus: Double) -> CGFloat {
        let u = CGFloat(index) - CGFloat(focus)
        let near = min(abs(u), 1)
        let mid = min(max(abs(u) - 1, 0), 2)
        let far = max(abs(u) - 3, 0)
        return (u < 0 ? -1 : 1) * (110 * near + 48 * mid + 14 * far)
    }

    static func coverFlowDepth(_ distance: CGFloat) -> CGFloat {
        -(100 * min(distance, 1) + 20 * min(max(distance - 1, 0), 2) + 15 * max(distance - 3, 0))
    }

    /// Indices the shelf builds layers for: the ones inside the band plus the ones still crossing
    /// its fade ramps. The row itself is as long as the library.
    static func visibleCards(
        style: ShelfStyle, count: Int, rowOffset: CGFloat, focus: Double, windowSize: CGSize,
        capacity: Int = shelfCapacity
    ) -> Range<Int> {
        guard count > 0 else { return 0 ..< 0 }
        guard style != .coverFlow else {
            let centre = Int(focus.rounded())
            return max(0, centre - coverFlowReach) ..< min(count, centre + coverFlowReach + 1)
        }
        let pitch = metrics(for: style).pitch
        let band = shelfBand(style: style, capacity: capacity, windowSize: windowSize)
        let leading = rowLeading(style: style, count: count, windowSize: windowSize, capacity: capacity) + rowOffset
        // The ones on the ramps are still drawn, so the slice is the cap plus its two fading ends.
        let first = Int(((band.lowerBound - bandFade - leading) / pitch).rounded(.down))
        let last = Int(((band.upperBound + bandFade - leading) / pitch).rounded(.up)) + 1
        return (first ..< last).clamped(to: 0 ..< count)
    }

    /// Where the shelf's card origins may sit: `capacity` slots, centred, clear of the window's
    /// margins. The library scrolls through them, so a band narrower than the window is what makes
    /// the cap real — one N cannot both bound the work and fill an arbitrarily wide window.
    static func shelfBand(style: ShelfStyle, capacity: Int, windowSize: CGSize) -> ClosedRange<CGFloat> {
        let card = projectedCardWidth(style)
        let room = windowSize.width - 2 * cardRowMinLeading - card
        let span = max(0, min(CGFloat(max(capacity - 1, 0)) * metrics(for: style).pitch, room))
        let leading = max(cardRowMinLeading, (windowSize.width - span - card) / 2)
        return leading ... (leading + span)
    }

    /// Alpha for a card whose near edge sits at `cardMinX`: cards do not pop in and out at the
    /// band's ends, they cross a `bandFade`-wide ramp.
    static func bandOpacity(cardMinX: CGFloat, style: ShelfStyle, capacity: Int, windowSize: CGSize) -> CGFloat {
        guard style != .coverFlow else { return 1 }
        let band = shelfBand(style: style, capacity: capacity, windowSize: windowSize)
        let overshoot = max(band.lowerBound - cardMinX, cardMinX - band.upperBound)
        return max(0, 1 - max(0, overshoot) / bandFade)
    }

    /// x of card 0: a row shorter than the band centres in the window, a longer one starts at the
    /// band and scrolls. `rowFrame` and `visibleCards` have to agree on it.
    private static func rowLeading(style: ShelfStyle, count: Int, windowSize: CGSize, capacity: Int) -> CGFloat {
        let span = CGFloat(max(count - 1, 0)) * metrics(for: style).pitch + projectedCardWidth(style)
        let band = shelfBand(style: style, capacity: capacity, windowSize: windowSize)
        return max(band.lowerBound, (windowSize.width - span) / 2)
    }

    static func rowFrame(
        style: ShelfStyle, index: Int, count: Int, focus: Double, windowSize: CGSize,
        capacity: Int = shelfCapacity
    ) -> CGRect {
        let y = windowSize.height - cardRowBottomInset
        guard style != .coverFlow else {
            return CGRect(
                x: (windowSize.width - cardSize.width) / 2 + coverFlowOffset(index: index, focus: focus),
                y: y, width: cardSize.width, height: cardSize.height
            )
        }
        let leading = rowLeading(style: style, count: count, windowSize: windowSize, capacity: capacity)
        let x = leading + CGFloat(index) * metrics(for: style).pitch
        return CGRect(x: x, y: y, width: cardSize.width, height: cardSize.height)
    }

    static func gridColumns(windowWidth: CGFloat) -> Int {
        DesignTokens.LibraryGrid.columns(
            for: .medium, aspect: .wide,
            fitting: windowWidth - 2 * DesignTokens.LibraryGrid.horizontalPadding
        ).count
    }

    static func gridCellSize(windowWidth: CGFloat) -> CGSize {
        gridFrame(index: 0, windowWidth: windowWidth).size
    }

    static func gridFrame(index: Int, windowWidth: CGFloat) -> CGRect {
        DesignTokens.LibraryGrid.tileFrame(
            index: index, size: .medium, aspect: .wide,
            fitting: windowWidth - 2 * DesignTokens.LibraryGrid.horizontalPadding,
            tileAspectRatio: cardAspectRatio
        ).offsetBy(
            dx: DesignTokens.LibraryGrid.horizontalPadding,
            dy: gridTop + DesignTokens.LibraryGrid.verticalPadding
        )
    }

    static func visibleGridCards(count: Int, windowSize: CGSize, scrollOffset: CGFloat) -> Range<Int> {
        guard count > 0, windowSize.height > gridTop else { return 0 ..< 0 }
        let columns = gridColumns(windowWidth: windowSize.width)
        let cell = gridCellSize(windowWidth: windowSize.width)
        let pitch = cell.height + DesignTokens.LibraryGrid.spacing
        let top = scrollOffset - DesignTokens.LibraryGrid.verticalPadding
        let firstRow = max(0, Int(floor((top - cell.height) / pitch)) + 1)
        let endRow = max(firstRow, Int(ceil((top + windowSize.height - gridTop) / pitch)))
        return min(count, firstRow * columns) ..< min(count, endRow * columns)
    }

    static func cardPlacement(
        style: ShelfStyle, index: Int, count: Int, progress: Double, focus: Double, windowSize: CGSize,
        capacity: Int = shelfCapacity
    ) -> CardPlacement {
        let p = clampProgress(progress)
        let (t1, t2) = progressSplit(p)
        let m = metrics(for: style)
        let row = rowFrame(
            style: style, index: index, count: count, focus: focus, windowSize: windowSize, capacity: capacity
        )
        let grid = gridFrame(index: index, windowWidth: windowSize.width)
        let mix = CGFloat(t2)
        let flat = 1 - mix
        let hidden = shelfHiddenOffset * CGFloat(1 - t1)
        let frame = CGRect(
            x: lerp(row.minX, grid.minX, mix),
            y: lerp(row.minY, grid.minY, mix) + hidden,
            width: lerp(row.width, grid.width, mix),
            height: lerp(row.height, grid.height, mix)
        )
        let signed = CGFloat(index) - CGFloat(focus)
        let distance = abs(signed)
        let isFlow = style == .coverFlow
        // Cover Flow turns each side card inward, so its near edge is the one facing the focus.
        let tilt = isFlow ? min(65, max(-65, signed * 62)) : m.tiltDegrees
        // Fallen dominoes: the row is one plane at z = 0, so every card is the same size and
        // brightness and only the tilt plus the overlap carry the depth. Each card is still a
        // trapezoid — rotating about its own edge sinks its far side below the plane.
        let alongRow = CGFloat(index)
        let depth = isFlow ? coverFlowDepth(distance) : m.depthStep * alongRow
        let shelfScale = isFlow ? 1 - min(0.24, distance * 0.08) : 1
        let dim = min(m.maxDim, m.dimStep * (isFlow ? distance : alongRow))
        // Dominoes: each card leans away to the right and the next one lies on top of it, so the
        // part left showing is its own near edge.
        let order = isFlow ? 100 - distance * 10 : CGFloat(index) * 10
        // Cards more than three slots out are parked; past six they stop drawing entirely.
        let parked: CGFloat = isFlow ? max(0, 1 - max(0, distance - 3) * 0.35) : 1
        let reveal: CGFloat = p < 0.02 ? 0 : min(1, CGFloat(t1) * 1.2)
        return CardPlacement(
            frame: frame,
            rotationYDegrees: tilt * flat,
            opacity: reveal * lerp(parked, 1, mix),
            translateZ: depth * flat,
            scale: lerp(shelfScale, 1, mix),
            dim: dim * flat,
            depthOrder: lerp(order, CGFloat(index), mix),
            anchorX: m.anchorX
        )
    }

    /// Grabbable footprint: the card's own corners run through the very matrix `ShelfCardLayer`
    /// builds, so the hit area can never drift from what is drawn.
    /// Edges of the card as the hover it is settling into leaves them — never the interpolated
    /// frame, which would move the target under the pointer and re-trigger the hover that started
    /// it. `hovered` applies what `ShelfCardLayer` draws at `hover == 1`.
    /// The pose a card has at `hover` ∈ 0…1. `ShelfCardLayer` draws this and `hitRect` measures it,
    /// so the hover lean exists once: a second copy drifts apart at p > 1, where `gridMix` cancels
    /// the lean but leaves the hit rect claiming the full turn.
    static func applyingHover(
        _ placement: CardPlacement, style: ShelfStyle, hover: CGFloat, gridMix: CGFloat
    ) -> CardPlacement {
        var placement = placement
        let m = metrics(for: style)
        let leaned = hover * (1 - gridMix)
        placement.translateZ += m.hoverDepth * leaned
        placement.rotationYDegrees += m.hoverTiltDegrees * leaned
        placement.scale *= 1 + 0.04 * hover * gridMix
        return placement
    }

    static func hitRect(
        _ placement: CardPlacement, style: ShelfStyle, hover: CGFloat = 0, gridMix: CGFloat = 0
    ) -> CGRect {
        let placement = applyingHover(placement, style: style, hover: hover, gridMix: gridMix)
        let size = placement.frame.size
        let pivot = metrics(for: style).anchorX * size.width
        let radians = placement.rotationYDegrees * .pi / 180
        func project(_ u: CGFloat) -> (x: CGFloat, shrink: CGFloat) {
            let offset = (u - pivot) * placement.scale
            let z = placement.translateZ - offset * sin(radians)
            let shrink = shelfPerspective / max(1, shelfPerspective - z)
            return (size.width / 2 + (pivot + offset * cos(radians) - size.width / 2) * shrink, shrink)
        }
        let near = project(0)
        let far = project(size.width)
        let height = size.height * placement.scale * max(near.shrink, far.shrink)
        return CGRect(
            x: placement.frame.minX + min(near.x, far.x),
            y: placement.frame.midY - height / 2,
            width: abs(far.x - near.x), height: height
        )
    }

    /// Negative lift for card `index` when the pointer sits at `centre`, measured in slots — 3.5
    /// means halfway between cards 3 and 4. Continuous in `centre`, and with a zero derivative at
    /// both ends, so the crest tracks the pointer inside a slot instead of stepping at its edges.
    /// Cover Flow lifts only the focused card: its neighbours are already turned away.
    static func waveLift(style: ShelfStyle, index: Int, centre: CGFloat?) -> CGFloat {
        guard let centre else { return 0 }
        let peak = -metrics(for: style).hoverLift
        guard style != .coverFlow else { return abs(CGFloat(index) - centre) < 0.5 ? -peak : 0 }
        let u = abs(CGFloat(index) - centre) / waveFalloff
        guard u < 1 else { return 0 }
        return -peak * (1 + cos(.pi * u)) / 2
    }

    static func waveLift(style: ShelfStyle, index: Int, hovered: Int?) -> CGFloat {
        waveLift(style: style, index: index, centre: hovered.map(CGFloat.init))
    }

    private static func lerp(_ from: CGFloat, _ to: CGFloat, _ mix: CGFloat) -> CGFloat {
        from + (to - from) * mix
    }
}
