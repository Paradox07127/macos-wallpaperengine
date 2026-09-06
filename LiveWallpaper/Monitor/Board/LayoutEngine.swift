import CoreGraphics
import Foundation
import LiveWallpaperCore

// MARK: - Monitor board layout engine

/// The strip each display edge loses to the menu bar or the Dock, as a fraction
/// of the display's own size, counted y-down from the top-left like every other
/// board coordinate. Fractions rather than points so one value describes both
/// the desktop board and the inspector's scaled-down copy of the same display.
struct MonitorSafeAreaInsets: Equatable, Sendable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let none = MonitorSafeAreaInsets()

    init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = Self.fraction(top)
        self.leading = Self.fraction(leading)
        self.bottom = Self.fraction(bottom)
        self.trailing = Self.fraction(trailing)
    }

    /// `visibleFrame` is the display's frame minus the menu bar and the Dock,
    /// wherever the Dock happens to be — so measuring all four edges against it
    /// covers a left, right or bottom Dock without asking AppKit about the Dock
    /// at all, and without special-casing the top. Both rects are AppKit's
    /// y-up screen coordinates, which is why `top` reads off `maxY`.
    init(frame: CGRect, visibleFrame visible: CGRect) {
        guard frame.width > 0, frame.height > 0 else {
            self.init()
            return
        }
        self.init(
            top: (frame.maxY - visible.maxY) / frame.height,
            leading: (visible.minX - frame.minX) / frame.width,
            bottom: (visible.minY - frame.minY) / frame.height,
            trailing: (frame.maxX - visible.maxX) / frame.width
        )
    }

    private static func fraction(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// Cell-exact geometry on Apple's 170 pt tile: S 170×170, M 356×170, L 356×356 pt.
struct MonitorBoardGeometry: Equatable {
    let boardSize: CGSize
    let columns: Int
    let rows: Int
    /// Cell pitch (gutter included); RAW footprint = span × pitch.
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// HALF-gutter, both axes: neighbours end up `2 * tileInset` apart.
    let tileInset: CGFloat
    let cornerRadius: CGFloat
    /// Menu-bar / Dock avoidance in board pixels: the part of the board a widget
    /// may be placed into. Equal to the whole board when the host passes no
    /// insets.
    let safeRect: CGRect

    /// Pitch = tile + one gutter (`tile == pitch - 2 * inset`), so a small widget stays exactly Apple's
    /// 170×170; spans absorb the gutter they cross (medium 356×170, large 356×356). Numbers live in
    /// `MonitorBoardMetrics` so the schema's default packer measures in the same cell the renderer draws
    /// in.
    static let appleCellPitch = CGSize(
        width: MonitorBoardMetrics.cellPitch, height: MonitorBoardMetrics.cellPitch
    )
    static let appleTileInset = CGFloat(MonitorBoardMetrics.gutter / 2)
    static let appleCornerRadius: CGFloat = 16

    init(boardSize: CGSize, referenceWidth: CGFloat = 0, safeArea: MonitorSafeAreaInsets = .none) {
        let reference = referenceWidth > 0 ? referenceWidth : boardSize.width
        let s = reference > 0 ? boardSize.width / reference : 1

        let cw = Self.appleCellPitch.width * s
        let ch = Self.appleCellPitch.height * s
        self.boardSize = boardSize
        self.columns = cw > 0 ? max(Int((boardSize.width / cw).rounded(.down)), 1) : 1
        self.rows = ch > 0 ? max(Int((boardSize.height / ch).rounded(.down)), 1) : 1
        self.cellWidth = max(cw, 0)
        self.cellHeight = max(ch, 0)
        self.tileInset = Self.appleTileInset * s
        self.cornerRadius = max(Self.appleCornerRadius * s, 1)
        safeRect = Self.safeRect(boardSize: boardSize, safeArea: safeArea)
    }

    /// Menu-bar avoidance floor for widget origins.
    var topInset: CGFloat {
        safeRect.minY
    }

    /// Opposing insets that between them swallow the display leave nothing to
    /// place into; the whole board is a better answer than a negative rect.
    private static func safeRect(boardSize: CGSize, safeArea: MonitorSafeAreaInsets) -> CGRect {
        let width = boardSize.width * (1 - safeArea.leading - safeArea.trailing)
        let height = boardSize.height * (1 - safeArea.top - safeArea.bottom)
        // `CGRect.width` reports the standardized magnitude, so a negative span
        // has to be caught before the rect is built.
        guard width > 0, height > 0 else { return CGRect(origin: .zero, size: boardSize) }
        return CGRect(
            x: boardSize.width * safeArea.leading,
            y: boardSize.height * safeArea.top,
            width: width,
            height: height
        )
    }

    var isDegenerate: Bool {
        boardSize.width <= 0 || boardSize.height <= 0 || cellWidth <= 0 || cellHeight <= 0
    }

    /// RAW footprint (pitch multiples; gutter applied via inset, not here).
    func pixelSize(columns cols: Int, rows spanRows: Int) -> CGSize {
        CGSize(width: CGFloat(cols) * cellWidth, height: CGFloat(spanRows) * cellHeight)
    }

    func pixelSize(for kind: MonitorWidgetKind, size: MonitorWidgetSize) -> CGSize {
        let cells = kind.cellSize(for: size)
        return pixelSize(columns: cells.columns, rows: cells.rows)
    }

    /// Inset raw rect per axis for gutters; never inverts a tiny rect.
    func renderRect(forRawRect raw: CGRect) -> CGRect {
        let dx = min(tileInset, raw.width / 2)
        let dy = min(tileInset, raw.height / 2)
        return raw.insetBy(dx: dx, dy: dy)
    }

    /// Keeps a footprint inside the usable area. A footprint larger than that
    /// area pins to its top-left corner rather than inverting the range.
    func clampOrigin(_ origin: CGPoint, footprint: CGSize) -> CGPoint {
        CGPoint(
            x: LayoutEngine.clamp(
                origin.x, safeRect.minX, max(safeRect.maxX - footprint.width, safeRect.minX)
            ),
            y: LayoutEngine.clamp(
                origin.y, safeRect.minY, max(safeRect.maxY - footprint.height, safeRect.minY)
            )
        )
    }
}

struct MonitorSnapGuide: Equatable {
    enum Axis { case vertical, horizontal }
    var axis: Axis
    /// Perpendicular-axis position in board pixels (x for vertical guide, y for horizontal).
    var position: CGFloat
    var partner: CGRect?
}

/// Magnetic snap solve for one drag frame.
struct MonitorSnapResult: Equatable {
    var origin: CGPoint
    var snappedX: Bool
    var snappedY: Bool
    var guideX: MonitorSnapGuide?
    var guideY: MonitorSnapGuide?

    var snapped: Bool { snappedX || snappedY }
}

/// Board occupant: id + RAW (pre-inset) pixel rect.
struct MonitorBoardItem: Equatable {
    var id: UUID
    var rect: CGRect
}

/// Pure layout algorithms (static; no stored state).
enum LayoutEngine {

    static let snapThreshold: CGFloat = 14
    static let snapNeighborhood: CGFloat = 140
    static let epsilon: CGFloat = 0.5

    static func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
        min(max(value, low), high)
    }

    // MARK: Normalized ↔ pixel

    static func pixelOrigin(normalized: CGPoint, boardSize: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * boardSize.width, y: normalized.y * boardSize.height)
    }

    static func normalized(pixelOrigin origin: CGPoint, boardSize: CGSize) -> CGPoint {
        CGPoint(
            x: boardSize.width > 0 ? origin.x / boardSize.width : 0,
            y: boardSize.height > 0 ? origin.y / boardSize.height : 0
        )
    }

    // MARK: AABB overlap

    static func conflicts(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX - epsilon
            && a.maxX > b.minX + epsilon
            && a.minY < b.maxY - epsilon
            && a.maxY > b.minY + epsilon
    }

    static func isLegal(
        rect: CGRect,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?
    ) -> Bool {
        let area = geometry.safeRect
        if rect.minX < area.minX - epsilon
            || rect.minY < area.minY - epsilon
            || rect.maxX > area.maxX + epsilon
            || rect.maxY > area.maxY + epsilon {
            return false
        }
        for item in items {
            if item.id == ignoredID { continue }
            if conflicts(rect, item.rect) { return false }
        }
        return true
    }

    // MARK: Overlap resolution

    static func resolve(
        origin requested: CGPoint,
        footprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?,
        maxDisplacement: CGFloat
    ) -> CGPoint? {
        let clamped = geometry.clampOrigin(requested, footprint: footprint)
        if isLegal(
            rect: CGRect(origin: clamped, size: footprint),
            geometry: geometry, items: items, ignoring: ignoredID
        ) {
            return clamped
        }

        var xs: [CGFloat] = [clamped.x]
        var ys: [CGFloat] = [clamped.y]
        for item in items where item.id != ignoredID {
            let r = item.rect
            xs.append(r.maxX)
            xs.append(r.minX - footprint.width)
            ys.append(r.maxY)
            ys.append(r.minY - footprint.height)
        }

        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        for candidateX in xs {
            for candidateY in ys {
                let point = geometry.clampOrigin(CGPoint(x: candidateX, y: candidateY), footprint: footprint)
                let rect = CGRect(origin: point, size: footprint)
                if !isLegal(rect: rect, geometry: geometry, items: items, ignoring: ignoredID) { continue }
                let distance = hypot(point.x - clamped.x, point.y - clamped.y)
                if distance < bestDistance {
                    bestDistance = distance
                    best = point
                }
            }
        }
        if let best, bestDistance <= maxDisplacement {
            return best
        }
        return nil
    }

    // MARK: Magnetic snap

    static func snap(
        freeOrigin free: CGPoint,
        footprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?
    ) -> MonitorSnapResult {
        let area = geometry.safeRect
        let dw = footprint.width
        let dh = footprint.height

        var snapX: CGFloat?
        var snapY: CGFloat?
        var guideX: MonitorSnapGuide?
        var guideY: MonitorSnapGuide?
        var bestDX = snapThreshold + 0.001
        var bestDY = snapThreshold + 0.001

        func considerX(target: CGFloat, guidePos: CGFloat?, partner: CGRect?) {
            let d = abs(free.x - target)
            if d < bestDX - 0.25 {
                bestDX = d
                snapX = target
                guideX = guidePos.map { MonitorSnapGuide(axis: .vertical, position: $0, partner: partner) }
            } else if let current = snapX, abs(target - current) < 0.5, guideX == nil, let guidePos {
                guideX = MonitorSnapGuide(axis: .vertical, position: guidePos, partner: partner)
            }
        }
        func considerY(target: CGFloat, guidePos: CGFloat?, partner: CGRect?) {
            let d = abs(free.y - target)
            if d < bestDY - 0.25 {
                bestDY = d
                snapY = target
                guideY = guidePos.map { MonitorSnapGuide(axis: .horizontal, position: $0, partner: partner) }
            } else if let current = snapY, abs(target - current) < 0.5, guideY == nil, let guidePos {
                guideY = MonitorSnapGuide(axis: .horizontal, position: guidePos, partner: partner)
            }
        }

        // Edges of the usable area, not of the display: with a Dock on screen
        // the two differ, and snapping to the screen edge would park a tile
        // underneath it.
        considerX(target: area.minX, guidePos: area.minX, partner: nil)
        considerX(target: area.maxX - dw, guidePos: area.maxX, partner: nil)
        considerX(target: area.midX - dw / 2, guidePos: area.midX, partner: nil)
        considerY(target: area.minY, guidePos: area.minY, partner: nil)
        considerY(target: area.maxY - dh, guidePos: area.maxY, partner: nil)
        considerY(target: area.midY - dh / 2, guidePos: area.midY, partner: nil)

        for item in items where item.id != ignoredID {
            let r = item.rect
            let near = !(free.x > r.maxX + snapNeighborhood
                || free.x + dw < r.minX - snapNeighborhood
                || free.y > r.maxY + snapNeighborhood
                || free.y + dh < r.minY - snapNeighborhood)
            if !near { continue }
            considerX(target: r.minX, guidePos: r.minX, partner: r)                 // L-L
            considerX(target: r.maxX - dw, guidePos: r.maxX, partner: r)            // R-R
            considerX(target: r.midX - dw / 2, guidePos: r.midX, partner: r)        // C-C
            considerX(target: r.maxX, guidePos: nil, partner: r)                    // flush right
            considerX(target: r.minX - dw, guidePos: nil, partner: r)               // flush left
            considerY(target: r.minY, guidePos: r.minY, partner: r)
            considerY(target: r.maxY - dh, guidePos: r.maxY, partner: r)
            considerY(target: r.midY - dh / 2, guidePos: r.midY, partner: r)
            considerY(target: r.maxY, guidePos: nil, partner: r)
            considerY(target: r.minY - dh, guidePos: nil, partner: r)
        }

        return MonitorSnapResult(
            origin: CGPoint(x: snapX ?? free.x, y: snapY ?? free.y),
            snappedX: snapX != nil,
            snappedY: snapY != nil,
            guideX: guideX,
            guideY: guideY
        )
    }

    // MARK: Guide line segment geometry

    static func guideSegment(
        _ guide: MonitorSnapGuide,
        draggedRect: CGRect,
        geometry: MonitorBoardGeometry,
        pad: CGFloat = 12
    ) -> (start: CGPoint, end: CGPoint) {
        switch guide.axis {
        case .vertical:
            let x = guide.position
            if let p = guide.partner {
                let from = min(draggedRect.minY, p.minY) - pad
                let to = max(draggedRect.maxY, p.maxY) + pad
                return (CGPoint(x: x, y: from), CGPoint(x: x, y: to))
            }
            return (CGPoint(x: x, y: 0), CGPoint(x: x, y: geometry.boardSize.height))
        case .horizontal:
            let y = guide.position
            if let p = guide.partner {
                let from = min(draggedRect.minX, p.minX) - pad
                let to = max(draggedRect.maxX, p.maxX) + pad
                return (CGPoint(x: from, y: y), CGPoint(x: to, y: y))
            }
            return (CGPoint(x: 0, y: y), CGPoint(x: geometry.boardSize.width, y: y))
        }
    }

    // MARK: Drag landing

    static func land(
        freeOrigin free: CGPoint,
        snappedOrigin: CGPoint?,
        footprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?
    ) -> CGPoint? {
        let target = snappedOrigin ?? free
        return resolve(
            origin: target,
            footprint: footprint,
            geometry: geometry,
            items: items,
            ignoring: ignoredID,
            maxDisplacement: max(footprint.width, footprint.height)
        )
    }

    // MARK: Size toggle re-fit

    static func refitForSizeChange(
        anchor: CGPoint,
        newFootprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem],
        ignoring ignoredID: UUID?
    ) -> CGPoint? {
        func legal(_ origin: CGPoint) -> CGPoint? {
            let clamped = geometry.clampOrigin(origin, footprint: newFootprint)
            let rect = CGRect(origin: clamped, size: newFootprint)
            return isLegal(rect: rect, geometry: geometry, items: items, ignoring: ignoredID) ? clamped : nil
        }

        if let atAnchor = legal(anchor) { return atAnchor }

        let shiftedLeft = CGPoint(x: geometry.safeRect.maxX - newFootprint.width, y: anchor.y)
        if shiftedLeft.x < anchor.x, let hit = legal(shiftedLeft) {
            return hit
        }
        let shiftedUp = CGPoint(x: anchor.x, y: geometry.safeRect.maxY - newFootprint.height)
        if shiftedUp.y < anchor.y, let hit = legal(shiftedUp) {
            return hit
        }
        let shiftedBoth = CGPoint(x: shiftedLeft.x, y: shiftedUp.y)
        if let hit = legal(shiftedBoth) { return hit }

        return resolve(
            origin: anchor,
            footprint: newFootprint,
            geometry: geometry,
            items: items,
            ignoring: ignoredID,
            maxDisplacement: max(newFootprint.width, newFootprint.height)
        )
    }

    // MARK: Add-widget first fit

    static func firstFit(
        footprint: CGSize,
        geometry: MonitorBoardGeometry,
        items: [MonitorBoardItem]
    ) -> CGPoint? {
        let target = CGPoint(
            x: geometry.safeRect.midX - footprint.width / 2,
            y: geometry.safeRect.minY + geometry.safeRect.height * 0.64
        )
        guard let spot = resolve(
            origin: target,
            footprint: footprint,
            geometry: geometry,
            items: items,
            ignoring: nil,
            maxDisplacement: .greatestFiniteMagnitude
        ) else {
            return nil
        }
        let snapResult = snap(
            freeOrigin: spot,
            footprint: footprint,
            geometry: geometry,
            items: items,
            ignoring: nil
        )
        if snapResult.snapped {
            let rect = CGRect(origin: snapResult.origin, size: footprint)
            if isLegal(rect: rect, geometry: geometry, items: items, ignoring: nil) {
                return snapResult.origin
            }
        }
        return spot
    }
}
