import AppKit
@testable import LiveWallpaper
import Testing

@Suite("Stage touch reveal rules")
struct StageTouchRevealTests {
    @Test("A click is the touch's own only within 8 pt and half a second after the finger landed")
    func simulatedClickMatch() {
        let touch = StageTouch(point: CGPoint(x: 100, y: 100), time: 10)
        #expect(!StageTouchReveal.isSimulatedClick(at: touch.point, time: 10, touch: nil), "a mouse click has no touch to match")
        #expect(StageTouchReveal.isSimulatedClick(at: touch.point, time: 10.2, touch: touch))
        #expect(StageTouchReveal.isSimulatedClick(at: CGPoint(x: 108, y: 100), time: 10.5, touch: touch))
        #expect(!StageTouchReveal.isSimulatedClick(at: CGPoint(x: 106.1, y: 106.1), time: 10.1, touch: touch))
        #expect(!StageTouchReveal.isSimulatedClick(at: touch.point, time: 10.6, touch: touch))
        #expect(!StageTouchReveal.isSimulatedClick(at: touch.point, time: 9.9, touch: touch), "a click before the touch is not its click")
    }

    @Test("A tap reveals only hidden controls a display offers")
    func revealNeedsHiddenControls() {
        var reveal = StageTouchReveal()
        let nothingToShow = reveal.reveal(1, offersControls: false, controlsShowing: false)
        #expect(!nothingToShow)
        #expect(reveal.display == nil)
        let alreadyShowing = reveal.reveal(1, offersControls: true, controlsShowing: true)
        #expect(!alreadyShowing, "showing controls let the tap open the display")
        #expect(reveal.display == nil)
        let hidden = reveal.reveal(1, offersControls: true, controlsShowing: false)
        #expect(hidden)
        #expect(reveal.display == 1)
    }

    @Test("A touch on the revealed display keeps it; a touch elsewhere, hover or its own timer hides it")
    func revealEnds() {
        var reveal = StageTouchReveal()
        _ = reveal.reveal(1, offersControls: true, controlsShowing: false)
        reveal.touchLanded(on: 1)
        #expect(reveal.display == 1)
        reveal.touchLanded(on: 2)
        #expect(reveal.display == nil)

        _ = reveal.reveal(1, offersControls: true, controlsShowing: false)
        reveal.touchLanded(on: nil)
        #expect(reveal.display == nil)

        _ = reveal.reveal(1, offersControls: true, controlsShowing: false)
        reveal.hoverBegan()
        #expect(reveal.display == nil)

        _ = reveal.reveal(1, offersControls: true, controlsShowing: false)
        let first = reveal.generation
        _ = reveal.reveal(2, offersControls: true, controlsShowing: false)
        reveal.expire(generation: first)
        #expect(reveal.display == 2, "an earlier reveal's timer must not hide a later one")
        reveal.expire(generation: reveal.generation)
        #expect(reveal.display == nil)
    }
}

