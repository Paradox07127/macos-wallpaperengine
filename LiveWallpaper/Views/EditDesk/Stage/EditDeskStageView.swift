import AppKit
import LiveWallpaperCore
import Observation
import QuartzCore
import SwiftUI

@MainActor
final class EditDeskStageView: NSView, EditDeskStageEngine {
    let model: EditDeskStageModel
    private(set) var displayLayers: [StageDisplay.ID: DisplayShellLayer] = [:]
    private(set) var cardLayers: [StageCard.ID: ShelfCardLayer] = [:]
    private let arrangementLayer = CALayer()
    private let shelfLayer = CALayer()
    private let flightLayer = CALayer()
    private let ghost = DragGhostLayer()
    private var displays: [StageDisplay] = []
    private var cards: [StageCard] = []
    /// Slice of `cards` that currently has layers; the row is as long as the whole library.
    private var cardWindow = 0 ..< 0
    private var reserve: [ShelfCardLayer] = []
    private static let reserveLimit = 8
    private var shelfStyle = ShelfStyle.crate
    private var paintsCanvas = true
    private var dropHint = ""
    private var progress = StageSpring(value: 0, target: 0, parameters: StageSpring.snap)
    private var row = StageSpring(value: 0, target: 0, parameters: StageSpring.row)
    private let gesture = ShelfGestureController(clock: CACurrentMediaTime)
    private var attached = true
    private var screenObserver: (any NSObjectProtocol)?
    private var snapInFlight = false
    private var staggerToGrid = false
    private var snapTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var linkTarget: DisplayLinkTarget?
    private var lastTimestamp: TimeInterval?
    private var tracking: NSTrackingArea?
    private var pressedCard: StageCard.ID?
    private var dragging = false
    private var accessibilityItems: [StageAccessibilityElement] = []
    /// `arrangement` allocates while it works out the gaps; it only changes with the displays or
    /// the window, never per frame.
    private var arrangementCache: (size: CGSize, value: StageGeometry.Arrangement)?
    private var flights: [StageDisplay.ID: TileFlight] = [:]

    @MainActor
    private struct TileFlight {
        var home: CGRect
        var destination: CGRect
        var spring = StageSpring(value: 0, target: 1, parameters: StageSpring.fly)
        var continuation: CheckedContinuation<Void, Never>?
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    init(model: EditDeskStageModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true
        for child in [arrangementLayer, shelfLayer, flightLayer, ghost.layer] {
            layer?.addSublayer(child)
        }
        applyPalette()
        arrangementLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        progress.jump(to: model.progress)
        model.engine = self
        setAccessibilityElement(false)
        observeInputs()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: Appearance

    /// CALayer keeps resolved CGColors, so every dynamic colour has to be re-read by hand when the
    /// window's appearance flips between light and dark.
    private func applyPalette() {
        ghost.refreshPalette()
        for display in displays {
            displayLayers[display.id]?.update(display: display, dropHint: dropHint)
        }
        for card in cards {
            cardLayers[card.id]?.update(card: card)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            withoutActions {
                applyPalette()
                render()
            }
        }
    }

    // MARK: Model and layout

    private func observeInputs() {
        guard attached else { return }
        withObservationTracking {
            _ = model.displays
            _ = model.shelfItems
            _ = model.shelfStyle
            _ = model.reduceMotion
            _ = model.interactionBlocked
            _ = model.dropHintText
            _ = model.shelfRenderBudget
            _ = model.opaqueBackground
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeInputs()
            }
        }
        withoutActions {
            synchronizeInputs()
            render()
        }
        startDisplayLinkIfNeeded()
    }

