import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// Every card between the shelf (p = 1) and the library grid (p = 2), frame by frame on a stage with
/// no window: the release carries the swipe's speed, cards ease onto their tiles, the grid takes over
/// as the last one arrives, cards the shelf never showed do not sweep across the window, the 3D pose is
/// gone before the last stretch, and a swipe does not jump where its axis locks.
@MainActor
@Suite("Shelf to grid flight, frame by frame")
struct ShelfGridFlightTests {
    static let sizes = [CGSize(width: 1040, height: 700), CGSize(width: 1280, height: 820), CGSize(width: 1728, height: 1080)]
    static let styles: [ShelfStyle] = [.facingIn, .crate]
    private static let frameTime = 1.0 / 60

    private struct CardState {
        /// What is drawn: the card's corners through its own transform.
        var visual: CGRect
        var opacity: Float
    }

    private struct Frame {
        var progress: Double
        var snapped: Int
        var cards: [Int: CardState]
    }

    enum Launch: String {
        /// Tracked with the fingers to about 1.4, then released at the tracked speed.
        case flick
        /// The nav pill or the keyboard: from rest on the shelf, no speed.
        case pill
    }

    private struct Run {
        var frames: [Frame]
        /// The last frame before the release; 0 for the pill.
        var release: Int
        var gridWindow: Range<Int>
        var tiles: [Int: CGRect]
        var size: CGSize
        var label: String

        /// Cards the resting shelf showed (α > 0.2) and cards it never drew (α ≤ 0.05).
        var shown: Set<Int> {
            Set(frames[0].cards.filter { $0.value.opacity > 0.2 }.map(\.key))
        }

        var neverShown: [Int] {
            gridWindow.filter { (frames[0].cards[$0]?.opacity ?? 0) <= 0.05 }
        }
    }

    private func edgeOffset(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    }

    private func centreStep(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private func scroll(x: Int32 = 0, y: Int32 = 0, phase: CGScrollPhase?) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        return try #require(NSEvent(cgEvent: event))
    }