@MainActor
@Suite("Edit Desk stage touch")
struct EditDeskStageTouchTests {
    private func makeView() -> (EditDeskStageModel, EditDeskStageView) {
        let model = EditDeskStageModel()
        model.reduceMotion = true
        model.displays = [
            StageDisplay(
                id: 1, fingerprint: "external", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                isBuiltin: false, name: "External", badgeText: "External", statusText: "Active", cover: nil, state: .ok,
                hasConfiguration: true
            ),
            StageDisplay(
                id: 2, fingerprint: "builtin", frame: CGRect(x: 96, y: -1117, width: 1728, height: 1117),
                isBuiltin: true, name: "Builtin", badgeText: "Builtin", statusText: "Paused", cover: nil, state: .empty
            ),
        ]
        model.shelfItems = (0 ..< 14).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "Meta", thumbnail: nil, nowPlaying: nil, isDraggable: true)
        }
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        return (model, view)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: EditDeskStageView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func screenCentre(_ id: StageDisplay.ID, in view: EditDeskStageView) throws -> CGPoint {
        let shell = try #require(view.displayLayers[id])
        let layer = try #require(view.layer)
        return shell.content.convert(CGPoint(x: shell.content.bounds.midX, y: shell.content.bounds.midY), to: layer)
    }

    /// A finger's tap as AppKit delivers it: the observer sees the touch land, then a simulated click follows.
    private func fingerTap(_ point: CGPoint, landing: CGPoint? = nil, in view: EditDeskStageView) throws {
        view.touchLanded(atWindowLocation: view.convert(landing ?? point, to: nil))
        try click(point, in: view)
    }

    private func click(_ point: CGPoint, in view: EditDeskStageView) throws {
        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        try view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))
    }

    /// Reads the buffered events up to a marker, so an event that never comes cannot hang the test.
    private func drain(_ model: EditDeskStageModel) async -> [StageEvent] {
        model.emit(.cardTapped("end"))
        var events = model.events.makeAsyncIterator()
        var seen: [StageEvent] = []
        while let event = await events.next(), event != .cardTapped("end") {
            seen.append(event)
        }
        return seen
    }

    private func cardPoint(_ index: Int, in view: EditDeskStageView, model: EditDeskStageModel) -> CGPoint {
        let hit = StageGeometry.hitRect(
            StageGeometry.cardPlacement(
                style: model.shelfStyle, index: index, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
            ),
            style: model.shelfStyle
        )
        return CGPoint(x: hit.minX + 8, y: hit.midY)
    }

    @Test("A finger's tap on a display shows its playback controls, and a second tap opens it", .timeLimit(.minutes(1)))
    func tapRevealsThenOpens() async throws {
        let (model, view) = makeView()
        defer { view.detach() }
        let centre = try screenCentre(1, in: view)
        try #require(model.hoveredPlayback == nil)

        try fingerTap(centre, in: view)
        #expect(model.hoveredPlayback?.displayID == 1, "a tap must stand in for the hover touch never produces")
        try fingerTap(centre, in: view)
        #expect(await drain(model) == [.displayTapped(1)])
    }

    @Test("A mouse click, a click away from the touch, and a tap on a display without controls still open it", .timeLimit(.minutes(1)))
    func clicksThatDoNotReveal() async throws {
        let (model, view) = makeView()
        defer { view.detach() }
        let wallpapered = try screenCentre(1, in: view)
        let empty = try screenCentre(2, in: view)

        try click(wallpapered, in: view)
        try fingerTap(wallpapered, landing: CGPoint(x: wallpapered.x + 20, y: wallpapered.y), in: view)
        try fingerTap(empty, in: view)
        #expect(model.hoveredPlayback == nil)
        #expect(await drain(model) == [.displayTapped(1), .displayTapped(1), .displayTapped(2)])
    }

    @Test("Revealed controls stay for a touch on their display and hide for a touch elsewhere or a moving pointer")
    func revealHides() throws {
        let (model, view) = makeView()
        defer { view.detach() }
        let centre = try screenCentre(1, in: view)
        let blank = CGPoint(x: 8, y: view.bounds.maxY - 8)
        try #require(!view.ownsPoint(blank, clicking: true), "control: the blank point is on a display")

        try fingerTap(centre, in: view)
        try #require(model.hoveredPlayback?.displayID == 1)
        view.touchLanded(atWindowLocation: view.convert(CGPoint(x: centre.x + 30, y: centre.y), to: nil))
        #expect(model.hoveredPlayback?.displayID == 1)
        view.touchLanded(atWindowLocation: view.convert(blank, to: nil))
        #expect(model.hoveredPlayback == nil)

        try fingerTap(centre, in: view)
        try #require(model.hoveredPlayback?.displayID == 1)
        try view.mouseMoved(with: mouse(.mouseMoved, at: blank, in: view))
        #expect(model.hoveredPlayback == nil, "real hover takes the controls back")
    }

    @Test("A finger pressed on a shelf card and moved onto a display drops the card there, as the mouse does", .timeLimit(.minutes(1)))
    func fingerDragDropsCard() async throws {
        let (model, view) = makeView()
        defer { view.detach() }
        model.setProgress(1, animated: false)
        let point = cardPoint(5, in: view, model: model)
        try #require(view.cardIndex(at: point) == 5)
        let target = try screenCentre(1, in: view)

        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: target, in: view))
        try view.mouseUp(with: mouse(.leftMouseUp, at: target, in: view))
        try #require(await drain(model) == [.snapped(1), .dropped(card: "card-5", onto: 1)], "control: the mouse drop")

        view.touchPress(.began, at: point)
        view.touchPress(.changed, at: CGPoint(x: point.x + StageGeometry.dragThreshold / 2, y: point.y))
        #expect(!view.debugDragging, "a finger still within the drag threshold carries nothing")
        view.touchPress(.changed, at: target)
        #expect(view.debugDragging)
        #expect(model.dropTarget == 1)
        view.touchPress(.ended, at: target)
        #expect(!view.debugDragging)
        #expect(model.dropTarget == nil)
        #expect(await drain(model) == [.dropped(card: "card-5", onto: 1)])
    }

    @Test("A still finger press neither opens nor carries the card, and a cancelled one puts it back", .timeLimit(.minutes(1)))
    func stillAndCancelledPress() async throws {
        let (model, view) = makeView()
        defer { view.detach() }
        model.setProgress(1, animated: false)
        let point = cardPoint(5, in: view, model: model)
        let target = try screenCentre(1, in: view)

        view.touchPress(.began, at: point)
        view.touchPress(.ended, at: point)
        #expect(!view.debugDragging)

        view.touchPress(.began, at: point)
        view.touchPress(.changed, at: target)
        try #require(view.debugDragging)
        view.touchPress(.cancelled, at: target)
        #expect(!view.debugDragging)
        #expect(model.dropTarget == nil)
        #expect(await drain(model) == [.snapped(1), .dropCancelled(card: "card-5")])
    }

    @Test("The stage's press recognizer turns every mouse event away, so mouse drags never meet it")
    func pressRecognizerIsTouchOnly() throws {
        guard #available(macOS 27, *) else { return }
        let (_, view) = makeView()
        defer { view.detach() }
        let press = try #require(view.gestureRecognizers.first { $0 is NSPressGestureRecognizer })
        let delegate = try #require(press.delegate)
        let down = try mouse(.leftMouseDown, at: .zero, in: view)
        #expect(delegate.gestureRecognizer?(press, shouldAttemptToRecognizeWith: down) == false)
    }
}