    private func synchronizeInputs() {
        let nextDisplays = model.displays
        let nextCards = model.shelfItems
        let changed = displays != nextDisplays || cards != nextCards
        if displays.map(\.frame) != nextDisplays.map(\.frame) {
            arrangementCache = nil
        }
        for id in Array(displayLayers.keys) where !nextDisplays.contains(where: { $0.id == id }) {
            flights.removeValue(forKey: id)?.continuation?.resume()
            displayLayers[id]?.content.removeFromSuperlayer()
            displayLayers.removeValue(forKey: id)?.layer.removeFromSuperlayer()
        }
        for display in nextDisplays {
            let shell: DisplayShellLayer
            if let existing = displayLayers[display.id] {
                shell = existing
            } else {
                shell = DisplayShellLayer()
                displayLayers[display.id] = shell
                arrangementLayer.addSublayer(shell.layer)
            }
            if displays.first(where: { $0.id == display.id }) != display || dropHint != model.dropHintText {
                shell.update(display: display, dropHint: model.dropHintText)
            }
        }
        let live = Set(nextCards.map(\.id))
        for id in Array(cardLayers.keys) where !live.contains(id) {
            cardLayers.removeValue(forKey: id)?.layer.removeFromSuperlayer()
        }
        if cards.count != nextCards.count {
            for spare in reserve {
                spare.layer.removeFromSuperlayer()
            }
            reserve.removeAll()
        }
        for card in nextCards where cardLayers[card.id] != nil {
            if cards.first(where: { $0.id == card.id }) != card {
                cardLayers[card.id]?.update(card: card)
            }
        }
        if cards.map(\.id) != nextCards.map(\.id) {
            // Identity, not count: swapping ten cards for ten others left the window equal, so the
            // reconcile bailed out after the old layers were already gone and the shelf went blank.
            cardWindow = 0 ..< 0
        }
        displays = nextDisplays
        cards = nextCards
        dropHint = model.dropHintText
        if paintsCanvas != model.opaqueBackground {
            paintsCanvas = model.opaqueBackground
            applyPalette()
        }
        if shelfStyle != model.shelfStyle {
            // The row offset means points in one style and focused slots in another.
            shelfStyle = model.shelfStyle
            gesture.reset()
            row.jump(to: 0)
        }
        if changed {
            rebuildAccessibility()
            // A shrinking library can leave the row scrolled past its new end.
            let count = cards.count
            if count > 0, bounds.width > 0 {
                let limits = rowLimits(count: count, style: model.shelfStyle)
                let clamped = min(max(row.value, limits.lowerBound), limits.upperBound)
                if clamped != row.value {
                    row.jump(to: clamped)
                    gesture.reset()
                }
            }
        }
        if model.interactionBlocked {
            clearHover()
            pressedCard = nil
            gesture.mouseUp()
            snapTask?.cancel()
            if dragging {
                endDrag(cancelled: true)
            }
            // A flick interrupted by a modal must not leave the shelf between rest states.
            if progress.target != progress.target.rounded() || (!snapInFlight && progress.value != progress.value.rounded()) {
                gesture.reset()
                setProgress(Double(StageGeometry.snapTarget(for: progress.value)), animated: !model.reduceMotion)
            }
        }
        if let source = ghost.source, !cards.contains(where: { $0.id == source }) {
            if dragging {
                model.emit(.dropCancelled(card: source))
            }
            dragging = false
            ghost.finish()
            NSCursor.arrow.set()
        }
        if model.reduceMotion {
            progress.jump(to: progress.target)
            row.jump(to: row.target)
            staggerToGrid = false
            for id in flights.keys {
                if let target = flights[id]?.spring.target {
                    flights[id]?.spring.jump(to: target)
                }
            }
            completeFlights()
            for tile in cardLayers.values {
                tile.lift.jump(to: tile.lift.target)
                tile.hover.jump(to: tile.hover.target)
                tile.shakeElapsed = nil
            }
            if snapInFlight {
                finishSnap()
            }
            reportProgress()
        }
    }

    override func layout() {
        super.layout()
        withoutActions {
            synchronizeInputs()
            render()
        }
    }

