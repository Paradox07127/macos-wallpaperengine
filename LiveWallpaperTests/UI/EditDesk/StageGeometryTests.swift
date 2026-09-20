import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// Pins SCREENS.md S1–S3, MOTION_SPEC 1–4 and GAP_ANALYSIS §6 numerically.
@Suite("Edit Desk stage geometry")
struct StageGeometryTests {
    private static let designWindow = CGSize(width: 1280, height: 820)
    private static let smallWindow = CGSize(width: 1040, height: 700)
    private static let designStage = CGRect(x: 0, y: 56, width: 1280, height: 764)

    private func near(_ actual: CGFloat, _ expected: CGFloat, _ tolerance: CGFloat = 0.5) -> Bool {
        abs(actual - expected) <= tolerance
    }

    private func near(_ actual: Double, _ expected: Double, _ tolerance: Double = 0.5) -> Bool {
        abs(actual - expected) <= tolerance
    }

    private func near(_ actual: CGRect, _ expected: CGRect, _ tolerance: CGFloat = 0.5) -> Bool {
        near(actual.minX, expected.minX, tolerance)
            && near(actual.minY, expected.minY, tolerance)
            && near(actual.width, expected.width, tolerance)
            && near(actual.height, expected.height, tolerance)
    }

    // MARK: Progress

    @Test("Progress splits into the two legs of the gesture")
    func progressSplit() {
        let expectations: [(p: Double, t1: Double, t2: Double)] = [
            (0, 0, 0), (0.5, 0.5, 0), (1, 1, 0), (1.5, 1, 0.5), (2, 1, 1),
        ]
        for e in expectations {
            let split = StageGeometry.progressSplit(e.p)
            #expect(split.t1 == e.t1 && split.t2 == e.t2, Comment(rawValue: "p=\(e.p) → \(split)"))
        }
    }

    @Test("Progress clamps to 0…2 and snaps to the nearest rest state")
    func clampAndSnap() {
        #expect(StageGeometry.clampProgress(-0.3) == 0)
        #expect(StageGeometry.clampProgress(2.4) == 2)
        #expect(StageGeometry.clampProgress(1.2) == 1.2)
        #expect(StageGeometry.snapTarget(for: 0.4) == 0)
        #expect(StageGeometry.snapTarget(for: 0.6) == 1)
        #expect(StageGeometry.snapTarget(for: 1.49) == 1)
        #expect(StageGeometry.snapTarget(for: 1.6) == 2)
        #expect(StageGeometry.snapTarget(for: 2.7) == 2)
    }