    private func makeStage(size: CGSize, style: ShelfStyle, count: Int) -> (EditDeskStageView, EditDeskStageModel) {
        let model = EditDeskStageModel()
        model.reduceMotion = false
        model.shelfStyle = style
        model.displays = [
            StageDisplay(
                id: 1, fingerprint: "external", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                isBuiltin: false, name: "External", badgeText: "External", statusText: "Active", cover: nil, state: .ok
            ),
        ]
        model.shelfItems = (0 ..< count).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "", thumbnail: nil, nowPlaying: nil, isDraggable: true)
        }
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        return (view, model)
    }

    private func snapshot(_ view: EditDeskStageView, _ model: EditDeskStageModel) -> Frame {
        var cards: [Int: CardState] = [:]
        for (index, card) in model.shelfItems.enumerated() {
            guard let tile = view.cardLayers[card.id], !tile.layer.isHidden else { continue }
            cards[index] = CardState(visual: tile.hitRect, opacity: tile.layer.opacity)
        }
        return Frame(progress: model.progress, snapped: model.snappedIndex, cards: cards)
    }

    /// One expansion, recorded from the resting shelf to well after the grid has taken over.
    private func expand(
        size: CGSize, style: ShelfStyle, launch: Launch, count: Int = 60, scrolledCards: Int = 0
    ) throws -> Run {
        let (view, model) = makeStage(size: size, style: style, count: count)
        defer { view.detach() }
        if scrolledCards > 0 {
            let pitch = StageGeometry.metrics(for: style).pitch
            try view.scrollWheel(with: scroll(x: Int32(-(CGFloat(scrolledCards) * pitch).rounded()), phase: nil))
            view.advance(dt: Self.frameTime)
        }
        var frames = [snapshot(view, model)]
        var velocity = 0.0
        if launch == .flick {
            try view.scrollWheel(with: scroll(phase: .began))
            while model.progress < 1.4 {
                try view.scrollWheel(with: scroll(y: -15, phase: .changed))
                view.advance(dt: Self.frameTime)
                frames.append(snapshot(view, model))
            }
            velocity = (frames[frames.count - 1].progress - frames[frames.count - 2].progress) / Self.frameTime
        }
        let release = frames.count - 1
        view.setProgress(2, animated: true, velocity: velocity)
        for _ in 0 ..< 150 {
            view.advance(dt: Self.frameTime)
            frames.append(snapshot(view, model))
        }
        let gridWindow = model.visibleGridRange
        var tiles: [Int: CGRect] = [:]
        for index in gridWindow {
            tiles[index] = StageGeometry.gridFrame(index: index, windowWidth: size.width, size: model.gridTileSize)
        }
        let label = "\(Int(size.width))×\(Int(size.height)) \(style) \(launch)\(scrolledCards > 0 ? " scrolled \(scrolledCards)" : "")"
        return Run(frames: frames, release: release, gridWindow: gridWindow, tiles: tiles, size: size, label: label)
    }

    private var launches: [(CGSize, ShelfStyle, Launch)] {
        Self.sizes.flatMap { size in Self.styles.flatMap { style in [(size, style, Launch.flick), (size, style, .pill)] } }
    }

    // MARK: - The release

    /// The cards were moving with the fingers; the frame after the fingers leave must not stop them.
    @Test("Releasing a swipe keeps every card moving at least as fast as the fingers moved it")
    func releaseKeepsTheSpeed() throws {
        for size in Self.sizes {
            for style in Self.styles {
                let run = try expand(size: size, style: style, launch: .flick)
                let tracked = run.frames[run.release - 1]
                let released = run.frames[run.release]
                let after = run.frames[run.release + 1]
                var slowest: (ratio: CGFloat, index: Int, last: CGFloat, first: CGFloat)?
                for (index, card) in released.cards where card.opacity > 0.2 {
                    guard let before = tracked.cards[index]?.visual, let next = after.cards[index]?.visual else { continue }
                    let last = centreStep(before, card.visual)
                    guard last > 0.5 else { continue }
                    let first = centreStep(card.visual, next)
                    if first / last < (slowest?.ratio ?? .infinity) {
                        slowest = (first / last, index, last, first)
                    }
                }
                let worst = try #require(slowest, Comment(rawValue: "\(run.label): no card was moving at the release"))
                #expect(
                    worst.ratio >= 0.9,
                    Comment(rawValue: "\(run.label): card \(worst.index) moved \(String(format: "%.2f", worst.last))pt in the last tracked frame and \(String(format: "%.2f", worst.first))pt in the first after the release")
                )
            }
        }
    }

    // MARK: - The arrival

    /// A card eases onto its tile: the frame it gets within half a point moves it no more than that,
    /// and nothing carries it away again.
    @Test("Every card eases onto its tile instead of stopping dead on it")
    func cardsEaseOntoTheirTiles() throws {
        for (size, style, launch) in launches {
            let run = try expand(size: size, style: style, launch: launch)
            var hardest: (step: CGFloat, index: Int)?
            var strayed: [Int] = []
            for index in run.gridWindow {
                guard let tile = run.tiles[index] else { continue }
                let track = run.frames.indices.compactMap { frame in run.frames[frame].cards[index].map { (frame, $0.visual) } }
                guard let arrival = track.firstIndex(where: { edgeOffset($0.1, tile) <= 0.5 }), arrival > 0 else { continue }
                let step = centreStep(track[arrival - 1].1, track[arrival].1)
                if step > (hardest?.step ?? -1) {
                    hardest = (step, index)
                }
                if track[arrival...].contains(where: { edgeOffset($0.1, tile) > 0.5 }) {
                    strayed.append(index)
                }
            }
            if let hardest {
                #expect(
                    hardest.step <= 0.5,
                    Comment(rawValue: "\(run.label): card \(hardest.index) moved \(String(format: "%.2f", hardest.step))pt on the frame it reached its tile")
                )
            }
            #expect(strayed.isEmpty, Comment(rawValue: "\(run.label): cards \(strayed) left their tile after reaching it"))
        }
    }

    /// Nothing waits for the springs' last creep: the grid takes over the frame the last card arrives.
    @Test("The grid takes over as the last card arrives, not after the cards have sat still")
    func gridTakesOverOnArrival() throws {
        for (size, style, launch) in launches {
            let run = try expand(size: size, style: style, launch: launch)
            let snap = try #require(
                run.frames.indices.first { $0 > run.release && run.frames[$0].snapped == 2 },
                Comment(rawValue: "\(run.label): never handed over")
            )
            let lastMove = (run.release + 1 ... snap).last { frame in
                run.frames[frame].cards.contains { index, now in
                    guard let then = run.frames[frame - 1].cards[index], now.opacity > 0.05 else { return false }
                    return edgeOffset(then.visual, now.visual) > 0.1
                }
            } ?? run.release
            #expect(
                snap - lastMove <= 1,
                Comment(rawValue: "\(run.label): the cards sat still \(snap - lastMove) frames before the grid took over")
            )
        }
    }

    // MARK: - Cards the shelf never showed

    /// A card the resting shelf did not draw has no place on it to fly from: it appears where its tile is,
    /// so nothing sweeps in from beyond the window. A shelf scrolled far in opens the library at its top,
    /// and the cards it showed leave the window downwards, fading.
    @Test("Cards the shelf never showed appear on their tiles instead of sweeping in")
    func unseenCardsDoNotSweep() throws {
        var runs = try launches.map { try expand(size: $0.0, style: $0.1, launch: $0.2) }
        for style in Self.styles {
            try runs.append(expand(size: CGSize(width: 1280, height: 820), style: style, launch: .pill, count: 200, scrolledCards: 100))
        }
        for run in runs {
            var fastest: (step: CGFloat, index: Int, frame: Int)?
            for index in run.neverShown {
                for frame in 1 ..< run.frames.count {
                    guard let now = run.frames[frame].cards[index], let then = run.frames[frame - 1].cards[index],
                          max(now.opacity, then.opacity) > 0.05 else { continue }
                    let step = centreStep(then.visual, now.visual)
                    if step > (fastest?.step ?? -1) {
                        fastest = (step, index, frame)
                    }
                }
            }
            if let fastest {
                #expect(
                    fastest.step <= 2,
                    Comment(rawValue: "\(run.label): card \(fastest.index), never on the shelf, moved \(String(format: "%.1f", fastest.step))pt in frame \(fastest.frame)")
                )
            }
            let end = run.frames[run.frames.count - 1]
            let lingering = run.shown.filter { index in
                guard let card = end.cards[index], card.visual.minY >= run.size.height else { return false }
                return card.opacity > 0
            }
            #expect(lingering.isEmpty, Comment(rawValue: "\(run.label): shelf cards \(lingering.sorted()) sit below the window still visible"))
        }
    }

    // MARK: - The pose

    /// By 70% of the way the card is a flat grid tile: no lean, no turn, no depth, no dimming, the grid's corners.
    @Test("A card is flat, square to the viewer and grid-cornered by 70% of the flight", arguments: ShelfStyle.allCases)
    func flatByTheLastStretch(style: ShelfStyle) {
        let size = CGSize(width: 1280, height: 820)
        // A card beside the middle: it leans, turns or dims on every shelf style.
        for index in [2, 5] {
            let placement = StageGeometry.cardPlacement(
                style: style, index: index, count: 20, progress: 1.7, focus: 0, windowSize: size
            )
            #expect(placement.rotationYDegrees == 0, Comment(rawValue: "\(style) card \(index) still leans \(placement.rotationYDegrees)° at 70%"))
            #expect(placement.rotationZDegrees == 0, Comment(rawValue: "\(style) card \(index) still turns \(placement.rotationZDegrees)° at 70%"))
            #expect(placement.translateZ == 0, Comment(rawValue: "\(style) card \(index) still sits \(placement.translateZ)pt deep at 70%"))
            #expect(placement.dim == 0, Comment(rawValue: "\(style) card \(index) is still dimmed \(placement.dim) at 70%"))
            #expect(placement.scale == 1, Comment(rawValue: "\(style) card \(index) is still scaled \(placement.scale) at 70%"))
            let tile = ShelfCardLayer()
            tile.place(placement, style: style, gridMix: 0.7, dragged: false, reduceMotion: false)
            #expect(tile.thumbnail.cornerRadius == DesignTokens.Corner.lg, Comment(rawValue: "\(style) card \(index) has a \(tile.thumbnail.cornerRadius)pt corner at 70%"))
        }
    }

    // MARK: - The start of a swipe

    /// The deadband keeps the first few points of a swipe from choosing an axis; the frame the axis locks
    /// must not dump all of them at once.
    @Test("A slow swipe does not jump on the frame its axis locks")
    func axisLockDoesNotJump() throws {
        let (view, model) = makeStage(size: CGSize(width: 1280, height: 820), style: .facingIn, count: 60)
        defer { view.detach() }
        try view.scrollWheel(with: scroll(phase: .began))
        var steps: [Double] = []
        var cardSteps: [CGFloat] = []
        var last = snapshot(view, model)
        for _ in 0 ..< 24 {
            try view.scrollWheel(with: scroll(y: -4, phase: .changed))
            view.advance(dt: Self.frameTime)
            let now = snapshot(view, model)
            steps.append((now.progress - last.progress) * Double(StageGeometry.scrollPointsPerProgress))
            let moves = now.cards.compactMap { index, card -> CGFloat? in
                guard let then = last.cards[index], max(then.opacity, card.opacity) > 0.05 else { return nil }
                return centreStep(then.visual, card.visual)
            }
            cardSteps.append(moves.max() ?? 0)
            last = now
        }
        let lock = try #require(steps.firstIndex { $0 > 0 }, "the swipe never moved the stage")
        try #require(lock + 1 < steps.count)
        let described = steps.prefix(lock + 4).map { String(format: "%.1f", $0) }.joined(separator: ", ")
        #expect(
            cardSteps[lock] <= cardSteps[lock + 1] * 1.5,
            Comment(rawValue: "a card jumped \(String(format: "%.1f", cardSteps[lock]))pt on the lock frame against \(String(format: "%.1f", cardSteps[lock + 1]))pt the frame after; finger points per frame: \(described)")
        )
        // Eased in, not dropped: the stage has taken the whole 96pt of the swipe by the end.
        let travelled = (model.progress - 1) * Double(StageGeometry.scrollPointsPerProgress)
        #expect(abs(travelled - 96) <= 0.5, Comment(rawValue: "the stage took \(travelled)pt of a 96pt swipe"))
    }
}