    private func render() {
        model.report(stageSize: bounds.size)
        arrangementLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        arrangementLayer.position = CGPoint(x: bounds.midX, y: 0)
        shelfLayer.frame = bounds
        flightLayer.frame = bounds
        let p = progress.value
        let arrangement: StageGeometry.Arrangement
        if let cached = arrangementCache, cached.size == bounds.size {
            arrangement = cached.value
        } else {
            arrangement = StageGeometry.arrangement(
                frames: displays.map(\.frame), in: StageGeometry.stageRect(windowSize: bounds.size)
            )
            arrangementCache = (bounds.size, arrangement)
        }
        let transform = StageGeometry.stageTransform(progress: dragging ? min(progress.value, 1) : progress.value)
        arrangementLayer.transform = CATransform3DScale(
            CATransform3DMakeTranslation(0, transform.translationY, 0), transform.scale, transform.scale, 1
        )
        arrangementLayer.opacity = Float(transform.opacity)
        let fade = flights.values.map(\.spring.value).max() ?? 0
        for (index, display) in displays.enumerated() {
            guard let shell = displayLayers[display.id] else { continue }
            shell.place(content: arrangement.contentRects[index], isBuiltin: display.isBuiltin)
            shell.setHovered(!model.interactionBlocked && model.hoveredDisplay == display.id)
            shell.setDropTarget(model.dropTarget == display.id)
            shell.layer.opacity = Float(1 - min(1, fade))
        }
        let count = cards.count
        let style = model.shelfStyle
        if count > 0 {
            gesture.rowLimits = rowLimits(count: count, style: style)
        }
        syncCardWindow(count: count, style: style)
        let hovered = hoveredIndex
        let wave = model.snappedIndex == 1 && !snapInFlight && progress.value == 1
        for index in cardWindow {
            let card = cards[index]
            guard let tile = cardLayers[card.id] else { continue }
            tile.lift.target = wave ? Double(StageGeometry.waveLift(style: style, index: index, hovered: hovered)) : 0
            tile.hover.target = model.hoveredCard == card.id ? 1 : 0
            if model.reduceMotion {
                tile.lift.jump(to: tile.lift.target)
                tile.hover.jump(to: tile.hover.target)
            }
            let p = staggerToGrid ? tile.gridProgress.value : progress.value
            var placement = cardPlacement(style: style, index: index, count: count, progress: p)
            let mix = CGFloat(StageGeometry.progressSplit(p).t2)
            placement.frame.origin.y += tile.lift.value
            if let elapsed = tile.shakeElapsed {
                placement.frame.origin.x += 6 * sin(elapsed / 0.3 * 6 * .pi)
            }
            tile.place(placement, style: style, gridMix: mix, dragged: dragging && ghost.source == card.id)
            // Continuous in the hover spring: a hover change never re-sorts the cards behind it.
            tile.layer.zPosition = placement.depthOrder + CGFloat(tile.hover.value) * 400
        }
        reportHoveredCardRect(style: style, count: count)
        renderFlights()
        ghost.render()
        updateAccessibilityFrames()
    }

    private func reportHoveredCardRect(style: ShelfStyle, count: Int) {
        guard let index = hoveredIndex, cardWindow.contains(index) else {
            model.report(hoveredCardRect: nil)
            return
        }
        var placement = cardPlacement(style: style, index: index, count: count, progress: progress.value)
        placement.frame.origin.y += cardLayers[cards[index].id]?.lift.value ?? 0
        model.report(hoveredCardRect: StageGeometry.hitRect(placement, style: style, hovered: true))
    }

    /// Builds and drops card layers as the row scrolls, so the shelf can be as long as the
    /// library without paying for every card at once.
    private func syncCardWindow(count: Int, style: ShelfStyle) {
        let window = StageGeometry.visibleCards(
            style: style, count: count, rowOffset: row.value, focus: focus, windowSize: bounds.size,
            capacity: model.shelfRenderBudget
        )
        guard window != cardWindow else { return }
        cardWindow = window
        let wanted = Set(cards[window].map(\.id))
        for (id, tile) in cardLayers where !wanted.contains(id) {
            cardLayers[id] = nil
            // Recycled, not rebuilt: a fast flick crosses a slot boundary every few frames and
            // building a card means ten sublayers and two fonts.
            if reserve.count < Self.reserveLimit {
                tile.layer.isHidden = true
                reserve.append(tile)
            } else {
                tile.layer.removeFromSuperlayer()
            }
        }
        for index in window where cardLayers[cards[index].id] == nil {
            let tile: ShelfCardLayer
            if let spare = reserve.popLast() {
                tile = spare
                tile.layer.isHidden = false
            } else {
                tile = ShelfCardLayer()
                shelfLayer.addSublayer(tile.layer)
            }
            tile.update(card: cards[index])
            tile.lift.jump(to: 0)
            tile.hover.jump(to: 0)
            tile.shakeElapsed = nil
            tile.gridProgress.jump(to: progress.value)
            cardLayers[cards[index].id] = tile
        }
        model.report(visibleShelfRange: window)
        rebuildAccessibility()
    }

    /// Cover Flow only: which slot faces the viewer. Driven by the row offset, never by hover —
    /// moving the run under the pointer would re-enter the hover feedback loop.
    private var focus: Double {
        guard model.shelfStyle == .coverFlow else { return 0 }
        return Double(-row.value / StageGeometry.metrics(for: .coverFlow).pitch)
    }

