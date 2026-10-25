import LiveWallpaperCore
import SwiftUI

/// Playlist records stacked along a diagonal with the current one pulled out in the middle; drag a record to reorder.
struct PlaylistCrate: View {
    struct Record: Identifiable, Equatable {
        let id: String
        let title: String
        let image: CGImage?
    }

    /// Queue order: the first record sits bottom-left, the last top-right.
    let records: [Record]
    /// The record held in the centre; nil centres the first.
    let currentID: Record.ID?
    @Binding var selectedID: Record.ID?
    /// `List.onMove`'s contract: source indices, and the destination offset in the original array.
    let onMove: (IndexSet, Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredID: Record.ID?
    @State private var lift: Lift?

    private struct Lift {
        let id: Record.ID
        let from: Int
        /// Queue index kept in the centre for the whole drag, so the row doesn't slide under the pointer.
        let anchor: Int
        /// Pointer travel in canvas units.
        var travel: CGSize
        var target: Int
    }

    private static let space = "PlaylistCrate"

    private var currentIndex: Int {
        records.firstIndex { $0.id == currentID } ?? 0
    }

    private var dragAnimation: Animation {
        reduceMotion ? DesignTokens.Motion.reducedMotionFade : DesignTokens.Motion.dragSettle
    }

    var body: some View {
        GeometryReader { proxy in
            let fit = CanvasFit(size: proxy.size)
            let anchor = lift?.anchor ?? currentIndex
            ZStack(alignment: .topLeading) {
                guide(fit)
                if let lift {
                    dropGap(at: Self.slot(lift.target - anchor), fit: fit)
                }
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    recordView(record, index: index, anchor: anchor, fit: fit)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .coordinateSpace(.named(Self.space))
        .animation(DesignTokens.Motion.pageSwitch(reduceMotion: reduceMotion), value: currentID)
    }

    private func recordView(_ record: Record, index: Int, anchor: Int, fit: CanvasFit) -> some View {
        let lifted = lift?.id == record.id ? lift : nil
        let position = lift.map { Self.previewIndex(of: index, from: $0.from, to: $0.target) } ?? index
        let playingPosition = records.firstIndex { $0.id == currentID }.map { playing in
            lift.map { Self.previewIndex(of: playing, from: $0.from, to: $0.target) } ?? playing
        }
        let offset = position - anchor
        let slot = Self.slot(lifted.map { $0.from - anchor } ?? offset)
        let hovered = hoveredID == record.id && lift == nil && offset != 0
        var center = slot.center
        var scale = slot.scale
        if let lifted {
            center.x += lifted.travel.width
            center.y += lifted.travel.height
            if !reduceMotion {
                center.y -= Self.liftRise
                scale *= Self.liftScale
            }
        } else if hovered, !reduceMotion {
            center.y -= Self.hoverRise
        }
        let isPlaying = record.id == currentID
        let isSelected = selectedID == record.id
        let number = String(format: "%02d", position + 1)
        // The played record next to the centre stays undimmed; earlier ones darken under an opaque scrim.
        let dimmed = lifted == nil && offset != 0 && playingPosition.map { position < $0 - 1 } == true
        let elevation: CrateElevation = lifted != nil ? .lifted : offset == 0 ? .centered : .resting
        // Played records stack nearer the viewer the farther they sit from the centre; upcoming ones recede.
        let layer: Double = lifted != nil ? 300 : offset == 0 ? 100 : Double(50 - offset)

        return Button {
            selectedID = record.id
        } label: {
            CrateRecordCard(
                record: record,
                tab: hovered ? "\(number)  \(record.title)" : abs(offset) > Self.evenlySpaced ? nil : number,
                isPlaying: isPlaying,
                showsNowPlaying: isPlaying && offset == 0,
                isSelected: isSelected,
                isDimmed: dimmed,
                elevation: elevation,
                tabScale: 1 / scale
            )
        }
        .buttonStyle(.plain)
        .highPriorityGesture(liftGesture(record, index: index, fit: fit))
        .onHover { inside in hover(record.id, inside) }
        .accessibilityLabel(Text(verbatim: record.title))
        .accessibilityValue(isPlaying ? Text("Now playing") : Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .crateTransform(Slot(center: center, scale: scale, tilt: slot.tilt, roll: slot.roll), fit: fit)
        .zIndex(layer)
    }

    private func hover(_ id: Record.ID, _ inside: Bool) {
        withAnimation(reduceMotion ? DesignTokens.Motion.reducedMotionFade : DesignTokens.Motion.feedback) {
            if inside {
                hoveredID = id
            } else if hoveredID == id {
                hoveredID = nil
            }
        }
    }

    private func liftGesture(_ record: Record, index: Int, fit: CanvasFit) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard fit.scale > 0 else { return }
                let travel = CGSize(
                    width: value.translation.width / fit.scale,
                    height: value.translation.height / fit.scale
                )
                guard var moving = lift else {
                    withAnimation(dragAnimation) {
                        hoveredID = nil
                        lift = Lift(id: record.id, from: index, anchor: currentIndex, travel: travel, target: index)
                    }
                    return
                }
                moving.travel = travel
                let start = Self.slot(moving.from - moving.anchor).center
                let target = Self.dropTarget(
                    at: CGPoint(x: start.x + travel.width, y: start.y + travel.height),
                    count: records.count,
                    anchor: moving.anchor
                )
                if target == moving.target {
                    lift = moving
                } else {
                    moving.target = target
                    withAnimation(dragAnimation) { lift = moving }
                }
            }
            .onEnded { _ in
                guard let moving = lift else { return }
                withAnimation(dragAnimation) {
                    lift = nil
                    if moving.target != moving.from {
                        onMove(IndexSet(integer: moving.from), Self.moveDestination(from: moving.from, to: moving.target))
                    }
                }
            }
    }

    private func guide(_ fit: CanvasFit) -> some View {
        Path { path in
            path.addLines(Self.guidePoints.map(fit.point))
        }
        .stroke(
            DesignTokens.EditDesk.Colors.strokePanel,
            style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 6])
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func dropGap(at slot: Slot, fit: CanvasFit) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Corner.panel, style: .continuous)
        return shape
            .fill(DesignTokens.EditDesk.Colors.fillEmptyScreen)
            .overlay {
                shape.strokeBorder(DesignTokens.Colors.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .crateTransform(slot, fit: fit)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(60)
    }
}

// MARK: - Geometry

extension PlaylistCrate {
    /// A record's pose in canvas units; `tilt` turns it about the vertical axis, `roll` in the plane, both in degrees.
    struct Slot: Equatable {
        var center: CGPoint
        var scale: CGFloat
        var tilt: Double
        var roll: Double
    }

    // Canvas units follow the design: a 992×500 shelf holding 360×202 records on a 5pt mat.
    nonisolated static let shelfRect = CGRect(x: 0, y: 0, width: 992, height: 500)
    nonisolated static let cardSize = CGSize(width: 360, height: 202)
    nonisolated static let cardInset: CGFloat = 5
    nonisolated static let centeredScale: CGFloat = 1.2
    /// Largest size, in points, any record is drawn at: the centred one once the canvas reaches full size.
    nonisolated static let centeredRecordSize = CGSize(
        width: cardSize.width * centeredScale, height: cardSize.height * centeredScale
    )
    /// `rotation3DEffect` measures perspective against the card's size: the design's 1000pt eye distance.
    nonisolated static let perspective: CGFloat = cardSize.width / 1000
    nonisolated static let hoverRise: CGFloat = 12
    nonisolated static let liftRise: CGFloat = 10
    nonisolated static let liftScale: CGFloat = 1.12
    nonisolated static let guidePoints = [
        CGPoint(x: 70, y: 470), CGPoint(x: 250, y: 360), CGPoint(x: 500, y: 300),
        CGPoint(x: 760, y: 190), CGPoint(x: 960, y: 50),
    ]
    /// Neighbours on each side that keep a full step before the spacing starts to shrink.
    nonisolated static let evenlySpaced = 4
    /// Each step past `evenlySpaced` is this fraction of the one before, so the tails converge.
    nonisolated static let compression: CGFloat = 0.8

    /// The shelf grown to hold the farthest converged slots, so any queue length fits at one scale.
    nonisolated static let canvas: CGRect = (-80 ... 80).reduce(shelfRect) { bounds, offset in
        let slot = slot(offset)
        let width = cardSize.width * slot.scale
        let height = cardSize.height * slot.scale
        return bounds.union(CGRect(
            x: slot.center.x - width / 2, y: slot.center.y - height / 2, width: width, height: height
        ))
    }

    /// Pose of the record `offset` places from the one in view: negative is played (bottom-left), positive upcoming.
    nonisolated static func slot(_ offset: Int) -> Slot {
        guard offset != 0 else {
            return Slot(center: CGPoint(x: 500, y: 246), scale: centeredScale, tilt: 0, roll: -1)
        }
        let steps = abs(offset)
        let run = spread(steps)
        if offset < 0 {
            return Slot(
                center: CGPoint(x: 250 - 24 * run, y: 338 + 15 * run),
                scale: 0.65 + 0.02 * CGFloat(min(steps - 1, 5)),
                tilt: 18, roll: -4
            )
        }
        return Slot(
            center: CGPoint(x: 752 + 28 * run, y: 150 - 17 * run),
            scale: 0.65 * pow(0.95, CGFloat(steps - 1)),
            tilt: -22, roll: 3
        )
    }

    /// Steps travelled out from the first neighbour (`steps` ≥ 1), in units of the full step.
    nonisolated static func spread(_ steps: Int) -> CGFloat {
        let full = CGFloat(min(steps, evenlySpaced) - 1)
        let extra = steps - evenlySpaced
        guard extra > 0 else { return full }
        return full + compression * (1 - pow(compression, CGFloat(extra))) / (1 - compression)
    }

    /// Final queue index for a record dropped at `point` (canvas units): the slot nearest the point's projection
    /// onto the crate's diagonal. `anchor` is the queue index held in the centre.
    nonisolated static func dropTarget(at point: CGPoint, count: Int, anchor: Int) -> Int {
        let origin = slot(-1).center
        let end = slot(1).center
        let axis = CGVector(dx: end.x - origin.x, dy: end.y - origin.y)
        func along(_ point: CGPoint) -> CGFloat {
            (point.x - origin.x) * axis.dx + (point.y - origin.y) * axis.dy
        }
        let pointer = along(point)
        return (0 ..< max(count, 1)).min { lhs, rhs in
            abs(along(slot(lhs - anchor).center) - pointer) < abs(along(slot(rhs - anchor).center) - pointer)
        } ?? 0
    }

    /// One record drawn at `cardSize` the way the crate holds its playing centre record, without a queue tab.
    static func nowPlayingRecord(_ record: Record) -> some View {
        CrateRecordCard(
            record: record, tab: nil, isPlaying: true, showsNowPlaying: true, isSelected: false, isDimmed: false,
            elevation: .centered, tabScale: 1
        )
    }

    /// `List.onMove`'s destination for moving the record at `from` to final index `to`.
    nonisolated static func moveDestination(from: Int, to: Int) -> Int {
        to > from ? to + 1 : to
    }

    /// Where the record at `index` shows while the record from `from` is held over `to`.
    nonisolated static func previewIndex(of index: Int, from: Int, to: Int) -> Int {
        if index == from {
            return to
        }
        if from < to, index > from, index <= to {
            return index - 1
        }
        if to < from, index >= to, index < from {
            return index + 1
        }
        return index
    }
}

/// Maps canvas units onto the view: one uniform scale, centred.
private struct CanvasFit {
    let scale: CGFloat
    let origin: CGPoint

    init(size: CGSize) {
        let canvas = PlaylistCrate.canvas
        // Capped at 1 so no record outgrows `centeredRecordSize`, the size the artwork loads at.
        scale = max(0, min(1, size.width / canvas.width, size.height / canvas.height))
        origin = CGPoint(
            x: (size.width - canvas.width * scale) / 2 - canvas.minX * scale,
            y: (size.height - canvas.height * scale) / 2 - canvas.minY * scale
        )
    }

    func point(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }
}

private extension View {
    /// Poses a card-sized view; `scaleEffect` runs first so the tilts turn the record as drawn.
    func crateTransform(_ slot: PlaylistCrate.Slot, fit: CanvasFit) -> some View {
        scaleEffect(slot.scale * fit.scale)
            .rotationEffect(.degrees(slot.roll))
            .rotation3DEffect(.degrees(slot.tilt), axis: (x: 0, y: 1, z: 0), perspective: PlaylistCrate.perspective)
            .position(fit.point(slot.center))
    }
}

// MARK: - Record

private enum CrateElevation {
    case resting, centered, lifted

    var spread: DesignTokens.EditDesk.Shadow {
        switch self {
        case .resting: DesignTokens.PlaylistCrate.restShadow
        case .centered: DesignTokens.PlaylistCrate.centeredShadow
        case .lifted: DesignTokens.PlaylistCrate.liftedShadow
        }
    }

    var edge: DesignTokens.EditDesk.Shadow {
        switch self {
        case .resting: DesignTokens.PlaylistCrate.restShadowEdge
        case .centered: DesignTokens.PlaylistCrate.centeredShadowEdge
        case .lifted: DesignTokens.PlaylistCrate.liftedShadowEdge
        }
    }
}

private struct CrateRecordCard: View {
    let record: PlaylistCrate.Record
    /// nil on compressed records, whose tabs would pile into each other.
    let tab: String?
    let isPlaying: Bool
    let showsNowPlaying: Bool
    let isSelected: Bool
    let isDimmed: Bool
    let elevation: CrateElevation
    /// Undoes the slot's scale so the queue tab reads at one size along the whole row.
    let tabScale: CGFloat

    var body: some View {
        cover
            .overlay {
                if isDimmed {
                    DesignTokens.PlaylistCrate.playedScrim
                }
            }
            .overlay(alignment: .topLeading) {
                if showsNowPlaying {
                    nowPlayingBadge
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.gridCard, style: .continuous))
            .padding(PlaylistCrate.cardInset)
            .frame(width: PlaylistCrate.cardSize.width, height: PlaylistCrate.cardSize.height)
            .galleryTileChrome(isHovering: false, isSelected: isSelected, cornerRadius: DesignTokens.Corner.panel)
            .overlay {
                if isPlaying, !isSelected {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.panel, style: .continuous)
                        .strokeBorder(DesignTokens.Colors.accent, lineWidth: 1)
                }
            }
            // Hidden rather than removed: an `if` here drops the tab's alignment guide and sinks it into the card.
            .overlay(alignment: .topLeading) { queueTab(tab ?? "").opacity(tab == nil ? 0 : 1) }
            .compositingGroup()
            .shadow(color: elevation.edge.color, radius: elevation.edge.radius, y: elevation.edge.y)
            .shadow(color: elevation.spread.color, radius: elevation.spread.radius, y: elevation.spread.y)
    }

    @ViewBuilder
    private var cover: some View {
        if let image = record.image {
            Color.clear.overlay {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
        } else {
            placeholder
        }
    }

    /// Placeholder artwork: a horizon band over the lower 36% and a sun disc 24% wide, 16% in from the right.
    private var placeholder: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                DesignTokens.Colors.surfaceSunken
                DesignTokens.EditDesk.Colors.fillSelectedChip
                    .frame(height: size.height * 0.36)
                    .offset(y: size.height * 0.64)
                Circle()
                    .fill(DesignTokens.EditDesk.Colors.strokeShell)
                    .frame(width: size.width * 0.24, height: size.width * 0.24)
                    .offset(x: size.width * 0.6, y: size.height * 0.14)
            }
        }
    }

    private var nowPlayingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DesignTokens.EditDesk.Colors.nowPlayingGlyph)
                .frame(width: 6, height: 6)
            Text("Now playing")
        }
        .font(DesignTokens.EditDesk.Typography.floatName)
        .foregroundStyle(DesignTokens.Colors.overlayForeground)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .thumbnailBadgeGlass(in: .roundedRectangle(DesignTokens.Corner.sm))
        .padding(10)
    }

    private func queueTab(_ tab: String) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: DesignTokens.Corner.sm, topTrailingRadius: DesignTokens.Corner.sm, style: .continuous
        )
        let border = isPlaying
            ? DesignTokens.Colors.accent
            : DesignTokens.Colors.textPrimary.opacity(DesignTokens.Card.strokeOpacity)
        return Text(verbatim: tab)
            .font(DesignTokens.PlaylistCrate.tabNumber)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isPlaying ? DesignTokens.Colors.onAccentFill : DesignTokens.Colors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.top, 3)
            .padding(.bottom, 2)
            .background(shape.fill(isPlaying ? DesignTokens.Colors.accent : DesignTokens.Colors.surfaceRaised))
            .overlay(shape.stroke(border, lineWidth: 1))
            .scaleEffect(tabScale, anchor: .bottomLeading)
            // Bottom edge sits on the card's top border, overlapping it by 1pt.
            .alignmentGuide(.top) { $0[.bottom] - 1 }
            .offset(x: 14)
    }
}
