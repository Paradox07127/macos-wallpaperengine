import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Edit Desk stage layers")
struct EditDeskStageViewTests {
    private func makeModel() -> EditDeskStageModel {
        let model = EditDeskStageModel()
        model.reduceMotion = true
        model.displays = [
            StageDisplay(
                id: 1, fingerprint: "external", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                isBuiltin: false, name: "External", badgeText: "External", statusText: "Active", cover: nil, state: .ok
            ),
            StageDisplay(
                id: 2, fingerprint: "builtin", frame: CGRect(x: 96, y: -1117, width: 1728, height: 1117),
                isBuiltin: true, name: "Builtin", badgeText: "Builtin", statusText: "Paused", cover: nil, state: .empty
            ),
        ]
        model.shelfItems = (0 ..< 14).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "Meta", thumbnail: nil, onBadge: nil, isDraggable: true)
        }
        return model
    }

    /// Resolves the stage canvas under one appearance; -1 when the colour will not convert.
    private static func tone(_ name: NSAppearance.Name) -> CGFloat {
        var value: CGFloat = -1
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            value = NSColor(DesignTokens.EditDesk.Colors.background).usingColorSpace(.sRGB)?.redComponent ?? -1
        }
        return value
    }

    private func sameRect(_ actual: CGRect, _ expected: CGRect) -> Bool {
        // CALayer reconstructs frame from bounds and position, introducing sub-ULP origin differences.
        abs(actual.minX - expected.minX) < 0.00000001
            && abs(actual.minY - expected.minY) < 0.00000001
            && abs(actual.width - expected.width) < 0.00000001
            && abs(actual.height - expected.height) < 0.00000001
    }

    @Test("Rest states agree with geometry and expose all accessibility children")
    func geometry() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        for progress in [0.0, 1.0, 2.0] {
            model.setProgress(progress, animated: false)
            for (index, card) in model.shelfItems.enumerated() {
                let layer = try #require(view.cardLayers[card.id])
                #expect(sameRect(layer.frame, StageGeometry.cardPlacement(
                    style: model.shelfStyle, index: index, count: 14, progress: progress,
                    focus: 0, windowSize: view.bounds.size
                ).frame))
            }
        }
        let arrangement = StageGeometry.arrangement(
            frames: model.displays.map(\.frame), in: StageGeometry.stageRect(windowSize: view.bounds.size)
        )
        for (index, display) in model.displays.enumerated() {
            let shell = try #require(view.displayLayers[display.id])
            #expect(sameRect(shell.frame, StageGeometry.shellRect(
                content: arrangement.contentRects[index], isBuiltin: display.isBuiltin
            )))
        }
        #expect(view.accessibilityChildren()?.count == 16)
    }

    @Test("Hover hit-testing reads rest slots, so a lifted card cannot hand the pointer to its neighbour")
    func hoverHitTestIgnoresLift() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let rest = StageGeometry.cardPlacement(
            style: model.shelfStyle, index: 5, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
        )
        let hit = StageGeometry.hitRect(
            rest, style: model.shelfStyle
        )
        let tile = try #require(view.cardLayers["card-5"])
        tile.lift.jump(to: -StageGeometry.waveAmplitude)
        view.advance(dt: 1.0 / 60)
        // The card to the right lies on top, so card 5's own sliver is its left edge.
        #expect(view.cardIndex(at: CGPoint(x: hit.minX + 8, y: hit.midY)) == 5)
        #expect(tile.frame.minY < rest.frame.minY, "the lift must still move the card on screen")
    }

    @Test("A stationary pointer keeps one card hovered while the wave is still animating")
    func hoverDoesNotChatter() {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let rest = StageGeometry.hitRect(
            StageGeometry.cardPlacement(
                style: model.shelfStyle, index: 5, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
            ),
            style: model.shelfStyle
        )
        // Closing the loop the pointer does: read the hovered card, feed it back, advance a frame.
        let point = CGPoint(x: rest.minX + 8, y: rest.midY)
        var visited = Set<Int>()
        for _ in 0 ..< 120 {
            guard let index = view.cardIndex(at: point) else { continue }
            visited.insert(index)
            model.report(hoveredCard: model.shelfItems[index].id)
            view.advance(dt: 1.0 / 60)
        }
        #expect(visited == [5], Comment(rawValue: "a still pointer hovered \(visited.sorted())"))
    }

    @Test("Cover Flow cards faded out past the end of the run cannot be grabbed")
    func fadedCoverFlowCardsAreNotGrabbable() {
        let model = makeModel()
        model.shelfStyle = .coverFlow
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let far = StageGeometry.cardPlacement(
            style: .coverFlow, index: 11, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
        )
        #expect(far.opacity == 0, Comment(rawValue: "slot 11 should already be invisible: \(far.opacity)"))
        #expect(view.cardIndex(at: CGPoint(x: far.frame.midX, y: far.frame.midY)) == nil)
    }

    @Test("A library bigger than the shelf only builds layers for the slice on screen")
    func shelfWindowsTheLibrary() {
        let model = makeModel()
        model.shelfItems = (0 ..< 120).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "Meta", thumbnail: nil, onBadge: nil, isDraggable: true)
        }
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        #expect(view.cardLayers.count < 120, Comment(rawValue: "built \(view.cardLayers.count) layers"))
        #expect(view.cardLayers.count > 10, Comment(rawValue: "built \(view.cardLayers.count) layers"))
        #expect(model.visibleShelfRange.lowerBound == 0 && model.visibleShelfRange.count == view.cardLayers.count)
        // The row is as long as the library, so there is somewhere to scroll to.
        let last = StageGeometry.rowFrame(
            style: model.shelfStyle, index: 119, count: 120, focus: 0, windowSize: view.bounds.size
        )
        #expect(last.minX > StageGeometry.designWindow.width, Comment(rawValue: "\(last)"))
    }

    @Test("Flipping the appearance re-resolves the CALayer palette but not the on-media colours")
    func paletteFollowsAppearance() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        // The canvas is a SwiftUI layer now; what the stage still resolves by hand is its own tree.
        let dark = try #require(view.displayLayers.values.first?.normalStroke)
        view.appearance = NSAppearance(named: .aqua)
        let light = try #require(view.displayLayers.values.first?.normalStroke)
        #expect(dark != light, "the stage's own layers have to follow General → Appearance")
        #expect(Self.tone(.aqua) > Self.tone(.darkAqua), Comment(rawValue: "\(Self.tone(.aqua)) vs \(Self.tone(.darkAqua))"))
        // Anything drawn over a wallpaper thumbnail is fixed: the thumbnail does not get lighter.
        #expect(StageLayerStyle.white == NSColor.white.cgColor)
    }

    @Test("Swapping the library for a different set of the same size keeps the shelf drawn")
    func sameCountFilterKeepsLayers() {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let before = view.cardLayers.count
        #expect(before > 0)
        // A filter change that happens to keep the count: the window range is identical, so a
        // range-only reconcile would drop every layer and never rebuild.
        model.shelfItems = (0 ..< 14).map {
            StageCard(id: "other-\($0)", title: "Other \($0)", metaLine: "Meta", thumbnail: nil, onBadge: nil, isDraggable: true)
        }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.cardLayers.count == before, Comment(rawValue: "\(view.cardLayers.count) layers left"))
        #expect(view.cardLayers.keys.allSatisfy { $0.hasPrefix("other-") })
    }

    @Test("A settled hover lets the display link stop instead of spinning forever")
    func hoverSettlesSoTheLinkCanStop() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        shell.setHovered(true)
        for _ in 0 ..< 60 {
            shell.step(dt: 1.0 / 60, reduceMotion: false)
        }
        #expect(!shell.hasAnimation, "a finished hover must not keep the stage animating")
    }

    @Test("A card click emits its event and removed displays release their layers")
    func clickAndDiff() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        model.setProgress(1, animated: false)
        var events = model.events.makeAsyncIterator()
        #expect(await events.next() == .snapped(1))
        let frame = StageGeometry.hitRect(
            StageGeometry.cardPlacement(
                style: model.shelfStyle, index: 3, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
            ),
            style: model.shelfStyle
        )
        view.tap(at: CGPoint(x: frame.minX + 8, y: frame.midY))
        #expect(await events.next() == .cardTapped("card-3"))
        let retained = try #require(view.displayLayers[1])
        model.displays.removeLast()
        await Task.yield()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.displayLayers.count == 1)
        #expect(view.displayLayers[1] === retained)
        #expect(view.displayLayers[2] == nil)
        #expect(view.accessibilityChildren()?.count == 15)
    }

    @Test("Animated progress settles through manual display-link steps without a window")
    func manualAnimation() {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        model.setProgress(2, animated: true)
        view.advance(dt: 1 / 120)
        #expect(model.progress > 0 && model.progress < 2)
        for _ in 0 ..< 480 {
            view.advance(dt: 1 / 120)
        }
        #expect(model.progress == 2)
        #expect(model.snappedIndex == 2)
        for (index, card) in model.shelfItems.enumerated() {
            guard let tile = view.cardLayers[card.id] else { continue }
            #expect(sameRect(tile.frame, StageGeometry.gridFrame(index: index, windowWidth: view.bounds.width)))
        }
    }

    @Test("Reduced-motion fly and return finish synchronously and restore content ownership")
    func reducedMotionFlight() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        let original = shell.content.frame
        let destination = CGRect(x: 100, y: 100, width: 800, height: 450)
        await model.flyTile(display: 1, to: destination)
        #expect(sameRect(shell.content.frame, destination))
        await model.returnTile(display: 1)
        #expect(shell.content.superlayer === shell.layer)
        #expect(sameRect(shell.content.frame, original))
    }

    @Test("The hovered card keeps the part of itself that sticks out past its rest slot")
    func hoveredCardOwnsItsLiftedShape() {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let style = model.shelfStyle
        let placement = StageGeometry.cardPlacement(
            style: style, index: 5, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
        )
        let rest = StageGeometry.hitRect(placement, style: style)
        // A point on the strip the lift uncovers above the rest slot: it belongs to no card at rest.
        let above = CGPoint(x: rest.midX, y: rest.minY - 20)
        #expect(view.cardIndex(at: above) == nil)

        model.report(hoveredCard: model.shelfItems[5].id)
        #expect(view.cardIndex(at: above) == 5, "the lifted card must answer for the pixels it now covers")

        // Leaving that region hands the pointer back to whoever owns it at rest, not to the
        // neighbour the hovered card's own shape happens to overlap.
        let far = CGPoint(x: rest.midX, y: rest.minY - 400)
        #expect(view.cardIndex(at: far) == nil)
    }

    @Test("Clicks off the cards fall through to the chrome below; scrolling never does")
    func clicksFallThroughButScrollDoesNot() {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)

        let placement = StageGeometry.cardPlacement(
            style: model.shelfStyle, index: 5, count: 14, progress: 1, focus: 0,
            windowSize: view.bounds.size, capacity: model.shelfRenderBudget
        )
        let onCard = CGPoint(
            x: StageGeometry.hitRect(placement, style: model.shelfStyle).minX + 8, y: placement.frame.midY
        )
        // The chip row's band: above the shelf, clear of every display.
        let onChrome = CGPoint(x: 24, y: StageGeometry.chipRowTop(progress: 1, windowSize: view.bounds.size) + 8)
        #expect(view.cardIndex(at: onCard) == 5)
        #expect(view.cardIndex(at: onChrome) == nil)

        #expect(view.ownsPoint(onCard, clicking: true), "a click on a card belongs to the stage")
        #expect(!view.ownsPoint(onChrome, clicking: true), "a click on nothing has to reach the chip row below")
        // Scroll and hover are routed by the same hit test, and they belong to the stage everywhere.
        #expect(view.ownsPoint(onChrome, clicking: false))
        #expect(view.ownsPoint(onCard, clicking: false))
    }
}