    /// The card's rest slot: everything `render` adds on top (wave lift, shake) is deliberately
    /// left out so hit testing cannot chase a card that is moving.
    private func cardPlacement(style: ShelfStyle, index: Int, count: Int, progress p: Double) -> StageGeometry.CardPlacement {
        var placement = StageGeometry.cardPlacement(
            style: style, index: index, count: count, progress: p, focus: focus, windowSize: bounds.size,
            capacity: model.shelfRenderBudget
        )
        guard style != .coverFlow else { return placement }
        let flat = CGFloat(1 - StageGeometry.progressSplit(p).t2)
        placement.frame.origin.x += row.value * flat
        let fade = StageGeometry.bandOpacity(
            cardMinX: placement.frame.minX, style: style,
            capacity: model.shelfRenderBudget, windowSize: bounds.size
        )
        // Only the row is banded; the grid spreads across the whole window.
        placement.opacity *= 1 - (1 - fade) * flat
        return placement
    }

    private func rowLimits(count: Int, style: ShelfStyle) -> ClosedRange<CGFloat> {
        guard style != .coverFlow else {
            return -CGFloat(max(count - 1, 0)) * StageGeometry.metrics(for: .coverFlow).pitch ... 0
        }
        let last = StageGeometry.rowFrame(
            style: style, index: count - 1, count: count, focus: 0, windowSize: bounds.size,
            capacity: model.shelfRenderBudget
        )
        let band = StageGeometry.shelfBand(style: style, capacity: model.shelfRenderBudget, windowSize: bounds.size)
        return min(0, band.upperBound - last.minX) ... 0
    }

    // MARK: Commands

    func setProgress(_ value: Double, animated: Bool) {
        setProgress(value, animated: animated, velocity: 0)
    }

    /// `velocity` is the gesture's own speed in states per second; the landing spring starts from
    /// it so a flick lands fast and a slow drag settles slowly.
    func setProgress(_ value: Double, animated: Bool, velocity: Double) {
        snapTask?.cancel()
        let target = StageGeometry.clampProgress(value)
        withoutActions {
            if animated, !model.reduceMotion {
                progress.launch(to: target, velocity: velocity)
                snapInFlight = true
                staggerToGrid = target == 2
                for (index, card) in cards.enumerated() {
                    cardLayers[card.id]?.gridProgress.jump(to: progress.value)
                    cardLayers[card.id]?.gridProgress.target = target
                    cardLayers[card.id]?.staggerRemaining = Double(index) * 0.025
                }
                if progress.isSettled {
                    progress.jump(to: target)
                    finishSnap()
                }
            } else {
                progress.jump(to: target)
                staggerToGrid = false
                snapInFlight = false
                finishSnap()
            }
            reportProgress()
            render()
        }
        startDisplayLinkIfNeeded()
    }

    private func reportProgress() {
        let value = StageGeometry.clampProgress(progress.value)
        if model.progress != value {
            model.report(progress: value)
        }
    }

    private func finishSnap() {
        snapInFlight = false
        if progress.target == progress.target.rounded() {
            let index = Int(progress.target)
            model.report(snappedIndex: index)
            model.emit(.snapped(index))
        }
    }

    func flyTile(display: StageDisplay.ID, to rectInWindow: CGRect) async {
        guard let shell = displayLayers[display], let root = layer else { return }
        await withCheckedContinuation { continuation in
            withoutActions {
                flights.removeValue(forKey: display)?.continuation?.resume()
                let home = shell.content.convert(shell.content.bounds, to: root)
                shell.content.removeFromSuperlayer()
                flightLayer.addSublayer(shell.content)
                flights[display] = TileFlight(home: home, destination: rectInWindow, continuation: continuation)
                if model.reduceMotion {
                    flights[display]?.spring.jump(to: 1)
                    flights[display]?.continuation?.resume()
                    flights[display]?.continuation = nil
                }
                render()
            }
            startDisplayLinkIfNeeded()
            settleFlightsWithoutDisplayLink()
        }
    }

    /// Off-screen there is no frame driver, so a flight that cannot animate lands immediately.
    private func settleFlightsWithoutDisplayLink() {
        guard displayLink == nil else { return }
        withoutActions {
            for id in flights.keys {
                if let target = flights[id]?.spring.target {
                    flights[id]?.spring.jump(to: target)
                }
            }
            completeFlights()
            render()
        }
    }

    func returnTile(display: StageDisplay.ID) async {
        guard flights[display] != nil else { return }
        await withCheckedContinuation { continuation in
            withoutActions {
                flights[display]?.continuation?.resume()
                flights[display]?.continuation = continuation
                flights[display]?.spring.target = 0
                if model.reduceMotion {
                    flights[display]?.spring.jump(to: 0)
                }
                completeFlights()
                render()
            }
            startDisplayLinkIfNeeded()
            settleFlightsWithoutDisplayLink()
        }
    }

