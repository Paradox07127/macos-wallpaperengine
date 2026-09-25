import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
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
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "Meta", thumbnail: nil, nowPlaying: nil, isDraggable: true)
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

    @Test("Manual and policy pauses render distinct text in the existing top-right pause pill")
    func pausePillText() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        var display = model.displays[0]
        let manual = String(localized: "Paused", bundle: .appLanguage)
        let policy = try #require(SuspendReasonText.localized(for: [.battery]))
        #expect(manual != policy)
        for text in [manual, policy] {
            display.state = .paused(reasonText: text)
            shell.update(display: display, dropHint: "", increasedContrast: false)
            shell.layoutContent()
            let group = try #require(shell.content.sublayers?.first { layer in
                layer.sublayers?.contains { ($0 as? CATextLayer)?.string as? String == text } == true
            })
            let label = try #require(group.sublayers?.compactMap { $0 as? CATextLayer }.first)
            #expect(!group.isHidden && !label.isHidden)
            #expect(abs(group.frame.maxX - (shell.content.bounds.width - 10)) < 0.00000001)
            #expect(group.sublayers?.contains { !($0 is CATextLayer) && !$0.isHidden && $0.contents != nil } == true)
        }
    }

    @Test("Rest states agree with geometry, and the grid state hands its accessibility children over")
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
        // The loop leaves the stage at p = 2, where the SwiftUI grid is on top and lists every tile
        // itself; a stage copy would read each wallpaper out twice.
        #expect(view.accessibilityChildren()?.isEmpty == true)
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
        // The lift is derived from the hover now, so raise it the way the pointer does.
        model.report(hoveredCard: "card-5")
        for _ in 0 ..< 60 {
            view.advance(dt: 1.0 / 60)
        }
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

    @Test("A fan card all but faded out at the arc's end cannot be grabbed; the card drawn under it takes the pointer")
    func fadedFanCardsAreNotGrabbable() throws {
        let model = makeModel()
        model.shelfStyle = .fan
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        // 64pt of row turns card 8 to 15.9°: nearly gone, but still built.
        try view.scrollWheel(with: scroll(x: -64))
        let far = StageGeometry.cardPlacement(
            style: .fan, index: 8, count: 14, progress: 1, focus: 64.0 / 60, windowSize: view.bounds.size
        )
        try #require(far.opacity > 0 && far.opacity < 0.05, Comment(rawValue: "card 8 should be all but invisible: \(far.opacity)"))
        try #require(view.cardWindowForTesting.contains(8))
        #expect(view.cardIndex(at: CGPoint(x: far.frame.midX, y: far.frame.midY)) == 7)
    }

    @Test("A library bigger than the shelf only builds layers for the slice on screen")
    func shelfWindowsTheLibrary() {
        let model = makeModel()
        model.shelfItems = (0 ..< 120).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "Meta", thumbnail: nil, nowPlaying: nil, isDraggable: true)
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

    @Test("Increase Contrast swaps the stage's stroke tier; Reduce Motion leaves every stroke alone")
    func increaseContrastReachesTheLayers() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        model.setProgress(2, animated: false)
        let wallpapered = try #require(view.displayLayers[1])
        let empty = try #require(view.displayLayers[2])
        let card = try #require(view.cardLayers["card-0"])

        // Why the stage takes a flag rather than drawing under a high-contrast appearance: AppKit
        // hands the token provider plain `darkAqua` while the system setting is off, so the tier
        // the appearance was asked for never arrives.
        var underHighContrastAppearance: CGFloat = -1
        NSAppearance(named: .accessibilityHighContrastDarkAqua)?.performAsCurrentDrawingAppearance {
            underHighContrastAppearance = NSColor(DesignTokens.EditDesk.Colors.strokeShell).cgColor.alpha
        }
        #expect(underHighContrastAppearance == 0.25, Comment(rawValue: "\(underHighContrastAppearance)"))

        let restShell = try #require(wallpapered.normalStroke).alpha
        let restEmpty = try #require(empty.normalStroke).alpha
        let restRing = try #require(card.thumbnail.borderColor).alpha
        // S9 gives the empty display its own `1px dashed .4`; the wallpapered shell stays on .25.
        #expect(restShell == 0.25, Comment(rawValue: "\(restShell)"))
        #expect(restEmpty == 0.40, Comment(rawValue: "\(restEmpty)"))
        #expect(restRing == 0.10, Comment(rawValue: "\(restRing)"))

        model.increaseContrast = true
        await Task.yield()
        let hotShell = try #require(wallpapered.normalStroke).alpha
        let hotEmpty = try #require(empty.normalStroke).alpha
        let hotRing = try #require(card.thumbnail.borderColor).alpha
        // GAP §6's tiers, and the proof that `Increased` has not drifted from `ink(contrast:)`.
        #expect(hotShell == 0.65, Comment(rawValue: "shell \(restShell) → \(hotShell)"))
        #expect(hotEmpty == 0.80, Comment(rawValue: "empty shell \(restEmpty) → \(hotEmpty)"))
        #expect(hotRing == 0.35, Comment(rawValue: "inner ring \(restRing) → \(hotRing)"))

        // Control: the other accessibility input the stage carries must not move a single stroke.
        model.increaseContrast = false
        await Task.yield()
        model.reduceMotion = !model.reduceMotion
        await Task.yield()
        let backShell = try #require(wallpapered.normalStroke).alpha
        let backEmpty = try #require(empty.normalStroke).alpha
        let backRing = try #require(card.thumbnail.borderColor).alpha
        #expect(backShell == restShell, Comment(rawValue: "shell \(restShell) → \(backShell)"))
        #expect(backEmpty == restEmpty, Comment(rawValue: "empty shell \(restEmpty) → \(backEmpty)"))
        #expect(backRing == restRing, Comment(rawValue: "inner ring \(restRing) → \(backRing)"))
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
            StageCard(id: "other-\($0)", title: "Other \($0)", metaLine: "Meta", thumbnail: nil, nowPlaying: nil, isDraggable: true)
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

    @Test("⌥-click on a shelf card asks to apply it; a plain click still opens it", .timeLimit(.minutes(1)))
    func optionClickAppliesTheCard() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
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
        let point = CGPoint(x: frame.minX + 8, y: frame.midY)
        try #require(view.cardIndex(at: point) == 3)
        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view, modifiers: .option))
        try view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view, modifiers: .option))
        // Bound first: an awaited operand is not printed when the expectation fails.
        let optionClick = await events.next()
        #expect(optionClick == .cardApplyRequested("card-3"))
        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        try view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))
        let plainClick = await events.next()
        #expect(plainClick == .cardTapped("card-3"))
    }

    @Test("Focus Row side clicks centre first and only the centred card opens", arguments: [false, true])
    func focusRowSideClickCentresBeforeOpening(reduceMotion: Bool) async throws {
        let model = makeModel()
        model.shelfStyle = .focusRow
        model.reduceMotion = reduceMotion
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        var events = model.events.makeAsyncIterator()
        #expect(await events.next() == .snapped(1))
        let side = try #require(view.cardLayers["card-2"])
        let point = CGPoint(x: side.hitRect.midX, y: side.hitRect.midY)
        try #require(view.cardIndex(at: point) == 2)
        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        #expect(view.debugFocusedCardIndex == 2)
        try view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))
        #expect(abs(view.debugRowTarget - -2 * StageGeometry.metrics(for: .focusRow).pitch) < 0.001)
        for _ in 0 ..< 120 {
            view.advance(dt: 1 / 60)
        }
        #expect(abs(side.frame.midX - view.bounds.midX) < 0.001)
        // A following snap makes an unwanted tap observable without waiting on a silent stream.
        model.setProgress(1, animated: false)
        #expect(await events.next() == .snapped(1), "centring and settling must not open the card")
        let centre = CGPoint(x: side.hitRect.midX, y: side.hitRect.midY)
        try #require(view.cardIndex(at: centre) == 2)
        try view.mouseDown(with: mouse(.leftMouseDown, at: centre, in: view))
        try view.mouseUp(with: mouse(.leftMouseUp, at: centre, in: view))
        #expect(await events.next() == .cardTapped("card-2"))
    }

    @Test("Focus Row centre and grid cards, a fan side card, crate and folders open on the first click")
    func shelfSingleClickControls() async throws {
        for (style, progress, index) in [
            (ShelfStyle.focusRow, 1.0, 0), (.focusRow, 2.0, 2), (.fan, 1.0, 3), (.crate, 1.0, 3), (.folders, 1.0, 3),
        ] {
            let model = makeModel()
            model.shelfStyle = style
            let view = EditDeskStageView(model: model)
            defer { view.detach() }
            view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
            view.layoutSubtreeIfNeeded()
            model.setProgress(progress, animated: false)
            var events = model.events.makeAsyncIterator()
            #expect(await events.next() == .snapped(Int(progress)))
            let tile = try #require(view.cardLayers["card-\(index)"])
            let point = CGPoint(x: tile.hitRect.minX + 8, y: tile.hitRect.midY)
            try #require(view.cardIndex(at: point) == index)
            try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
            try view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))
            #expect(await events.next() == .cardTapped("card-\(index)"))
        }
    }

    @Test("Focus Row Return, Enter, Space and VoiceOver Preview open immediately")
    func focusRowKeyboardAndPreviewOpenImmediately() async throws {
        let model = makeModel()
        model.shelfStyle = .focusRow
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        var events = model.events.makeAsyncIterator()
        #expect(await events.next() == .snapped(1))
        for _ in 0 ... 3 {
            try view.keyDown(with: key(124))
        }
        for code in [UInt16(36), 76, 49] {
            try view.keyDown(with: key(code))
            #expect(await events.next() == .cardTapped("card-3"))
        }
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let side = try #require(children.first { $0.accessibilityLabel() == "Card 4 Meta" })
        let preview = try #require(side.accessibilityCustomActions()?.first {
            $0.name == String(localized: "Preview", bundle: .appLanguage)
        })
        try #require(preview.handler?() == true)
        #expect(await events.next() == .cardTapped("card-4"))
    }

    @Test("Style round trips retain keyboard focus by identity and reveal it in each style")
    func shelfStyleRoundTripKeepsFocusedCard() throws {
        let model = makeModel()
        model.shelfItems = bigLibrary(120)
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        for _ in 0 ... 40 {
            try view.keyDown(with: key(124))
        }
        for style in [ShelfStyle.facingIn, .fan, .focusRow, .folders, .crate] {
            model.shelfItems.swapAt(40, 45)
            model.shelfStyle = style
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            let index = try #require(view.debugFocusedCardIndex)
            #expect(model.shelfItems[index].id == "card-40")
            #expect(model.visibleShelfRange.contains(index))
            let tile = try #require(view.cardLayers["card-40"])
            #expect(try sameRect(#require(view.debugFocusRingFrame), tile.hitRect))
            if style.isCentred {
                #expect(view.debugRowTarget == -Double(index) * StageGeometry.metrics(for: style).pitch)
                #expect(abs(tile.frame.midX - view.bounds.midX) < 0.001)
            } else {
                let band = StageGeometry.shelfBand(style: style, capacity: model.shelfRenderBudget, windowSize: view.bounds.size)
                #expect(tile.frame.minX >= band.lowerBound - 0.001 && tile.frame.minX <= band.upperBound + 0.001)
            }
            let before = view.debugRowTarget
            try view.scrollWheel(with: scroll(x: -24))
            #expect(abs(view.debugRowTarget - (before - 24)) < 0.001, "the gesture must adopt the new style's offset")
        }
    }

    @Test("Without keyboard focus, style changes retain the visual centre", arguments: ShelfStyle.allCases)
    func shelfStyleKeepsVisualCentre(style: ShelfStyle) throws {
        let model = makeModel()
        model.shelfStyle = style
        model.shelfItems = bigLibrary(120)
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let pitch = StageGeometry.metrics(for: style).pitch
        try view.scrollWheel(with: scroll(x: -Int32(20.25 * pitch)))
        #expect(view.debugFocusedCardIndex == nil)
        let centred = style.isCentred
        let index: Int
        if centred {
            index = 20
        } else {
            let band = StageGeometry.shelfBand(style: style, capacity: model.shelfRenderBudget, windowSize: view.bounds.size)
            let middle = (band.lowerBound + band.upperBound) / 2
            index = try #require(model.visibleShelfRange.min {
                abs((view.cardLayers[model.shelfItems[$0].id]?.frame.minX ?? .infinity) - middle)
                    < abs((view.cardLayers[model.shelfItems[$1].id]?.frame.minX ?? .infinity) - middle)
            })
        }
        let id = model.shelfItems[index].id
        model.shelfStyle = centred ? .folders : .fan
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let focused = try #require(view.debugFocusedCardIndex)
        #expect(model.shelfItems[focused].id == id)
        #expect(model.visibleShelfRange.contains(focused))
        if model.shelfStyle == .fan {
            #expect(view.debugRowTarget == -Double(index) * StageGeometry.metrics(for: .fan).pitch)
        }
    }

    @Test("Style changes fall back to row zero for empty libraries and filtered focus", arguments: [false, true])
    func shelfStyleMissingFocusFallsBackToZero(explicitFocus: Bool) throws {
        let pitch = Double(StageGeometry.metrics(for: .focusRow).pitch)
        for empty in [false, true] {
            let model = makeModel()
            model.shelfStyle = .focusRow
            let view = EditDeskStageView(model: model)
            defer { view.detach() }
            view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
            view.layoutSubtreeIfNeeded()
            model.setProgress(1, animated: false)
            if explicitFocus {
                for _ in 0 ... 5 {
                    try view.keyDown(with: key(124))
                }
            } else {
                try view.scrollWheel(with: scroll(x: -Int32(5 * pitch)))
            }
            #expect(view.debugRowTarget == -5 * pitch)
            model.shelfItems = empty ? [] : model.shelfItems.filter { $0.id != "card-5" }
            model.shelfStyle = .folders
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            #expect(view.debugRowTarget == 0)
            #expect(view.debugFocusedCardIndex == nil)
            if empty {
                for style in [ShelfStyle.crate, .fan, .focusRow, .folders] {
                    model.shelfStyle = style
                    view.needsLayout = true
                    view.layoutSubtreeIfNeeded()
                    #expect(view.debugRowTarget == 0)
                    #expect(view.debugFocusedCardIndex == nil)
                }
            } else {
                let first = try #require(view.cardLayers["card-0"])
                #expect(sameRect(first.frame, StageGeometry.rowFrame(
                    style: .folders, index: 0, count: model.shelfItems.count, focus: 0, windowSize: view.bounds.size
                )))
            }
        }
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

    @Test("Only a downward gesture that starts at the grid's top belongs to the stage")
    func gridScrollOwnership() {
        #expect(EditDeskStageView.shouldOwnGridScroll(phase: .began, gridAtTop: true, deltaY: 20))
        #expect(!EditDeskStageView.shouldOwnGridScroll(phase: .began, gridAtTop: false, deltaY: 20))
        #expect(!EditDeskStageView.shouldOwnGridScroll(phase: .momentum, gridAtTop: true, deltaY: 20))
        #expect(!EditDeskStageView.shouldOwnGridScroll(phase: .began, gridAtTop: true, deltaY: -20))
        #expect(!EditDeskStageView.shouldOwnGridScroll(phase: .changed, gridAtTop: true, deltaY: 20))
        #expect(EditDeskStageView.shouldOwnGridScroll(phase: .changed, gridAtTop: true, deltaY: 24, wheelBurstBegan: true))
        #expect(!EditDeskStageView.shouldOwnGridScroll(phase: .changed, gridAtTop: false, deltaY: 24, wheelBurstBegan: true))
    }

    @Test("A swipe the stage started keeps its end once the grid is under the pointer, so it lands instead of freezing")
    func stageKeepsTheSwipeItStarted() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        // AppKit hands the start of the swipe to the stage…
        try view.scrollWheel(with: scroll(phase: .began))
        for _ in 0 ..< 4 {
            try view.scrollWheel(with: scroll(y: -80, phase: .changed))
        }
        try #require(model.progress > StageGeometry.libraryHandoffProgress, Comment(rawValue: "the swipe only reached \(model.progress)"))
        // …and the rest to whatever is under the pointer by then, which only the monitor still sees.
        #expect(try view.forwardGridScroll(scroll(y: -20, phase: .changed)) == nil, "the rest of the swipe left the stage")
        #expect(try view.forwardGridScroll(scroll(phase: .ended)) == nil, "the release left the stage")
        for _ in 0 ..< 480 {
            view.advance(dt: 1 / 120)
        }
        #expect(
            model.progress == 2 && model.snappedIndex == 2,
            Comment(rawValue: "stuck at \(model.progress), last snapped to \(model.snappedIndex)")
        )
    }

    @Test("A swipe that starts on the grid stays the grid's")
    func gridKeepsItsOwnSwipe() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(2, animated: false)
        model.gridAtTop = false
        for event in try [scroll(phase: .began), scroll(y: 40, phase: .changed), scroll(phase: .ended)] {
            #expect(view.forwardGridScroll(event) === event, Comment(rawValue: "the stage took \(event.phase)"))
        }
        #expect(model.progress == 2 && model.snappedIndex == 2)
    }

    @Test("A finished swipe does not claim precise scrolling that arrives without phases from another device")
    func stageLetsGoOfPhaselessScrolling() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        try view.scrollWheel(with: scroll(phase: .began))
        #expect(try view.forwardGridScroll(scroll(y: -80, phase: .changed)) == nil)
        #expect(try view.forwardGridScroll(scroll(phase: .ended)) == nil)
        // A smooth-scrolling mouse: pixel deltas and no phase, so it never belonged to the swipe.
        let smooth = try scroll(y: 40)
        #expect(view.forwardGridScroll(smooth) === smooth, "a swipe with no momentum kept its claim on the next device")
    }

    @Test("A wheel burst the stage took keeps its later notches; the next burst is routed afresh")
    func stageKeepsItsWheelBurst() throws {
        func notch(at seconds: Double) throws -> NSEvent {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
            event.timestamp = CGEventTimestamp(seconds * 1_000_000_000)
            return try #require(NSEvent(cgEvent: event))
        }
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let first = try notch(at: 100)
        #expect(view.forwardGridScroll(first) === first, "the burst's first notch is AppKit's to route")
        view.scrollWheel(with: first)
        let moved = model.progress
        try #require(moved > 1)
        #expect(try view.forwardGridScroll(notch(at: 100)) == nil, "a later notch of the same burst left the stage")
        #expect(model.progress > moved)
        let later = try notch(at: 101)
        try #require(later.timestamp - first.timestamp > StageGeometry.snapDelay)
        #expect(view.forwardGridScroll(later) === later, "a burst after a pause was kept by the stage")
    }

    @Test("Expanding a scrolled thousand-card shelf prepares the grid before the flight and caps stagger")
    func gridFlightWindowAndStagger() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfItems = (0 ..< 1000).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "", thumbnail: nil, nowPlaying: nil, isDraggable: true)
        }
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -19200, wheel3: 0))
        try view.scrollWheel(with: #require(NSEvent(cgEvent: scroll)))
        let rowWindow = model.visibleShelfRange
        #expect(rowWindow.contains(400))
        #expect(!rowWindow.contains(0))
        #expect(view.cardLayers.count < 30)
        model.setProgress(2, animated: true)
        let gridWindow = StageGeometry.visibleGridCards(count: 1000, windowSize: view.bounds.size, scrollOffset: 0)
        #expect(!gridWindow.isEmpty)
        for index in gridWindow {
            #expect(view.cardLayers["card-\(index)"] != nil)
        }
        #expect(model.visibleShelfRange == rowWindow)
        #expect(model.visibleGridRange == gridWindow)
        // No card waits its turn: the stagger is in how fast each card's spring responds.
        let responses = view.cardLayers.values.map(\.gridProgress.parameters.response)
        #expect(try #require(responses.max()) <= 0.44 + 1e-9)
        #expect(try #require(responses.max()) > #require(responses.min()))
        view.advance(dt: 1 / 120)
        #expect(view.cardLayers.values.allSatisfy { $0.gridProgress.value > 1 }, "a card sat out the first frame")
        for _ in 0 ..< 480 {
            view.advance(dt: 1 / 120)
            if model.snappedIndex == 2 {
                // Handed over once landed: within half a point of the tile, not necessarily settled on it.
                for index in gridWindow {
                    let tile = try #require(view.cardLayers["card-\(index)"]).frame
                    let grid = StageGeometry.gridFrame(index: index, windowWidth: view.bounds.width)
                    let off = max(abs(tile.minX - grid.minX), abs(tile.minY - grid.minY), abs(tile.width - grid.width))
                    #expect(off <= 0.5, Comment(rawValue: "card \(index) is \(off)pt off its tile at the handover"))
                }
                break
            }
        }
        #expect(model.snappedIndex == 2)
        model.setProgress(1, animated: false)
        #expect(model.visibleShelfRange == rowWindow)
        #expect(model.visibleGridRange.isEmpty)
    }

    @Test("Reduced-motion fly and return finish synchronously and restore content ownership")
    func reducedMotionFlight() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        let original = shell.content.frame
        #expect(shell.content.cornerCurve == .continuous)
        #expect(shell.content.cornerRadius == 3)
        model.setTileConcealed(display: 1, true)
        #expect(shell.content.opacity == 1)
        #expect(shell.content.superlayer === shell.layer)
        #expect(sameRect(shell.content.frame, original))
        let destination = CGRect(x: 100, y: 100, width: 800, height: 450)
        await model.flyTile(display: 1, to: destination)
        let flightLayer = try #require(shell.content.superlayer)
        #expect(flightLayer !== shell.layer)
        #expect(shell.content.cornerRadius == 12)
        #expect(shell.content.cornerCurve == .continuous)
        model.setTileConcealed(display: 1, true)
        #expect(shell.content.opacity == 0)
        #expect(shell.content.animation(forKey: "opacity") == nil)
        #expect(shell.content.superlayer === flightLayer)
        #expect(sameRect(shell.content.frame, destination))
        #expect(!view.debugNeedsDisplayLink)
        model.setTileConcealed(display: 1, false)
        #expect(shell.content.opacity == 1)
        #expect(shell.content.animation(forKey: "opacity") == nil)
        #expect(shell.content.superlayer === flightLayer)
        #expect(sameRect(shell.content.frame, destination))
        model.setTileConcealed(display: 1, true)
        await model.returnTile(display: 1)
        #expect(shell.content.opacity == 1)
        #expect(shell.content.superlayer === shell.layer)
        #expect(sameRect(shell.content.frame, original))
        #expect(shell.content.cornerRadius == 3)
        #expect(flightLayer.sublayers?.isEmpty != false)
    }

    @Test("Unplug, detach and window removal restore concealed content and release an awaiting flight", arguments: ["unplug", "detach", "window"])
    func interruptedFlightRestoresOwnership(exit: String) async throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer {
            view.detach()
            window.contentView = nil
        }
        try #require(window.screen != nil)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        let original = shell.content.frame
        let flight = Task { await model.flyTile(display: 1, to: CGRect(x: 100, y: 100, width: 800, height: 450)) }
        while shell.content.superlayer === shell.layer {
            await Task.yield()
        }
        let flightLayer = try #require(shell.content.superlayer)
        #expect(!view.debugSpringsSettled)
        model.setTileConcealed(display: 1, true)
        switch exit {
        case "unplug":
            model.displays.removeFirst()
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            #expect(view.displayLayers[1] == nil)
        case "detach":
            view.detach()
            #expect(model.engine == nil)
        default:
            window.contentView = nil
        }
        await flight.value
        #expect(shell.content.superlayer === shell.layer)
        #expect(shell.content.opacity == 1)
        #expect(sameRect(shell.content.frame, original))
        #expect(flightLayer.sublayers?.isEmpty != false)
        view.setTileConcealed(display: 1, true)
        #expect(shell.content.opacity == 1, "the exit must also drop the flight")
    }

    @Test("A superseded await resumes and its replacement still returns to the shell's home")
    func supersededFlight() async throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer {
            view.detach()
            window.contentView = nil
        }
        try #require(window.screen != nil)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        let original = shell.content.frame
        let home = shell.content.convert(shell.content.bounds, to: view.layer)
        let first = Task { await model.flyTile(display: 1, to: CGRect(x: 50, y: 50, width: 700, height: 400)) }
        while shell.content.superlayer === shell.layer {
            await Task.yield()
        }
        view.advance(dt: 1 / 60)
        model.setTileConcealed(display: 1, true)
        let destination = CGRect(x: 100, y: 100, width: 800, height: 450)
        let second = Task { await model.flyTile(display: 1, to: destination) }
        await first.value
        #expect(shell.content.opacity == 1)
        #expect(try sameRect(#require(view.debugFlightHomes[1]), home))
        #expect(!view.debugSpringsSettled, "a superseded await returns before its replacement settles")
        for _ in 0 ..< 240 {
            view.advance(dt: 1 / 120)
        }
        await second.value
        #expect(sameRect(shell.content.frame, destination))
        model.setTileConcealed(display: 1, true)
        let returning = Task { await model.returnTile(display: 1) }
        while shell.content.opacity == 0 {
            await Task.yield()
        }
        #expect(shell.content.superlayer !== shell.layer, "return reveals before it finishes flying home")
        for _ in 0 ..< 240 {
            view.advance(dt: 1 / 120)
        }
        await returning.value
        #expect(shell.content.superlayer === shell.layer)
        #expect(shell.content.opacity == 1)
        #expect(sameRect(shell.content.frame, original))
    }

    @Test("A flown tile suppresses shelf wave and display hover until it returns")
    func flightSuppressesHover() async throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let shell = try #require(view.displayLayers[1])
        let tile = try #require(view.cardLayers["card-5"])
        model.report(hoveredCard: "card-5")
        model.report(hoveredDisplay: 1)
        view.advance(dt: 1 / 60)
        #expect(tile.lift.target != 0)
        await model.flyTile(display: 1, to: CGRect(x: 100, y: 100, width: 800, height: 450))
        for _ in 0 ..< 240 {
            view.advance(dt: 1 / 120)
        }
        #expect(tile.lift.target == 0)
        #expect(tile.lift.isSettled)
        #expect(CATransform3DIsIdentity(shell.coverGroup.transform))
        #expect(!view.debugNeedsDisplayLink)
        await model.returnTile(display: 1)
        for _ in 0 ..< 240 {
            view.advance(dt: 1 / 120)
        }
        #expect(tile.lift.target != 0)
        #expect(shell.coverGroup.transform.m11 > 1)
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
        // A point on the strip the lift uncovers above the card's own slot: no card owns it at rest.
        let above = CGPoint(x: rest.minX + 8, y: rest.minY - 20)
        #expect(view.cardIndex(at: above) == nil)

        model.report(hoveredCard: model.shelfItems[5].id)
        #expect(view.cardIndex(at: above) == 5, "the lifted card must answer for the pixels it now covers")

        // …but the band is still resolved slot by slot, so travelling along it hands the wave on
        // instead of leaving it parked on the card that happens to be lifted.
        let pitch = StageGeometry.metrics(for: model.shelfStyle).pitch
        let alongTheBand = (0 ..< 4).map { view.cardIndex(at: CGPoint(x: above.x + CGFloat($0) * pitch, y: above.y)) }
        #expect(alongTheBand == [5, 6, 7, 8], Comment(rawValue: "\(alongTheBand)"))

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

    @Test("A covered stage passes clicks, hover and scroll through to the display editor")
    func blockedStageDoesNotSwallowEditorInput() {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.interactionBlocked = true
        for point in [CGPoint(x: 1100, y: 28), CGPoint(x: 400, y: 300)] {
            #expect(!view.ownsPoint(point, clicking: true))
            #expect(!view.ownsPoint(point, clicking: false))
            #expect(view.hitTest(point) == nil)
        }
        model.interactionBlocked = false
        #expect(view.ownsPoint(CGPoint(x: 400, y: 300), clicking: false))
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
        ))
    }

    /// `phase` rides the CGEvent field `NSEvent.phase` is built from; without one the event is a
    /// mouse wheel, which is what the stage reads as `.changed`.
    private func scroll(
        x: Int32 = 0, y: Int32 = 0, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil
    ) throws -> NSEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0
        ))
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        if let momentum {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        }
        return try #require(NSEvent(cgEvent: event))
    }

    /// The last card's near edge sits exactly on the band's end when the row is on its lower limit.
    private func expectRowAtItsEnd(_ view: EditDeskStageView, _ model: EditDeskStageModel, after step: String) throws {
        let band = StageGeometry.shelfBand(
            style: model.shelfStyle, capacity: model.shelfRenderBudget, windowSize: view.bounds.size
        )
        let last = try #require(view.cardLayers["card-\(model.shelfItems.count - 1)"])
        #expect(
            abs(last.frame.minX - band.upperBound) < 0.5,
            Comment(rawValue: "after \(step) the last card is at \(last.frame.minX), the band ends at \(band.upperBound)")
        )
    }

    private func mouse(
        _ type: NSEvent.EventType, at point: CGPoint, in view: EditDeskStageView, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    /// `zPositions`, when given, is the stacking order the step under test must have left alone.
    private func expectReducedFade(_ view: EditDeskStageView, zPositions: [StageCard.ID: CGFloat]? = nil) throws {
        func layers(_ root: CALayer) -> [CALayer] {
            [root] + (root.sublayers ?? []).flatMap { layers($0) }
        }
        let tree = try layers(#require(view.layer))
        let keys = Set(tree.flatMap { $0.animationKeys() ?? [] })
        #expect(keys == ["opacity"], "a real opacity animation must replace motion")
        for layer in tree {
            for key in layer.animationKeys() ?? [] {
                let animation = try #require(layer.animation(forKey: key) as? CAPropertyAnimation)
                #expect(animation.keyPath == "opacity")
                #expect(animation.duration > 0 && animation.duration <= 0.15)
                if let fade = animation as? CABasicAnimation {
                    #expect(fade.toValue as? Float == layer.opacity, "a fade must be built after its final opacity is written")
                    #expect(fade.fromValue as? Float != fade.toValue as? Float, "a fade from a value to itself is a no-op dressed as an animation")
                } else {
                    let pulse = try #require(animation as? CAKeyframeAnimation)
                    #expect(pulse.values?.last as? Float == layer.opacity)
                    #expect((pulse.values?.count ?? 0) > 1)
                }
            }
            layer.removeAllAnimations()
        }
        if let zPositions {
            #expect(view.cardLayers.mapValues(\.layer.zPosition) == zPositions, "Reduce Motion must not restack the row")
        }
        #expect(view.debugSpringsSettled)
        #expect(!view.debugStaggerToGrid)
        #expect(!view.debugNeedsDisplayLink, "Core Animation fades must not keep the frame driver alive")
    }

    @Test("Reduce Motion replaces transitions, hover, ghosts and flights with explicit opacity fades")
    func reducedMotionUsesOnlyFades() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(2, animated: true)
        try expectReducedFade(view)
        model.setProgress(1, animated: true)
        try expectReducedFade(view)
        model.setProgress(2, animated: false)
        try expectReducedFade(view)
        model.setProgress(1, animated: false)
        try expectReducedFade(view)
        let placement = StageGeometry.cardPlacement(
            style: model.shelfStyle, index: 5, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
        )
        let hit = StageGeometry.hitRect(placement, style: model.shelfStyle)
        let point = CGPoint(x: hit.minX + 8, y: hit.midY)
        let tile = try #require(view.cardLayers["card-5"])
        let restTransform = tile.face.transform
        let restStacking = view.cardLayers.mapValues(\.layer.zPosition)
        try view.mouseMoved(with: mouse(.mouseMoved, at: point, in: view))
        #expect(model.hoveredCard == "card-5")
        #expect(CATransform3DEqualToTransform(tile.face.transform, restTransform))
        #expect(sameRect(tile.frame, placement.frame))
        try expectReducedFade(view, zPositions: restStacking)
        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        let dragged = CGPoint(x: point.x + 20, y: point.y - 20)
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: dragged, in: view))
        try expectReducedFade(view)
        try view.keyDown(with: key(53))
        try expectReducedFade(view)
        await view.flyTile(display: 1, to: CGRect(x: 100, y: 100, width: 800, height: 450))
        try expectReducedFade(view)
        await view.returnTile(display: 1)
        try expectReducedFade(view)

        let control = makeModel()
        control.reduceMotion = false
        let moving = EditDeskStageView(model: control)
        defer { moving.detach() }
        moving.frame = view.frame
        control.setProgress(2, animated: true)
        #expect(!moving.debugSpringsSettled)
        #expect(moving.debugStaggerToGrid)
        #expect(moving.debugNeedsDisplayLink)
    }

    @Test("Reduce Motion cuts the row to a new offset and fades the shelf, but only when the offset moves")
    func reducedMotionRowCutFadesTheShelf() throws {
        let model = makeModel()
        model.shelfStyle = .fan
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let shelf = view.debugShelfLayer
        shelf.removeAllAnimations()
        try view.keyDown(with: key(124))
        #expect(view.debugFocusedCardIndex == 0)
        #expect(shelf.animation(forKey: "opacity") == nil, "a reveal that leaves the row where it is must not fade")
        let restX = try #require(view.cardLayers["card-1"]).frame.origin.x
        try view.keyDown(with: key(124))
        #expect(view.debugFocusedCardIndex == 1)
        #expect(try #require(view.cardLayers["card-1"]).frame.origin.x != restX, "the reveal must have moved the row")
        let fade = try #require(shelf.animation(forKey: "opacity") as? CABasicAnimation)
        #expect(fade.keyPath == "opacity")
        #expect(fade.duration == 0.15)
        #expect(fade.fromValue as? Float == 0)
        #expect(fade.toValue as? Float == shelf.opacity)
        #expect(view.debugSpringsSettled)
        #expect(!view.debugNeedsDisplayLink)
    }

    @Test("Reduce Motion answers a rejected card with an opacity pulse instead of a shake")
    func reducedMotionShakeFallsBackToAnOpacityPulse() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let tile = try #require(view.cardLayers["card-5"])
        tile.layer.removeAllAnimations()
        view.shake(card: "card-5")
        let pulse = try #require(tile.layer.animation(forKey: "opacity") as? CAKeyframeAnimation)
        #expect(pulse.keyPath == "opacity")
        #expect(pulse.duration == 0.15)
        #expect(pulse.values?.count == 3)
        #expect(pulse.values?.first as? Float == tile.layer.opacity)
        #expect(pulse.values?.last as? Float == tile.layer.opacity)
        #expect(pulse.values?.dropFirst().first as? Float != tile.layer.opacity)
        #expect(!view.debugNeedsDisplayLink, "a Core Animation pulse must not start the frame driver")

        let control = makeModel()
        control.reduceMotion = false
        let moving = EditDeskStageView(model: control)
        defer { moving.detach() }
        moving.frame = view.frame
        moving.layoutSubtreeIfNeeded()
        control.setProgress(1, animated: false)
        let movingTile = try #require(moving.cardLayers["card-5"])
        movingTile.layer.removeAllAnimations()
        moving.shake(card: "card-5")
        #expect(movingTile.layer.animation(forKey: "opacity") == nil)
        #expect(moving.debugNeedsDisplayLink)
    }

    @Test(
        "A Finder file over a display lights it, a drop emits filesDropped, a covered stage neither registers nor targets",
        .timeLimit(.minutes(1))
    )
    func finderFileDropTargetsTheDisplayUnderIt() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        #expect(view.registeredDraggedTypes.contains(.fileURL))
        // Display 2 is the empty one: a screen with no wallpaper takes a file as well.
        let root = try #require(view.layer)
        let shell = try #require(view.displayLayers[2])
        let point = shell.layer.convert(CGPoint(x: shell.layer.bounds.midX, y: shell.layer.bounds.midY), to: root)
        #expect(view.trackFileDrag(at: point) == .display(2))
        #expect(model.dropTarget == 2)
        #expect(view.trackFileDrag(at: CGPoint(x: 4, y: 4)) == nil, "off the displays nothing lights")
        #expect(model.dropTarget == nil)
        let file = URL(fileURLWithPath: "/private/tmp/loomscreen-drop/clip.mp4")
        let accepted = view.acceptFileDrop([file], at: point)
        #expect(accepted)
        if accepted {
            var events = model.events.makeAsyncIterator()
            #expect(await events.next() == .filesDropped([file], onto: 2))
        }
        #expect(model.dropTarget == nil)

        model.interactionBlocked = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.registeredDraggedTypes.isEmpty, "a covered stage would take the detail page's drops")
        #expect(view.trackFileDrag(at: point) == nil)
        #expect(!view.acceptFileDrop([file], at: point))
    }

    @Test(
        "A Finder file in the shelf band raises a hidden shelf and lights the band, and its drop joins the library",
        .timeLimit(.minutes(1))
    )
    func shelfBandRaisesAHiddenShelfAndTakesTheDrop() async {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        // Inside the band, left of both displays.
        let band = CGPoint(x: 100, y: view.bounds.height - 40)
        #expect(view.trackFileDrag(at: band) == .shelf)
        #expect(model.progress == 1, "the file has no shelf to land on")
        #expect(model.shelfDropTargeted)
        #expect(model.dropTarget == nil)
        let file = URL(fileURLWithPath: "/private/tmp/loomscreen-drop/clip.mp4")
        let accepted = view.acceptFileDrop([file], at: band)
        #expect(accepted)
        if accepted {
            var events = model.events.makeAsyncIterator()
            #expect(await events.next() == .snapped(1))
            #expect(await events.next() == .filesDroppedOnShelf([file]))
        }
        #expect(!model.shelfDropTargeted)
        view.endFileDrag(session: 0)
        #expect(model.progress == 1, "the shelf went down under the card that just joined it")
    }

    @Test("A shelf raised for a Finder drag goes back down when that drag ends anywhere but on the shelf")
    func autoRaisedShelfGoesBackWhenTheDragEndsElsewhere() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let band = CGPoint(x: 100, y: view.bounds.height - 40)
        // Esc, or a drop in another app: the drag leaves the window, then ends.
        #expect(view.trackFileDrag(at: band) == .shelf)
        view.trackFileDrag(at: nil)
        #expect(model.progress == 1, "a drag straying past the window's bottom edge bobs the shelf down and up")
        view.endFileDrag(session: 0)
        #expect(model.progress == 0)
        // A drop on a display applies the file there.
        #expect(view.trackFileDrag(at: band) == .shelf)
        let root = try #require(view.layer)
        let shell = try #require(view.displayLayers[1])
        let onDisplay = shell.layer.convert(CGPoint(x: shell.layer.bounds.midX, y: shell.layer.bounds.midY), to: root)
        #expect(view.acceptFileDrop([URL(fileURLWithPath: "/private/tmp/loomscreen-drop/clip.mp4")], at: onDisplay))
        view.endFileDrag(session: 0)
        #expect(model.progress == 0)
        // Control: the end of a drag that did not raise it.
        #expect(view.trackFileDrag(at: band) == .shelf)
        view.endFileDrag(session: 1)
        #expect(model.progress == 1, "another drag's end lowered this one's shelf")

        // Control: a shelf the user had open before the drag came in.
        let opened = makeModel()
        let other = EditDeskStageView(model: opened)
        defer { other.detach() }
        other.frame = view.frame
        other.layoutSubtreeIfNeeded()
        opened.setProgress(1, animated: false)
        #expect(other.trackFileDrag(at: band) == .shelf)
        other.endFileDrag(session: 0)
        #expect(opened.progress == 1, "the drag's end closed a shelf the user had opened")
    }

    @Test("A display reaching into the shelf band takes the file there, and the shelf stays down")
    func displaysWinOverTheShelfBand() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let root = try #require(view.layer)
        let shell = try #require(view.displayLayers[2])
        let rect = shell.layer.convert(shell.layer.bounds, to: root)
        let top = StageGeometry.shelfDropTop(windowSize: view.bounds.size)
        try #require(rect.maxY > top, "display 2 no longer reaches into the band; pick a fixture display that does")
        let point = CGPoint(x: rect.midX, y: (max(rect.minY, top) + rect.maxY) / 2)
        #expect(view.trackFileDrag(at: point) == .display(2))
        #expect(model.dropTarget == 2)
        #expect(!model.shelfDropTargeted)
        #expect(model.progress == 0, "aiming at a display's lower half raised the shelf")
    }

    @Test("Nothing takes a file off the displays and the band, over the library grid, or on a covered stage")
    func nothingElseTakesAFile() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let root = try #require(view.layer)
        let upper = try #require(view.displayLayers[1]).layer
        let lower = try #require(view.displayLayers[2]).layer
        let upperRect = upper.convert(upper.bounds, to: root)
        let lowerRect = lower.convert(lower.bounds, to: root)
        let between = CGPoint(x: lowerRect.midX, y: (upperRect.maxY + lowerRect.minY) / 2)
        try #require(!upperRect.contains(between) && !lowerRect.contains(between))
        try #require(between.y < StageGeometry.shelfDropTop(windowSize: view.bounds.size))
        let file = URL(fileURLWithPath: "/private/tmp/loomscreen-drop/clip.mp4")
        for point in [CGPoint(x: 4, y: 4), between] {
            #expect(view.trackFileDrag(at: point) == nil)
            #expect(!view.acceptFileDrop([file], at: point))
        }
        #expect(model.progress == 0)
        #expect(!model.shelfDropTargeted)

        let band = CGPoint(x: 100, y: view.bounds.height - 40)
        model.setProgress(2, animated: false)
        #expect(view.trackFileDrag(at: band) == nil, "the library grid took a file")
        #expect(!view.acceptFileDrop([file], at: band))
        #expect(model.progress == 2)
        #expect(!model.shelfDropTargeted)

        model.setProgress(0, animated: false)
        model.interactionBlocked = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.trackFileDrag(at: band) == nil)
        #expect(!view.acceptFileDrop([file], at: band))
        #expect(model.progress == 0, "a covered stage raised its shelf")
        #expect(!model.shelfDropTargeted)
    }

    @Test("A scroll hands a shelf raised for a Finder drag to the user, so the drag's end leaves it up")
    func userScrollHandsTheShelfBack() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        #expect(view.trackFileDrag(at: CGPoint(x: 100, y: view.bounds.height - 40)) == .shelf)
        #expect(model.progress == 1)
        try view.scrollWheel(with: scroll(x: -24))
        view.endFileDrag(session: 0)
        #expect(model.progress == 1, "the drag's end took back a shelf the user had started scrolling")
    }

    @Test("A rejected Finder drop shakes its display; Reduce Motion pulses it instead")
    func rejectedFileDropShakesTheDisplay() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        shell.layer.removeAllAnimations()
        view.shake(display: 1)
        let pulse = try #require(shell.layer.animation(forKey: "opacity") as? CAKeyframeAnimation)
        #expect(pulse.duration == 0.15)
        #expect(pulse.values?.last as? Float == shell.layer.opacity)
        #expect(!view.debugNeedsDisplayLink, "a Core Animation pulse must not start the frame driver")

        let control = makeModel()
        control.reduceMotion = false
        let moving = EditDeskStageView(model: control)
        defer { moving.detach() }
        moving.frame = view.frame
        moving.layoutSubtreeIfNeeded()
        let movingShell = try #require(moving.displayLayers[1])
        movingShell.layer.removeAllAnimations()
        moving.shake(display: 1)
        #expect(movingShell.layer.animation(forKey: "opacity") == nil)
        #expect(moving.debugNeedsDisplayLink)
        // A quarter of the first cycle in, the curve is at its 6pt peak.
        moving.advance(dt: 0.025)
        #expect(abs(movingShell.layer.sublayerTransform.m41 - 6) < 0.001)
        // Reduce Motion arriving mid-shake ends it rather than leaving the frame driver running.
        control.reduceMotion = true
        moving.advance(dt: 1.0 / 60)
        #expect(CATransform3DIsIdentity(movingShell.layer.sublayerTransform))
        #expect(!moving.debugNeedsDisplayLink)
    }

    @Test("Right-click on a shelf card opens that card's menu, submenus included")
    func cardContextMenu() throws {
        let model = makeModel()
        var picked: [String] = []
        model.cardMenu = { id in
            [[
                StageMenuItem(
                    title: "Apply to", isEnabled: true,
                    submenu: [StageMenuItem(title: "External", isEnabled: true) { picked.append("apply \(id)") }]
                ) {},
                StageMenuItem(title: "Remove", isEnabled: false, isDestructive: true) { picked.append("remove") },
            ]]
        }
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let rest = StageGeometry.cardPlacement(
            style: model.shelfStyle, index: 5, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
        )
        let hit = StageGeometry.hitRect(rest, style: model.shelfStyle)
        let point = CGPoint(x: hit.minX + 8, y: hit.midY)
        try #require(view.cardIndex(at: point) == 5)

        let menu = try #require(view.menu(for: mouse(.rightMouseDown, at: point, in: view)))
        #expect(menu.items.map(\.title) == ["Apply to", "Remove"])
        #expect(menu.items.map(\.isEnabled) == [true, false])
        let submenu = try #require(menu.items.first?.submenu)
        #expect(submenu.items.map(\.title) == ["External"])
        submenu.performActionForItem(at: 0)
        #expect(picked == ["apply card-5"])
    }

    @Test("Right-click on a display opens its menu; empty space and a covered stage open none")
    func displayContextMenu() throws {
        let model = makeModel()
        var picked: [String] = []
        model.displayMenu = { id in
            [
                [StageMenuItem(title: "Rename \(id)", isEnabled: true) { picked.append("rename \(id)") }],
                [StageMenuItem(title: "Clear", isEnabled: false) { picked.append("clear") }],
            ]
        }
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let root = try #require(view.layer)
        let shell = try #require(view.displayLayers[1])
        let point = shell.layer.convert(CGPoint(x: shell.layer.bounds.midX, y: shell.layer.bounds.midY), to: root)
        let menu = try #require(view.menu(for: mouse(.rightMouseDown, at: point, in: view)))
        #expect(menu.items.map(\.title) == ["Rename 1", "", "Clear"])
        #expect(menu.items.map(\.isSeparatorItem) == [false, true, false])
        #expect(menu.items.first?.isEnabled == true)
        #expect(menu.items.last?.isEnabled == false)
        menu.performActionForItem(at: 0)
        #expect(picked == ["rename 1"])
        #expect(try view.menu(for: mouse(.rightMouseDown, at: CGPoint(x: 4, y: 4), in: view)) == nil, "off the displays there is no menu")
        model.interactionBlocked = true
        #expect(try view.menu(for: mouse(.rightMouseDown, at: point, in: view)) == nil, "a covered stage must not open a menu under the detail page")
    }

    @Test("Esc cancels a drag first, then returns the shelf and the library to the overview", .timeLimit(.minutes(1)))
    func escapeStepsBackOneLevel() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        var events = model.events.makeAsyncIterator()
        #expect(!view.escape(), "at rest there is nothing to leave")
        model.setProgress(1, animated: false)
        let placement = StageGeometry.cardPlacement(
            style: model.shelfStyle, index: 5, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
        )
        let hit = StageGeometry.hitRect(placement, style: model.shelfStyle)
        let point = CGPoint(x: hit.minX + 8, y: hit.midY)
        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: point.x + 20, y: point.y - 20), in: view))
        #expect(view.debugDragging)
        try view.keyDown(with: key(53))
        #expect(!view.debugDragging)
        #expect(model.progress == 1, "the first Esc only drops the card")
        #expect(view.escape())
        #expect(model.progress == 0)
        model.setProgress(2, animated: false)
        #expect(view.escape())
        #expect(model.progress == 0)
        // The host turns the snap back to 0 into the home page; read up to a marker so a missing snap cannot hang.
        model.emit(.cardTapped("end"))
        var seen: [StageEvent] = []
        while let event = await events.next(), event != .cardTapped("end") {
            seen.append(event)
        }
        #expect(seen == [.snapped(1), .dropCancelled(card: "card-5"), .snapped(0), .snapped(2), .snapped(0)])
    }

    @Test("The name-row dot is green only while the wallpaper runs")
    func statusDotFollowsTheState() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        // The dot is the one small ellipse among the shell's own sublayers.
        let dot = try #require(shell.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first {
            let width = $0.path?.boundingBox.width ?? 0
            return width > 0 && width < 12
        })
        let colors = DesignTokens.EditDesk.Colors.self
        let cases: [(StageDisplay.State, () -> CGColor)] = [
            (.ok, { NSColor(colors.success).cgColor }),
            (.paused(reasonText: "Paused"), { NSColor(colors.warning).cgColor }),
            (.preparing(text: "Preparing"), { NSColor(colors.textSecondary).cgColor }),
            (.off(text: "Off"), { NSColor(colors.textTertiary).cgColor }),
            (.empty, { NSColor(colors.textTertiary).cgColor }),
        ]
        var display = model.displays[0]
        for (state, token) in cases {
            display.state = state
            var drawn: CGColor?
            var wanted: CGColor?
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                shell.update(display: display, dropHint: "", increasedContrast: false)
                drawn = dot.fillColor
                wanted = token()
            }
            #expect(drawn == wanted, Comment(rawValue: "\(state)"))
        }
        let chip = StageFailureChip(symbol: "xmark.octagon.fill", text: "Failed", tint: CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
        display.state = .failed(chip)
        shell.update(display: display, dropHint: "", increasedContrast: false)
        #expect(dot.fillColor == chip.tint, "a failure's dot takes its chip's colour")
    }

    @Test("VoiceOver hears what each display plays and its state")
    func displayAccessibilityReadsWhatPlays() throws {
        let model = makeModel()
        model.displays[0].wallpaperTitle = "Aurora"
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        func display(_ index: Int) throws -> NSAccessibilityElement {
            try #require(view.accessibilityChildren()?[index] as? NSAccessibilityElement)
        }
        #expect(try display(0).accessibilityLabel() == "External, Active")
        #expect(try display(0).accessibilityValue() as? String == String(localized: "Now playing \("Aurora")", bundle: .appLanguage))
        #expect(try display(1).accessibilityValue() as? String == String(localized: "No wallpaper configured", bundle: .appLanguage))
        model.displays[0].state = .paused(reasonText: "On battery")
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(try display(0).accessibilityValue() as? String == "Aurora, On battery")
    }

    @Test("A Reduce Motion fade built on the gesture path ends where the layer ends")
    func reducedMotionGestureFadeEndsWhereTheLayerEnds() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let arrangement = view.debugArrangementLayer
        arrangement.removeAllAnimations()
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -1920, wheel2: 0, wheel3: 0))
        try view.scrollWheel(with: #require(NSEvent(cgEvent: scroll)))
        #expect(model.progress == 2)
        #expect(arrangement.opacity == 0)
        let fade = try #require(arrangement.animation(forKey: "opacity") as? CABasicAnimation)
        #expect(fade.duration == 0.15)
        #expect(fade.toValue as? Float == arrangement.opacity, "a fade must be built after its final opacity is written")
        #expect(fade.fromValue as? Float == 1, "the arrangement must fade out from what it was showing")
    }

    @Test("Card actions retain identity and shelf arrows move a visible focus ring, except during drag or grid focus")
    func cardAccessibilityAndKeyboardFocus() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        var events = model.events.makeAsyncIterator()
        #expect(await events.next() == .snapped(1))
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let card = try #require(children.first { $0.accessibilityLabel() == "Card 1 Meta" })
        let actions = try #require(card.accessibilityCustomActions())
        #expect(actions.map(\.name) == [String(localized: "Apply", bundle: .appLanguage), String(localized: "Preview", bundle: .appLanguage)])
        try #require(actions[0].handler?() == true)
        #expect(await events.next() == .cardApplyRequested("card-1"))
        try #require(actions[1].handler?() == true)
        #expect(await events.next() == .cardTapped("card-1"))
        try view.keyDown(with: key(124))
        #expect(view.debugFocusedCardIndex == 0)
        try view.keyDown(with: key(124))
        #expect(view.debugFocusedCardIndex == 1)
        let expected = StageGeometry.hitRect(StageGeometry.cardPlacement(
            style: model.shelfStyle, index: 1, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
        ), style: model.shelfStyle)
        #expect(try sameRect(#require(view.debugFocusRingFrame), expected))
        #expect(card.isAccessibilityFocused())
        try view.keyDown(with: key(123))
        #expect(view.debugFocusedCardIndex == 0)
        try view.keyDown(with: key(124))
        model.shelfItems.swapAt(1, 2)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.debugFocusedCardIndex == 2)
        let reordered = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(reordered.first { $0.accessibilityLabel() == "Card 1 Meta" } === card)
        try expectArrowsIgnoredOffTheShelfAndDuringDrag(view, model)
    }

    /// Kept out of `cardAccessibilityAndKeyboardFocus`: inline, it slows that body's type-check past the 300 ms warning in a full build.
    private func expectArrowsIgnoredOffTheShelfAndDuringDrag(_ view: EditDeskStageView, _ model: EditDeskStageModel) throws {
        model.setProgress(2, animated: false)
        try view.keyDown(with: key(124))
        #expect(view.debugFocusedCardIndex == 2)
        #expect(view.debugFocusRingFrame == nil)
        #expect(view.accessibilityChildren()?.isEmpty == true)
        model.setProgress(0, animated: false)
        try view.keyDown(with: key(123))
        #expect(view.debugFocusedCardIndex == 2)
        model.setProgress(1, animated: false)
        let hit = StageGeometry.hitRect(StageGeometry.cardPlacement(
            style: model.shelfStyle, index: 3, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
        ), style: model.shelfStyle)
        let point = CGPoint(x: hit.minX + 8, y: hit.midY)
        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        #expect(view.debugFocusedCardIndex == 3)
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: point.x + 20, y: point.y - 20), in: view))
        try view.keyDown(with: key(124))
        try view.keyDown(with: key(126))
        #expect(view.debugFocusedCardIndex == 3)
        #expect(model.progress == 1)
    }

    @Test("The stage lists only what it is drawing: faded displays and the grid's own tiles drop out")
    func accessibilityChildrenFollowVisibility() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        #expect(view.accessibilityChildren()?.count == 16, "half open draws two displays and fourteen cards")
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let display = try #require(children.first { $0.accessibilityLabel() == "External, Active" })
        model.setProgress(2, animated: false)
        #expect(view.accessibilityChildren()?.isEmpty == true)
        // An element VoiceOver is still holding must refuse too, or pressing it opens the detail
        // page for a display that has faded out.
        #expect(display.accessibilityPerformPress() == false)
        model.setProgress(1, animated: false)
        #expect(display.accessibilityPerformPress())
    }

    @Test("Return, Enter and Space open the card the focus ring is on", .timeLimit(.minutes(1)))
    func returnAndSpaceActivateTheFocusedCard() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        var events = model.events.makeAsyncIterator()
        #expect(await events.next() == .snapped(1))
        try view.keyDown(with: key(124))
        #expect(view.debugFocusedCardIndex == 0)
        try view.keyDown(with: key(36))
        #expect(await events.next() == .cardTapped("card-0"))
        try view.keyDown(with: key(124))
        try view.keyDown(with: key(49))
        #expect(await events.next() == .cardTapped("card-1"))
        try view.keyDown(with: key(76))
        #expect(await events.next() == .cardTapped("card-1"))
        // The arrows' own conditions, so the grid and the hidden shelf both refuse. Each refusal is
        // read through a snap that follows it: a leaked tap comes out of the stream ahead of it, and
        // a silent stream would otherwise be indistinguishable from a passing test.
        model.setProgress(2, animated: false)
        #expect(await events.next() == .snapped(2))
        try view.keyDown(with: key(36))
        model.setProgress(0, animated: false)
        #expect(await events.next() == .snapped(0), "the grid must not take Return")
        try view.keyDown(with: key(49))
        model.setProgress(1, animated: false)
        #expect(await events.next() == .snapped(1), "a hidden shelf must not take Space")
    }

    @Test("A card's accessibility frame is the trapezoid it draws, not its upright container")
    func cardAccessibilityFrameMatchesTheDrawnCard() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let element = try #require(children.first { $0.accessibilityLabel() == "Card 5 Meta" })
        let tile = try #require(view.cardLayers["card-5"])
        #expect(sameRect(element.accessibilityFrame(), view.convert(tile.hitRect, to: nil)))
        // Control: the container the old frame came from is the full 200pt, the drawn card is not.
        #expect(
            abs(element.accessibilityFrame().width - StageGeometry.cardSize.width) > 1,
            Comment(rawValue: "accessibility frame \(element.accessibilityFrame()) against card \(tile.hitRect)")
        )
    }

    @Test("The shelf card's shadow darkens with the hover lift instead of stepping on the first frame")
    func shadowAlphaDoesNotStep() {
        let placement = StageGeometry.cardPlacement(
            style: .crate, index: 0, count: 14, progress: 1, focus: 0, windowSize: StageGeometry.designWindow
        )
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let tile = ShelfCardLayer()
            var restColor: NSColor?
            var hotColor: NSColor?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                tile.update(
                    card: StageCard(id: "a", title: "A", metaLine: "", thumbnail: nil, nowPlaying: nil, isDraggable: true),
                    increasedContrast: false
                )
                restColor = NSColor(DesignTokens.EditDesk.Shadow.shelfCard.color).usingColorSpace(.sRGB)
                hotColor = NSColor(DesignTokens.EditDesk.Shadow.shelfCardHover.color).usingColorSpace(.sRGB)
            }
            func alpha(_ hover: Double) -> CGFloat {
                tile.hover.jump(to: hover)
                tile.place(placement, style: .crate, gridMix: 0, dragged: false, reduceMotion: false)
                return (tile.face.shadowColor?.alpha ?? 0) * CGFloat(tile.face.shadowOpacity)
            }
            let rest = alpha(0)
            let first = alpha(0.001)
            #expect(
                abs(first - rest) < 0.005,
                Comment(rawValue: "\(appearance.rawValue): one hover frame moved the shadow from \(rest) to \(first)")
            )
            let half = alpha(0.5)
            let hot = alpha(1)
            #expect(
                half > rest && half < hot,
                Comment(rawValue: "\(appearance.rawValue): \(rest) → \(half) → \(hot) is not a travelled alpha")
            )
            // Folding the two tokens' alphas into one opacity only holds while they are the same colour.
            #expect(restColor?.redComponent == hotColor?.redComponent)
            #expect(restColor?.greenComponent == hotColor?.greenComponent)
            #expect(restColor?.blueComponent == hotColor?.blueComponent)
        }
    }

    @Test("Facing In draws the spine and contact shadow on each card's outer edge, and none on the face-on middle card")
    func facingInSpineSitsOnTheOuterEdge() {
        let tile = ShelfCardLayer()
        tile.update(
            card: StageCard(id: "a", title: "A", metaLine: "", thumbnail: nil, nowPlaying: nil, isDraggable: true),
            increasedContrast: false
        )
        func place(_ style: ShelfStyle, _ index: Int) -> (spine: CALayer, shadow: CGFloat) {
            let placement = StageGeometry.cardPlacement(
                style: style, index: index, count: 13, progress: 1, focus: 6, windowSize: StageGeometry.designWindow
            )
            tile.place(placement, style: style, gridMix: 0, dragged: false, reduceMotion: false)
            return (tile.spine, tile.face.shadowOffset.width)
        }
        let right = place(.facingIn, 8)
        #expect(right.spine.frame.maxX == StageGeometry.cardSize.width && right.spine.opacity == 1 && right.shadow > 0,
                Comment(rawValue: "right card: spine \(right.spine.frame) at \(right.spine.opacity), shadow \(right.shadow)"))
        let left = place(.facingIn, 4)
        #expect(left.spine.frame.minX == 0 && left.spine.opacity == 1 && left.shadow < 0,
                Comment(rawValue: "left card: spine \(left.spine.frame) at \(left.spine.opacity), shadow \(left.shadow)"))
        let middle = place(.facingIn, 6)
        #expect(middle.spine.opacity == 0 && middle.shadow == 0,
                Comment(rawValue: "middle card: spine at \(middle.spine.opacity), shadow \(middle.shadow)"))
        // Control: the crate keeps both on every card's left edge.
        let crate = place(.crate, 8)
        #expect(crate.spine.frame.minX == 0 && crate.spine.opacity == 1 && crate.shadow < 0,
                Comment(rawValue: "crate card: spine \(crate.spine.frame) at \(crate.spine.opacity), shadow \(crate.shadow)"))
    }

    @Test("A card collapsing out of the grid casts a shadow its own size, not the grid's")
    func shadowPathTracksTheCardMidFlight() throws {
        let tile = ShelfCardLayer()
        tile.update(
            card: StageCard(id: "a", title: "A", metaLine: "", thumbnail: nil, nowPlaying: nil, isDraggable: true),
            increasedContrast: false
        )
        func place(_ progress: Double) -> CGSize {
            let placement = StageGeometry.cardPlacement(
                style: .crate, index: 0, count: 14, progress: progress, focus: 0, windowSize: StageGeometry.designWindow
            )
            tile.place(
                placement, style: .crate, gridMix: CGFloat(StageGeometry.progressSplit(progress).t2),
                dragged: false, reduceMotion: false
            )
            return placement.frame.size
        }
        _ = place(2)
        let mid = place(1.5)
        let box = try #require(tile.face.shadowPath).boundingBox
        #expect(
            abs(box.width - mid.width) < 0.5 && abs(box.height - mid.height) < 0.5,
            Comment(rawValue: "shadow \(box.size) against card \(mid)")
        )
        // Control: back at the row size the cached path is in use again.
        _ = place(1)
        let settled = try #require(tile.face.shadowPath)
        #expect(settled.boundingBox.size == StageGeometry.cardSize)
    }

    private func refinedTile(_ appearance: NSAppearance.Name = .darkAqua, increasedContrast: Bool = false) -> ShelfCardLayer {
        let tile = ShelfCardLayer()
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            tile.update(
                card: StageCard(id: "a", title: "A", metaLine: "", thumbnail: nil, nowPlaying: nil, isDraggable: true),
                increasedContrast: increasedContrast
            )
        }
        return tile
    }

    /// Places `tile` the way `render` does, with `gridMix` read off `progress`.
    private func pose(
        _ tile: ShelfCardLayer, style: ShelfStyle = .crate, index: Int = 0, focus: Double = 0,
        progress: Double = 1, hover: Double = 0, reduceMotion: Bool = false
    ) {
        tile.hover.jump(to: hover)
        tile.place(
            StageGeometry.cardPlacement(
                style: style, index: index, count: 13, progress: progress, focus: focus, windowSize: StageGeometry.designWindow
            ),
            style: style, gridMix: CGFloat(StageGeometry.progressSplit(progress).t2), dragged: false, reduceMotion: reduceMotion
        )
    }

    private func layerTree(_ root: CALayer) -> [CALayer] {
        [root] + (root.sublayers ?? []).flatMap { layerTree($0) }
    }

    private func shadowAlpha(_ layer: CALayer) -> CGFloat {
        (layer.shadowColor?.alpha ?? 0) * CGFloat(layer.shadowOpacity)
    }

    @Test("The spine hangs in the thumbnail's rounded clip, so the near corners cut it instead of it poking past them")
    func spineIsClippedByTheThumbnail() {
        let tile = refinedTile()
        pose(tile)
        #expect(
            tile.spine.superlayer === tile.thumbnail,
            Comment(rawValue: "the spine hangs off \(tile.spine.superlayer === tile.face ? "the face" : "another layer")")
        )
        #expect(tile.thumbnail.masksToBounds && tile.thumbnail.cornerRadius > 0)
    }

    @Test("At the grid end the card is the tile it hands over to: GalleryTileChrome's corner, curve, stroke and rest shadow")
    func gridEndMatchesTheTile() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let tile = refinedTile(appearance)
            pose(tile, progress: 2)
            var tileStroke: CGFloat = -1
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                tileStroke = NSColor(Color.primary.opacity(DesignTokens.Card.strokeOpacity)).cgColor.alpha
            }
            let face = tile.face
            let name = appearance.rawValue
            #expect(face.cornerRadius == DesignTokens.Corner.lg, Comment(rawValue: "\(name): corner \(face.cornerRadius)"))
            let circular = layerTree(tile.layer).filter { $0.cornerRadius > 0 && $0.cornerCurve != .continuous }
            #expect(circular.isEmpty, Comment(rawValue: "\(name): \(circular.count) rounded layers keep circular corners"))
            let stroke = face.borderColor?.alpha ?? -1
            #expect(
                face.borderWidth == DesignTokens.Card.strokeWidth && abs(stroke - tileStroke) < 0.0001,
                Comment(rawValue: "\(name): stroke \(face.borderWidth)pt at α \(stroke), the tile's is α \(tileStroke)")
            )
            let spread = shadowAlpha(face)
            #expect(
                abs(spread - CGFloat(DesignTokens.Card.restShadowOpacity)) < 0.0001
                    && face.shadowRadius == DesignTokens.Card.shadowRadius
                    && face.shadowOffset == CGSize(width: 0, height: DesignTokens.Card.restShadowYOffset),
                Comment(rawValue: "\(name): shadow α \(spread), r \(face.shadowRadius), offset \(face.shadowOffset)")
            )
            #expect(
                shadowAlpha(tile.edgeShadow) == 0 && tile.sheen.opacity == 0,
                Comment(rawValue: "\(name): contact shadow α \(shadowAlpha(tile.edgeShadow)), sheen \(tile.sheen.opacity)")
            )
        }
        let view = EditDeskStageView(model: makeModel())
        defer { view.detach() }
        #expect(view.debugFocusRing.cornerCurve == .continuous)
    }

    @Test("Landing in the grid moves corner, stroke and shadows a little each frame, never all at once on the last")
    func gridHandOffDoesNotStep() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let tile = refinedTile(appearance)
            var last: [CGFloat]?
            for step in 95 ... 100 {
                pose(tile, progress: 1 + Double(step) / 100)
                let now = [
                    tile.face.cornerRadius, tile.face.borderColor?.alpha ?? 0, shadowAlpha(tile.face), shadowAlpha(tile.edgeShadow),
                ]
                if let last {
                    let moved = zip(now, last).map { abs($0 - $1) }
                    #expect(
                        moved[0] <= 0.1 && moved.dropFirst().allSatisfy { $0 <= 0.01 },
                        Comment(rawValue: "\(appearance.rawValue) at gridMix .\(step): corner, stroke, shadow, contact moved \(moved)")
                    )
                }
                last = now
            }
        }
    }

    @Test("A tight contact shadow sits under the face on the face's own path and leans out past the near edge only")
    func contactShadowHugsTheNearEdge() throws {
        let tile = refinedTile()
        pose(tile, index: 8)
        let edge = tile.edgeShadow
        #expect(tile.face.sublayers?.first === edge, "the contact shadow must lie under everything else the face holds")
        // Core Animation copies a `shadowPath` it is handed, so equal is the closest a test sees to "the same object".
        let path = try #require(tile.face.shadowPath)
        #expect(edge.shadowPath == path && edge.frame == tile.face.bounds)
        #expect(
            abs(shadowAlpha(edge) - 0.38) < 0.0001 && edge.shadowRadius == 1 && edge.shadowOffset.height == 1,
            Comment(rawValue: "contact shadow α \(shadowAlpha(edge)), r \(edge.shadowRadius), offset \(edge.shadowOffset)")
        )
        let crate = edge.shadowOffset.width
        pose(tile, style: .facingIn, index: 8, focus: 6)
        let right = edge.shadowOffset.width
        pose(tile, style: .facingIn, index: 6, focus: 6)
        let middle = edge.shadowOffset.width
        #expect(crate < 0 && right > 0 && middle == 0, Comment(rawValue: "x: crate \(crate), right half \(right), middle \(middle)"))
    }

    @Test("The sheen slides with each card's turn, stays on the card at 40°, holds under Reduce Motion and is gone in the grid")
    func sheenFollowsTheTurn() {
        let tile = refinedTile()
        func slide(_ style: ShelfStyle, index: Int = 0, focus: Double = 0, hover: Double = 0, reduceMotion: Bool = false) -> CGFloat {
            pose(tile, style: style, index: index, focus: focus, hover: hover, reduceMotion: reduceMotion)
            return tile.sheen.frame.minX
        }
        // x = −1.6 × 200 × clamp(0.50 + 0.014·rotY + 0.012·rotZ, 0.10, 0.90)
        let cases: [(String, CGFloat, CGFloat)] = [
            ("crate at rest, 28°", slide(.crate), -285.44),
            ("crate hovered square", slide(.crate, hover: 1), -160),
            ("Facing In's right half, −28°", slide(.facingIn, index: 8, focus: 6), -34.56),
            ("folders at 40°, clamped to .90", slide(.folders), -288),
            ("crate hovered under Reduce Motion", slide(.crate, hover: 1, reduceMotion: true), -285.44),
        ]
        for (name, actual, expected) in cases {
            #expect(abs(actual - expected) < 0.01, Comment(rawValue: "\(name): sheen at x \(actual), expected \(expected)"))
        }
        let sheen = tile.sheen
        #expect(
            sheen.superlayer === tile.thumbnail && abs(sheen.frame.width - 520) < 0.01 && sheen.frame.height == 112
                && sheen.opacity == 1,
            Comment(rawValue: "sheen \(sheen.frame) at \(sheen.opacity)")
        )
        pose(tile, progress: 2)
        #expect(sheen.opacity == 0, Comment(rawValue: "sheen at \(sheen.opacity) in the grid"))
    }

    @Test("The top light and bottom shade are 1pt lines in the thumbnail's clip, and the inner ring takes the contrast tier")
    func rimLinesAndInnerRing() {
        let tile = refinedTile()
        pose(tile)
        let bounds = tile.thumbnail.bounds
        #expect(tile.rimTop.superlayer === tile.thumbnail && tile.rimBottom.superlayer === tile.thumbnail)
        #expect(
            tile.rimTop.frame == CGRect(x: 0, y: 0, width: bounds.width, height: 1)
                && tile.rimBottom.frame == CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1),
            Comment(rawValue: "top \(tile.rimTop.frame), bottom \(tile.rimBottom.frame) in \(bounds)")
        )
        let light = tile.rimTop.backgroundColor
        let shade = tile.rimBottom.backgroundColor
        #expect(
            (light?.components?.first ?? 0) > 0.99 && abs((light?.alpha ?? 0) - 0.30) < 0.0001
                && (shade?.components?.first ?? 1) < 0.01 && abs((shade?.alpha ?? 0) - 0.35) < 0.0001,
            Comment(rawValue: "top \(String(describing: light)), bottom \(String(describing: shade))")
        )
        let ring = tile.thumbnail.borderColor?.alpha ?? 0
        #expect(tile.thumbnail.borderWidth == 1 && abs(ring - 0.10) < 0.0001, Comment(rawValue: "ring \(tile.thumbnail.borderWidth)pt at α \(ring)"))
        let contrast = refinedTile(increasedContrast: true)
        pose(contrast)
        let raised = contrast.thumbnail.borderColor?.alpha ?? 0
        #expect(abs(raised - 0.35) < 0.0001, Comment(rawValue: "Increase Contrast ring at α \(raised)"))
    }

    @Test("A tilted card keeps Core Animation's macOS default of antialiasing all four edges of its face and picture")
    func tiltedEdgesAreAntialiased() {
        let tile = refinedTile()
        pose(tile)
        let allEdges: CAEdgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerBottomEdge, .layerTopEdge]
        for (name, layer) in [("face", tile.face), ("thumbnail", tile.thumbnail)] {
            #expect(
                layer.allowsEdgeAntialiasing && layer.edgeAntialiasingMask == allEdges,
                Comment(rawValue: "\(name): antialiasing \(layer.allowsEdgeAntialiasing), edges \(layer.edgeAntialiasingMask.rawValue)")
            )
        }
    }

    /// "Studio" draws its wallpaper; "MPG" has it set but paused.
    private static let badgeDisplays = [
        StageDisplay(
            id: 1, fingerprint: "Studio", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isBuiltin: false,
            name: "Studio", badgeText: "", statusText: "", cover: nil, state: .ok
        ),
        StageDisplay(
            id: 2, fingerprint: "MPG", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), isBuiltin: false,
            name: "MPG", badgeText: "", statusText: "", cover: nil, state: .paused(reasonText: "Paused")
        ),
    ]

    private func badgedCard(on ids: [StageDisplay.ID], status: String? = nil) -> StageCard {
        StageCard(
            id: "a", title: "A", metaLine: "", thumbnail: nil,
            nowPlaying: NowPlayingBadge(on: ids, among: Self.badgeDisplays), isDraggable: true, statusBadge: status
        )
    }

    private func badgedTile(on ids: [StageDisplay.ID], status: String? = nil) -> ShelfCardLayer {
        let tile = ShelfCardLayer()
        tile.update(card: badgedCard(on: ids, status: status), increasedContrast: false)
        return tile
    }

    private func controlPoints(_ function: CAMediaTimingFunction?) -> [Float] {
        guard let function else { return [] }
        return (1 ... 2).flatMap { index -> [Float] in
            var point: [Float] = [0, 0]
            function.getControlPoint(at: index, values: &point)
            return point
        }
    }

    @Test("The now-playing capsule and the warning badge sit on the side each style leaves showing, and cross a Facing In middle smoothly")
    func badgesSitOnTheShowingSide() throws {
        let tile = badgedTile(on: [1])
        let capsule = try #require(tile.capsule, "a card set on a display draws no capsule")
        func frame(_ style: ShelfStyle, _ index: Int, focus: Double = 6, progress: Double = 1) -> CGRect {
            pose(tile, style: style, index: index, focus: focus, progress: progress)
            return capsule.frame
        }
        let right = frame(.facingIn, 8)
        #expect(
            right.minY == 8 && right.height == 18 && abs(right.maxX - (StageGeometry.cardSize.width - 8)) < 0.001,
            Comment(rawValue: "Facing In's right half shows its right side, but the capsule is at \(right)")
        )
        // Core Animation does not clamp a radius: past half the height it draws a lens, or nothing.
        #expect(capsule.cornerRadius * 2 <= right.height, Comment(rawValue: "corner radius \(capsule.cornerRadius) on an \(right.height)pt capsule"))
        let leftSide: [(String, CGRect)] = [
            ("crate", frame(.crate, 3, focus: 0)), ("folders", frame(.folders, 3, focus: 0)), ("fan", frame(.fan, 8)),
            ("focus row", frame(.focusRow, 6)), ("Facing In's left half", frame(.facingIn, 4)),
            ("Facing In's middle", frame(.facingIn, 6)), ("Facing In's right half in the grid", frame(.facingIn, 8, progress: 2)),
        ]
        for (name, rect) in leftSide {
            #expect(rect.minX == 8 && rect.minY == 8 && rect.width == right.width, Comment(rawValue: "\(name): \(rect)"))
        }
        var last: CGFloat?
        for step in 0 ... 100 {
            let focus = 5.5 + Double(step) / 100
            let x = frame(.facingIn, 6, focus: focus).minX
            if let last {
                #expect(abs(x - last) <= 3, Comment(rawValue: "the capsule jumped \(last) → \(x) at focus \(focus)"))
            }
            last = x
        }
        let warned = badgedTile(on: [1], status: "File unavailable")
        pose(warned, style: .facingIn, index: 8, focus: 6)
        #expect(
            abs(warned.badge.frame.maxX - (StageGeometry.cardSize.width - 8)) < 0.001 && warned.capsule?.isHidden != false,
            Comment(rawValue: "the warning badge is at \(warned.badge.frame); capsule hidden: \(String(describing: warned.capsule?.isHidden))")
        )
    }

    @Test("Where the capsule is drawn its card is on top: a Facing In card in the right half and a crate card keep theirs uncovered")
    func capsuleIsNeverUnderTheNextCard() throws {
        for (style, index) in [(ShelfStyle.facingIn, 2), (.crate, 3)] {
            let model = makeModel()
            model.shelfStyle = style
            let badge = try #require(NowPlayingBadge(on: [1], among: model.displays))
            model.shelfItems = model.shelfItems.map { card in
                var card = card
                card.nowPlaying = badge
                return card
            }
            let view = EditDeskStageView(model: model)
            defer { view.detach() }
            view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
            view.layoutSubtreeIfNeeded()
            model.setProgress(1, animated: false)
            let tile = try #require(view.cardLayers["card-\(index)"])
            let capsule = try #require(tile.capsule)
            let centre = drawnPoint(tile, CGPoint(x: capsule.frame.midX, y: capsule.frame.midY))
            let owner = view.cardIndex(at: centre)
            #expect(owner == index, Comment(rawValue: "\(style): card \(index)'s capsule at \(centre) lies under card \(owner.map { "\($0)" } ?? "none")"))
        }
    }

    @Test("The capsule's bars wave while a display draws the wallpaper and the card is on the shelf, and stand still anywhere else")
    func barsWaveOnlyWhileLive() throws {
        let rest: [CGFloat] = [5.0 / 9, 1, 6.0 / 9]
        let tile = badgedTile(on: [1])
        pose(tile)
        try #require(tile.waveBars.count == 3, "the capsule has \(tile.waveBars.count) bars")
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        for (index, bar) in tile.waveBars.enumerated() {
            let wave = try #require(bar.animation(forKey: "wave") as? CABasicAnimation, "bar \(index) is still on a live card")
            #expect(
                wave.keyPath == "transform.scale.y" && wave.fromValue as? Double == 1.0 / 3 && wave.toValue as? Double == 1
                    && wave.duration == 0.45 && wave.autoreverses && wave.repeatCount == .infinity
                    && abs(wave.timeOffset - 0.3 * Double(index)) < 1e-9 && controlPoints(wave.timingFunction) == controlPoints(ease),
                Comment(rawValue: "bar \(index): \(wave)")
            )
        }
        func still(_ situation: String) {
            for (index, bar) in tile.waveBars.enumerated() {
                #expect(
                    bar.animation(forKey: "wave") == nil && abs(bar.transform.m22 - rest[index]) < 1e-9,
                    Comment(rawValue: "\(situation): bar \(index) waves, or stands at \(bar.transform.m22)")
                )
            }
        }
        pose(tile, reduceMotion: true)
        still("Reduce Motion")
        pose(tile, progress: 2)
        still("in the grid")
        pose(tile, progress: 0)
        still("with the shelf down")
        pose(tile)
        #expect(tile.waveBars.allSatisfy { $0.animation(forKey: "wave") != nil }, "back on the shelf the bars stay still")
        tile.update(card: badgedCard(on: [2]), increasedContrast: false)
        pose(tile)
        still("on a paused display")
    }

    @Test("A shelf of waving bars still lets the display link stop once its springs settle")
    func waveNeverHoldsTheDisplayLink() throws {
        let model = makeModel()
        model.reduceMotion = false
        let badge = try #require(NowPlayingBadge(on: [1], among: model.displays))
        model.shelfItems = model.shelfItems.map { card in
            var card = card
            card.nowPlaying = badge
            return card
        }
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        for _ in 0 ..< 240 where view.debugNeedsDisplayLink {
            view.advance(dt: 1.0 / 60)
        }
        #expect(view.cardLayers.values.contains { $0.waveBars.first?.animation(forKey: "wave") != nil }, "no card on the shelf waves")
        #expect(!view.debugNeedsDisplayLink, "the bars' wave keeps the display link running")
        // Control: a hover spring in flight does hold it.
        model.report(hoveredCard: "card-3")
        view.advance(dt: 1.0 / 60)
        #expect(view.debugNeedsDisplayLink)
    }

    @Test("VoiceOver hears where a shelf card's wallpaper plays, or where it is set while no display draws it")
    func cardReadsWhereItPlays() throws {
        let model = makeModel()
        model.displays[1].state = .paused(reasonText: "Paused")
        model.shelfItems[5].nowPlaying = NowPlayingBadge(on: [1], among: model.displays)
        model.shelfItems[6].nowPlaying = NowPlayingBadge(on: [2], among: model.displays)
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let labels = try #require(view.accessibilityChildren() as? [NSAccessibilityElement]).compactMap { $0.accessibilityLabel() }
        let playing = "Card 5 Meta, " + String(localized: "Playing on \("External")", bundle: .appLanguage)
        let inUse = "Card 6 Meta, " + String(localized: "In use on \("Builtin")", bundle: .appLanguage)
        #expect(labels.contains(playing) && labels.contains(inUse), Comment(rawValue: "\(labels.filter { $0.hasPrefix("Card") })"))
        #expect(labels.contains("Card 4 Meta"), "a card set on no display reads as before")
    }

    @Test("A shelf card reads its status badge as its value, and not the now-playing capsule the badge is drawn in place of")
    func cardReadsItsStatusBadge() throws {
        let model = makeModel()
        let playing = try #require(NowPlayingBadge(on: [1], among: model.displays))
        model.shelfItems[5].nowPlaying = playing
        model.shelfItems[5].statusBadge = "File unavailable"
        model.shelfItems[6].nowPlaying = playing
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let badged = try #require(children.first { $0.accessibilityLabel()?.hasPrefix("Card 5 ") == true })
        let control = try #require(children.first { $0.accessibilityLabel()?.hasPrefix("Card 6 ") == true })
        #expect(badged.accessibilityValue() as? String == "File unavailable")
        #expect(badged.accessibilityLabel() == "Card 5 Meta", "the capsule the badge replaces is still read")
        // Control: without a badge the card still reads where it plays.
        #expect(control.accessibilityLabel() == "Card 6 Meta, " + playing.accessibilityText)
        #expect(control.accessibilityValue() as? String == "", "a reused element would keep an old badge")
    }

    @Test("The wave follows the pointer slot by slot instead of sticking to the card it lifted")
    func hoverFollowsThePointerAcrossSlots() {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let style = model.shelfStyle
        let pitch = StageGeometry.metrics(for: style).pitch
        let start = StageGeometry.hitRect(
            StageGeometry.cardPlacement(
                style: style, index: 5, count: 14, progress: 1, focus: 0,
                windowSize: view.bounds.size, capacity: model.shelfRenderBudget
            ),
            style: style
        )
        // Walk the pointer right one slot at a time, feeding the hover back like the mouse does.
        var seen: [Int] = []
        for step in 0 ..< 6 {
            let point = CGPoint(x: start.minX + 8 + CGFloat(step) * pitch, y: start.midY)
            guard let index = view.cardIndex(at: point) else { continue }
            seen.append(index)
            model.report(hoveredCard: model.shelfItems[index].id)
            view.advance(dt: 1.0 / 60)
        }
        #expect(seen == [5, 6, 7, 8, 9, 10], Comment(rawValue: "pointer walked slots but hovered \(seen)"))
    }

    @Test("A still pointer follows the row when the row moves underneath it")
    func hoverFollowsAMovingRowUnderAStillPointer() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfItems = (0 ..< 60).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "Meta", thumbnail: nil, nowPlaying: nil, isDraggable: true)
        }
        let view = EditDeskStageView(model: model)
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)

        // Park the pointer on one card without moving it again.
        let index = try #require(view.cardWindowForTesting.first.map { $0 + 3 })
        let rest = StageGeometry.hitRect(
            StageGeometry.cardPlacement(
                style: model.shelfStyle, index: index, count: model.shelfItems.count, progress: 1,
                focus: 0, windowSize: view.bounds.size, capacity: model.shelfRenderBudget
            ),
            style: model.shelfStyle
        )
        view.setPointerForTesting(CGPoint(x: rest.minX + 8, y: rest.midY))
        #expect(model.hoveredCard == model.shelfItems[index].id)
        let before = model.hoveredCard

        // The pointer does not move; an arrow-key reveal scrolls the row out from under it.
        let beforeReveal = view.debugFrameDriverRequests
        for _ in 0 ..< 30 {
            try view.keyDown(with: key(124))
        }
        #expect(
            model.hoveredCard != before,
            Comment(rawValue: "row scrolled but hover stayed on \(model.hoveredCard ?? "nil")")
        )
        // Handing the hover to another card leaves both hover springs running, and nothing else is
        // going to step them: no frame here means the outline and the lean freeze until the mouse
        // moves. The same holds for the other two renders that write spring targets off-gesture.
        #expect(view.debugNeedsDisplayLink)
        #expect(view.debugFrameDriverRequests > beforeReveal, "an arrow-key reveal has to wake the frame driver")
        let afterReveal = view.debugFrameDriverRequests
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.debugFrameDriverRequests > afterReveal, "layout re-renders and must not leave its springs unattended")
        let afterLayout = view.debugFrameDriverRequests
        view.viewDidChangeEffectiveAppearance()
        #expect(view.debugFrameDriverRequests > afterLayout, "an appearance flip re-renders too")
    }

    private func maxLift(_ view: EditDeskStageView) -> CGFloat {
        view.cardLayers.values.map { -CGFloat($0.lift.value) }.max() ?? 0
    }

    @Test("The wave eases in with the pointer's distance to the row instead of jumping onto the first card")
    func waveEasesInWithDistance() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfStyle = .crate
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let card = StageGeometry.cardPlacement(
            style: .crate, index: 5, count: 14, progress: 1, focus: 0,
            windowSize: view.bounds.size, capacity: model.shelfRenderBudget
        ).frame
        // Straight down onto card 5's own slot, so the crest sits on one card and full strength is 54pt.
        var lifts: [CGFloat] = []
        for y in stride(from: card.minY - 60, through: card.midY, by: 2) {
            try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: card.minX, y: y), in: view))
            view.advance(dt: 1.0 / 60)
            lifts.append(maxLift(view))
        }
        let steps = zip(lifts, lifts.dropFirst()).map { $1 - $0 }
        print("WAVE approach lifts \(lifts.map { ($0 * 10).rounded() / 10 })")
        #expect((steps.max() ?? 0) <= 8, Comment(rawValue: "the lift rose \(steps.max() ?? 0)pt in one 2pt step: \(lifts)"))
        #expect((steps.min() ?? 0) >= -0.001, Comment(rawValue: "the lift fell back on the way in: \(lifts)"))
        #expect(abs((lifts.last ?? 0) - 54) < 0.01, Comment(rawValue: "full strength should read 54pt, got \(lifts.last ?? 0)"))
        // Held still, nothing is left for the frame driver to step.
        for _ in 0 ..< 90 {
            view.advance(dt: 1.0 / 60)
        }
        #expect(!view.debugNeedsDisplayLink)
    }

    @Test("Pointing at the filter row lifts nothing, while the last stretch above the cards already does")
    func filterRowLiftsNothing() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfStyle = .crate
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let card = StageGeometry.cardPlacement(
            style: .crate, index: 5, count: 14, progress: 1, focus: 0,
            windowSize: view.bounds.size, capacity: model.shelfRenderBudget
        ).frame
        // The filter row rides `chipRowGap` (52pt) above the cards; 40pt up is on it.
        try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: card.minX, y: card.minY - 40), in: view))
        for _ in 0 ..< 30 {
            view.advance(dt: 1.0 / 60)
        }
        #expect(maxLift(view) == 0, Comment(rawValue: "the filter row lifted the shelf by \(maxLift(view))pt"))
        // Control: 10pt above the same card, with nothing hovered yet, the wave is already up.
        try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: card.minX, y: card.minY - 10), in: view))
        view.advance(dt: 1.0 / 60)
        #expect(model.hoveredCard == nil)
        #expect(maxLift(view) > 20, Comment(rawValue: "10pt above the row lifted \(maxLift(view))pt"))
    }

    @Test("A hovered crate card stays up while the pointer climbs onto the part its lift raised")
    func hoveredCardHoldsItsLift() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfStyle = .crate
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let card = StageGeometry.cardPlacement(
            style: .crate, index: 5, count: 14, progress: 1, focus: 0,
            windowSize: view.bounds.size, capacity: model.shelfRenderBudget
        ).frame
        try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: card.minX + 10, y: card.midY), in: view))
        for _ in 0 ..< 60 {
            view.advance(dt: 1.0 / 60)
        }
        try #require(model.hoveredCard == "card-5")
        // Up the card's own visible strip to 44pt above the row: still on the card, 10pt below its lifted top.
        for y in stride(from: card.midY, through: card.minY - 44, by: -4) {
            try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: card.minX + 10, y: y), in: view))
            view.advance(dt: 1.0 / 60)
        }
        for _ in 0 ..< 60 {
            view.advance(dt: 1.0 / 60)
        }
        #expect(model.hoveredCard == "card-5")
        let lift = try -CGFloat(#require(view.cardLayers["card-5"]).lift.value)
        #expect(lift > 53, Comment(rawValue: "the hovered card sank to \(lift)pt under the pointer"))
    }

    @Test("A centred style keeps the hover while the pointer climbs into the band its lift raised", arguments: [
        ShelfStyle.facingIn, .fan, .focusRow,
    ])
    func centredCardHoldsItsLiftedBand(style: ShelfStyle) throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfStyle = style
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let full = -StageGeometry.metrics(for: style).hoverLift
        let middle = try #require(view.cardLayers["card-0"]).hitRect
        // Near the left edge: the fan's next card lies over the rest of the middle one.
        let x = middle.minX + 30
        try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: x, y: middle.midY), in: view))
        for _ in 0 ..< 60 {
            view.advance(dt: 1.0 / 60)
        }
        try #require(model.hoveredCard == "card-0")
        // Halfway into the strip the lift uncovered above the resting card.
        try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: x, y: middle.minY - full / 2), in: view))
        for _ in 0 ..< 60 {
            view.advance(dt: 1.0 / 60)
        }
        #expect(model.hoveredCard == "card-0", Comment(rawValue: "\(style): hover moved to \(String(describing: model.hoveredCard))"))
        let lift = try -CGFloat(#require(view.cardLayers["card-0"]).lift.value)
        #expect(abs(lift - full) < 0.01, Comment(rawValue: "\(style): the card sank to \(lift)pt of \(full)pt"))
    }

    @Test("The centred styles hand the lift from card to card instead of jumping it", arguments: [
        ShelfStyle.facingIn, .fan, .focusRow,
    ])
    func centredStylesHandTheLiftOver(style: ShelfStyle) throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfStyle = style
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let full = -StageGeometry.metrics(for: style).hoverLift
        let middle = try #require(view.cardLayers["card-0"]).hitRect
        let next = try #require(view.cardLayers["card-1"]).hitRect
        // Where each card shows: a fan card only left of the card lying over it, a Facing In side
        // card only outside the middle one.
        let start = style == .fan ? middle.minX + 30 : middle.midX
        let end = style == .fan ? next.minX + 30 : next.maxX - 8
        try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: start, y: middle.midY), in: view))
        for _ in 0 ..< 60 {
            view.advance(dt: 1.0 / 60)
        }
        try #require(model.hoveredCard == "card-0")
        func lifts() -> [StageCard.ID: CGFloat] {
            view.cardLayers.mapValues { -CGFloat($0.lift.value) }
        }
        var previous = lifts()
        var worst: CGFloat = 0
        func frame() {
            view.advance(dt: 1.0 / 60)
            let now = lifts()
            for (id, lift) in now {
                worst = max(worst, abs(lift - (previous[id] ?? 0)))
            }
            previous = now
        }
        // Across onto the visible part of the right neighbour, 4pt a frame, then let it settle.
        for x in stride(from: start, through: end, by: 4) {
            try view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: x, y: middle.midY), in: view))
            frame()
        }
        #expect(model.hoveredCard == "card-1")
        for _ in 0 ..< 60 {
            frame()
        }
        print("HANDOFF \(style) worst frame step \(worst) of \(full)")
        #expect(worst <= full / 4, Comment(rawValue: "\(style): a lift moved \(worst)pt in one frame, the full lift is \(full)pt"))
        #expect(
            abs((previous["card-1"] ?? 0) - full) < 0.01 && (previous["card-0"] ?? 1) < 0.01,
            Comment(rawValue: "\(style): the lift ended at \(previous)")
        )
    }

    /// The face's corners taken through what `ShelfCardLayer` set on its layers — anchor, position,
    /// face transform and the host's perspective about its own centre — in stage space, at unit
    /// points (0,0), (1,0), (0,1), (1,1).
    private func drawnCorners(_ tile: ShelfCardLayer) -> [CGPoint] {
        let size = tile.face.bounds.size
        return [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map {
            drawnPoint(tile, CGPoint(x: $0.x * size.width, y: $0.y * size.height))
        }
    }

    /// `point`, in the face's own coordinates, taken to stage space the same way.
    private func drawnPoint(_ tile: ShelfCardLayer, _ point: CGPoint) -> CGPoint {
        let face = tile.face
        let host = tile.layer
        let t = face.transform
        let p = host.sublayerTransform
        let centre = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        // Row vectors, as Core Animation multiplies them.
        let x = point.x - face.anchorPoint.x * face.bounds.width
        let y = point.y - face.anchorPoint.y * face.bounds.height
        let fw = x * t.m14 + y * t.m24 + t.m44
        let hx = face.position.x + (x * t.m11 + y * t.m21 + t.m41) / fw - centre.x
        let hy = face.position.y + (x * t.m12 + y * t.m22 + t.m42) / fw - centre.y
        let hz = (x * t.m13 + y * t.m23 + t.m43) / fw
        let pw = hx * p.m14 + hy * p.m24 + hz * p.m34 + p.m44
        return CGPoint(
            x: host.frame.minX + centre.x + (hx * p.m11 + hy * p.m21 + hz * p.m31 + p.m41) / pw,
            y: host.frame.minY + centre.y + (hx * p.m12 + hy * p.m22 + hz * p.m32 + p.m42) / pw
        )
    }

    @Test("The centred styles' hit shapes are the corners their layers actually draw", arguments: [
        ShelfStyle.facingIn, .fan, .focusRow,
    ])
    func hitRectsMatchTheDrawnCorners(style: ShelfStyle) {
        let tile = ShelfCardLayer()
        tile.update(
            card: StageCard(id: "a", title: "A", metaLine: "", thumbnail: nil, nowPlaying: nil, isDraggable: true),
            increasedContrast: false
        )
        for focus in [6.0, 6.4] {
            for index in [2, 4, 5, 6, 7, 9] {
                let placement = StageGeometry.cardPlacement(
                    style: style, index: index, count: 13, progress: 1, focus: focus, windowSize: StageGeometry.designWindow
                )
                for hover in [0.0, 0.5, 1] {
                    tile.hover.jump(to: hover)
                    tile.place(placement, style: style, gridMix: 0, dragged: false, reduceMotion: false)
                    let corners = drawnCorners(tile)
                    let xs = corners.map(\.x)
                    let ys = corners.map(\.y)
                    let hit = tile.hitRect
                    let label = "\(style) card \(index), focus \(focus), hover \(hover): hit \(hit), drawn \(corners)"
                    #expect(
                        abs(hit.minX - (xs.min() ?? 0)) < 0.01 && abs(hit.maxX - (xs.max() ?? 0)) < 0.01
                            && abs(hit.minY - (ys.min() ?? 0)) < 0.01 && abs(hit.maxY - (ys.max() ?? 0)) < 0.01,
                        Comment(rawValue: label)
                    )
                    // Only a card turned in the plane is a rectangle on screen, so only there does the
                    // shape have to match corner for corner.
                    if style == .fan {
                        let turned = zip(tile.hitShape.corners, corners).map { hypot($0.x - $1.x, $0.y - $1.y) }
                        #expect(turned.allSatisfy { $0 < 0.01 }, Comment(rawValue: "\(label), shape \(tile.hitShape.corners)"))
                    }
                }
            }
        }
    }

    /// A point given in fan card `index`'s own unturned frame, relative to its centre, in stage space.
    private func point(onFanCard index: Int, x: CGFloat, y: CGFloat, focus: Double, in view: EditDeskStageView) -> CGPoint {
        let card = StageGeometry.cardPlacement(
            style: .fan, index: index, count: 14, progress: 1, focus: focus, windowSize: view.bounds.size
        )
        let turn = card.rotationZDegrees * .pi / 180
        return CGPoint(
            x: card.frame.midX + x * cos(turn) - y * sin(turn), y: card.frame.midY + x * sin(turn) + y * cos(turn)
        )
    }

    @Test("Fan hits follow each turned card: its exposed strip is its own, and 5pt past a neighbour's edge is not the neighbour's")
    func fanHitTestingFollowsTheTurnedCards() throws {
        let model = makeModel()
        model.shelfStyle = .fan
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        // Card 7 in the middle, so both sides of the fan are out.
        try view.scrollWheel(with: scroll(x: -420))
        let shown = model.visibleShelfRange
        try #require(shown == 1 ..< 14, Comment(rawValue: "\(shown)"))
        let edge = StageGeometry.cardSize.width / 2
        for index in shown {
            // 30pt in from the card's own left edge; the card lying over it starts about 60pt in.
            let strip = point(onFanCard: index, x: -edge + 30, y: 0, focus: 7, in: view)
            #expect(view.cardIndex(at: strip) == index, Comment(rawValue: "card \(index)'s strip at \(strip)"))
        }
        for index in shown.dropLast() {
            for y: CGFloat in [-40, 0, 40] {
                // Either side of the edge along which card `index + 1` starts to lie over card `index`.
                let outside = point(onFanCard: index + 1, x: -edge - 5, y: y, focus: 7, in: view)
                let inside = point(onFanCard: index + 1, x: -edge + 5, y: y, focus: 7, in: view)
                #expect(view.cardIndex(at: outside) == index, Comment(rawValue: "5pt outside card \(index + 1) at \(outside)"))
                #expect(view.cardIndex(at: inside) == index + 1, Comment(rawValue: "5pt inside card \(index + 1) at \(inside)"))
            }
        }
    }

    @Test("A hovered fan card slides 30pt out along its own up without turning upright, and owns the band it slid into")
    func fanHoverSlidesAlongTheRadius() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfStyle = .fan
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let rest = StageGeometry.cardPlacement(
            style: .fan, index: 4, count: 14, progress: 1, focus: 0, windowSize: view.bounds.size
        )
        let edge = StageGeometry.cardSize.width / 2
        try view.mouseMoved(with: mouse(.mouseMoved, at: point(onFanCard: 4, x: -edge + 30, y: 0, focus: 0, in: view), in: view))
        for _ in 0 ..< 90 {
            view.advance(dt: 1.0 / 60)
        }
        try #require(model.hoveredCard == "card-4")
        let tile = try #require(view.cardLayers["card-4"])
        let turn = rest.rotationZDegrees * .pi / 180
        let moved = CGPoint(x: tile.frame.midX - rest.frame.midX, y: tile.frame.midY - rest.frame.midY)
        #expect(
            abs(moved.x - 30 * sin(turn)) < 0.01 && abs(moved.y + 30 * cos(turn)) < 0.01,
            Comment(rawValue: "moved \(moved) for a card turned \(rest.rotationZDegrees)°")
        )
        #expect(tile.hitShape.rotationZDegrees == rest.rotationZDegrees, "the hover must not turn the card upright")
        // 15pt past the resting top edge, in the card's own frame: the slid card covers it, no card at rest does.
        let band = point(onFanCard: 4, x: -edge + 30, y: -56 - 15, focus: 0, in: view)
        try view.mouseMoved(with: mouse(.mouseMoved, at: band, in: view))
        view.advance(dt: 1.0 / 60)
        #expect(model.hoveredCard == "card-4", Comment(rawValue: "the band at \(band) went to \(String(describing: model.hoveredCard))"))
        // 5pt past the slid card's left edge at the same height is outside it, however wide its box is.
        let beside = point(onFanCard: 4, x: -edge - 5, y: -56 - 15, focus: 0, in: view)
        #expect(view.cardIndex(at: beside) == nil, Comment(rawValue: "\(beside)"))
    }

    @Test("The keyboard focus ring turns with the fan card it sits on")
    func focusRingTurnsWithTheFanCard() throws {
        let model = makeModel()
        model.shelfStyle = .fan
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        // A press focuses the card where it lies; only the arrow keys bring it to the middle.
        let strip = point(onFanCard: 4, x: -StageGeometry.cardSize.width / 2 + 30, y: 0, focus: 0, in: view)
        try view.mouseDown(with: mouse(.leftMouseDown, at: strip, in: view))
        try #require(view.debugFocusedCardIndex == 4)
        let tile = try #require(view.cardLayers["card-4"])
        let ring = view.debugFocusRing
        let turn = atan2(ring.transform.m12, ring.transform.m11) * 180 / .pi
        #expect(!ring.isHidden)
        #expect(ring.bounds.size == tile.hitShape.rect.size, Comment(rawValue: "ring \(ring.bounds.size), card \(tile.hitShape.rect.size)"))
        #expect(
            abs(turn - tile.hitShape.rotationZDegrees) < 0.000_001,
            Comment(rawValue: "ring turned \(turn)°, card \(tile.hitShape.rotationZDegrees)°")
        )
        #expect(abs(ring.position.x - tile.hitShape.rect.midX) < 0.000_001 && abs(ring.position.y - tile.hitShape.rect.midY) < 0.000_001)
    }

    private func bigLibrary(_ count: Int) -> [StageCard] {
        (0 ..< count).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "", thumbnail: nil, nowPlaying: nil, isDraggable: true)
        }
    }

    @Test("A scrolled shelf expanding to the grid keeps two windows instead of one span")
    func gridFlightWindowIsAUnionNotAHull() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfItems = bigLibrary(1000)
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        try view.scrollWheel(with: scroll(x: -19200))
        let rowWindow = model.visibleShelfRange
        #expect(rowWindow.contains(400) && !rowWindow.contains(0))
        model.setProgress(2, animated: true)
        let gridWindow = StageGeometry.visibleGridCards(count: 1000, windowSize: view.bounds.size, scrollOffset: 0)
        #expect(!gridWindow.isEmpty)
        let budget = rowWindow.count + gridWindow.count
        #expect(view.cardLayers.count <= budget, Comment(rawValue: "built \(view.cardLayers.count) layers for \(budget) visible cards"))
        // Nothing between the two runs is on screen in either of them.
        #expect(view.cardLayers["card-200"] == nil)
        #expect(view.cardLayers["card-400"] != nil)
        for index in gridWindow {
            #expect(view.cardLayers["card-\(index)"] != nil)
        }
        for _ in 0 ..< 480 {
            view.advance(dt: 1 / 120)
            if model.snappedIndex == 2 {
                break
            }
        }
        #expect(model.snappedIndex == 2)
        // The grid window does not shrink back at p = 2, so this is what stays resident.
        #expect(view.cardLayers.count <= budget, Comment(rawValue: "\(view.cardLayers.count) layers resident at p = 2"))
        #expect(model.visibleShelfRange == rowWindow)
        #expect(model.visibleGridRange == gridWindow)
    }

    @Test("A card that enters the window mid-stagger still flies to the grid")
    func lateCardJoinsTheStagger() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfItems = bigLibrary(1000)
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        try view.scrollWheel(with: scroll(x: -19200))
        let before = StageGeometry.visibleGridCards(count: 1000, windowSize: view.bounds.size, scrollOffset: 0)
        model.setProgress(2, animated: true)
        for _ in 0 ..< 6 {
            view.advance(dt: 1 / 60)
        }
        #expect(view.debugStaggerToGrid)
        let wider = CGSize(width: 1700, height: StageGeometry.designWindow.height)
        view.frame = CGRect(origin: .zero, size: wider)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let after = StageGeometry.visibleGridCards(count: 1000, windowSize: wider, scrollOffset: 0)
        let late = try #require(after.first { !before.contains($0) })
        let tile = try #require(view.cardLayers["card-\(late)"])
        #expect(tile.gridProgress.target == 2, Comment(rawValue: "card \(late) is flying to \(tile.gridProgress.target)"))
        for _ in 0 ..< 480 {
            view.advance(dt: 1 / 120)
            if model.snappedIndex == 2 {
                break
            }
        }
        #expect(sameRect(tile.frame, StageGeometry.gridFrame(index: late, windowWidth: view.bounds.width)))
    }

    @Test("Fingers landing mid-stagger never teleport a card")
    func freezingMidStaggerIsContinuous() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        model.setProgress(2, animated: true)
        for _ in 0 ..< 6 {
            view.advance(dt: 1 / 60)
        }
        let before = view.cardLayers.mapValues(\.frame.minY)
        // Only meaningful while the cards are spread across the transition: that spread is what a
        // switch back to the global progress would collapse.
        let spread = try #require(before.values.max()) - #require(before.values.min())
        #expect(spread > 20, Comment(rawValue: "the stagger only spread the row by \(spread)pt"))
        try view.scrollWheel(with: scroll(phase: .began))
        #expect(view.cardLayers.values.allSatisfy { $0.gridProgress.target == model.progress }, "the fingers have to take the stagger over")
        for (id, tile) in view.cardLayers {
            let moved = tile.frame.minY - (before[id] ?? tile.frame.minY)
            #expect(abs(moved) < 0.5, Comment(rawValue: "card \(id) jumped \(moved)pt on the frame the fingers landed"))
        }
        // Releasing back towards the grid re-seeds the flight; the cards have to carry on from
        // where the fingers left them.
        let frozen = view.cardLayers.mapValues(\.frame.minY)
        model.setProgress(2, animated: true)
        for (id, tile) in view.cardLayers {
            let moved = tile.frame.minY - (frozen[id] ?? tile.frame.minY)
            #expect(abs(moved) < 0.5, Comment(rawValue: "card \(id) jumped \(moved)pt when the gesture was released"))
        }
    }

    @Test("The row's limits follow the window and the shelf budget, not only the library")
    func rowClampFollowsTheWindowAndTheBudget() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfItems = bigLibrary(1000)
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        let narrow = CGSize(width: StageGeometry.minimumWindow.width, height: StageGeometry.designWindow.height)
        view.frame = CGRect(origin: .zero, size: narrow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        try view.scrollWheel(with: scroll(x: -60000))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        try expectRowAtItsEnd(view, model, after: "a layout pass on the stretched row")

        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        try expectRowAtItsEnd(view, model, after: "the window widened")

        model.shelfRenderBudget = 40
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        try expectRowAtItsEnd(view, model, after: "the shelf budget grew")
    }

    @Test("A wheel scroll after a shrink-clamp continues from the row on screen, not from zero")
    func wheelAfterAClampDoesNotTeleport() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfItems = bigLibrary(1000)
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        try view.scrollWheel(with: scroll(x: -19200))
        model.shelfItems = Array(model.shelfItems.prefix(300))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let before = view.cardWindowForTesting
        #expect(before.upperBound == 300, Comment(rawValue: "the clamp left the row at \(before)"))
        try view.scrollWheel(with: scroll(x: -24))
        #expect(
            abs(view.cardWindowForTesting.lowerBound - before.lowerBound) <= 1,
            Comment(rawValue: "one notch moved the window from \(before) to \(view.cardWindowForTesting)")
        )
    }

    @Test("A modal opening mid-flick settles the row onto a slot instead of leaving it between two")
    func interactionLockSettlesTheRow() throws {
        let pitch = StageGeometry.metrics(for: .crate).pitch
        func rowOffset(_ view: EditDeskStageView) throws -> CGFloat {
            let tile = try #require(view.cardLayers["card-400"])
            return tile.frame.minX - StageGeometry.rowFrame(
                style: .crate, index: 400, count: 1000, focus: 0, windowSize: view.bounds.size
            ).minX
        }
        func scrolledStage() throws -> (EditDeskStageModel, EditDeskStageView) {
            let model = makeModel()
            model.reduceMotion = false
            model.shelfItems = bigLibrary(1000)
            let view = EditDeskStageView(model: model)
            view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
            view.layoutSubtreeIfNeeded()
            model.setProgress(1, animated: false)
            // Ten points past a slot: inside the limits, so only the interrupted gesture's own
            // settle can bring the row back into line.
            try view.scrollWheel(with: scroll(x: -19210))
            return (model, view)
        }

        let (model, view) = try scrolledStage()
        defer { view.detach() }
        model.interactionBlocked = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        for _ in 0 ..< 120 {
            view.advance(dt: 1 / 60)
        }
        let settled = try rowOffset(view)
        #expect(abs(settled - (settled / pitch).rounded() * pitch) < 0.5, Comment(rawValue: "the row rests at \(settled)"))
        #expect(abs(settled + 19200) < 0.5, Comment(rawValue: "the row rests at \(settled)"))

        let (_, control) = try scrolledStage()
        defer { control.detach() }
        control.needsLayout = true
        control.layoutSubtreeIfNeeded()
        for _ in 0 ..< 120 {
            control.advance(dt: 1 / 60)
        }
        let unlocked = try rowOffset(control)
        #expect(abs(unlocked + 19210) < 0.5, "without the lock the row stays where the gesture left it")
    }

    @Test("A shrinking library clamps a row target the spring has not reached yet")
    func shrinkClampsTheRowTarget() throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfItems = bigLibrary(1000)
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        let size = CGSize(width: 1100, height: StageGeometry.designWindow.height)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        // The shrunken library's limit falls between a slot and the offset the row is scrolled to,
        // so the value stays inside the new limits while the settle target does not.
        let kept = 300
        let pitch = StageGeometry.metrics(for: .crate).pitch
        let band = StageGeometry.shelfBand(style: .crate, capacity: model.shelfRenderBudget, windowSize: size)
        let last = StageGeometry.rowFrame(
            style: .crate, index: kept - 1, count: kept, focus: 0, windowSize: size, capacity: model.shelfRenderBudget
        )
        let limit = band.upperBound - last.minX
        let slot = (limit / pitch).rounded(.down) * pitch
        let start = CGFloat(Int32(((limit + slot + pitch / 2) / 2).rounded()))
        try #require(start > limit)
        try #require((start / pitch).rounded() * pitch < limit)
        try view.scrollWheel(with: scroll(x: Int32(start)))
        // The interaction lock stands in for the release the flick never got: it points the row
        // spring at that slot while the row itself is still where the fingers left it.
        model.interactionBlocked = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        // Without that divergence the shrink has nothing to catch and the rest of this proves nothing.
        try #require(view.debugRowTarget < Double(limit))
        model.interactionBlocked = false
        model.shelfItems = Array(model.shelfItems.prefix(kept))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        for _ in 0 ..< 120 {
            view.advance(dt: 1 / 60)
        }
        // The clamp stops the flight where the row is, so the last card may rest short of the
        // band's end — but never past it, which is where the stale target was pointing.
        let tile = try #require(view.cardLayers["card-\(kept - 1)"])
        #expect(
            tile.frame.minX >= band.upperBound - 0.5,
            Comment(rawValue: "the row flew \(band.upperBound - tile.frame.minX)pt past its new end")
        )
    }

    @Test("A drag started while the snap to the grid is still flying is a cancelled click")
    func dragDuringTheSnapToTheGridIsACancelledClick() async throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        var events = model.events.makeAsyncIterator()
        #expect(await events.next() == .snapped(1))
        model.setProgress(2, animated: true)
        for _ in 0 ..< 3 {
            view.advance(dt: 1 / 60)
        }
        #expect(model.progress > 1 && model.progress < 2)
        let hit = StageGeometry.hitRect(StageGeometry.cardPlacement(
            style: model.shelfStyle, index: 3, count: 14, progress: model.progress, focus: 0, windowSize: view.bounds.size
        ), style: model.shelfStyle)
        let point = CGPoint(x: hit.minX + 8, y: hit.midY)
        _ = try #require(view.cardIndex(at: point))
        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: point.x + 20, y: point.y), in: view))
        #expect(!view.debugDragging, "a snap still flying to the grid must not become a drag")
        try view.mouseUp(with: mouse(.leftMouseUp, at: point, in: view))
        for _ in 0 ..< 480 {
            view.advance(dt: 1 / 120)
            if model.snappedIndex == 2 {
                break
            }
        }
        // The press was cancelled, so nothing was tapped between the two snaps.
        #expect(await events.next() == .snapped(2))

        let control = makeModel()
        control.reduceMotion = false
        let settled = EditDeskStageView(model: control)
        defer { settled.detach() }
        settled.frame = view.frame
        settled.layoutSubtreeIfNeeded()
        control.setProgress(1, animated: false)
        let rest = StageGeometry.hitRect(StageGeometry.cardPlacement(
            style: control.shelfStyle, index: 3, count: 14, progress: 1, focus: 0, windowSize: settled.bounds.size
        ), style: control.shelfStyle)
        let restPoint = CGPoint(x: rest.minX + 8, y: rest.midY)
        try settled.mouseDown(with: mouse(.leftMouseDown, at: restPoint, in: settled))
        try settled.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: restPoint.x + 20, y: restPoint.y), in: settled))
        #expect(settled.debugDragging, "a settled shelf still starts drags")
    }

    @Test("A card dragged before a scroll has landed still leaves the stage on a rest state")
    func dragBeforeTheScrollLandsStillLands() async throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        // No phase, so the landing is left to the snap that fires once the scroll goes quiet.
        try view.scrollWheel(with: scroll(y: -24))
        try #require(model.progress > 1 && model.progress < 1.5, Comment(rawValue: "the scroll moved the stage to \(model.progress)"))
        let hit = StageGeometry.hitRect(StageGeometry.cardPlacement(
            style: model.shelfStyle, index: 3, count: 14, progress: model.progress, focus: 0, windowSize: view.bounds.size
        ), style: model.shelfStyle)
        let point = CGPoint(x: hit.minX + 8, y: hit.midY)
        try view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view))
        try view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: point.x + 20, y: point.y), in: view))
        try #require(view.debugDragging)
        try view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: point.x + 20, y: point.y), in: view))
        // Long enough for any snap the drag left scheduled to fire.
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0 ..< 480 {
            view.advance(dt: 1 / 120)
        }
        #expect(model.progress == model.progress.rounded(), Comment(rawValue: "the stage rests at \(model.progress)"))
        #expect(Double(model.snappedIndex) == model.progress)
    }

    @Test("The library grid mounts only once the stage has landed on it, and stays while the stage carries the cards off it")
    func libraryGridWaitsForTheLanding() {
        // Mid-swipe past the handoff point the cards are still the stage's.
        #expect(!HomePage.mountsLibraryGrid(page: .library, snappedIndex: 1, progress: 1.842))
        #expect(!HomePage.mountsLibraryGrid(page: .home, snappedIndex: 1, progress: 1.842))
        // Landed, but the page has not taken the snap yet.
        #expect(!HomePage.mountsLibraryGrid(page: .home, snappedIndex: 2, progress: 2))
        #expect(HomePage.mountsLibraryGrid(page: .library, snappedIndex: 2, progress: 2))
        #expect(HomePage.mountsLibraryGrid(page: .library, snappedIndex: 2, progress: 1.9))
        #expect(!HomePage.mountsLibraryGrid(page: .library, snappedIndex: 2, progress: 1.7))
        // Leaving keeps the grid however deep the return goes, and never mounts it before a landing.
        #expect(HomePage.mountsLibraryGrid(page: .library, snappedIndex: 2, progress: 1.2, leaving: true))
        #expect(!HomePage.mountsLibraryGrid(page: .library, snappedIndex: 1, progress: 1.2, leaving: true))
    }

    @Test("A quick apply goes to the display the library was opened for, else the main display, else the first")
    func quickApplyTarget() {
        #expect(HomePage.quickApplyTarget(displays: [1, 2, 3], main: 2, libraryTarget: 3) == 3)
        #expect(HomePage.quickApplyTarget(displays: [1, 2, 3], main: 2, libraryTarget: nil) == 2)
        #expect(HomePage.quickApplyTarget(displays: [1, 2, 3], main: 2, libraryTarget: 9) == 2, "the library's display was unplugged")
        #expect(HomePage.quickApplyTarget(displays: [1, 2, 3], main: nil, libraryTarget: nil) == 1)
    }

    @Test("A re-snap to the grid while cards are still flying keeps them flying and waits for them to land before handing over")
    func snapToTheGridWaitsForTheStagger() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        model.setProgress(2, animated: true)
        for _ in 0 ..< 10 {
            view.advance(dt: 1 / 120)
        }
        try #require(view.debugStaggerToGrid && model.snappedIndex != 2, "the cards were not flying at the re-snap, so nothing was tested")
        let before = view.cardLayers.mapValues(\.frame)
        // What a second Up arrow asks for mid-flight.
        model.setProgress(2, animated: true)
        for (id, tile) in view.cardLayers {
            let was = try #require(before[id])
            let jump = max(abs(tile.frame.minX - was.minX), abs(tile.frame.minY - was.minY), abs(tile.frame.width - was.width))
            #expect(jump < 0.5, Comment(rawValue: "\(id) jumped \(jump)pt on the re-snap"))
        }
        for _ in 0 ..< 480 {
            view.advance(dt: 1 / 120)
            if model.snappedIndex == 2 {
                break
            }
        }
        #expect(model.snappedIndex == 2)
        // Landed, not necessarily settled: within half a point of the tile the grid can fade in over the card.
        for (index, card) in model.shelfItems.enumerated() {
            let tile = try #require(view.cardLayers[card.id]).frame
            let grid = StageGeometry.gridFrame(index: index, windowWidth: view.bounds.width)
            let off = max(abs(tile.minX - grid.minX), abs(tile.minY - grid.minY), abs(tile.width - grid.width))
            #expect(off <= 0.5, Comment(rawValue: "card \(index) is \(off)pt off its tile at the handover: \(tile)"))
        }
    }

    @Test("The grid takes over once every card sits within half a point of its tile, not after the springs finish creeping")
    func gridTakesOverWhenTheCardsHaveLanded() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        model.setProgress(2, animated: true)
        var elapsed = 0.0
        while model.snappedIndex != 2, elapsed < 4 {
            view.advance(dt: 1 / 120)
            elapsed += 1 / 120
        }
        try #require(model.snappedIndex == 2)
        #expect(elapsed < 0.7, Comment(rawValue: "the grid waited \(elapsed)s after the release"))
        let atHandover = Dictionary(uniqueKeysWithValues: view.cardLayers.map { ($0.key, $0.value.frame) })
        for _ in 0 ..< 240 {
            view.advance(dt: 1 / 120)
        }
        for (id, frame) in atHandover {
            let settled = try #require(view.cardLayers[id]).frame
            let moved = max(abs(settled.minX - frame.minX), abs(settled.minY - frame.minY), abs(settled.width - frame.width))
            #expect(moved <= 0.5, Comment(rawValue: "\(id) moved \(moved)pt under the grid after the handover"))
        }
    }

    @Test(
        "A swipe's momentum end neither restarts the landing its release began nor lands it a second time",
        .timeLimit(.minutes(1)), arguments: [false, true]
    )
    func momentumEndLeavesTheReleaseLanding(landsFirst: Bool) async throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        try view.scrollWheel(with: scroll(phase: .began))
        for _ in 0 ..< 4 {
            try view.scrollWheel(with: scroll(y: -80, phase: .changed))
        }
        // Held still before lifting, so the landing starts from rest instead of from the synthetic events' spacing.
        try await Task.sleep(for: .milliseconds(200))
        #expect(try view.forwardGridScroll(scroll(phase: .ended)) == nil, "the release left the stage")
        for _ in 0 ..< 3 {
            view.advance(dt: 1 / 120)
        }
        try #require(
            model.progress > StageGeometry.libraryHandoffProgress && model.progress < 2,
            Comment(rawValue: "the landing is at \(model.progress)")
        )
        var before = model.progress
        view.advance(dt: 1 / 120)
        let step = model.progress - before
        let momentumEnd = try scroll(momentum: .end)
        try #require(momentumEnd.momentumPhase.contains(.ended))
        #expect(view.forwardGridScroll(momentumEnd) == nil, "the momentum end left the stage")
        if landsFirst {
            // Landed without suspending, so a snap the momentum end scheduled can only fire afterwards.
            var frames = 0
            while model.snappedIndex != 2, frames < 480 {
                view.advance(dt: 1 / 120)
                frames += 1
            }
            try #require(model.snappedIndex == 2)
        }
        // Past `snapDelay`: a snap the momentum end scheduled has fired by now.
        try await Task.sleep(for: .milliseconds(200))
        if !landsFirst {
            before = model.progress
            view.advance(dt: 1 / 120)
            #expect(
                model.progress - before > step / 2,
                Comment(rawValue: "the landing restarted from rest: \(model.progress - before) in a frame after \(step)")
            )
        }
        for _ in 0 ..< 480 {
            view.advance(dt: 1 / 120)
        }
        #expect(model.progress == 2 && model.snappedIndex == 2)
        model.emit(.cardTapped("end"))
        var landings = 0
        for await event in model.events {
            if event == .cardTapped("end") {
                break
            }
            if event == .snapped(2) {
                landings += 1
            }
        }
        #expect(landings == 1, Comment(rawValue: "the stage reported landing on the grid \(landings) times"))
    }

    @Test("Cards leave for the grid together, in order on critically damped springs of 0.34s to 0.44s", arguments: [14, 1000])
    func staggerToTheGridIsShort(count: Int) throws {
        let model = makeModel()
        model.reduceMotion = false
        model.shelfItems = bigLibrary(count)
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        model.setProgress(2, animated: true)
        let springs = model.shelfItems.compactMap { view.cardLayers[$0.id]?.gridProgress }
        let responses = springs.map(\.parameters.response)
        let first = try #require(responses.first)
        let last = try #require(responses.last)
        #expect(abs(first - 0.34) < 1e-9 && abs(last - 0.44) < 1e-9, Comment(rawValue: "\(springs.count) cards respond from \(first)s to \(last)s"))
        #expect(zip(responses.dropFirst(), responses).allSatisfy { $0 >= $1 }, "a later card responds faster than an earlier one")
        #expect(springs.allSatisfy { $0.parameters.dampingFraction == 1 }, "a card's spring overshoots its tile")
        view.advance(dt: 1 / 120)
        let waiting = model.shelfItems.filter { (view.cardLayers[$0.id]?.gridProgress.value ?? 2) <= 1 }.count
        #expect(waiting == 0, Comment(rawValue: "\(waiting) cards sat out the first frame"))
    }

    @Test("A long hitch moves every card's flight and the shake timer on the same clock")
    func hitchKeepsEveryTimerOnTheSameClock() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        model.setProgress(2, animated: true)
        view.shake(card: "card-5")
        var expected = view.cardLayers.mapValues(\.gridProgress)
        for id in expected.keys {
            expected[id]?.step(dt: StageSpring.maximumStep)
        }
        view.advance(dt: 0.3)
        let overran = view.cardLayers.filter { $0.value.gridProgress.value != expected[$0.key]?.value }.map(\.key)
        #expect(overran.isEmpty, Comment(rawValue: "a 300ms hitch moved \(overran.sorted()) further than one 100ms step"))
        #expect(view.cardLayers["card-5"]?.shakeElapsed != nil, "the shake timer runs on the frame clock too")
    }

    @Test("An empty thumbnail opens detail everywhere instead of embedding setup controls")
    func emptyScreenOpensDetail() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        var events = model.events.makeAsyncIterator()
        let shell = try #require(view.displayLayers[2])
        let center = shell.content.convert(CGPoint(x: shell.content.bounds.midX, y: shell.content.bounds.midY), to: view.layer)
        view.tap(at: center)
        #expect(await events.next() == .displayTapped(2))
    }

    @Test("VoiceOver reaches both entry points on an empty display and neither on a wallpapered one")
    func emptyScreenAccessibilityActions() async throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let children = try #require(view.accessibilityChildren())
        let empty = try #require(children.first { ($0 as? NSAccessibilityElement)?.accessibilityLabel()?.hasPrefix("Builtin") == true })
        let filled = try #require(children.first { ($0 as? NSAccessibilityElement)?.accessibilityLabel()?.hasPrefix("External") == true })
        let actions = try #require((empty as? NSAccessibilityElement)?.accessibilityCustomActions())
        #expect(actions.map(\.name) == [
            String(localized: "Choose File", bundle: .appLanguage),
            String(localized: "Paste URL", bundle: .appLanguage),
        ])
        #expect((filled as? NSAccessibilityElement)?.accessibilityCustomActions()?.isEmpty == true)
        var events = model.events.makeAsyncIterator()
        #expect(actions[1].handler?() == true)
        #expect(await events.next() == .emptyActionTapped(2, .pasteURL))
    }

    @Test("Reduce Motion leaves the empty entry points with nothing but opacity animations")
    func emptyScreenUnderReducedMotion() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[2])
        shell.setHovered(true, reduceMotion: true)
        shell.step(dt: 1.0 / 60, reduceMotion: true)
        func layers(_ root: CALayer) -> [CALayer] {
            [root] + (root.sublayers ?? []).flatMap { layers($0) }
        }
        for layer in layers(shell.layer) {
            for key in layer.animationKeys() ?? [] {
                let animation = try #require(layer.animation(forKey: key) as? CAPropertyAnimation)
                #expect(animation.keyPath == "opacity", Comment(rawValue: "\(key) animates \(animation.keyPath ?? "nothing")"))
            }
        }
        #expect(CATransform3DIsIdentity(shell.layer.transform), "Reduce Motion drops the hover lift")
        #expect(CATransform3DIsIdentity(shell.coverGroup.transform), "Reduce Motion drops the hover zoom")
    }

    private func textLayers(in root: CALayer) -> [CATextLayer] {
        ((root as? CATextLayer).map { [$0] } ?? []) + (root.sublayers ?? []).flatMap { textLayers(in: $0) }
    }

    @Test("Hover zooms the picture inside the screen and leaves the display itself still")
    func hoverZoomsTheCoverNotTheShell() throws {
        let model = makeModel()
        model.reduceMotion = false
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        #expect(CATransform3DIsIdentity(shell.coverGroup.transform))
        #expect(shell.coverGroup.anchorPoint == CGPoint(x: 0.5, y: 0.5), "an off-centre anchor crops one side")
        #expect(shell.cover.superlayer === shell.coverGroup)

        shell.setHovered(true)
        for _ in 0 ..< 60 {
            shell.step(dt: 1.0 / 60, reduceMotion: false)
        }
        #expect(CATransform3DIsIdentity(shell.layer.transform), "the shell must not move any more")
        #expect(abs(shell.coverGroup.transform.m11 - 1.04) < 0.001, Comment(rawValue: "\(shell.coverGroup.transform.m11)"))
        #expect(abs(shell.coverGroup.transform.m22 - 1.04) < 0.001)
        // The zoom must not reach the text or the transport: they are content's own sublayers.
        #expect(shell.coverGroup.sublayers?.compactMap { $0 as? CATextLayer }.isEmpty == true)

        shell.setHovered(false)
        for _ in 0 ..< 60 {
            shell.step(dt: 1.0 / 60, reduceMotion: false)
        }
        #expect(abs(shell.coverGroup.transform.m11 - 1) < 0.001, "the picture returns to its own size")
    }

    @Test("The two lines inside the screen name the wallpaper, not the display")
    func screenLinesNameTheWallpaper() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        var display = model.displays[0]
        display.wallpaperTitle = "Aurora"
        display.wallpaperKind = "Video"
        shell.update(display: display, dropHint: "", increasedContrast: false)
        shell.layoutContent()
        let lines = try #require(shell.content.sublayers?.compactMap { $0 as? CATextLayer })
        #expect(lines.count == 2)
        #expect(lines.map { $0.string as? String } == ["Aurora", "Video"])
        #expect(lines.map(\.fontSize) == [17, 12])
    }

    /// The macOS type ladder is 10 / 11 / 12 / 13 / 15 / 17 / 22 / 26; the stage draws six of them.
    @Test("Every text layer a shell draws sits on the macOS type ladder")
    func shellTextSizesFollowTheLadder() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        #expect(textLayers(in: shell.layer).map(\.fontSize).sorted() == [12, 12, 12, 13, 15, 17, 17])
        model.setProgress(1, animated: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let tile = try #require(view.cardLayers["card-0"])
        #expect(textLayers(in: tile.layer).map(\.fontSize) == [11])
    }

    @Test("Previous and next take a tap only where the playlist can actually move")
    func playbackHitTestingFollowsCapability() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        var display = model.displays[0]
        display.canTogglePlayback = true

        func show(_ configure: (inout StageDisplay) -> Void) {
            configure(&display)
            shell.update(display: display, dropHint: "", increasedContrast: false)
            shell.layoutContent()
            shell.setHovered(true, reduceMotion: true)
        }

        /// Centre of the `index`th button of the capsule a playlist display draws, in shell points.
        func centre(_ index: Int, showsPlaylistControls: Bool) -> CGPoint {
            let layout = StageGeometry.playbackLayout(
                content: shell.content.bounds.size, showsPlaylistControls: showsPlaylistControls
            )
            let button = layout.buttons[index].offsetBy(
                dx: layout.container.minX + shell.content.frame.minX,
                dy: layout.container.minY + shell.content.frame.minY
            )
            return CGPoint(x: button.midX, y: button.midY)
        }

        show { $0.showsPlaylistControls = true; $0.canChangePlaylistEntry = true }
        #expect(shell.playbackAction(at: centre(0, showsPlaylistControls: true)) == .previous)
        #expect(shell.playbackAction(at: centre(1, showsPlaylistControls: true)) == .toggle)
        #expect(shell.playbackAction(at: centre(2, showsPlaylistControls: true)) == .next)

        // A playlist of one: the buttons stay put so the row does not reflow, but they are dead.
        show { $0.canChangePlaylistEntry = false }
        #expect(shell.playbackAction(at: centre(0, showsPlaylistControls: true)) == nil)
        #expect(shell.playbackAction(at: centre(2, showsPlaylistControls: true)) == nil)
        #expect(shell.playbackAction(at: centre(1, showsPlaylistControls: true)) == .toggle)

        // Not a playlist at all: previous and next are not drawn, so their slots answer to nobody.
        show { $0.showsPlaylistControls = false }
        #expect(shell.playbackAction(at: centre(0, showsPlaylistControls: true)) == nil)
        #expect(shell.playbackAction(at: centre(0, showsPlaylistControls: false)) == .toggle)

        show { $0.canTogglePlayback = false }
        #expect(shell.playbackAction(at: centre(0, showsPlaylistControls: false)) == nil)
    }

    @Test("The shell's state pill, transport capsule and main button round to at most half their size")
    func shellCapsulesRoundWithinTheirSize() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        var display = model.displays[0]
        display.state = .paused(reasonText: "Paused")
        display.showsPlaylistControls = true
        display.canTogglePlayback = true
        shell.update(display: display, dropHint: "", increasedContrast: false)
        shell.layoutContent()
        shell.setHovered(true, reduceMotion: true)
        let layout = StageGeometry.playbackLayout(content: shell.content.bounds.size, showsPlaylistControls: true)
        let pill = try #require(shell.content.sublayers?.first { layer in
            layer.sublayers?.contains { ($0 as? CATextLayer)?.string as? String == "Paused" } == true
        })
        let transport = try #require(shell.content.sublayers?.first { sameRect($0.frame, layout.container) })
        let mainButton = try #require(transport.sublayers?.first { sameRect($0.frame, layout.buttons[1]) })
        for (name, layer) in [("state pill", pill), ("transport", transport), ("main button", mainButton)] {
            try #require(!layer.isHidden && layer.bounds.height > 0, Comment(rawValue: "the \(name) is not laid out"))
            #expect(
                layer.cornerRadius <= min(layer.bounds.width, layer.bounds.height) / 2,
                Comment(rawValue: "the \(name) rounds \(layer.cornerRadius) on \(layer.bounds.size)")
            )
        }
    }

    @Test("The screen's own two lines stop short of the transport at either capsule width")
    func inScreenLinesClearTheTransport() throws {
        let model = makeModel()
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let shell = try #require(view.displayLayers[1])
        var display = model.displays[0]
        display.wallpaperTitle = String(repeating: "Aurora Borealis ", count: 12)
        display.wallpaperKind = String(repeating: "Video ", count: 12)

        for showsPlaylistControls in [true, false] {
            display.showsPlaylistControls = showsPlaylistControls
            shell.update(display: display, dropHint: "", increasedContrast: false)
            shell.layoutContent()
            let size = shell.content.bounds.size
            let container = StageGeometry.playbackLayout(
                content: size, showsPlaylistControls: showsPlaylistControls
            ).container
            let lines = textLayers(in: shell.content).filter {
                abs($0.frame.minY - (size.height - 49)) < 0.5 || abs($0.frame.minY - (size.height - 25)) < 0.5
            }
            #expect(lines.count == 2, "the title and the kind line are the two rows in the band")
            for line in lines {
                #expect(line.frame.maxX <= container.minX, "a line runs under the transport capsule")
            }
        }
    }
}