    @Test("Stage transform follows MOTION 3: translateY(−60·t1−220·t2) scale(1−.18·t1−.3·t2) opacity(1−t2)")
    func stageTransform() {
        let expectations: [(p: Double, ty: CGFloat, scale: CGFloat, opacity: CGFloat)] = [
            (0, 0, 1, 1), (1, -60, 0.82, 1), (1.5, -170, 0.67, 0.5), (2, -280, 0.52, 0),
        ]
        for e in expectations {
            let t = StageGeometry.stageTransform(progress: e.p)
            #expect(
                near(t.translationY, e.ty, 0.01) && near(t.scale, e.scale, 0.001) && near(t.opacity, e.opacity, 0.001),
                Comment(rawValue: "p=\(e.p) → \(t)")
            )
        }
    }

    @Test("Chip row rides above the card row until the grid takes over at p ≥ 1.5, then sits at 70")
    func chipRowTop() {
        #expect(StageGeometry.chipRowTop(progress: 1, windowSize: Self.designWindow) == 632)
        #expect(StageGeometry.chipRowTop(progress: 1.49, windowSize: Self.designWindow) == 632)
        #expect(StageGeometry.chipRowTop(progress: 1.5, windowSize: Self.designWindow) == 70)
        #expect(StageGeometry.chipRowTop(progress: 2, windowSize: Self.designWindow) == 70)
        // The row rides with the shelf: a short window must not drop it into the cards.
        for height in stride(from: CGFloat(700), through: 1400, by: 20) {
            let size = CGSize(width: 1280, height: height)
            let chips = StageGeometry.chipRowTop(progress: 1, windowSize: size)
            let cards = StageGeometry.rowFrame(style: .crate, index: 0, count: 8, focus: 0, windowSize: size)
            #expect(chips + 26 <= cards.minY, Comment(rawValue: "at \(height): chips \(chips), cards \(cards.minY)"))
        }
    }

    @Test("Snap spring converts to CASpringAnimation terms")
    func springConversion() {
        let spring = StageGeometry.snapSpring
        #expect(spring.mass == 1)
        #expect(near(spring.stiffness, 273.4, 0.05), Comment(rawValue: "stiffness \(spring.stiffness)"))
        #expect(near(spring.damping, 27.45, 0.01), Comment(rawValue: "damping \(spring.damping)"))
    }

    // MARK: Arrangement

    @Test("Stage area is everything under the 56pt top bar")
    func stageRect() {
        #expect(StageGeometry.stageRect(windowSize: Self.designWindow) == Self.designStage)
        #expect(StageGeometry.stageRect(windowSize: Self.smallWindow) == CGRect(x: 0, y: 56, width: 1040, height: 644))
    }

    @Test("One display scales 1:4 and centers in the stage, biased up for its name row")
    func singleDisplayArrangement() {
        let a = StageGeometry.arrangement(frames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)], in: Self.designStage)
        #expect(near(a.scale, 0.25, 0.0001))
        #expect(a.contentRects.count == 1)
        let rect = a.contentRects.first ?? .zero
        #expect(near(rect, CGRect(x: 400, y: 283, width: 480, height: 270)), Comment(rawValue: "\(rect)"))
    }

    @Test("Two displays keep their relative placement, flipped from y-up to top-left")
    func twoDisplayArrangement() {
        // MacBook sits below-left of the external display in global (y-up) space.
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 96, y: -1117, width: 1728, height: 1117),
        ]
        let a = StageGeometry.arrangement(frames: frames, in: Self.designStage)
        #expect(near(a.scale, 0.2130, 0.0001))
        #expect(a.contentRects.count == 2)
        guard a.contentRects.count == 2 else { return }
        let external = a.contentRects[0]
        let builtin = a.contentRects[1]
        #expect(near(external, CGRect(x: 435.5, y: 138, width: 409, height: 230.1)), Comment(rawValue: "\(external)"))
        #expect(near(builtin, CGRect(x: 455.9, y: 460.1, width: 368.1, height: 237.9)), Comment(rawValue: "\(builtin)"))
        #expect(builtin.minY > external.minY, "The lower screen must land lower on the stage")
    }

    @Test("Wide or tall arrangements shrink below 1:4 to stay inside 1180×560, gaps included")
    func cappedArrangement() {
        let wide = (0 ..< 3).map { CGRect(x: CGFloat($0) * 3840, y: 0, width: 3840, height: 2160) }
        let a = StageGeometry.arrangement(frames: wide, in: Self.designStage)
        #expect(a.scale < 0.25)
        let union = a.contentRects.reduce(CGRect.null) { $0.union($1) }
        #expect(near(union.width, 1180) && union.height <= 560.5, Comment(rawValue: "union \(union)"))
        #expect(near(union.midX, 640) && near(union.midY, 418), Comment(rawValue: "union \(union)"))

        let tall = (0 ..< 3).map { CGRect(x: 0, y: CGFloat($0) * 1080, width: 1920, height: 1080) }
        let b = StageGeometry.arrangement(frames: tall, in: Self.designStage)
        let tallUnion = b.contentRects.reduce(CGRect.null) { $0.union($1) }
        #expect(near(tallUnion.height, 560) && tallUnion.width <= 1180.5, Comment(rawValue: "union \(tallUnion)"))

        let mixed = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1080, height: 1920),
        ]
        let c = StageGeometry.arrangement(frames: mixed, in: Self.designStage)
        #expect(near(c.scale, 0.25, 0.0001), "778×480 plus one column gap fits, so the nominal scale stays")
    }

    @Test("Neighbouring displays never overlap, badges and name rows included")
    func displaysDoNotOverlap() {
        let layouts: [(String, [(CGRect, Bool)])] = [
            ("two 4K side by side", [
                (CGRect(x: 0, y: 0, width: 3840, height: 2160), false),
                (CGRect(x: 3840, y: 0, width: 3840, height: 2160), false),
            ]),
            ("external above MacBook", [
                (CGRect(x: 0, y: 0, width: 1920, height: 1080), false),
                (CGRect(x: 96, y: -1117, width: 1728, height: 1117), true),
            ]),
            ("three in a row", (0 ..< 3).map { (CGRect(x: CGFloat($0) * 1920, y: 0, width: 1920, height: 1080), false) }),
            ("stacked pair", [
                (CGRect(x: 0, y: 1080, width: 1920, height: 1080), false),
                (CGRect(x: 0, y: 0, width: 1920, height: 1080), false),
            ]),
            ("L shape", [
                (CGRect(x: 0, y: 0, width: 1920, height: 1080), false),
                (CGRect(x: 1920, y: 0, width: 1920, height: 1080), false),
                (CGRect(x: 1920, y: -1080, width: 1920, height: 1080), true),
            ]),
            // Corner to corner is the one shape that straddles no boundary on either axis, so it is
            // the only one where neither separation pass opens a gap.
            ("corner touch", [
                (CGRect(x: 0, y: 0, width: 1920, height: 1080), false),
                (CGRect(x: 1920, y: -1080, width: 1920, height: 1080), false),
            ]),
            ("laptop at the corner", [
                (CGRect(x: 0, y: 0, width: 1920, height: 1080), false),
                (CGRect(x: 1920, y: -1117, width: 1728, height: 1117), true),
            ]),
        ]
        for (name, layout) in layouts {
            let a = StageGeometry.arrangement(frames: layout.map(\.0), in: Self.designStage)
            let boxes = a.contentRects.enumerated().map {
                StageGeometry.occupiedRect(content: $1, isBuiltin: layout[$0].1)
            }
            for i in boxes.indices {
                for j in boxes.indices where j > i {
                    #expect(
                        !boxes[i].intersects(boxes[j]),
                        Comment(rawValue: "\(name): \(boxes[i]) overlaps \(boxes[j])")
                    )
                }
            }
        }
    }

    @Test("Shells pad the content: 8 all round for external, 7/7/9 for the MacBook")
    func shellRects() {
        let content = CGRect(x: 100, y: 100, width: 384, height: 216)
        #expect(StageGeometry.shellRect(content: content, isBuiltin: false) == CGRect(x: 92, y: 92, width: 400, height: 232))
        #expect(StageGeometry.shellRect(content: content, isBuiltin: true) == CGRect(x: 93, y: 93, width: 398, height: 232))
    }

    // MARK: Shelf row

    @Test("Folder row: 84pt pitch, 200×112 cards, 136pt above the window bottom, leading ≥ 48")
    func rowFrames() {
        for i in 0 ..< 14 {
            let f = StageGeometry.rowFrame(style: .folders, index: i, count: 14, focus: 0, windowSize: Self.designWindow)
            #expect(near(f, CGRect(x: 48 + 84 * CGFloat(i), y: 684, width: 200, height: 112)), Comment(rawValue: "card \(i): \(f)"))
        }
        // Centring uses the projected width, so a turned-away card does not drag the run right.
        let five = (0 ..< 5).map { StageGeometry.rowFrame(style: .folders, index: $0, count: 5, focus: 0, windowSize: Self.designWindow) }
        #expect(near(five[0].minX, 395.4) && near(five[4].maxX, 931.4), Comment(rawValue: "five cards center: \(five)"))
        let small = StageGeometry.rowFrame(style: .folders, index: 0, count: 14, focus: 0, windowSize: Self.smallWindow)
        #expect(near(small.minY, 564) && near(small.minX, 48), Comment(rawValue: "\(small)"))
    }

    @Test("Crate packs to a 48pt pitch and Cover Flow orbits the focused slot")
    func styledRows() {
        let crate = (0 ..< 5).map { StageGeometry.rowFrame(style: .crate, index: $0, count: 5, focus: 0, windowSize: Self.designWindow) }
        #expect(near(crate[0].minX, 455.7) && near(crate[1].minX - crate[0].minX, 48), Comment(rawValue: "\(crate)"))

        let focused = StageGeometry.rowFrame(style: .coverFlow, index: 2, count: 7, focus: 2, windowSize: Self.designWindow)
        #expect(near(focused.minX, 540), Comment(rawValue: "\(focused)"))
        let right = StageGeometry.rowFrame(style: .coverFlow, index: 3, count: 7, focus: 2, windowSize: Self.designWindow)
        let left = StageGeometry.rowFrame(style: .coverFlow, index: 0, count: 7, focus: 2, windowSize: Self.designWindow)
        #expect(near(right.minX, 650) && near(left.minX, 382), Comment(rawValue: "\(right) \(left)"))
        // A fractional focus must not jump: half a slot out is half the first offset.
        let gliding = StageGeometry.rowFrame(style: .coverFlow, index: 3, count: 7, focus: 2.5, windowSize: Self.designWindow)
        #expect(near(gliding.minX, 595), Comment(rawValue: "\(gliding)"))
    }

    @Test("Wave lift peaks under the hovered card and dies out three cards away")
    func waveLift() {
        #expect(StageGeometry.waveLift(style: .folders, index: 3, centre: nil) == 0)
        #expect(near(StageGeometry.waveLift(style: .folders, index: 3, hovered: 3), -48, 0.01))
        #expect(near(StageGeometry.waveLift(style: .folders, index: 4, hovered: 3), -32.51, 0.05))
        #expect(near(StageGeometry.waveLift(style: .folders, index: 1, hovered: 3), -6.04, 0.05))
        #expect(StageGeometry.waveLift(style: .folders, index: 0, hovered: 3) == 0)
        #expect(StageGeometry.waveLift(style: .folders, index: 6, hovered: 3) == 0)
        #expect(near(StageGeometry.waveLift(style: .crate, index: 3, hovered: 3), -54, 0.01))
        #expect(near(StageGeometry.waveLift(style: .coverFlow, index: 3, hovered: 3), -16, 0.01))
        #expect(StageGeometry.waveLift(style: .coverFlow, index: 4, hovered: 3) == 0)

        // The whole point of the rewrite: the crest moves inside a slot, and it is smooth across
        // the boundary — a spring can hide a step, but it cannot invent the motion that is missing.
        // Lifts are negative, so "falling off" means rising toward zero.
        let inSlot = (0 ... 4).map { StageGeometry.waveLift(style: .crate, index: 3, centre: 3 + CGFloat($0) * 0.25) }
        #expect(inSlot == inSlot.sorted(), Comment(rawValue: "\(inSlot)"))
        #expect(inSlot[0] < inSlot[inSlot.count - 1], "the crest has to fall off as the pointer leaves the card")
        #expect(inSlot[0] != inSlot[1], "a quarter-slot of pointer travel has to change the wave")
        let step = CGFloat(0.02)
        for centre in stride(from: CGFloat(2), through: 4, by: step) {
            let here = StageGeometry.waveLift(style: .crate, index: 3, centre: centre)
            let next = StageGeometry.waveLift(style: .crate, index: 3, centre: centre + step)
            #expect(abs(next - here) < 2, Comment(rawValue: "jump of \(abs(next - here))pt at centre \(centre)"))
        }
    }

    // MARK: Grid

    @Test("The visible slice follows the row offset and always covers the window")
    func visibleCards() {
        let size = Self.designWindow
        let home = StageGeometry.visibleCards(style: .crate, count: 120, rowOffset: 0, focus: 0, windowSize: size)
        #expect(home.lowerBound == 0 && home.count < 40, Comment(rawValue: "\(home)"))
        let scrolled = StageGeometry.visibleCards(style: .crate, count: 120, rowOffset: -2400, focus: 0, windowSize: size)
        #expect(scrolled.lowerBound > 40 && scrolled.upperBound <= 120, Comment(rawValue: "\(scrolled)"))
        // Every card that is not fully faded out at the band's ends has to be inside the slice.
        let band = StageGeometry.shelfBand(style: .crate, capacity: StageGeometry.shelfCapacity, windowSize: size)
        for offset in stride(from: CGFloat(0), through: -5000, by: -137) {
            let slice = StageGeometry.visibleCards(style: .crate, count: 120, rowOffset: offset, focus: 0, windowSize: size)
            for index in 0 ..< 120 where !slice.contains(index) {
                let frame = StageGeometry.rowFrame(style: .crate, index: index, count: 120, focus: 0, windowSize: size)
                    .offsetBy(dx: offset, dy: 0)
                let alpha = StageGeometry.bandOpacity(
                    cardMinX: frame.minX, style: .crate,
                    capacity: StageGeometry.shelfCapacity, windowSize: size
                )
                #expect(
                    alpha == 0 || frame.minX < band.lowerBound - StageGeometry.bandFade,
                    Comment(rawValue: "offset \(offset): card \(index) at \(frame) still shows but is outside \(slice)")
                )
            }
        }
        #expect(StageGeometry.visibleCards(style: .crate, count: 0, rowOffset: 0, focus: 0, windowSize: size).isEmpty)
        let flow = StageGeometry.visibleCards(style: .coverFlow, count: 120, rowOffset: 0, focus: 40, windowSize: size)
        #expect(flow.contains(40) && flow.count <= 2 * StageGeometry.coverFlowReach + 1, Comment(rawValue: "\(flow)"))
    }

    @Test("Grid ladder follows the library's fixed medium-wide columns")
    func gridLadder() {
        #expect(StageGeometry.gridColumns(windowWidth: 1040) == 2)
        #expect(StageGeometry.gridColumns(windowWidth: 1280) == 3)
        #expect(StageGeometry.gridColumns(windowWidth: 1600) == 3)
        for width in [CGFloat(1040), 1280, 1600] {
            #expect(StageGeometry.gridCellSize(windowWidth: width) == CGSize(width: 384, height: 216))
        }
    }

    @Test("Flight endpoints match the library tile frames including both paddings")
    func gridFrames() {
        for width in [CGFloat(1040), 1280, 1600] {
            for index in [0, 1, 2, 3, 7, 11] {
                let expected = DesignTokens.LibraryGrid.tileFrame(
                    index: index, size: .medium, aspect: .wide,
                    fitting: width - 2 * DesignTokens.LibraryGrid.horizontalPadding, tileAspectRatio: 16 / 9
                ).offsetBy(
                    dx: DesignTokens.LibraryGrid.horizontalPadding,
                    dy: StageGeometry.gridTop + DesignTokens.LibraryGrid.verticalPadding
                )
                #expect(near(StageGeometry.gridFrame(index: index, windowWidth: width), expected, 0.001))
                let wrongAspect = DesignTokens.LibraryGrid.tileFrame(
                    index: index, size: .medium, aspect: .wide,
                    fitting: width - 2 * DesignTokens.LibraryGrid.horizontalPadding, tileAspectRatio: 4 / 3
                ).offsetBy(
                    dx: DesignTokens.LibraryGrid.horizontalPadding,
                    dy: StageGeometry.gridTop + DesignTokens.LibraryGrid.verticalPadding
                )
                #expect(!near(StageGeometry.gridFrame(index: index, windowWidth: width), wrongAspect, 1))
            }
        }
    }

    @Test("The grid window covers intersecting rows and is bounded by viewport height")
    func visibleGridCards() {
        for width in [CGFloat(1040), 1280, 1600] {
            let size = CGSize(width: width, height: 820)
            for offset in [CGFloat(0), 230, CGFloat(400 * 230), 100_000] {
                let visible = StageGeometry.visibleGridCards(count: 1000, windowSize: size, scrollOffset: offset)
                let viewport = CGRect(x: 0, y: StageGeometry.gridTop, width: width, height: size.height - StageGeometry.gridTop)
                for index in 0 ..< 1000 {
                    let frame = StageGeometry.gridFrame(index: index, windowWidth: width).offsetBy(dx: 0, dy: -offset)
                    #expect(visible.contains(index) == frame.intersects(viewport))
                }
                #expect(visible.count <= 5 * StageGeometry.gridColumns(windowWidth: width))
            }
        }
        #expect(StageGeometry.visibleGridCards(count: 0, windowSize: Self.designWindow, scrollOffset: 0).isEmpty)
    }

    @Test("Card placement rises over the first leg, then interpolates row → grid and untilts")
    func cardPlacement() {
        let row = StageGeometry.rowFrame(style: .folders, index: 3, count: 14, focus: 0, windowSize: Self.designWindow)
        let grid = StageGeometry.gridFrame(index: 3, windowWidth: 1280)
        func placement(_ progress: Double) -> StageGeometry.CardPlacement {
            StageGeometry.cardPlacement(
                style: .folders, index: 3, count: 14, progress: progress, focus: 0, windowSize: Self.designWindow
            )
        }

        let hidden = placement(0)
        #expect(near(hidden.frame.minY, 864) && hidden.opacity == 0, Comment(rawValue: "p=0 → \(hidden)"))
        let rising = placement(0.5)
        #expect(near(rising.frame.minY, 774) && near(rising.opacity, 0.6, 0.001), Comment(rawValue: "p=0.5 → \(rising)"))
        #expect(near(rising.frame.minX, row.minX) && near(rising.rotationYDegrees, 40, 0.01))

        let half = placement(1)
        #expect(near(half.frame, row) && near(half.rotationYDegrees, 40, 0.01) && half.opacity == 1, Comment(rawValue: "p=1 → \(half)"))
        // One plane: no card sits deeper or darker than any other, the overlap carries the depth.
        #expect(half.translateZ == 0 && half.dim == 0, Comment(rawValue: "depth \(half)"))
        #expect(near(half.depthOrder, 30, 0.01))
        let neighbour = StageGeometry.cardPlacement(
            style: .folders, index: 4, count: 14, progress: 1, focus: 0, windowSize: Self.designWindow
        )
        #expect(neighbour.depthOrder > half.depthOrder, "a card further right has to lie on top")

        let mid = placement(1.5)
        let expectedMid = CGRect(
            x: (row.minX + grid.minX) / 2, y: (row.minY + grid.minY) / 2,
            width: (row.width + grid.width) / 2, height: (row.height + grid.height) / 2
        )
        #expect(near(mid.frame, expectedMid) && near(mid.rotationYDegrees, 20, 0.01), Comment(rawValue: "p=1.5 → \(mid)"))

        let full = placement(2)
        #expect(near(full.frame, grid) && near(full.rotationYDegrees, 0, 0.01) && full.opacity == 1, Comment(rawValue: "p=2 → \(full)"))
        #expect(full.translateZ == 0 && full.dim == 0 && full.scale == 1, Comment(rawValue: "grid must be flat: \(full)"))
    }

    @Test("Dominoes: each card's near edge is its left one, and the card to its right lies on top")
    func cardsLeanLeftFront() {
        for style in [ShelfStyle.folders, .crate] {
            let placement = StageGeometry.cardPlacement(
                style: style, index: 0, count: 8, progress: 1, focus: 0, windowSize: Self.designWindow
            )
            // A Y rotation maps z' = −x·sinθ, so the angle has to be positive to send the right
            // edge away. Negative would pull it toward the viewer and the run would read right-front.
            #expect(placement.rotationYDegrees > 0, Comment(rawValue: "\(style) leans \(placement.rotationYDegrees)"))
            let hit = StageGeometry.hitRect(placement, style: style)
            #expect(
                hit.width < StageGeometry.projectedCardWidth(style),
                Comment(rawValue: "\(style): footprint \(hit.width) vs flat \(StageGeometry.projectedCardWidth(style))")
            )
            #expect(near(hit.minX, placement.frame.minX), "the near edge stays on the pivot")
        }
        let left = StageGeometry.cardPlacement(
            style: .crate, index: 0, count: 8, progress: 1, focus: 0, windowSize: Self.designWindow
        )
        let right = StageGeometry.cardPlacement(
            style: .crate, index: 1, count: 8, progress: 1, focus: 0, windowSize: Self.designWindow
        )
        #expect(right.depthOrder > left.depthOrder, "the card to the right has to lie on top")
        #expect(left.translateZ == 0 && right.translateZ == 0, "one plane: nothing steps back")
    }

    @Test("Hit rects follow the drawn card: projected width, and the perspective divide")
    func hitRects() {
        let half = StageGeometry.cardPlacement(
            style: .folders, index: 3, count: 14, progress: 1, focus: 0, windowSize: Self.designWindow
        )
        let rect = StageGeometry.hitRect(half, style: .folders)
        // Near edge on the pivot, far edge foreshortened: 200·cos40 = 153.2 orthographic, 142.3
        // once the far edge's own −128.6pt of depth goes through the divide.
        #expect(near(rect.minX, half.frame.minX) && near(rect.width, 142.3, 0.3), Comment(rawValue: "\(rect)"))
        #expect(near(rect.height, 112), Comment(rawValue: "\(rect)"))
        let flow = StageGeometry.cardPlacement(
            style: .coverFlow, index: 3, count: 7, progress: 1, focus: 2, windowSize: Self.designWindow
        )
        let flowRect = StageGeometry.hitRect(flow, style: .coverFlow)
        #expect(near(flowRect.width, 73.3, 0.5), Comment(rawValue: "\(flowRect)"))
        let grid = StageGeometry.cardPlacement(
            style: .folders, index: 3, count: 14, progress: 2, focus: 0, windowSize: Self.designWindow
        )
        #expect(near(StageGeometry.hitRect(grid, style: .folders), grid.frame, 0.01))
    }

    @Test("The arrangement never spills outside the window it is drawn in")
    func arrangementFitsTheWindow() {
        let layouts = [
            [CGRect(x: 0, y: 0, width: 2560, height: 1440), CGRect(x: 2560, y: 0, width: 2560, height: 1440)],
            [CGRect(x: 0, y: 0, width: 3840, height: 2160)],
            (0 ..< 3).map { CGRect(x: 0, y: CGFloat($0) * 1080, width: 1920, height: 1080) },
        ]
        for size in [Self.smallWindow, Self.designWindow, CGSize(width: 1600, height: 1000)] {
            let stage = StageGeometry.stageRect(windowSize: size)
            for frames in layouts {
                let a = StageGeometry.arrangement(frames: frames, in: stage)
                for (index, content) in a.contentRects.enumerated() {
                    let box = StageGeometry.occupiedRect(content: content, isBuiltin: false)
                    #expect(
                        box.minX >= 0 && box.maxX <= size.width && box.minY >= StageGeometry.topBarHeight
                            && box.maxY <= size.height,
                        Comment(rawValue: "\(size) display \(index) at \(box)")
                    )
                }
            }
        }
    }

    @Test("A hovered card turns to face the viewer, and its hit rect turns with it")
    func hoveredCardFacesTheViewer() {
        for style in [ShelfStyle.crate, .folders] {
            let m = StageGeometry.metrics(for: style)
            #expect(
                m.tiltDegrees + m.hoverTiltDegrees == 0,
                Comment(rawValue: "\(style) leaves \(m.tiltDegrees + m.hoverTiltDegrees)° of turn on the hovered card")
            )
            let placement = StageGeometry.cardPlacement(
                style: style, index: 5, count: 14, progress: 1, focus: 0, windowSize: StageGeometry.designWindow
            )
            let rest = StageGeometry.hitRect(placement, style: style)
            let hovered = StageGeometry.hitRect(placement, style: style, hover: 1)
            // Face-on, the only thing left is the perspective bump from pulling it toward the viewer.
            let expected = StageGeometry.cardSize.width
                * StageGeometry.shelfPerspective / (StageGeometry.shelfPerspective - m.hoverDepth)
            #expect(abs(hovered.width - expected) < 0.5)
            #expect(hovered.width > rest.width)
        }
    }

    @Test("The shelf is a centred band of `capacity` slots, and the slice never exceeds it")
    func shelfBandCapsWhatIsOnScreen() {
        let size = Self.designWindow
        for capacity in [6, 20, 24] {
            let band = StageGeometry.shelfBand(style: .crate, capacity: capacity, windowSize: size)
            let pitch = StageGeometry.metrics(for: .crate).pitch
            let card = StageGeometry.projectedCardWidth(.crate)
            // The band holds `capacity` origins one pitch apart, and the last card's width on top.
            let expected = min(CGFloat(capacity - 1) * pitch, size.width - 2 * StageGeometry.cardRowMinLeading - card)
            #expect(abs((band.upperBound - band.lowerBound) - expected) < 0.01)
            // Centred, so the air is split evenly around the strip the cards actually cover.
            #expect(abs((size.width - band.upperBound - card) - band.lowerBound) < 0.01)

            // The slice is the cap plus the two ramps a card crosses on its way in and out.
            let ramps = 2 * Int((StageGeometry.bandFade / pitch).rounded(.up)) + 2
            for offset in stride(from: CGFloat(0), through: -3000, by: -53) {
                let slice = StageGeometry.visibleCards(
                    style: .crate, count: 400, rowOffset: offset, focus: 0, windowSize: size, capacity: capacity
                )
                #expect(
                    slice.count <= capacity + ramps,
                    Comment(rawValue: "capacity \(capacity) at offset \(offset) drew \(slice.count)")
                )
            }
        }
    }

    @Test("Cards fade across the band's ends instead of popping")
    func bandEndsFade() {
        let size = Self.designWindow
        let band = StageGeometry.shelfBand(style: .crate, capacity: 20, windowSize: size)
        func alpha(_ x: CGFloat) -> CGFloat {
            StageGeometry.bandOpacity(cardMinX: x, style: .crate, capacity: 20, windowSize: size)
        }
        #expect(alpha((band.lowerBound + band.upperBound) / 2) == 1)
        #expect(alpha(band.lowerBound) == 1)
        #expect(alpha(band.upperBound) == 1, "the last card inside the band is not faded")
        #expect(alpha(band.lowerBound - StageGeometry.bandFade) == 0)
        #expect(alpha(band.upperBound + StageGeometry.bandFade) == 0)
        let half = alpha(band.lowerBound - StageGeometry.bandFade / 2)
        #expect(abs(half - 0.5) < 0.01, Comment(rawValue: "\(half)"))
        // Cover Flow has its own parking curve and no band.
        #expect(StageGeometry.bandOpacity(cardMinX: -9999, style: .coverFlow, capacity: 14, windowSize: size) == 1)
    }
}