    func crossfadeCover(display: StageDisplay.ID, to image: CGImage, duration: TimeInterval) {
        withoutActions { displayLayers[display]?.crossfade(to: image, duration: model.reduceMotion ? 0.15 : duration) }
        startDisplayLinkIfNeeded()
    }

    func shake(card: StageCard.ID) {
        guard !model.reduceMotion else { return }
        cardLayers[card]?.shakeElapsed = 0
        startDisplayLinkIfNeeded()
    }

    private func renderFlights() {
        for (id, flight) in flights {
            guard let shell = displayLayers[id] else { continue }
            let t = flight.spring.value
            shell.content.frame = CGRect(
                x: flight.home.minX + (flight.destination.minX - flight.home.minX) * t,
                y: flight.home.minY + (flight.destination.minY - flight.home.minY) * t,
                width: flight.home.width + (flight.destination.width - flight.home.width) * t,
                height: flight.home.height + (flight.destination.height - flight.home.height) * t
            )
            shell.content.cornerRadius = DesignTokens.EditDesk.Corner.content
                + (DesignTokens.EditDesk.Corner.panelLarge - DesignTokens.EditDesk.Corner.content) * t
            shell.layoutContent()
        }
    }

    private func completeFlights() {
        for id in Array(flights.keys) {
            guard let flight = flights[id], flight.spring.isSettled else { continue }
            flight.continuation?.resume()
            flights[id]?.continuation = nil
            if flight.spring.target == 0 {
                displayLayers[id]?.restoreContent()
                flights[id] = nil
            }
        }
    }

    // MARK: Frame driver

    private var isAnimating: Bool {
        !progress.isSettled || !row.isSettled || dragging
            || ghost.destination != nil
            || displayLayers.values.contains(where: \.hasAnimation)
            || flights.values.contains { !$0.spring.isSettled }
            || cardLayers.values.contains {
                !$0.lift.isSettled || !$0.hover.isSettled || $0.shakeElapsed != nil
                    || (staggerToGrid && !$0.gridProgress.isSettled)
            }
    }

