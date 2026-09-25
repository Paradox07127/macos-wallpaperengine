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
    private let cardFocusRing = CALayer()
    private var focusedCardIndex: Int?
    /// Reduce Motion draws the nearest rest state instead of the finger's fraction; this is the
    /// state last drawn, so crossing into another one fades.
    private var reducedMotionState: Int?
    /// Set when the row was cut to a new offset rather than slid there; the next `render` spends it.
    private var cutRow = false
    private let flightLayer = CALayer()
    private let ghost = DragGhostLayer()
    private var displays: [StageDisplay] = []
    private var cards: [StageCard] = []
    /// Slice of `cards` the row draws; the row is as long as the whole library.
    private var cardWindow = 0 ..< 0
    /// Slice the grid draws while the shelf flies to p = 2, empty otherwise. Kept apart from
    /// `cardWindow`: a scrolled row puts the two runs hundreds of cards apart, and one span
    /// covering both is the whole library.
    private var gridWindow = 0 ..< 0
    private var reserve: [ShelfCardLayer] = []
    private static let reserveLimit = 8
    private var shelfStyle = ShelfStyle.crate
    private var highContrast = false
    private var paintsCanvas = true
    private var dropHint = ""
    private var progress = StageSpring(value: 0, target: 0, parameters: StageSpring.snap)
    private var row = StageSpring(value: 0, target: 0, parameters: StageSpring.row)
    /// The onboarding card's band; the arrangement re-centres in what is left (R-27).
    private var arrangementInset = StageSpring(value: 0, target: 0, parameters: StageSpring.snap)
    private let gesture = ShelfGestureController(clock: CACurrentMediaTime)
    private var attached = true
    /// Fades the whole wave in and out. The crest's *position* must never go through a spring —
    /// a spring tracking a moving target lags it by `damping/stiffness` (99ms here, a full slot at
    /// 480pt/s), which is exactly the "not following my mouse" feel. Only entering and leaving the
    /// shelf is animated; where the crest sits is read straight off the pointer.
    private var waveStrength = StageSpring(value: 0, target: 0, parameters: StageSpring.hover)
    /// Pointer position in slots, frozen at its last value while the wave fades out.
    private var waveCentre: CGFloat?
    /// Row offset and progress the current hover was resolved against. A scroll — sprung, flicked
    /// or jumped by a keyboard reveal — slides cards under a still pointer, and hover is a property
    /// of the point, not of the card it last landed on.
    private var hoverResolvedAt: CGPoint?
    /// Last pointer position in stage space, or nil when the pointer is outside the view.
    private var pointer: CGPoint?
    private var screenObserver: (any NSObjectProtocol)?
    private var gridScrollMonitor: Any?
    private var ownsGridScroll = false
    /// A swipe or wheel burst AppKit started on the stage; the rest of it stays here wherever the pointer goes.
    private var ownsStageScroll = false
    private var lastGridWheelTime: TimeInterval?
    private var snapInFlight = false
    private var staggerToGrid = false
    private var snapTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var linkTarget: DisplayLinkTarget?
    private var lastTimestamp: TimeInterval?
    private var tracking: NSTrackingArea?
    private var pressedCard: StageCard.ID?
    private var dragging = false
    /// `draggingSequenceNumber` of the Finder drag that raised a hidden shelf, so its end lowers the
    /// shelf again; nil once the drop lands on the shelf, or a scroll, ↑↓ or a covering page takes over.
    private var raisedForFileDrag: Int?
    private var accessibilityItems: [StageAccessibilityElement] = []
    private var cardAccessibility: [StageCard.ID: StageAccessibilityElement] = [:]
    private var displayAccessibility: [StageDisplay.ID: StageAccessibilityElement] = [:]
    /// What the last `rebuildAccessibility` was told to expose. Progress alone changes it, and
    /// neither of the other two triggers fires on progress.
    private var accessibilityExposure = (displays: false, cards: false)
    /// `arrangement` allocates while it works out the gaps; it only changes with the displays or
    /// the window, never per frame.
    private var arrangementCache: (size: CGSize, topInset: CGFloat, value: StageGeometry.Arrangement)?
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
        focusRingType = .none
        withoutActions {
            shelfLayer.addSublayer(cardFocusRing)
            cardFocusRing.borderWidth = 3
            cardFocusRing.cornerRadius = DesignTokens.EditDesk.Corner.shelfCard
            cardFocusRing.isHidden = true
            applyPalette()
            arrangementLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        }
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
    /// window's appearance flips between light and dark, or when Increase Contrast changes tier.
    private func applyPalette() {
        // Not every caller is a drawing callback: a contrast flip arrives on a plain observation
        // task, where the current appearance is the app's rather than this view's.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cardFocusRing.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            ghost.refreshPalette()
            for display in displays {
                displayLayers[display.id]?.update(display: display, dropHint: dropHint, increasedContrast: highContrast)
            }
            for card in cards {
                cardLayers[card.id]?.update(card: card, increasedContrast: highContrast)
            }
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
        startDisplayLinkIfNeeded()
    }

    // MARK: Model and layout

    private func observeInputs() {
        guard attached else { return }
        withObservationTracking {
            _ = model.displays
            _ = model.shelfItems
            _ = model.shelfStyle
            _ = model.reduceMotion
            _ = model.increaseContrast
            _ = model.gridTileSize
            _ = model.interactionBlocked
            _ = model.dropHintText
            _ = model.shelfRenderBudget
            _ = model.opaqueBackground
            _ = model.arrangementTopInset
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
        var styleFocusID: StageCard.ID?
        if shelfStyle != model.shelfStyle, !cards.isEmpty {
            let index: Int
            if let focusedCardIndex {
                index = focusedCardIndex
            } else if shelfStyle.isCentred {
                index = Int((-row.value / StageGeometry.metrics(for: shelfStyle).pitch).rounded())
            } else {
                let band = StageGeometry.shelfBand(style: shelfStyle, capacity: model.shelfRenderBudget, windowSize: bounds.size)
                let first = StageGeometry.rowFrame(
                    style: shelfStyle, index: 0, count: cards.count, focus: 0, windowSize: bounds.size,
                    capacity: model.shelfRenderBudget
                )
                index = Int((((band.lowerBound + band.upperBound) / 2 - first.minX - row.value)
                        / StageGeometry.metrics(for: shelfStyle).pitch).rounded())
            }
            styleFocusID = cards[min(max(index, 0), cards.count - 1)].id
        }
        let changed = displays != nextDisplays || cards != nextCards
        if displays.map(\.frame) != nextDisplays.map(\.frame) {
            arrangementCache = nil
        }
        for id in Array(displayLayers.keys) where !nextDisplays.contains(where: { $0.id == id }) {
            flights.removeValue(forKey: id)?.continuation?.resume()
            displayLayers[id]?.restoreContent()
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
                shell.update(display: display, dropHint: model.dropHintText, increasedContrast: highContrast)
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
                cardLayers[card.id]?.update(card: card, increasedContrast: highContrast)
            }
        }
        if cards.map(\.id) != nextCards.map(\.id) {
            // Identity, not count: swapping ten cards for ten others left the window equal, so the
            // reconcile bailed out after the old layers were already gone and the shelf went blank.
            let focusedID = focusedCardIndex.map { cards[$0].id }
            focusedCardIndex = nextCards.firstIndex { $0.id == focusedID }
            cardWindow = 0 ..< 0
            gridWindow = 0 ..< 0
        }
        displays = nextDisplays
        cards = nextCards
        dropHint = model.dropHintText
        if arrangementInset.target != Double(model.arrangementTopInset) {
            let inset = Double(model.arrangementTopInset)
            if model.reduceMotion {
                arrangementInset.jump(to: inset)
            } else {
                arrangementInset.target = inset
            }
        }
        if paintsCanvas != model.opaqueBackground {
            paintsCanvas = model.opaqueBackground
            applyPalette()
        }
        if highContrast != model.increaseContrast {
            highContrast = model.increaseContrast
            applyPalette()
        }
        if shelfStyle != model.shelfStyle {
            // The row offset means points in one style and focused slots in another.
            shelfStyle = model.shelfStyle
            gesture.reset()
            jumpRow(to: 0)
            if let index = cards.firstIndex(where: { $0.id == styleFocusID }) {
                focusedCardIndex = index
                if shelfStyle.isCentred {
                    jumpRow(to: -Double(index) * StageGeometry.metrics(for: shelfStyle).pitch)
                } else {
                    let frame = StageGeometry.rowFrame(
                        style: shelfStyle, index: index, count: cards.count, focus: 0, windowSize: bounds.size,
                        capacity: model.shelfRenderBudget
                    )
                    let band = StageGeometry.shelfBand(style: shelfStyle, capacity: model.shelfRenderBudget, windowSize: bounds.size)
                    jumpRow(to: min(max(frame.minX, band.lowerBound), band.upperBound) - frame.minX)
                }
            }
            clampRowIntoLimits()
            gesture.adopt(rowOffset: row.value)
        }
        if changed {
            rebuildAccessibility()
        }
        clampRowIntoLimits()
        if model.interactionBlocked {
            // AppKit hands a drag to a registered view without asking `hitTest`, so a covered stage
            // has to unregister or it takes the detail page's drops.
            if !registeredDraggedTypes.isEmpty {
                unregisterDraggedTypes()
            }
            clearHover()
            raisedForFileDrag = nil
            pressedCard = nil
            gesture.mouseUp()
            snapTask?.cancel()
            if dragging {
                endDrag(cancelled: true)
            }
            // A modal stands in for the release the shelf will never get: the real `.ended` cannot
            // reach the controller while the lock is up, and the snap that would have landed the
            // row was just cancelled.
            gesture.reset()
            ownsStageScroll = false
            if cards.count > 0, bounds.width > 0 {
                gesture.rowLimits = rowLimits(count: cards.count, style: model.shelfStyle)
                gesture.adopt(rowOffset: CGFloat(row.value))
                let settled = gesture.settleRow(quantum: StageGeometry.metrics(for: model.shelfStyle).pitch)
                if model.reduceMotion {
                    jumpRow(to: settled)
                } else {
                    row.target = settled
                }
            }
            // A flick interrupted by a modal must not leave the shelf between rest states.
            if progress.target != progress.target.rounded() || (!snapInFlight && progress.value != progress.value.rounded()) {
                setProgress(Double(StageGeometry.snapTarget(for: progress.value)), animated: !model.reduceMotion)
            }
        } else if registeredDraggedTypes.isEmpty {
            registerForDraggedTypes([.fileURL])
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
            settleReducedMotion()
            staggerToGrid = false
            if snapInFlight {
                finishSnap()
            }
            reportProgress()
        }
    }

    /// The row's end moves with the window and the shelf budget as well as with the library, so
    /// this cannot hang off "the cards changed". Both ends of the spring are checked: a flight
    /// whose value is still inside the new limits would otherwise carry on to a target outside them.
    private func clampRowIntoLimits() {
        guard cards.count > 0, bounds.width > 0 else { return }
        let limits = rowLimits(count: cards.count, style: model.shelfStyle)
        let clamped = min(max(row.value, limits.lowerBound), limits.upperBound)
        guard clamped != row.value || min(max(row.target, limits.lowerBound), limits.upperBound) != row.target else { return }
        jumpRow(to: clamped)
        // `adopt`, not `reset`: a wheel has no `.began` to re-base on, so a zeroed offset sends the
        // next notch back to the first card.
        gesture.adopt(rowOffset: clamped)
    }

    private func settleReducedMotion() {
        progress.jump(to: progress.target)
        jumpRow(to: row.target)
        arrangementInset.jump(to: arrangementInset.target)
        for id in flights.keys {
            if let target = flights[id]?.spring.target {
                flights[id]?.spring.jump(to: target)
            }
        }
        completeFlights()
        for tile in Array(cardLayers.values) + reserve {
            tile.lift.jump(to: 0)
            tile.hover.jump(to: tile.hover.target)
            tile.gridProgress.jump(to: progress.value)
            tile.staggerRemaining = 0
            tile.shakeElapsed = nil
        }
        ghost.x.jump(to: ghost.x.target)
        ghost.y.jump(to: ghost.y.target)
        ghost.scale.jump(to: 1)
        ghost.flight.jump(to: ghost.flight.target)
        if ghost.destination != nil {
            ghost.finish(reduceMotion: true)
        }
    }

    override func layout() {
        super.layout()
        withoutActions {
            synchronizeInputs()
            render()
        }
        // `render` writes spring targets, so every entry point that is not the frame driver itself
        // has to ask for frames; the driver's own `advance` must not, or it invalidates mid-callback.
        startDisplayLinkIfNeeded()
    }

    private func render() {
        model.report(stageSize: bounds.size)
        arrangementLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        arrangementLayer.position = CGPoint(x: bounds.midX, y: 0)
        shelfLayer.frame = bounds
        flightLayer.frame = bounds
        let p = renderProgress
        // Both fades are built at the end of this function: `fadeOpacity` reads the layer's own
        // opacity as its destination, so one built here would animate towards the value about to
        // be replaced — the arrangement would fade *in* on its way out.
        let crossedState = model.reduceMotion && reducedMotionState != nil && reducedMotionState != Int(p)
        let arrangementWas = arrangementLayer.opacity
        reducedMotionState = model.reduceMotion ? Int(p) : nil
        let topInset = CGFloat(arrangementInset.value)
        let arrangement: StageGeometry.Arrangement
        if let cached = arrangementCache, cached.size == bounds.size, cached.topInset == topInset {
            arrangement = cached.value
        } else {
            arrangement = StageGeometry.arrangement(
                frames: displays.map(\.frame),
                in: StageGeometry.stageRect(windowSize: bounds.size, topInset: topInset)
            )
            arrangementCache = (bounds.size, topInset, arrangement)
        }
        let transform = StageGeometry.stageTransform(progress: dragging ? min(p, 1) : p)
        arrangementLayer.transform = CATransform3DScale(
            CATransform3DMakeTranslation(0, transform.translationY, 0), transform.scale, transform.scale, 1
        )
        arrangementLayer.opacity = Float(transform.opacity)
        let fade = flights.values.map(\.spring.value).max() ?? 0
        for (index, display) in displays.enumerated() {
            guard let shell = displayLayers[display.id] else { continue }
            shell.place(content: arrangement.contentRects[index], isBuiltin: display.isBuiltin)
            shell.setHovered(!model.interactionBlocked && flights.isEmpty && model.hoveredDisplay == display.id, reduceMotion: model.reduceMotion)
            shell.setDropTarget(model.dropTarget == display.id, reduceMotion: model.reduceMotion)
            shell.layer.opacity = Float(1 - min(1, fade))
        }
        let count = cards.count
        let style = model.shelfStyle
        if count > 0 {
            gesture.rowLimits = rowLimits(count: count, style: style)
        }
        syncCardWindow(count: count, style: style)
        // Only when it flips: rebuilding the list every frame would bounce VoiceOver's cursor back
        // to the container, and neither of the other triggers watches progress.
        if accessibilityExposure != accessibilityExposureNow {
            rebuildAccessibility()
        }
        if hoverResolvedAt != CGPoint(x: row.value, y: progress.value) {
            hoverResolvedAt = CGPoint(x: row.value, y: progress.value)
            resolveHover()
        }
        let hovered = hoveredIndex
        // Was `progress.value == 1`: the settle tail and a gesture frozen a hair off the state
        // both read as "not the shelf" and dropped the wave mid-motion.
        let wave = !model.interactionBlocked && flights.isEmpty
            && !model.reduceMotion && abs(progress.value - 1) < StageGeometry.waveProgressBand
        if wave, !style.isCentred, let centre = slotPosition(atX: pointer?.x) ?? hovered.map(CGFloat.init) {
            // The pointer is the real input; the hovered index is the fallback for the paths that
            // set a hover without one, so the wave can never silently vanish.
            waveCentre = centre
        }
        // The centred styles have no wave: each card's own hover spring carries its lift, which is
        // what hands it from card to card, and the strength only gates it.
        let reach = wave ? (style.isCentred ? 1 : pointerApproach) : 0
        // Asymmetric on purpose: rising follows the pointer directly, because every millisecond here
        // is lag it feels; falling fades, because nothing is chasing the pointer any more.
        if reach >= waveStrength.value {
            waveStrength.jump(to: reach)
        } else {
            waveStrength.target = reach
            if model.reduceMotion {
                waveStrength.jump(to: 0)
            }
        }
        let hoverLift = Double(StageGeometry.metrics(for: style).hoverLift)
        for index in visibleCardIndices {
            let card = cards[index]
            guard let tile = cardLayers[card.id] else { continue }
            let lift = style.isCentred
                ? hoverLift * tile.hover.value
                : Double(StageGeometry.waveLift(style: style, index: index, centre: waveCentre))
            tile.lift.jump(to: waveStrength.value * lift)
            tile.hover.target = model.hoveredCard == card.id ? 1 : 0
            if model.reduceMotion {
                tile.lift.jump(to: tile.lift.target)
                tile.hover.jump(to: tile.hover.target)
            }
            let p = staggerToGrid ? tile.gridProgress.value : renderProgress
            var placement = cardPlacement(style: style, index: index, count: count, progress: p)
            let mix = CGFloat(StageGeometry.progressSplit(p).t2)
            placement.lift(by: tile.lift.value)
            if let elapsed = tile.shakeElapsed {
                placement.frame.origin.x += 6 * sin(elapsed / 0.3 * 6 * .pi)
            }
            let opacity = tile.layer.opacity
            tile.place(placement, style: style, gridMix: mix, dragged: dragging && ghost.source == card.id, reduceMotion: model.reduceMotion)
            if model.reduceMotion, opacity != tile.layer.opacity {
                StageLayerStyle.fadeOpacity(tile.layer, resumingFrom: opacity)
            }
            // Continuous in the hover spring: a hover change never re-sorts the cards behind it.
            // Reduce Motion has no hover pose to lift clear of the row, and hit-testing already
            // reads that state, so the bump would only cut the occlusion order out from under it.
            let lifted = model.reduceMotion ? 0 : CGFloat(tile.hover.value)
            tile.layer.zPosition = placement.depthOrder + lifted * 400
        }
        reportHoveredCardRect(style: style, count: count)
        renderFlights()
        ghost.render(reduceMotion: model.reduceMotion)
        updateCardFocusRing()
        updateAccessibilityFrames()
        if crossedState {
            StageLayerStyle.fadeOpacity(arrangementLayer, from: arrangementLayer.opacity > 0 ? 0 : arrangementWas)
        }
        if model.reduceMotion, crossedState || cutRow {
            StageLayerStyle.fadeOpacity(shelfLayer, from: 0)
        }
        cutRow = false
    }

    /// Reduce Motion turns a row slide into a cut, and the cut takes the fade the slide would have
    /// had. The tracked gesture is direct manipulation and stays continuous, so it does not come
    /// through here.
    private func jumpRow(to value: Double) {
        cutRow = cutRow || (model.reduceMotion && row.value != value)
        row.jump(to: value)
    }

    private func reportHoveredCardRect(style: ShelfStyle, count: Int) {
        guard let index = hoveredIndex, cardWindow.contains(index) else {
            model.report(hoveredCardRect: nil)
            return
        }
        var placement = cardPlacement(style: style, index: index, count: count, progress: progress.value)
        placement.lift(by: cardLayers[cards[index].id]?.lift.value ?? 0)
        model.report(hoveredCardRect: StageGeometry.hitRect(placement, style: style, hover: model.reduceMotion ? 0 : 1))
    }

    /// Builds and drops card layers as the row scrolls, so the shelf can be as long as the
    /// library without paying for every card at once.
    private func syncCardWindow(count: Int, style: ShelfStyle) {
        let window = StageGeometry.visibleCards(
            style: style, count: count, rowOffset: row.value, focus: focus, windowSize: bounds.size,
            capacity: model.shelfRenderBudget
        )
        var grid = 0 ..< 0
        if staggerToGrid || progress.value > 1 {
            grid = StageGeometry.visibleGridCards(count: count, windowSize: bounds.size, scrollOffset: 0, size: model.gridTileSize)
        }
        guard window != cardWindow || grid != gridWindow else { return }
        cardWindow = window
        gridWindow = grid
        let wanted = Set(cards[window].map(\.id)).union(cards[grid].map(\.id))
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
        for index in visibleCardIndices where cardLayers[cards[index].id] == nil {
            let tile: ShelfCardLayer
            if let spare = reserve.popLast() {
                tile = spare
                tile.layer.isHidden = false
            } else {
                tile = ShelfCardLayer()
                shelfLayer.addSublayer(tile.layer)
            }
            tile.update(card: cards[index], increasedContrast: highContrast)
            tile.lift.jump(to: 0)
            tile.hover.jump(to: 0)
            tile.shakeElapsed = nil
            tile.gridProgress.jump(to: progress.value)
            if staggerToGrid {
                // Born mid-flight: a card left on the value it was created with sits the animation
                // out, then gets dragged to the end state when the stagger stops.
                tile.gridProgress.target = progress.target
                tile.staggerRemaining = 0
            }
            cardLayers[cards[index].id] = tile
        }
        model.report(visibleShelfRange: window)
        model.report(visibleGridRange: grid)
        rebuildAccessibility()
    }

    /// Both runs, each index once and in ascending order — the grid window always starts at the top
    /// of the library. Layers are coordinated by card identity, so an index in both must not be
    /// built, ranked or exposed twice.
    private var visibleCardIndices: [Int] {
        Array(gridWindow) + cardWindow.filter { !gridWindow.contains($0) }
    }

    /// The centred styles' middle slot. Driven by the row offset, never by hover — moving the run
    /// under the pointer would re-enter the hover feedback loop.
    private var focus: Double {
        guard model.shelfStyle.isCentred else { return 0 }
        return Double(-row.value / StageGeometry.metrics(for: model.shelfStyle).pitch)
    }

    /// The card's rest slot: everything `render` adds on top (wave lift, shake) is deliberately
    /// left out so hit testing cannot chase a card that is moving.
    private func cardPlacement(style: ShelfStyle, index: Int, count: Int, progress p: Double) -> StageGeometry.CardPlacement {
        var placement = StageGeometry.cardPlacement(
            style: style, index: index, count: count, progress: p, focus: focus, windowSize: bounds.size,
            capacity: model.shelfRenderBudget, gridSize: model.gridTileSize
        )
        guard !style.isCentred else { return placement }
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
        guard !style.isCentred else {
            return -CGFloat(max(count - 1, 0)) * StageGeometry.metrics(for: style).pitch ... 0
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
            // A stagger already under way keeps running whatever the new target is: its cards are
            // spread across the transition, and both re-seeding them from the global progress and
            // switching the render source back to it collapse that spread in one frame.
            let continuing = staggerToGrid && animated && !model.reduceMotion
            staggerToGrid = continuing || (animated && !model.reduceMotion && target == 2)
            if animated, !model.reduceMotion {
                progress.launch(to: target, velocity: velocity)
                snapInFlight = true
                // Build the destination window before any flight frame or stagger is seeded.
                syncCardWindow(count: cards.count, style: model.shelfStyle)
                let visible = visibleCardIndices
                let step = min(0.015, 0.18 / Double(max(1, visible.count - 1)))
                for (rank, index) in visible.enumerated() {
                    let tile = cardLayers[cards[index].id]
                    if !continuing {
                        tile?.gridProgress.jump(to: progress.value)
                        tile?.staggerRemaining = Double(rank) * step
                    }
                    tile?.gridProgress.target = target
                }
                if progress.isSettled {
                    progress.jump(to: target)
                    if staggerToGrid, cardLayers.values.allSatisfy(\.gridProgress.isSettled) {
                        staggerToGrid = false
                    }
                    // Cards still flying: `advance` sends the snap once the last one lands.
                    if cardsHaveLanded {
                        finishSnap()
                    }
                }
            } else {
                progress.jump(to: target)
                if model.reduceMotion {
                    settleReducedMotion()
                }
                snapInFlight = false
                finishSnap()
            }
            reportProgress()
            render()
        }
        startDisplayLinkIfNeeded()
    }

    /// Reduce Motion: the stage shows whole states only, so a tracked gesture switches instead of sliding.
    private var renderProgress: Double {
        model.reduceMotion ? progress.value.rounded() : progress.value
    }

    private func reportProgress() {
        let value = StageGeometry.clampProgress(progress.value)
        if model.progress != value {
            model.report(progress: value)
        }
    }

    /// Progress units: across the ~560pt climb from the row to the grid, 0.002 is about a point.
    private static let landedTolerance = 0.002

    /// Every staggered card within a point of its tile and all but stopped: the grid can fade in over
    /// them now instead of waiting out the springs' last sub-point creep.
    private var cardsHaveLanded: Bool {
        !staggerToGrid || cardLayers.values.allSatisfy {
            abs($0.gridProgress.target - $0.gridProgress.value) < Self.landedTolerance
                && abs($0.gridProgress.velocity) < Self.landedTolerance * 10
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
                if let superseded = flights.removeValue(forKey: display) {
                    shell.restoreContent()
                    superseded.continuation?.resume()
                }
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
                if model.reduceMotion {
                    StageLayerStyle.fadeOpacity(shell.content, from: 0)
                    StageLayerStyle.fadeOpacity(shell.layer, from: 1)
                }
            }
            startDisplayLinkIfNeeded()
            settleFlightsWithoutDisplayLink()
        }
    }

    /// Only the endpoint moves: the tile keeps flying from where it took off, at the speed it had.
    func updateFlightDestination(display: StageDisplay.ID, to rectInWindow: CGRect) {
        guard flights[display] != nil else { return }
        withoutActions {
            flights[display]?.destination = rectInWindow
            render()
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
        setTileConcealed(display: display, false)
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
                if model.reduceMotion, let shell = displayLayers[display] {
                    StageLayerStyle.fadeOpacity(shell.layer, from: 0)
                }
            }
            startDisplayLinkIfNeeded()
            settleFlightsWithoutDisplayLink()
        }
    }

    func crossfadeCover(display: StageDisplay.ID, to image: CGImage, duration: TimeInterval) {
        withoutActions { displayLayers[display]?.crossfade(to: image, duration: duration, reduceMotion: model.reduceMotion) }
        startDisplayLinkIfNeeded()
    }

    func setTileConcealed(display: StageDisplay.ID, _ concealed: Bool) {
        guard flights[display] != nil else { return }
        withoutActions {
            // A reduced-motion fade must not override the hero's immediate handoff.
            displayLayers[display]?.content.removeAnimation(forKey: "opacity")
            displayLayers[display]?.content.opacity = concealed ? 0 : 1
        }
    }

    func shake(card: StageCard.ID) {
        guard let tile = cardLayers[card] else { return }
        guard !model.reduceMotion else {
            StageLayerStyle.pulseOpacity(tile.layer)
            return
        }
        tile.shakeElapsed = 0
        startDisplayLinkIfNeeded()
    }

    func escape() -> Bool {
        guard !model.interactionBlocked else { return false }
        if dragging {
            withoutActions { endDrag(cancelled: true) }
            startDisplayLinkIfNeeded()
            return true
        }
        guard progress.value > 0 || progress.target > 0 else { return false }
        setProgress(0, animated: true)
        return true
    }

    func shake(display: StageDisplay.ID) {
        guard let shell = displayLayers[display] else { return }
        #if DEBUG
        debugShakenDisplays.append(display)
        #endif
        withoutActions { shell.shake(reduceMotion: model.reduceMotion) }
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
        !progress.isSettled || !row.isSettled || !waveStrength.isSettled || !arrangementInset.isSettled
            || (dragging && !model.reduceMotion)
            || ghost.destination != nil
            || displayLayers.values.contains(where: \.hasAnimation)
            || flights.values.contains { !$0.spring.isSettled }
            || cardLayers.values.contains {
                !$0.lift.isSettled || !$0.hover.isSettled || $0.shakeElapsed != nil
                    || (staggerToGrid && !$0.gridProgress.isSettled)
            }
    }

    private func startDisplayLinkIfNeeded() {
        guard isAnimating else {
            stopDisplayLink()
            return
        }
        #if DEBUG
        debugFrameDriverRequests += 1
        #endif
        guard displayLink == nil, let screen = window?.screen else { return }
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
        // One clock for the whole frame: the springs clamp a hitch, so the stagger and shake timers
        // have to as well, or a single stutter spends the entire stagger schedule while the
        // transition it staggers has barely moved.
        let dt = min(dt, StageSpring.maximumStep)
        withoutActions {
            if model.reduceMotion {
                settleReducedMotion()
            }
            progress.step(dt: dt)
            row.step(dt: dt)
            waveStrength.step(dt: dt)
            arrangementInset.step(dt: dt)
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
            // SwiftUI takes over on the snap event, once the last staggered card has landed.
            if snapInFlight, progress.isSettled, cardsHaveLanded {
                finishSnap()
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
        removeGridScrollMonitor()
        if let window {
            gridScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                return forwardGridScroll(event)
            }
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
            withoutActions {
                for (id, flight) in flights {
                    displayLayers[id]?.restoreContent()
                    flight.continuation?.resume()
                }
                flights.removeAll()
                render()
            }
        }
    }

    func detach() {
        attached = false
        removeGridScrollMonitor()
        withoutActions {
            if dragging {
                endDrag(cancelled: true)
            }
            ghost.finish()
            clearHover()
            for (id, flight) in flights {
                displayLayers[id]?.restoreContent()
                flight.continuation?.resume()
            }
            flights.removeAll()
        }
        stopDisplayLink()
        snapTask?.cancel()
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

    static func shouldOwnGridScroll(
        phase: ShelfGestureController.Phase, gridAtTop: Bool, deltaY: CGFloat, wheelBurstBegan: Bool = false
    ) -> Bool {
        gridAtTop && deltaY > 0 && (phase == .began || (phase == .changed && wheelBurstBegan))
    }

    private func removeGridScrollMonitor() {
        if let gridScrollMonitor {
            NSEvent.removeMonitor(gridScrollMonitor)
            self.gridScrollMonitor = nil
        }
        ownsGridScroll = false
        ownsStageScroll = false
        lastGridWheelTime = nil
    }

    func forwardGridScroll(_ event: NSEvent) -> NSEvent? {
        guard !model.interactionBlocked, !dragging else {
            ownsGridScroll = false
            ownsStageScroll = false
            return event
        }
        let phase = Self.scrollPhase(event)
        let wheel = Self.isWheel(event)
        let wheelBurstBegan = wheel && lastGridWheelTime.map { event.timestamp - $0 > StageGeometry.snapDelay } != false
        lastGridWheelTime = wheel ? event.timestamp : nil
        // Precise deltas with no phase never come from a swipe: that is another device starting up.
        let otherDevice = event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty
        if phase == .began || wheelBurstBegan || event.phase.contains(.mayBegin) || otherDevice {
            ownsStageScroll = false
        }
        if phase == .began || wheelBurstBegan {
            ownsGridScroll = model.snappedIndex == 2 && model.progress > StageGeometry.libraryHandoffProgress && Self.shouldOwnGridScroll(
                phase: phase, gridAtTop: model.gridAtTop, deltaY: event.scrollingDeltaY, wheelBurstBegan: wheelBurstBegan
            )
        }
        guard ownsGridScroll || ownsStageScroll else { return event }
        handleScroll(event, phase: phase)
        if phase == .ended || phase == .momentumEnded {
            ownsGridScroll = false
        }
        if phase == .momentumEnded {
            ownsStageScroll = false
        }
        return nil
    }

    /// A mouse wheel notch: no phase, so its burst ends on silence rather than on a release.
    private static func isWheel(_ event: NSEvent) -> Bool {
        !event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty
    }

    private static func scrollPhase(_ event: NSEvent) -> ShelfGestureController.Phase {
        if event.momentumPhase.contains(.ended) {
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
    }

    override func scrollWheel(with event: NSEvent) {
        guard !model.interactionBlocked, !dragging else { return }
        let phase = Self.scrollPhase(event)
        // AppKit routes every event by the pointer: unclaimed, the rest of the swipe goes to whatever is under it by then.
        if phase == .began || Self.isWheel(event) {
            ownsStageScroll = true
        }
        handleScroll(event, phase: phase)
    }

    private func handleScroll(_ event: NSEvent, phase: ShelfGestureController.Phase) {
        raisedForFileDrag = nil
        if phase == .began {
            // Fingers coming down catch a snap in flight: stop it where it is so the gesture tracks
            // from what is on screen, instead of a baseline the spring keeps moving underneath it.
            withoutActions {
                freezeSprings()
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
                redirectStagger(to: value)
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

    private func freezeSprings() {
        snapTask?.cancel()
        snapInFlight = false
        progress.jump(to: progress.value)
        row.jump(to: row.value)
        // Not `staggerToGrid = false`: the cards are spread across the transition, and the render
        // source may not change under one that is off the pace. `advance` drops the flag once they
        // have all reached the finger.
        redirectStagger(to: progress.value)
        for tile in cardLayers.values {
            if !staggerToGrid {
                tile.gridProgress.jump(to: tile.gridProgress.value)
            }
            tile.lift.jump(to: tile.lift.value)
            tile.hover.jump(to: tile.hover.value)
        }
    }

    /// Hands a running stagger to the finger: every card springs to `value` from wherever it is,
    /// instead of the render source switching back to the global progress in one frame.
    private func redirectStagger(to value: Double) {
        guard staggerToGrid else { return }
        for tile in cardLayers.values {
            tile.gridProgress.target = value
            tile.staggerRemaining = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !model.interactionBlocked else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            if !escape() {
                super.keyDown(with: event)
            }
            return
        }
        // Changing state mid-drag would move the drop targets out from under the ghost.
        guard !dragging else { return }
        if event.keyCode == 123 || event.keyCode == 124 {
            guard progress.value >= StageGeometry.cardTapMinimumProgress, progress.value < 2,
                  let index = ShelfGestureController.nextCardIndex(
                      right: event.keyCode == 124, focusedIndex: focusedCardIndex, count: cards.count
                  ) else { return }
            focusCard(at: index)
            return
        }
        // Return, keypad Enter and Space open the focused card — the same event `tap(at:)` and the
        // "Preview" action send, under the arrows' conditions. Applying is destructive and stays on
        // the accessibility action, which asks first.
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 {
            guard progress.value >= StageGeometry.cardTapMinimumProgress, progress.value < 2,
                  let index = focusedCardIndex, cards.indices.contains(index) else { return }
            model.emit(.cardTapped(cards[index].id))
            return
        }
        guard event.keyCode == 126 || event.keyCode == 125 else {
            super.keyDown(with: event)
            return
        }
        raisedForFileDrag = nil
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
            shapes: placements.map {
                // A card faded out past the end of the flow is not there to be grabbed.
                $0.opacity < 0.05 ? StageGeometry.CardShape(rect: .null) : StageGeometry.hitShape($0, style: style)
            },
            order: placements.map(\.depthOrder)
        )
        return hit.map { cardWindow.lowerBound + $0 }
    }

    /// The shape the hovered card occupies once it has lifted and turned to face the viewer. It is
    /// consulted only where the rest layout owns nothing, so it cannot capture a neighbour's slot.
    private func hoverLiftedShape(for index: Int) -> StageGeometry.CardShape? {
        guard cardWindow.contains(index), progress.value >= StageGeometry.cardTapMinimumProgress else { return nil }
        let style = model.shelfStyle
        var placement = cardPlacement(style: style, index: index, count: cards.count, progress: progress.value)
        guard placement.opacity >= 0.05 else { return nil }
        let rest = StageGeometry.hitShape(placement, style: style)
        guard !model.reduceMotion else { return rest }
        placement.lift(by: StageGeometry.waveLift(style: style, index: index, hovered: index))
        let lifted = StageGeometry.hitShape(placement, style: style, hover: 1)
        return rest.union(lifted)
    }

    private var hoveredIndex: Int? {
        model.hoveredCard.flatMap { id in cards.firstIndex { $0.id == id } }
    }

    /// 0…1 for how close the pointer is to the card row at rest, easing in over `waveApproach`
    /// above or below it. A hover set without a pointer gets the whole wave.
    private var pointerApproach: Double {
        // A hovered card has lifted past the ramp; measured from the resting row it would sink out
        // from under the pointer that is holding it up.
        guard let pointer, hoveredIndex == nil else { return hoveredIndex == nil ? 0 : 1 }
        let top = StageGeometry.shelfRowTop(progress: progress.value, windowSize: bounds.size)
        let distance = max(0, top - pointer.y, pointer.y - top - StageGeometry.cardSize.height)
        let t = min(max(1 - distance / StageGeometry.waveApproach, 0), 1)
        return Double(t * t * (3 - 2 * t))
    }

    /// The rest layout decides first, always. The wave has to hand the pointer from slot to slot as
    /// it travels, so a shape the hover itself produced must never win the pointer back — that is
    /// what turns a continuous wave into a card that sticks for four slots and then jumps.
    /// The hovered card only claims what the rest layout leaves empty: the strip its lift uncovered.
    func cardIndex(at point: CGPoint) -> Int? {
        if let index = restCardIndex(at: point) {
            return index
        }
        // The lift uncovers a band above the row that belongs to no card at rest. Resolve it by
        // slot, not by "whoever is hovered": handing the whole band to one card stops the wave
        // dead the moment the pointer strays above the row.
        // The centred styles have no slots and lift only the hovered card, so the band is its own.
        let owner = model.shelfStyle.isCentred ? hoveredIndex : slotIndex(atX: point.x)
        guard hoveredIndex != nil, let index = owner,
              let band = hoverLiftedShape(for: index), band.contains(point) else { return nil }
        return index
    }

    /// Where the x sits in slot units — the inverse of `rowFrame`, so it stays true while the row
    /// scrolls. Fractional: 3.5 is halfway between cards 3 and 4.
    private func slotPosition(atX x: CGFloat?) -> CGFloat? {
        guard let x, !model.shelfStyle.isCentred, !cards.isEmpty else { return nil }
        let first = cardPlacement(style: model.shelfStyle, index: 0, count: cards.count, progress: progress.value)
        return (x - first.frame.minX) / StageGeometry.metrics(for: model.shelfStyle).pitch
    }

    private func slotIndex(atX x: CGFloat) -> Int? {
        guard let slot = slotPosition(atX: x).map({ Int($0.rounded(.down)) }) else { return nil }
        return cardWindow.contains(slot) ? slot : nil
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
            if model.shelfStyle == .focusRow, progress.value < StageGeometry.libraryHandoffProgress,
               index != Int(focus.rounded()) {
                focusCard(at: index)
                return
            }
            model.emit(.cardTapped(cards[index].id))
        } else if let id = displayID(at: point), let shell = displayLayers[id] {
            let local = shell.layer.convert(point, from: layer)
            if let action = shell.playbackAction(at: local) {
                model.emit(.playbackTapped(id, action))
            } else if let action = shell.emptyAction(at: local) {
                model.emit(.emptyActionTapped(id, action))
            } else {
                model.emit(.displayTapped(id))
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !model.interactionBlocked, flights.isEmpty else { return }
        pointer = convert(event.locationInWindow, from: nil)
        resolveHover()
        withoutActions { render() }
        startDisplayLinkIfNeeded()
    }

    /// Parks the pointer without an `NSEvent`, so a test can move the row under a still pointer.
    func setPointerForTesting(_ point: CGPoint) {
        pointer = point
        resolveHover()
        withoutActions { render() }
    }

    var cardWindowForTesting: Range<Int> {
        cardWindow
    }

    /// Hover belongs to a point on screen, not to a card id. The row scrolls and springs under a
    /// still pointer, so re-resolving only on `mouseMoved` leaves the wave on a card that has
    /// already slid away.
    private func resolveHover() {
        guard let pointer, !model.interactionBlocked, flights.isEmpty else { return }
        model.report(hoveredCard: cardIndex(at: pointer).map { cards[$0].id })
        model.report(hoveredDisplay: displayID(at: pointer))
    }

    override func mouseExited(with _: NSEvent) {
        clearHover()
        withoutActions { render() }
        startDisplayLinkIfNeeded()
    }

    private func clearHover() {
        pointer = nil
        model.report(hoveredCard: nil)
        model.report(hoveredDisplay: nil)
        model.report(dropTarget: nil)
        model.report(shelfDropTargeted: false)
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
        // A SwiftUI page can cover this AppKit view while it remains mounted for the return animation.
        guard !model.interactionBlocked else { return false }
        guard clicking, !dragging else { return true }
        return cardIndex(at: point) != nil || displayID(at: point) != nil
    }

    override func mouseDown(with event: NSEvent) {
        guard !model.interactionBlocked else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        gesture.mouseDown(at: point)
        if let index = cardIndex(at: point) {
            focusCard(at: index, reveal: false)
            pressedCard = cards[index].id
        } else {
            pressedCard = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !model.interactionBlocked else { return }
        let point = convert(event.locationInWindow, from: nil)
        withoutActions {
            if !dragging, gesture.shouldStartDrag(at: point), let card = cards.first(where: { $0.id == pressedCard }), card.isDraggable {
                // A snap still flying to the grid hands the page to SwiftUI when it lands, which
                // would cover the drag; the press becomes a cancelled click instead.
                guard progress.target != 2 || progress.isSettled else {
                    pressedCard = nil
                    return
                }
                dragging = true
                ownsStageScroll = false
                snapTask?.cancel()
                clearHover()
                ghost.begin(card: card, at: point, reduceMotion: model.reduceMotion)
                NSCursor.closedHand.set()
                render()
            }
            guard dragging else { return }
            ghost.x.target = point.x
            ghost.y.target = point.y
            let target = displayID(at: point)
            model.report(dropTarget: target)
            ghost.scale.target = target == nil ? 1 : 0.8
            if model.reduceMotion {
                ghost.x.jump(to: point.x)
                ghost.y.jump(to: point.y)
                ghost.scale.jump(to: 1)
            }
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
            ghost.finish(reduceMotion: true)
        }
        // Starting the drag cancelled the snap that would have landed a scroll, and nothing else will.
        if attached, progress.target != progress.target.rounded() || (!snapInFlight && progress.value != progress.value.rounded()) {
            gesture.reset()
            gesture.adopt(rowOffset: CGFloat(row.value))
            setProgress(Double(StageGeometry.snapTarget(for: progress.value)), animated: !model.reduceMotion)
        }
        render()
    }

    /// AppKit asks this for a right-click and a Control-click alike.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !model.interactionBlocked, !dragging else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let sections = if let index = cardIndex(at: point) {
            model.cardMenu?(cards[index].id)
        } else {
            displayID(at: point).flatMap { model.displayMenu?($0) }
        }
        guard let sections, !sections.isEmpty else { return nil }
        return StageContextMenu(sections: sections)
    }

    // MARK: Finder drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // A record from another drag, whose end never reached the stage.
        if raisedForFileDrag != sender.draggingSequenceNumber {
            raisedForFileDrag = nil
        }
        return fileDragOperation(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileDragOperation(sender)
    }

    /// Leaves a raised shelf up: it sits on the window's bottom edge, and a drag overshooting that
    /// edge is common enough that lowering here would bob the shelf down and up.
    override func draggingExited(_: (any NSDraggingInfo)?) {
        trackFileDrag(at: nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        trackFileDrag(at: nil)
        endFileDrag(session: sender.draggingSequenceNumber)
    }

    override func concludeDragOperation(_: (any NSDraggingInfo)?) {
        trackFileDrag(at: nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        sender.animatesToDestination = !model.reduceMotion
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return false }
        if let id = displayID(at: point), let shell = displayLayers[id] {
            // Where the dragged images land: inside the screen the file was dropped on.
            let destination = shell.content.convert(shell.content.bounds, to: layer)
            sender.enumerateDraggingItems(
                for: self, classes: [NSURL.self], searchOptions: [.urlReadingFileURLsOnly: true]
            ) { item, _, _ in
                item.draggingFrame = destination
            }
        }
        return acceptFileDrop(urls, at: point)
    }

    private func fileDragOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let carriesFiles = sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
        let point = carriesFiles ? convert(sender.draggingLocation, from: nil) : nil
        return trackFileDrag(at: point, session: sender.draggingSequenceNumber) == nil ? [] : .copy
    }

    /// A display takes the file even where its shell reaches into the shelf band; the band takes it
    /// only while the shelf is not on its way to the grid.
    private func fileDropTarget(at point: CGPoint) -> StageFileDropTarget? {
        if let id = displayID(at: point) {
            return .display(id)
        }
        guard progress.target <= 1, point.y >= StageGeometry.shelfDropTop(windowSize: bounds.size) else { return nil }
        return .shelf
    }

    /// Lights what a Finder file is over, a display or the shelf band, and raises a hidden shelf for
    /// the band; nil where nothing takes it, which also clears the light.
    @discardableResult
    func trackFileDrag(at point: CGPoint?, session: Int = 0) -> StageFileDropTarget? {
        let target = model.interactionBlocked ? nil : point.flatMap(fileDropTarget(at:))
        let display: StageDisplay.ID? = if case let .display(id) = target {
            id
        } else {
            nil
        }
        model.report(dropTarget: display)
        model.report(shelfDropTargeted: target == .shelf)
        if target == .shelf, progress.target < 1 {
            raisedForFileDrag = session
            setProgress(1, animated: !model.reduceMotion)
        }
        withoutActions { render() }
        startDisplayLinkIfNeeded()
        return target
    }

    /// Lowers a shelf this drag raised: Esc, a drop in another app and a drop on a display all end here.
    func endFileDrag(session: Int) {
        guard raisedForFileDrag == session else { return }
        raisedForFileDrag = nil
        setProgress(0, animated: !model.reduceMotion)
    }

    /// Any file is taken: an unsupported one is turned down after the drop, with a toast, and on a
    /// display with a shake too.
    func acceptFileDrop(_ urls: [URL], at point: CGPoint) -> Bool {
        defer { trackFileDrag(at: nil) }
        guard !model.interactionBlocked, !urls.isEmpty, let target = fileDropTarget(at: point) else { return false }
        switch target {
        case let .display(id):
            model.emit(.filesDropped(urls, onto: id))
        case .shelf:
            // The new card lands on this shelf, so the drag's end leaves it up.
            raisedForFileDrag = nil
            model.emit(.filesDroppedOnShelf(urls))
        }
        return true
    }

    // MARK: Accessibility and backing

    private func focusCard(at index: Int, reveal: Bool = true) {
        focusedCardIndex = index
        window?.makeFirstResponder(self)
        withoutActions {
            let style = model.shelfStyle
            if reveal, style.isCentred {
                jumpRow(to: -Double(index) * StageGeometry.metrics(for: style).pitch)
            } else if reveal {
                let placement = cardPlacement(style: style, index: index, count: cards.count, progress: 1)
                let band = StageGeometry.shelfBand(style: style, capacity: model.shelfRenderBudget, windowSize: bounds.size)
                let x = placement.frame.minX
                jumpRow(to: row.value + min(max(x, band.lowerBound), band.upperBound) - x)
            }
            gesture.adopt(rowOffset: row.value)
            render()
        }
        startDisplayLinkIfNeeded()
        for element in cardAccessibility.values {
            element.setAccessibilityFocused(element.cardID == cards[index].id)
        }
        if let element = cardAccessibility[cards[index].id] {
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    private func updateCardFocusRing() {
        guard let index = focusedCardIndex, cardWindow.contains(index),
              progress.value >= StageGeometry.cardTapMinimumProgress, progress.value < 2,
              !dragging, !model.interactionBlocked, window == nil || window?.firstResponder === self else {
            cardFocusRing.isHidden = true
            return
        }
        guard let tile = cardLayers[cards[index].id] else { return }
        let shape = tile.hitShape
        cardFocusRing.bounds = CGRect(origin: .zero, size: shape.rect.size)
        cardFocusRing.position = CGPoint(x: shape.rect.midX, y: shape.rect.midY)
        cardFocusRing.transform = CATransform3DMakeRotation(shape.rotationZDegrees * .pi / 180, 0, 0, 1)
        cardFocusRing.cornerRadius = tile.face.cornerRadius
        cardFocusRing.zPosition = (cardLayers.values.map(\.layer.zPosition).max() ?? 0) + 1
        cardFocusRing.isHidden = false
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        withoutActions { updateCardFocusRing() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            withoutActions { cardFocusRing.isHidden = true }
        }
        return accepted
    }

    /// Which halves the stage may list, read off the same quantities the mouse uses: the
    /// arrangement's own opacity, and the progress past which the library grid is mounted on top
    /// and lists every tile itself.
    private var accessibilityExposureNow: (displays: Bool, cards: Bool) {
        let handedOver = progress.value >= StageGeometry.libraryHandoffProgress
        return (displays: !handedOver && arrangementLayer.opacity > 0, cards: !handedOver)
    }

    private func emptyScreenAction(
        _ name: String, on id: StageDisplay.ID, _ action: EmptyScreenAction
    ) -> NSAccessibilityCustomAction {
        StageAccessibilityElement.customAction(name: name) { [weak self] in
            guard let self, !model.interactionBlocked, arrangementLayer.opacity > 0 else { return false }
            model.emit(.emptyActionTapped(id, action))
            return true
        }
    }

    private func rebuildAccessibility() {
        let liveCards = Set(cards.map(\.id))
        let liveDisplays = Set(displays.map(\.id))
        cardAccessibility = cardAccessibility.filter { liveCards.contains($0.key) }
        displayAccessibility = displayAccessibility.filter { liveDisplays.contains($0.key) }
        accessibilityExposure = accessibilityExposureNow
        accessibilityItems = (accessibilityExposure.displays ? displays : []).map { display in
            let id = display.id
            let element: StageAccessibilityElement
            if let existing = displayAccessibility[id] {
                element = existing
            } else {
                element = StageAccessibilityElement { [weak self] in
                    // The same gate `displayID(at:)` reads, so a press cannot open a display that
                    // has faded out from under VoiceOver's cursor.
                    guard let self, !model.interactionBlocked, arrangementLayer.opacity > 0 else { return false }
                    model.emit(.displayTapped(id))
                    return true
                }
                displayAccessibility[id] = element
            }
            element.setAccessibilityRole(.button)
            element.setAccessibilityEnabled(!model.interactionBlocked)
            element.setAccessibilityLabel([display.name, display.statusText].filter { !$0.isEmpty }.joined(separator: ", "))
            element.setAccessibilityValue(display.accessibilityValue)
            element.setAccessibilityParent(self)
            element.displayID = id
            // The keyboard equivalent of the two buttons drawn inside an empty display.
            element.setAccessibilityCustomActions(display.state == .empty ? [
                emptyScreenAction(String(localized: "Choose File", bundle: .appLanguage), on: id, .chooseFile),
                emptyScreenAction(String(localized: "Paste URL", bundle: .appLanguage), on: id, .pasteURL),
            ] : [])
            return element
        } + (accessibilityExposure.cards ? visibleCardIndices.map { cards[$0] } : []).map { card in
            let id = card.id
            let preview: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self, !model.interactionBlocked, progress.value >= StageGeometry.cardTapMinimumProgress,
                      cards.contains(where: { $0.id == id }) else { return false }
                model.emit(.cardTapped(id))
                return true
            }
            let element: StageAccessibilityElement
            if let existing = cardAccessibility[id] {
                element = existing
            } else {
                element = StageAccessibilityElement(press: preview)
                element.setAccessibilityCustomActions([
                    StageAccessibilityElement.customAction(name: String(localized: "Apply", bundle: .appLanguage)) { [weak self] in
                        guard let self, !model.interactionBlocked, progress.value >= StageGeometry.cardTapMinimumProgress,
                              cards.contains(where: { $0.id == id }) else { return false }
                        model.emit(.cardApplyRequested(id))
                        return true
                    },
                    StageAccessibilityElement.customAction(name: String(localized: "Preview", bundle: .appLanguage), action: preview),
                ])
                cardAccessibility[id] = element
            }
            element.setAccessibilityRole(.button)
            element.setAccessibilityEnabled(!model.interactionBlocked)
            element.setAccessibilityLabel(card.title + " " + card.metaLine)
            element.setAccessibilityParent(self)
            element.cardID = id
            return element
        }
        setAccessibilityChildren(accessibilityItems)
    }

    private func updateAccessibilityFrames() {
        for element in accessibilityItems {
            element.setAccessibilityEnabled(!model.interactionBlocked)
            // An AX frame can only be an axis-aligned rect, so take the bounding box of the turned shape.
            let local: CGRect? = if let id = element.displayID {
                displayLayers[id].map { $0.layer.convert($0.layer.bounds, to: layer) }
            } else if let id = element.cardID {
                cardLayers[id]?.hitRect
            } else {
                nil
            }
            guard let local else { continue }
            let rect = convert(local, to: nil)
            element.setAccessibilityFrame(window?.convertToScreen(rect) ?? rect)
        }
    }

    #if DEBUG
    /// Counts the calls made while something was still animating; off-screen there is no link to
    /// observe, so this is the only way a test can see a render asking for frames.
    private(set) var debugFrameDriverRequests = 0

    /// Every `shake(display:)`, in order; the shake itself leaves nothing a test can read once it settles.
    private(set) var debugShakenDisplays: [StageDisplay.ID] = []

    var debugFlightHomes: [StageDisplay.ID: CGRect] {
        flights.mapValues(\.home)
    }

    var debugFocusedCardIndex: Int? {
        focusedCardIndex
    }

    var debugFocusRingFrame: CGRect? {
        cardFocusRing.isHidden ? nil : cardFocusRing.frame
    }

    var debugFocusRing: CALayer {
        cardFocusRing
    }

    var debugStaggerToGrid: Bool {
        staggerToGrid
    }

    /// The stage's own progress spring only; the staggered cards keep their own.
    var debugProgressSettled: Bool {
        progress.isSettled
    }

    var debugDragging: Bool {
        dragging
    }

    /// Where the row is heading, which is not where it is while the spring is still flying.
    var debugRowTarget: Double {
        row.target
    }

    var debugArrangementLayer: CALayer {
        arrangementLayer
    }

    var debugShelfLayer: CALayer {
        shelfLayer
    }

    var debugNeedsDisplayLink: Bool {
        isAnimating
    }

    var debugSpringsSettled: Bool {
        progress.isSettled && row.isSettled && arrangementInset.isSettled
            && ghost.x.isSettled && ghost.y.isSettled && ghost.scale.isSettled && ghost.flight.isSettled
            && flights.values.allSatisfy(\.spring.isSettled)
            && (Array(cardLayers.values) + reserve).allSatisfy { $0.lift.isSettled && $0.hover.isSettled && $0.gridProgress.isSettled }
    }
    #endif

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

    nonisolated static func customAction(name: String, action: @escaping @MainActor @Sendable () -> Bool) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name) {
            MainActor.assumeIsolated { action() }
        }
    }

    override nonisolated func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated { action() }
    }
}

/// Holds the host's closures for as long as AppKit shows the menu; an item's tag indexes its closure.
@MainActor
private final class StageContextMenu: NSMenu {
    private var actions: [@MainActor () -> Void] = []

    init(sections: [[StageMenuItem]]) {
        super.init(title: "")
        autoenablesItems = false
        for (index, section) in sections.enumerated() {
            if index > 0 {
                addItem(.separator())
            }
            add(section, to: self)
        }
    }

    /// A submenu's rows target this menu too, which holds every closure.
    private func add(_ entries: [StageMenuItem], to menu: NSMenu) {
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.isEnabled
            if entry.submenu.isEmpty {
                item.action = #selector(runAction(_:))
                item.target = self
                item.tag = actions.count
                actions.append(entry.action)
            } else {
                let submenu = NSMenu(title: entry.title)
                submenu.autoenablesItems = false
                add(entry.submenu, to: submenu)
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func runAction(_ item: NSMenuItem) {
        actions[item.tag]()
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
