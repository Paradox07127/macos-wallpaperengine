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

    @Test("Every tile size lands on the same fixed columns as the visible library")
    func gridSizeHandoff() {
        for size in LibraryTileSize.allCases {
            for width in [CGFloat(1040), 1280, 1600] {
                for index in 0 ..< 12 {
                    let drawn = StageGeometry.cardPlacement(
                        style: .crate, index: index, count: 12, progress: 2, focus: 0,
                        windowSize: CGSize(width: width, height: 820), gridSize: size
                    ).frame
                    let expected = DesignTokens.LibraryGrid.tileFrame(
                        index: index, size: size, aspect: .wide,
                        fitting: width - 2 * DesignTokens.LibraryGrid.horizontalPadding,
                        tileAspectRatio: StageGeometry.cardAspectRatio
                    ).offsetBy(dx: DesignTokens.LibraryGrid.horizontalPadding,
                               dy: StageGeometry.gridTop + DesignTokens.LibraryGrid.verticalPadding)
                    #expect(near(drawn, expected))
                }
            }
        }
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

    @Test("The card row's top follows the shelf up over the first leg and rests there")
    func shelfRowTop() {
        let expectations: [(p: Double, top: CGFloat)] = [(0, 864), (0.5, 774), (1, 684), (2, 684)]
        for e in expectations {
            let top = StageGeometry.shelfRowTop(progress: e.p, windowSize: Self.designWindow)
            #expect(near(top, e.top), Comment(rawValue: "p=\(e.p) → \(top)"))
        }
        let row = StageGeometry.rowFrame(style: .crate, index: 0, count: 8, focus: 0, windowSize: Self.designWindow)
        #expect(
            StageGeometry.shelfRowTop(progress: 1, windowSize: Self.designWindow) == row.minY,
            "the open shelf's row top is the row's own frame"
        )
    }

    @Test("Chip row rides the card row, then crosses to 70 across the second leg instead of switching")
    func chipRowTop() {
        #expect(StageGeometry.chipRowTop(progress: 0, windowSize: Self.designWindow) == 812)
        #expect(StageGeometry.chipRowTop(progress: 1, windowSize: Self.designWindow) == 632)
        #expect(near(StageGeometry.chipRowTop(progress: 1.49, windowSize: Self.designWindow), 356.6))
        #expect(StageGeometry.chipRowTop(progress: 1.5, windowSize: Self.designWindow) == 351)
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

    @Test("The onboarding card's top inset is taken off the stage area, and given back at 0")
    func stageRectTopInset() {
        #expect(StageGeometry.stageRect(windowSize: Self.designWindow, topInset: 0) == Self.designStage)
        #expect(
            StageGeometry.stageRect(windowSize: Self.designWindow, topInset: 304)
                == CGRect(x: 0, y: 360, width: 1280, height: 460)
        )
    }

    @Test("A display re-centres in the shortened stage while the overview card is up")
    func arrangementWithTopInset() {
        let frames = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let open = StageGeometry.arrangement(
            frames: frames, in: StageGeometry.stageRect(windowSize: Self.designWindow, topInset: 304)
        )
        #expect(near(open.scale, 0.25, 0.0001), "460pt of stage still holds a 1:4 display")
        let rect = open.contentRects.first ?? .zero
        #expect(near(rect, CGRect(x: 400, y: 435, width: 480, height: 270)), Comment(rawValue: "\(rect)"))
        let rest = StageGeometry.arrangement(frames: frames, in: Self.designStage)
        let restRect = rest.contentRects.first ?? .zero
        #expect(rect.minY > restRect.minY, "the card pushes the arrangement down, it does not lift it")
        #expect(rect.minY - restRect.minY == 152, "half the inset, because the band is centred")
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

    // MARK: Name row

    /// The shell a display gets in the named window with a second one beside it.
    private func shellWidth(window: CGSize) -> CGFloat {
        let content = StageGeometry.arrangement(
            frames: [
                CGRect(x: 0, y: 0, width: 1920, height: 1080),
                CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            ],
            in: StageGeometry.stageRect(windowSize: window)
        ).contentRects[0]
        return StageGeometry.shellRect(content: content, isBuiltin: false).width
    }

    @Test("Dot, name and status ride as one group centred on the shell", arguments: [
        StageGeometry.designWindow, StageGeometry.minimumWindow,
    ])
    func nameRowCentresItsGroup(window: CGSize) {
        let width = shellWidth(window: window)
        let row = StageGeometry.nameRowLayout(shellWidth: width, top: 40, nameWidth: 96, statusWidth: 42)
        #expect(row.dot.width == StageGeometry.nameRowDotSize)
        #expect(row.name.width == 96)
        #expect(row.status.width == 42)
        #expect(row.name.minX - row.dot.maxX == StageGeometry.nameRowItemGap)
        #expect(row.status.minX - row.name.maxX == StageGeometry.nameRowItemGap)
        #expect(near((row.dot.minX + row.status.maxX) / 2, width / 2, 0.001))
        // One row: name and status share a baseline box, the dot is centred in it.
        #expect(row.name.minY == 40 && row.status.minY == 40)
        #expect(row.name.height == StageGeometry.nameRowHeight && row.status.height == StageGeometry.nameRowHeight)
        #expect(near(row.dot.midY, row.name.midY, 0.001))
    }

    /// Displays sit side by side with `displayColumnGap` between them, so a name row that kept
    /// growing past its own shell would be drawn over the neighbouring display.
    @Test("A name wider than the shell is clamped instead of reaching into the next display")
    func nameRowClampsALongName() {
        let width: CGFloat = 320
        let row = StageGeometry.nameRowLayout(shellWidth: width, top: 0, nameWidth: 900, statusWidth: 42)
        #expect(row.dot.minX >= StageGeometry.nameRowSideMargin)
        #expect(row.status.maxX <= width - StageGeometry.nameRowSideMargin)
        // The status keeps its own width; the name is what gives.
        #expect(row.status.width == 42)
        #expect(row.name.width == width - 2 * StageGeometry.nameRowSideMargin
            - StageGeometry.nameRowDotSize - 2 * StageGeometry.nameRowItemGap - 42)
    }

    // MARK: Playback controls

    @Test("The playback capsule holds three buttons in playlist mode and one otherwise", arguments: [true, false])
    func playbackCapsuleSizesToItsButtons(showsPlaylistControls: Bool) {
        let size = CGSize(width: 480, height: 270)
        let layout = StageGeometry.playbackLayout(content: size, showsPlaylistControls: showsPlaylistControls)
        #expect(layout.buttons.count == (showsPlaylistControls ? 3 : 1))
        let container = CGRect(origin: .zero, size: layout.container.size)
        for button in layout.buttons {
            #expect(button.width == StageGeometry.playbackButtonSide)
            #expect(container.contains(button))
        }
        #expect(near(size.width - layout.container.maxX, StageGeometry.playbackTrailingMargin, 0.001))
        #expect(near(size.height - layout.container.maxY, StageGeometry.playbackBottomMargin, 0.001))
        let inset = StageGeometry.playbackInset
        #expect(near(layout.container.width - (layout.buttons.last?.maxX ?? 0), inset.width, 0.001))
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

    @Test("Crate packs to a 48pt pitch and Focus Row orbits the focused slot")
    func styledRows() {
        let crate = (0 ..< 5).map { StageGeometry.rowFrame(style: .crate, index: $0, count: 5, focus: 0, windowSize: Self.designWindow) }
        #expect(near(crate[0].minX, 455.7) && near(crate[1].minX - crate[0].minX, 48), Comment(rawValue: "\(crate)"))

        let focused = StageGeometry.rowFrame(style: .focusRow, index: 2, count: 7, focus: 2, windowSize: Self.designWindow)
        #expect(near(focused.minX, 540), Comment(rawValue: "\(focused)"))
        // 194pt a slot, and 22pt more on each side of the grown middle card.
        let right = StageGeometry.rowFrame(style: .focusRow, index: 3, count: 7, focus: 2, windowSize: Self.designWindow)
        let left = StageGeometry.rowFrame(style: .focusRow, index: 0, count: 7, focus: 2, windowSize: Self.designWindow)
        #expect(near(right.minX, 756) && near(left.minX, 130), Comment(rawValue: "\(right) \(left)"))
        // A fractional focus must not jump: half a slot out is half the first offset.
        let gliding = StageGeometry.rowFrame(style: .focusRow, index: 3, count: 7, focus: 2.5, windowSize: Self.designWindow)
        #expect(near(gliding.minX, 648), Comment(rawValue: "\(gliding)"))
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
        #expect(near(StageGeometry.waveLift(style: .fan, index: 3, hovered: 3), -30, 0.01))
        #expect(near(StageGeometry.waveLift(style: .focusRow, index: 3, hovered: 3), -8, 0.01))
        #expect(StageGeometry.waveLift(style: .fan, index: 4, hovered: 3) == 0)

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
        // Six slots out is 13.8° and still showing; the seventh is past 16°.
        let fan = StageGeometry.visibleCards(style: .fan, count: 120, rowOffset: 0, focus: 40, windowSize: size)
        #expect(fan == 34 ..< 47, Comment(rawValue: "\(fan)"))
    }

    @Test("The default grid ladder packs four, five and six columns at 1040, 1280 and 1600")
    func gridLadder() {
        #expect(StageGeometry.gridColumns(windowWidth: 1040) == 4)
        #expect(StageGeometry.gridColumns(windowWidth: 1280) == 5)
        #expect(StageGeometry.gridColumns(windowWidth: 1600) == 6)
        for width in [CGFloat(1040), 1280, 1600] {
            let cell = StageGeometry.gridCellSize(windowWidth: width)
            #expect(abs(cell.width / cell.height - 16 / 9) < 0.001)
            #expect(cell.width < 340)
        }
    }

    @MainActor
    @Test("Until a size is picked the library shows small tiles: five columns of about 235pt at 1280, 1.18× a shelf card")
    func libraryDefaultsToSmallTiles() {
        #expect(LibraryTileSize.defaultSize == .small)
        #expect(EditDeskStageModel().gridTileSize == LibraryTileSize.defaultSize, "the stage would fly the cards to another grid")
        #expect(StageGeometry.gridColumns(windowWidth: 1280) == 5)
        let cell = StageGeometry.gridCellSize(windowWidth: 1280)
        #expect(abs(cell.width - 235.2) < 0.05, Comment(rawValue: "a default tile is \(cell.width)pt wide"))
        #expect(abs(cell.width / StageGeometry.cardSize.width - 1.18) < 0.005)
    }

    @Test("Flight endpoints match the library tile frames including both paddings")
    func gridFrames() {
        for width in [CGFloat(1040), 1280, 1600] {
            for index in [0, 1, 2, 3, 7, 11] {
                let expected = DesignTokens.LibraryGrid.tileFrame(
                    index: index, size: LibraryTileSize.defaultSize, aspect: .wide,
                    fitting: width - 2 * DesignTokens.LibraryGrid.horizontalPadding, tileAspectRatio: 16 / 9
                ).offsetBy(
                    dx: DesignTokens.LibraryGrid.horizontalPadding,
                    dy: StageGeometry.gridTop + DesignTokens.LibraryGrid.verticalPadding
                )
                #expect(near(StageGeometry.gridFrame(index: index, windowWidth: width), expected, 0.001))
                let wrongAspect = DesignTokens.LibraryGrid.tileFrame(
                    index: index, size: LibraryTileSize.defaultSize, aspect: .wide,
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
                // At most every row a viewport-high window can touch, a partial one at each end.
                let pitch = StageGeometry.gridCellSize(windowWidth: width).height + DesignTokens.LibraryGrid.spacing
                let rows = Int((viewport.height / pitch).rounded(.up)) + 1
                #expect(visible.count <= rows * StageGeometry.gridColumns(windowWidth: width))
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
        // The centred styles fade by their own curves and have no band.
        for style in [ShelfStyle.facingIn, .fan, .focusRow] {
            #expect(StageGeometry.bandOpacity(cardMinX: -9999, style: style, capacity: 14, windowSize: size) == 1)
        }
    }

    @Test("Fan and Focus Row flatten into the grid: no turn, no dim, full size, on the tiles", arguments: [
        ShelfStyle.fan, .focusRow,
    ])
    func centredStylesFlattenAtTheGrid(style: ShelfStyle) throws {
        func placement(_ index: Int, _ progress: Double) -> StageGeometry.CardPlacement {
            StageGeometry.cardPlacement(
                style: style, index: index, count: 13, progress: progress, focus: 6, windowSize: Self.designWindow
            )
        }
        // Only meaningful if the row has something to flatten: a turn on the fan, a size on the row.
        try #require(placement(9, 1).rotationZDegrees != 0 || placement(6, 1).scale != 1)
        for index in 0 ..< 13 {
            let row = placement(index, 1)
            let half = placement(index, 1.5)
            let grid = placement(index, 2)
            #expect(near(half.rotationZDegrees, row.rotationZDegrees / 2, 0.0001), Comment(rawValue: "card \(index): \(half)"))
            #expect(
                grid.rotationYDegrees == 0 && grid.rotationZDegrees == 0 && grid.translateZ == 0 && grid.dim == 0
                    && grid.scale == 1,
                Comment(rawValue: "card \(index): \(grid)")
            )
            #expect(near(grid.frame, StageGeometry.gridFrame(index: index, windowWidth: Self.designWindow.width), 0.001))
        }
        #expect(StageGeometry.shelfPerspective == 500)
    }

    // MARK: Fan

    private func fan(_ index: Int, focus: Double, count: Int = 13, progress: Double = 1, capacity: Int = 20) -> StageGeometry.CardPlacement {
        StageGeometry.cardPlacement(
            style: .fan, index: index, count: count, progress: progress, focus: focus,
            windowSize: Self.designWindow, capacity: capacity
        )
    }

    @Test("Fan mirrors about the window's centre line: positions, and turns of opposite sign", arguments: [6.0, 6.5])
    func fanIsSymmetric(focus: Double) {
        let size = Self.designWindow
        for right in 7 ... 12 {
            let left = Int(2 * focus) - right
            let r = fan(right, focus: focus)
            let l = fan(left, focus: focus)
            let label = "focus \(focus), cards \(left) ↔ \(right)"
            #expect(
                near(r.frame.midX - size.width / 2, size.width / 2 - l.frame.midX, 0.001) && near(r.frame.midY, l.frame.midY, 0.001),
                Comment(rawValue: "\(label): \(l.frame) vs \(r.frame)")
            )
            #expect(
                r.rotationZDegrees > 0 && near(r.rotationZDegrees, -l.rotationZDegrees, 0.001),
                Comment(rawValue: "\(label): turns \(l.rotationZDegrees) vs \(r.rotationZDegrees)")
            )
            #expect(near(r.opacity, l.opacity, 0.001), Comment(rawValue: "\(label): alpha \(l.opacity) vs \(r.opacity)"))
            let rh = StageGeometry.hitRect(r, style: .fan)
            let lh = StageGeometry.hitRect(l, style: .fan)
            #expect(
                near(rh.minX - size.width / 2, size.width / 2 - lh.maxX, 0.01) && near(rh.width, lh.width, 0.01)
                    && near(rh.minY, lh.minY, 0.01) && near(rh.height, lh.height, 0.01),
                Comment(rawValue: "\(label): hit \(lh) vs \(rh)")
            )
        }
    }

    @Test("Fan: every centre on one 1500pt arc whose top is 18pt above the row's middle, each card turned along its radius")
    func fanRidesOneArc() {
        let size = Self.designWindow
        let rowTop = size.height - StageGeometry.cardRowBottomInset
        let hub = CGPoint(x: size.width / 2, y: rowTop + 56 - 18 + 1500)
        for focus in [0.0, 3.3, 6.0] {
            for index in 0 ..< 13 {
                let card = fan(index, focus: focus)
                let u = CGFloat(index) - CGFloat(focus)
                let label = "focus \(focus), card \(index): \(card)"
                #expect(near(card.rotationZDegrees, 2.3 * u, 0.0001), Comment(rawValue: label))
                #expect(near(hypot(card.frame.midX - hub.x, card.frame.midY - hub.y), 1500, 0.001), Comment(rawValue: label))
                // The card's up runs out along the radius through its centre, away from the hub.
                let radius = atan2(card.frame.midX - hub.x, hub.y - card.frame.midY) * 180 / .pi
                #expect(near(card.rotationZDegrees, radius, 0.0001), Comment(rawValue: "\(label): radius at \(radius)°"))
                #expect(
                    card.frame.size == StageGeometry.cardSize && card.rotationYDegrees == 0 && card.scale == 1
                        && card.anchorX == 0.5 && card.translateZ == 0 && card.dim == 0,
                    Comment(rawValue: label)
                )
                if u > 0 {
                    // Clockwise on screen, y down: the right card's top edge runs downhill to the right.
                    let corners = StageGeometry.hitShape(card, style: .fan).corners
                    #expect(corners[1].y > corners[0].y, Comment(rawValue: "\(label): top edge \(corners[0]) → \(corners[1])"))
                }
            }
        }
        let middle = fan(6, focus: 6)
        #expect(middle.rotationZDegrees == 0, Comment(rawValue: "\(middle)"))
        #expect(middle.frame.midX == size.width / 2 && middle.frame.midY == rowTop + 56 - 18, Comment(rawValue: "\(middle)"))
        // Right lies over left, as in the crate.
        #expect((0 ..< 12).allSatisfy { fan($0 + 1, focus: 6).depthOrder > fan($0, focus: 6).depthOrder })
    }

    @Test("Fan: the arc rises with the shelf instead of flattening onto the row top")
    func fanRisesWithTheShelf() {
        for index in [2, 6, 11] {
            let arc = StageGeometry.rowFrame(style: .fan, index: index, count: 13, focus: 6, windowSize: Self.designWindow)
            for progress in [0.5, 1] {
                let card = fan(index, focus: 6, progress: progress)
                let below = StageGeometry.shelfHiddenOffset * CGFloat(1 - progress)
                #expect(
                    near(card.frame, arc.offsetBy(dx: 0, dy: below), 0.001),
                    Comment(rawValue: "card \(index) at p = \(progress): \(card.frame), arc \(arc)")
                )
            }
        }
    }

    @Test("Fan: a card is whole to 13° off the middle and has faded out by 16°, on either side")
    func fanFadesBetween13And16Degrees() {
        /// Card 10 turned `turn` degrees off the middle.
        func alpha(_ turn: CGFloat, capacity: Int = 20) -> CGFloat {
            fan(10, focus: Double(10 - turn / 2.3), count: 40, capacity: capacity).opacity
        }
        for sign in [CGFloat(1), -1] {
            #expect(alpha(sign * 12) == 1 && near(alpha(sign * 13), 1, 0.000_001), Comment(rawValue: "\(alpha(sign * 12)) \(alpha(sign * 13))"))
            #expect(near(alpha(sign * 14.5), 0.5, 0.000_001), Comment(rawValue: "\(alpha(sign * 14.5))"))
            #expect(near(alpha(sign * 16), 0, 0.000_001) && alpha(sign * 17) == 0, Comment(rawValue: "\(alpha(sign * 16)) \(alpha(sign * 17))"))
        }
        // The same half-slot cap as Facing In: six cards leave two a side, the third fading.
        #expect(near(fan(10, focus: 7.75, count: 40, capacity: 6).opacity, 0.5, 0.000_001))
    }

    @Test("Fan sweeps without a jump: centres, turns and hit corners move by bounded steps")
    func fanSweepsWithoutJumps() {
        func row(_ focus: Double) -> [StageGeometry.CardPlacement] {
            (0 ..< 8).map { fan($0, focus: focus, count: 8) }
        }
        var worst = (centre: CGFloat(0), turn: CGFloat(0), corner: CGFloat(0))
        var previous = row(0)
        for step in 1 ... 300 {
            let current = row(Double(step) / 100)
            for (before, after) in zip(previous, current) {
                worst.centre = max(worst.centre, hypot(after.frame.midX - before.frame.midX, after.frame.midY - before.frame.midY))
                worst.turn = max(worst.turn, abs(after.rotationZDegrees - before.rotationZDegrees))
                let a = StageGeometry.hitShape(before, style: .fan).corners
                let b = StageGeometry.hitShape(after, style: .fan).corners
                for (p, q) in zip(a, b) {
                    worst.corner = max(worst.corner, hypot(q.x - p.x, q.y - p.y))
                }
            }
            previous = current
        }
        print("FAN sweep worst step: centre \(worst.centre) turn \(worst.turn) corner \(worst.corner)")
        // 0.01 of a slot turns the whole fan 0.023° about its hub: 0.602pt at the 1500pt centres,
        // 0.626pt at the top corners, 1559pt out.
        #expect(worst.centre <= 0.61, Comment(rawValue: "a centre moved \(worst.centre)pt in one 0.01 step"))
        #expect(worst.turn <= 0.0231, Comment(rawValue: "a card turned \(worst.turn)° in one 0.01 step"))
        #expect(worst.corner <= 0.63, Comment(rawValue: "a hit corner moved \(worst.corner)pt in one 0.01 step"))
        // The bounds only mean something if the sweep carried cards across the middle.
        #expect(row(0)[2].rotationZDegrees > 0 && row(3)[2].rotationZDegrees < 0)
    }

    @Test("Fan and Focus Row build exactly the cards that show, at most (capacity − 1) / 2 a side", arguments: [
        ShelfStyle.fan, .focusRow,
    ], [6, 20])
    func centredSliceIsWhatShows(style: ShelfStyle, capacity: Int) {
        let side = (capacity - 1) / 2
        for width in [CGFloat(1040), 1280, 1920] {
            let size = CGSize(width: width, height: 820)
            for step in 0 ... 200 {
                let focus = Double(step) / 10
                let slice = StageGeometry.visibleCards(
                    style: style, count: 40, rowOffset: 0, focus: focus, windowSize: size, capacity: capacity
                )
                let centre = Int(focus.rounded())
                #expect(
                    slice.contains(centre) && centre - slice.lowerBound <= side && slice.upperBound - 1 - centre <= side,
                    Comment(rawValue: "\(width)pt, focus \(focus): \(slice)")
                )
                for index in 0 ..< 40 where index != centre {
                    let alpha = StageGeometry.cardPlacement(
                        style: style, index: index, count: 40, progress: 1, focus: focus, windowSize: size, capacity: capacity
                    ).opacity
                    #expect(
                        slice.contains(index) == (alpha > 0),
                        Comment(rawValue: "\(width)pt, focus \(focus): card \(index) at \(alpha), slice \(slice)")
                    )
                }
            }
        }
    }

    // MARK: Focus Row

    @Test("Focus Row: a 220×123 middle card between 176×99 neighbours, 18pt apart wherever the row stands")
    func focusRowSizesAndGaps() {
        let size = Self.designWindow
        func placements(_ focus: Double) -> [StageGeometry.CardPlacement] {
            (0 ..< 9).map {
                StageGeometry.cardPlacement(style: .focusRow, index: $0, count: 9, progress: 1, focus: focus, windowSize: size)
            }
        }
        func hits(_ focus: Double) -> [CGRect] {
            placements(focus).map { StageGeometry.hitRect($0, style: .focusRow) }
        }
        let rest = hits(4)
        #expect(near(rest[4].width, 220, 0.001) && near(rest[4].height, 123.2, 0.001), Comment(rawValue: "\(rest[4])"))
        #expect(
            near(rest[4].midX, size.width / 2, 0.001) && near(rest[4].midY, size.height - StageGeometry.cardRowBottomInset + 56, 0.001),
            Comment(rawValue: "\(rest[4])")
        )
        for index in [2, 3, 5, 6] {
            #expect(
                near(rest[index].width, 176, 0.001) && near(rest[index].height, 98.56, 0.001) && near(rest[index].midY, rest[4].midY, 0.001),
                Comment(rawValue: "card \(index): \(rest[index])")
            )
        }
        for step in 0 ... 40 {
            let focus = 3 + Double(step) / 20
            let row = hits(focus)
            for index in 1 ..< row.count {
                #expect(
                    near(row[index].minX - row[index - 1].maxX, 18, 0.001),
                    Comment(rawValue: "focus \(focus): cards \(index - 1) and \(index) are \(row[index].minX - row[index - 1].maxX)pt apart")
                )
            }
        }
        // Between two cards the growth is shared out: halfway, both are 198pt.
        let halfway = hits(4.5)
        #expect(near(halfway[4].width, 198, 0.001) && near(halfway[5].width, 198, 0.001), Comment(rawValue: "\(halfway[4]) \(halfway[5])"))
        var worst = (width: CGFloat(0), minX: CGFloat(0))
        var previous = hits(3)
        for step in 1 ... 200 {
            let current = hits(3 + Double(step) / 100)
            for (a, b) in zip(previous, current) {
                worst.width = max(worst.width, abs(b.width - a.width))
                worst.minX = max(worst.minX, abs(b.minX - a.minX))
            }
            previous = current
        }
        print("FOCUSROW sweep worst step: width \(worst.width) minX \(worst.minX)")
        // 0.01 of a slot grows a card by 0.44pt and moves an edge by at most 216 + 22 = 238pt a slot.
        #expect(worst.width <= 0.45 && worst.minX <= 2.39, Comment(rawValue: "\(worst)"))
        // Flat, the middle card on top, the others dimmed by up to 0.3.
        let row = placements(4.5)
        #expect(row.allSatisfy { $0.rotationYDegrees == 0 && $0.rotationZDegrees == 0 && $0.anchorX == 0.5 })
        #expect(near(row[4].dim, 0.15, 0.000_001) && near(row[3].dim, 0.3, 0.000_001) && near(row[7].dim, 0.3, 0.000_001))
        #expect(placements(4)[4].dim == 0 && placements(4)[4].depthOrder > placements(4)[5].depthOrder)
    }

    // MARK: Facing In

    @Test("Facing In mirrors about the window's centre line: position, turn and pivot", arguments: [6.0, 6.5])
    func facingInIsSymmetric(focus: Double) {
        let size = Self.designWindow
        func placement(_ index: Int) -> StageGeometry.CardPlacement {
            StageGeometry.cardPlacement(
                style: .facingIn, index: index, count: 13, progress: 1, focus: focus, windowSize: size
            )
        }
        for right in 7 ... 12 {
            let left = Int(2 * focus) - right
            let r = placement(right)
            let l = placement(left)
            let label = "focus \(focus), cards \(left) ↔ \(right)"
            #expect(
                near(r.frame.minX - size.width / 2, size.width / 2 - l.frame.maxX, 0.001),
                Comment(rawValue: "\(label): \(l.frame) vs \(r.frame)")
            )
            #expect(
                near(r.rotationYDegrees, -l.rotationYDegrees, 0.001),
                Comment(rawValue: "\(label): turns \(l.rotationYDegrees) vs \(r.rotationYDegrees)")
            )
            #expect(r.anchorX == 1 - l.anchorX, Comment(rawValue: "\(label): pivots \(l.anchorX) vs \(r.anchorX)"))
            #expect(near(r.opacity, l.opacity, 0.001), Comment(rawValue: "\(label): alpha \(l.opacity) vs \(r.opacity)"))
            let rh = StageGeometry.hitRect(r, style: .facingIn)
            let lh = StageGeometry.hitRect(l, style: .facingIn)
            #expect(
                near(rh.minX - size.width / 2, size.width / 2 - lh.maxX, 0.01) && near(rh.width, lh.width, 0.01)
                    && near(rh.height, lh.height, 0.01),
                Comment(rawValue: "\(label): hit \(lh) vs \(rh)")
            )
        }
    }

    @Test("Facing In: the middle card faces front on top, and each side turns its outer edge near")
    func facingInTurnsTowardTheMiddle() {
        let size = Self.designWindow
        let row = (0 ..< 13).map {
            StageGeometry.cardPlacement(style: .facingIn, index: $0, count: 13, progress: 1, focus: 6, windowSize: size)
        }
        let middle = row[6]
        #expect(middle.rotationYDegrees == 0, Comment(rawValue: "the middle card turns \(middle.rotationYDegrees)"))
        #expect(near(middle.frame.midX, size.width / 2, 0.001), Comment(rawValue: "\(middle.frame)"))
        for (index, card) in row.enumerated() where index != 6 {
            let inner = row[index < 6 ? index + 1 : index - 1]
            #expect(
                card.depthOrder < inner.depthOrder,
                Comment(rawValue: "card \(index) at \(card.depthOrder) is not under its inner neighbour at \(inner.depthOrder)")
            )
            if index > 6 {
                #expect(card.rotationYDegrees < 0, Comment(rawValue: "right card \(index) turns \(card.rotationYDegrees)"))
            } else {
                #expect(card.rotationYDegrees > 0, Comment(rawValue: "left card \(index) turns \(card.rotationYDegrees)"))
            }
        }
        #expect(near(row[7].rotationYDegrees, -28, 0.001) && near(row[5].rotationYDegrees, 28, 0.001))
        // Each side pivots on its outer edge, which stays on the frame; past the first neighbour every
        // card shows a 56pt strip beyond the one inside it.
        let hits = row.map { StageGeometry.hitRect($0, style: .facingIn) }
        #expect(near(hits[8].maxX, row[8].frame.maxX, 0.01) && near(hits[4].minX, row[4].frame.minX, 0.01))
        #expect(
            near(hits[8].maxX - hits[7].maxX, 56, 0.01) && near(hits[5].minX - hits[4].minX, 56, 0.01),
            Comment(rawValue: "\(hits[4]) \(hits[5]) \(hits[7]) \(hits[8])")
        )
    }

    @Test("Facing In sweeps across the centre line without a jump, pivot switch included")
    func facingInSweepsWithoutJumps() {
        let size = Self.designWindow
        func row(_ focus: Double) -> [StageGeometry.CardPlacement] {
            (0 ..< 8).map {
                StageGeometry.cardPlacement(style: .facingIn, index: $0, count: 8, progress: 1, focus: focus, windowSize: size)
            }
        }
        var worst = (x: CGFloat(0), turn: CGFloat(0), hit: CGFloat(0))
        var previous = row(0)
        for step in 1 ... 300 {
            let current = row(Double(step) / 100)
            for (before, after) in zip(previous, current) {
                let a = StageGeometry.hitRect(before, style: .facingIn)
                let b = StageGeometry.hitRect(after, style: .facingIn)
                worst.x = max(worst.x, abs(after.frame.minX - before.frame.minX))
                worst.turn = max(worst.turn, abs(after.rotationYDegrees - before.rotationYDegrees))
                worst.hit = max(worst.hit, abs(b.minX - a.minX), abs(b.maxX - a.maxX), abs(b.height - a.height))
            }
            previous = current
        }
        print("FACINGIN sweep worst step: minX \(worst.x) turn \(worst.turn) hitRect \(worst.hit)")
        // At the centre the curves are at their steepest: 156pt and 56° per slot, 0.01 of a slot a step.
        #expect(worst.x <= 1.6, Comment(rawValue: "a card moved \(worst.x)pt in one 0.01 step"))
        #expect(worst.turn <= 0.6, Comment(rawValue: "a card turned \(worst.turn)° in one 0.01 step"))
        #expect(worst.hit <= 2.5, Comment(rawValue: "a hit rect edge moved \(worst.hit)pt in one 0.01 step"))
        // The bounds only mean something if the sweep carried cards across the centre and flipped their pivot.
        let start = row(0)[2]
        let end = row(3)[2]
        #expect(start.rotationYDegrees < 0 && start.anchorX == 1, Comment(rawValue: "card 2 at focus 0: \(start)"))
        #expect(end.rotationYDegrees > 0 && end.anchorX == 0, Comment(rawValue: "card 2 at focus 3: \(end)"))
    }

    @Test("Facing In builds every card that still shows, and no more than (capacity − 1) / 2 a side", arguments: [6, 20])
    func facingInSliceCoversWhatShows(capacity: Int) {
        let side = (capacity - 1) / 2
        for width in [CGFloat(1040), 1280, 1920] {
            let size = CGSize(width: width, height: 820)
            for step in 0 ... 200 {
                let focus = Double(step) / 10
                let slice = StageGeometry.visibleCards(
                    style: .facingIn, count: 40, rowOffset: 0, focus: focus, windowSize: size, capacity: capacity
                )
                let centre = Int(focus.rounded())
                #expect(
                    slice.contains(centre) && centre - slice.lowerBound <= side && slice.upperBound - 1 - centre <= side,
                    Comment(rawValue: "\(width)pt, focus \(focus): \(slice)")
                )
                for index in 0 ..< 40 where !slice.contains(index) {
                    let alpha = StageGeometry.cardPlacement(
                        style: .facingIn, index: index, count: 40, progress: 1, focus: focus,
                        windowSize: size, capacity: capacity
                    ).opacity
                    #expect(alpha == 0, Comment(rawValue: "\(width)pt, focus \(focus): card \(index) shows at \(alpha) outside \(slice)"))
                }
            }
        }
    }
}