    private func startDisplayLinkIfNeeded() {
        guard isAnimating, displayLink == nil, let screen = window?.screen else { return }
        let target = DisplayLinkTarget(view: self)
        let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.step(_:)))
        linkTarget = target
        displayLink = link
        lastTimestamp = nil
        link.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        linkTarget = nil
        lastTimestamp = nil
    }

    private func advance(timestamp: TimeInterval, duration: TimeInterval) {
        let dt = lastTimestamp.map { timestamp - $0 } ?? duration
        lastTimestamp = timestamp
        advance(dt: dt)
    }

    func advance(dt: TimeInterval) {
        withoutActions {
            progress.step(dt: dt)
            row.step(dt: dt)
            if snapInFlight, progress.isSettled {
                finishSnap()
            }
            reportProgress()
            for tile in cardLayers.values {
                tile.lift.step(dt: dt)
                tile.hover.step(dt: dt)
                if staggerToGrid {
                    tile.staggerRemaining -= dt
                    if tile.staggerRemaining <= 0 {
                        tile.gridProgress.step(dt: dt)
                    }
                }
                if let elapsed = tile.shakeElapsed {
                    tile.shakeElapsed = elapsed + dt >= 0.3 ? nil : elapsed + dt
                }
            }
            if staggerToGrid, cardLayers.values.allSatisfy(\.gridProgress.isSettled) {
                staggerToGrid = false
            }
            for shell in displayLayers.values {
                shell.step(dt: dt, reduceMotion: model.reduceMotion)
            }
            for id in flights.keys {
                flights[id]?.spring.step(dt: dt)
            }
            completeFlights()
            if model.reduceMotion {
                ghost.x.jump(to: ghost.x.target)
                ghost.y.jump(to: ghost.y.target)
                ghost.scale.jump(to: ghost.scale.target)
                if ghost.destination != nil {
                    ghost.flight.jump(to: 1)
                }
            } else {
                ghost.x.step(dt: dt)
                ghost.y.step(dt: dt)
                ghost.scale.step(dt: dt)
                ghost.flight.step(dt: dt)
            }
            if ghost.destination != nil, ghost.flight.isSettled {
                ghost.finish()
            }
            render()
        }
        if !isAnimating {
            stopDisplayLink()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopDisplayLink()
        screenObserver.map(NotificationCenter.default.removeObserver)
        screenObserver = nil
        if let window {
            // The link is bound to one screen's refresh rate; dragged from a 60Hz panel onto
            // ProMotion it would keep stepping the springs at 60Hz.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.displayLink != nil else { return }
                    self.stopDisplayLink()
                    self.startDisplayLinkIfNeeded()
                }
            }
            startDisplayLinkIfNeeded()
        } else {
            for flight in flights.values {
                flight.continuation?.resume()
            }
            for id in flights.keys {
                flights[id]?.continuation = nil
            }
        }
    }

    func detach() {
        attached = false
        withoutActions {
            if dragging {
                endDrag(cancelled: true)
            }
            ghost.finish()
            clearHover()
        }
        stopDisplayLink()
        snapTask?.cancel()
        for flight in flights.values {
            flight.continuation?.resume()
        }
        flights.removeAll()
        if model.engine === self {
            model.engine = nil
        }
    }

    // MARK: Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !model.interactionBlocked, !dragging else { return }
        let phase: ShelfGestureController.Phase = if event.momentumPhase.contains(.ended) {
            .momentumEnded
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            .ended
        } else if event.phase.contains(.began) {
            .began
        } else if !event.momentumPhase.isEmpty {
            .momentum
        } else {
            .changed
        }
        if phase == .began {
            // Fingers coming down catch a snap in flight: stop it where it is so the gesture tracks
            // from what is on screen, instead of a baseline the spring keeps moving underneath it.
            snapTask?.cancel()
            snapInFlight = false
            staggerToGrid = false
            withoutActions {
                progress.jump(to: progress.value)
                row.jump(to: row.value)
            }
            gesture.adopt(rowOffset: CGFloat(row.value))
        }
        // Mouse wheels report line units, not points (`hasPreciseScrollingDeltas == false`).
        let precise = event.hasPreciseScrollingDeltas
        let unit: CGFloat = precise ? 1 : 24
        withoutActions {
            if let value = gesture.scroll(
                deltaX: event.scrollingDeltaX * unit, deltaY: event.scrollingDeltaY * unit, progress: progress.value,
                phase: phase, precise: precise, shift: event.modifierFlags.contains(.shift)
            ) {
                progress.jump(to: value)
                snapInFlight = false
                staggerToGrid = false
                reportProgress()
            }
            row.jump(to: gesture.rowOffset)
            render()
        }
        if let release = gesture.consumeRelease() {
            row.target = gesture.settleRow(quantum: StageGeometry.metrics(for: model.shelfStyle).pitch)
            setProgress(Double(release.target), animated: true, velocity: release.velocity)
        } else {
            scheduleSnap()
        }
        startDisplayLinkIfNeeded()
    }

    private func scheduleSnap() {
        snapTask?.cancel()
        guard let deadline = gesture.snapDeadline else { return }
        snapTask = Task { @MainActor [weak self] in
            let delay = max(0, deadline - CACurrentMediaTime())
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !model.interactionBlocked, !dragging, let target = gesture.consumeSnap(progress: progress.value) else { return }
            row.target = gesture.settleRow(quantum: StageGeometry.metrics(for: model.shelfStyle).pitch)
            setProgress(Double(target), animated: true)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !model.interactionBlocked else { return }
        if event.keyCode == 53 {
            if dragging {
                withoutActions { endDrag(cancelled: true) }
                startDisplayLinkIfNeeded()
            }
            return
        }
        // Changing state mid-drag would move the drop targets out from under the ghost.
        guard !dragging, event.keyCode == 126 || event.keyCode == 125 else {
            super.keyDown(with: event)
            return
        }
        setProgress(Double(ShelfGestureController.keyTarget(up: event.keyCode == 126, progress: progress.value)), animated: true)
    }

    /// Resolves the pointer against the row's **rest** shape — nothing lifted, nothing turned to
    /// face the viewer. Being a pure function of the pointer is what stops hover oscillating: the
    /// shape a hover produces can never decide who gets the next hover.
    private func restCardIndex(at point: CGPoint) -> Int? {
        guard progress.value >= StageGeometry.cardTapMinimumProgress else { return nil }
        let style = model.shelfStyle
        let count = cards.count
        let placements = cardWindow.map {
            cardPlacement(style: style, index: $0, count: count, progress: progress.value)
        }
        let hit = ShelfGestureController.card(
            at: point,
            frames: placements.map {
                // A card faded out past the end of the flow is not there to be grabbed.
                $0.opacity < 0.05 ? .null : StageGeometry.hitRect($0, style: style)
            },
            order: placements.map(\.depthOrder)
        )
        return hit.map { cardWindow.lowerBound + $0 }
    }

    /// The region the hovered card keeps the pointer inside: its rest shape plus the shape it has
    /// once lifted and turned. Strictly larger than the region that acquires a hover, which is
    /// what makes the two-state rule stable rather than a flip-flop.
    private func hoverRetentionRect(for index: Int) -> CGRect? {
        guard cardWindow.contains(index), progress.value >= StageGeometry.cardTapMinimumProgress else { return nil }
        let style = model.shelfStyle
        var placement = cardPlacement(style: style, index: index, count: cards.count, progress: progress.value)
        guard placement.opacity >= 0.05 else { return nil }
        let rest = StageGeometry.hitRect(placement, style: style)
        placement.frame.origin.y += StageGeometry.waveLift(style: style, index: index, hovered: index)
        return rest.union(StageGeometry.hitRect(placement, style: style, hovered: true))
    }

    private var hoveredIndex: Int? {
        model.hoveredCard.flatMap { id in cards.firstIndex { $0.id == id } }
    }

    /// Who the pointer belongs to, including the card that already owns the hover: clicking the
    /// part of a lifted card that sticks out past its rest slot has to reach that card.
    func cardIndex(at point: CGPoint) -> Int? {
        if let index = hoveredIndex, let retention = hoverRetentionRect(for: index), retention.contains(point) {
            return index
        }
        return restCardIndex(at: point)
    }

    private func displayID(at point: CGPoint) -> StageDisplay.ID? {
        guard arrangementLayer.opacity > 0, let root = layer else { return nil }
        return ShelfGestureController.display(at: point, frames: displays.compactMap {
            guard let shell = displayLayers[$0.id] else { return nil }
            return ($0.id, shell.layer.convert(shell.layer.bounds, to: root))
        })
    }

    func tap(at point: CGPoint) {
        guard !model.interactionBlocked else { return }
        if let index = cardIndex(at: point) {
            model.emit(.cardTapped(cards[index].id))
        } else if let id = displayID(at: point), let shell = displayLayers[id] {
            let local = shell.layer.convert(point, from: layer)
            if let action = shell.playbackAction(at: local) {
                model.emit(.playbackTapped(id, action))
            } else {
                model.emit(.displayTapped(id))
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !model.interactionBlocked else { return }
        let point = convert(event.locationInWindow, from: nil)
        model.report(hoveredCard: cardIndex(at: point).map { cards[$0].id })
        model.report(hoveredDisplay: displayID(at: point))
        withoutActions { render() }
        startDisplayLinkIfNeeded()
    }

    override func mouseExited(with _: NSEvent) {
        clearHover()
        withoutActions { render() }
        startDisplayLinkIfNeeded()
    }

    private func clearHover() {
        model.report(hoveredCard: nil)
        model.report(hoveredDisplay: nil)
        model.report(dropTarget: nil)
    }

    /// The stage covers the window so that scrolling works wherever the pointer is, but the chip
    /// row is drawn *underneath* it. Clicks that land on no card and no display therefore have to
    /// fall through; scroll and hover must not, or the shelf would stop taking the gesture over a
    /// third of the window. `NSApp.currentEvent` is what separates the two — it is the very event
    /// AppKit is routing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let clicking = switch NSApp.currentEvent?.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: true
        default: false
        }
        return ownsPoint(convert(point, from: superview), clicking: clicking) ? super.hitTest(point) : nil
    }

    func ownsPoint(_ point: CGPoint, clicking: Bool) -> Bool {
        guard clicking, !dragging, !model.interactionBlocked else { return true }
        return cardIndex(at: point) != nil || displayID(at: point) != nil
    }

    override func mouseDown(with event: NSEvent) {
        guard !model.interactionBlocked else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        gesture.mouseDown(at: point)
        pressedCard = cardIndex(at: point).map { cards[$0].id }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !model.interactionBlocked else { return }
        let point = convert(event.locationInWindow, from: nil)
        withoutActions {
            if !dragging, gesture.shouldStartDrag(at: point), let card = cards.first(where: { $0.id == pressedCard }), card.isDraggable {
                dragging = true
                snapTask?.cancel()
                clearHover()
                ghost.begin(card: card, at: point)
                NSCursor.closedHand.set()
                render()
            }
            guard dragging else { return }
            ghost.x.target = point.x
            ghost.y.target = point.y
            let target = displayID(at: point)
            model.report(dropTarget: target)
            ghost.scale.target = target == nil ? 1 : 0.8
            render()
        }
        startDisplayLinkIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        guard !model.interactionBlocked else { return }
        if dragging {
            // The pointer can leave the display after the last drag event, and the arrangement can
            // change mid-drag: the release point is the only thing that decides the target.
            let point = convert(event.locationInWindow, from: nil)
            model.report(dropTarget: displayID(at: point))
            withoutActions { endDrag(cancelled: false) }
        } else {
            let point = convert(event.locationInWindow, from: nil)
            if pressedCard == cardIndex(at: point).map({ cards[$0].id }) {
                tap(at: point)
            }
        }
        gesture.mouseUp()
        pressedCard = nil
        startDisplayLinkIfNeeded()
    }

    private func endDrag(cancelled: Bool) {
        guard let source = ghost.source else { return }
        let target = cancelled ? nil : model.dropTarget
        // The untransformed rect: `render` re-applies rotation and scale on top of it.
        ghost.flightOrigin = CGRect(
            x: ghost.x.value - DragGhostLayer.size.width / 2, y: ghost.y.value - DragGhostLayer.size.height / 2,
            width: DragGhostLayer.size.width, height: DragGhostLayer.size.height
        )
        if let target, let shell = displayLayers[target] {
            ghost.destination = shell.content.convert(shell.content.bounds, to: layer)
            model.emit(.dropped(card: source, onto: target))
        } else {
            ghost.destination = cardLayers[source]?.frame ?? ghost.layer.frame
            model.emit(.dropCancelled(card: source))
        }
        ghost.flight.target = 1
        ghost.scale.target = 1
        dragging = false
        model.report(dropTarget: nil)
        NSCursor.arrow.set()
        if model.reduceMotion {
            ghost.finish()
        }
        render()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !model.interactionBlocked, let window else { return }
        if let id = displayID(at: convert(event.locationInWindow, from: nil)) {
            model.emit(.displayContextMenu(id, screenPoint: window.convertPoint(toScreen: event.locationInWindow)))
        }
    }

    // MARK: Accessibility and backing

    private func rebuildAccessibility() {
        accessibilityItems = displays.map { display in
            let id = display.id
            let element = StageAccessibilityElement { [weak self] in
                guard let self, !model.interactionBlocked else { return false }
                model.emit(.displayTapped(id))
                return true
            }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(display.name + " " + display.statusText)
            element.setAccessibilityParent(self)
            element.displayID = id
            return element
        } + cardWindow.map { cards[$0] }.map { card in
            let id = card.id
            let element = StageAccessibilityElement { [weak self] in
                guard let self, !model.interactionBlocked, progress.value >= StageGeometry.cardTapMinimumProgress else { return false }
                model.emit(.cardTapped(id))
                return true
            }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(card.title + " " + card.metaLine)
            element.setAccessibilityParent(self)
            element.cardID = id
            return element
        }
        setAccessibilityChildren(accessibilityItems)
    }

    private func updateAccessibilityFrames() {
        for element in accessibilityItems {
            let item: CALayer? = if let id = element.displayID {
                displayLayers[id]?.layer
            } else if let id = element.cardID {
                cardLayers[id]?.layer
            } else {
                nil
            }
            guard let item else { continue }
            let rect = convert(item.convert(item.bounds, to: layer), to: nil)
            element.setAccessibilityFrame(window?.convertToScreen(rect) ?? rect)
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var view: EditDeskStageView?

        init(view: EditDeskStageView) {
            self.view = view
        }

        @objc nonisolated func step(_ link: CADisplayLink) {
            let timestamp = link.timestamp
            let duration = link.targetTimestamp - timestamp
            let attached = MainActor.assumeIsolated {
                guard let view else { return false }
                view.advance(timestamp: timestamp, duration: duration)
                return true
            }
            if !attached {
                link.invalidate()
            }
        }
    }
}

@MainActor
private final class StageAccessibilityElement: NSAccessibilityElement {
    var displayID: StageDisplay.ID?
    var cardID: StageCard.ID?
    private nonisolated let press: @MainActor @Sendable () -> Bool

    init(press: @escaping @MainActor @Sendable () -> Bool) {
        self.press = press
        super.init()
    }

    override nonisolated func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated { action() }
    }
}

@MainActor
struct EditDeskStageRepresentable: NSViewRepresentable {
    let model: EditDeskStageModel

    func makeNSView(context _: Context) -> EditDeskStageView {
        EditDeskStageView(model: model)
    }

    func updateNSView(_: EditDeskStageView, context _: Context) {
        // Inputs arrive through observation tracking; a layout per SwiftUI update would double the frame work.
    }

    static func dismantleNSView(_ nsView: EditDeskStageView, coordinator _: ()) {
        nsView.detach()
    }
}
