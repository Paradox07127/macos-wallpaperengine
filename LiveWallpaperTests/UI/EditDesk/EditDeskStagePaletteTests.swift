import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// Updates reach the stage outside drawing callbacks too — the observation task, the display link,
/// events — where the thread's drawing appearance is whatever its last setter left. These pin it to
/// the other tier from the window's.
extension EditDeskStageViewTests {
    private static let windowTier = NSAppearance.Name.darkAqua
    private static let threadTier = NSAppearance.Name.aqua

    private static func offTier(_ body: () -> Void) {
        NSAppearance(named: threadTier)?.performAsCurrentDrawingAppearance(body)
    }

    /// Attaching is the appearance update. AppKit calls `viewDidChangeEffectiveAppearance` for it with
    /// the thread still on the other tier, as it does when General → Appearance sets `NSApp.appearance`;
    /// setting `window.appearance` would hand the callback the new tier instead.
    private static func mount(_ model: EditDeskStageModel) -> (EditDeskStageView, NSWindow) {
        let view = EditDeskStageView(model: model)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.appearance = NSAppearance(named: windowTier)
        offTier {
            window.contentView = view
            view.layoutSubtreeIfNeeded()
        }
        return (view, window)
    }

    private static func display(_ id: StageDisplay.ID, _ name: String, x: CGFloat, state: StageDisplay.State) -> StageDisplay {
        StageDisplay(
            id: id, fingerprint: name, frame: CGRect(x: x, y: 0, width: 1920, height: 1080), isBuiltin: false,
            name: name, badgeText: "\(id)", statusText: "1920×1080", cover: nil, state: state
        )
    }

    @Test("An input update after an appearance update keeps a display's name and layers on the window's appearance")
    func inputUpdateKeepsTheWindowAppearance() throws {
        let model = EditDeskStageModel()
        model.reduceMotion = true
        model.displays = [Self.display(1, "Active", x: 0, state: .ok), Self.display(2, "Empty", x: 1920, state: .empty)]
        let (view, window) = Self.mount(model)
        defer {
            view.detach()
            window.contentView = nil
        }
        let active = try #require(view.displayLayers[1])
        let empty = try #require(view.displayLayers[2])
        let expected = try #require(StagePaint.resolved(DesignTokens.EditDesk.Colors.textPrimary, in: Self.windowTier))
        try #require(StagePaint.nameColor(active) == expected, "the appearance update itself has to paint the window's tier")
        try #require(StagePaint.nameColor(empty) == expected, "the appearance update itself has to paint the window's tier")
        let before = (active: StagePaint.of(active.layer), empty: StagePaint.of(empty.layer))

        // A running wallpaper keeps refreshing its display's row; an empty display has nothing to refresh.
        model.displays[0].statusText = "1920×1080 · 60 fps"
        // `layout` is the observation task's own body: `synchronizeInputs`, then `render`.
        Self.offTier { view.layout() }
        try #require(active.display?.statusText == model.displays[0].statusText, "the input update never reached the layer")

        #expect(StagePaint.nameColor(active) == expected, "the active display's name left the window's tier")
        #expect(StagePaint.nameColor(empty) == expected, "the empty display's name left the window's tier")
        let changes = StagePaint.changes(before.active, StagePaint.of(active.layer))
        #expect(changes.isEmpty, Comment(rawValue: "\(changes.count) colours left the window's tier: \(changes.prefix(8))"))
        #expect(StagePaint.changes(before.empty, StagePaint.of(empty.layer)).isEmpty)
    }

    @Test("A failed display's chip text, glyph and dot stay on the window's appearance through an input update; a display that did not fail keeps its paint")
    func failureChipKeepsTheWindowAppearance() throws {
        let failure = WallpaperFailureClass.blocked
        let model = EditDeskStageModel()
        model.reduceMotion = true
        model.displays = [
            Self.display(1, "Failed", x: 0, state: .failed(StageFailureChip(symbol: failure.symbol, text: "Didn't load", failureClass: failure))),
            Self.display(2, "Active", x: 1920, state: .ok),
        ]
        let (view, window) = Self.mount(model)
        defer {
            view.detach()
            window.contentView = nil
        }
        let shell = try #require(view.displayLayers[1])
        let control = try #require(view.displayLayers[2])
        let controlBefore = StagePaint.of(control.layer)
        model.displays[0].statusText = "1920×1080 · retrying"
        Self.offTier { view.layout() }
        try #require(shell.display?.statusText == model.displays[0].statusText, "the input update never reached the layer")
        let expected = try #require(StagePaint.resolved(failure.tint, in: Self.windowTier))
        let chip = try #require(StagePaint.failureChip(of: shell))
        #expect(chip.text.foregroundColor == expected, "the chip's text left the window's tier")
        #expect(chip.dot.fillColor == expected, "the name row's dot left the window's tier")
        let wantedGlyph = StageLayerStyle.symbol(failure.symbol, tint: expected)?.dataProvider?.data as Data?
        #expect(StagePaint.bitmap(chip.glyph) == wantedGlyph, "the chip's glyph left the window's tier")
        let changes = StagePaint.changes(controlBefore, StagePaint.of(control.layer))
        #expect(changes.isEmpty, Comment(rawValue: "the display that did not fail repainted \(changes.count) colours: \(changes.prefix(6))"))
    }

    @Test("A card layer built as the row scrolls after an appearance update paints like one the update painted")
    func scrolledInCardKeepsTheWindowAppearance() throws {
        let model = EditDeskStageModel()
        model.reduceMotion = true
        model.displays = [Self.display(1, "Active", x: 0, state: .ok)]
        model.shelfItems = (0 ..< 40).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "Meta", thumbnail: nil, nowPlaying: nil, isDraggable: true)
        }
        let (view, window) = Self.mount(model)
        defer {
            view.detach()
            window.contentView = nil
        }
        Self.offTier { model.setProgress(1, animated: false) }
        let first = try #require(view.cardLayers["card-0"])
        let expected = try #require(StagePaint.resolved(DesignTokens.Colors.surfaceRaised, in: Self.windowTier))
        try #require(first.thumbnail.backgroundColor == expected, "the appearance update itself has to paint the window's tier")
        let reference = StagePaint.of(first.layer)
        let shown = Set(view.cardLayers.keys)

        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -800, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: wheel))
        Self.offTier { view.scrollWheel(with: event) }
        let built = view.cardLayers.filter { !shown.contains($0.key) }
        try #require(!built.isEmpty, "the scroll never built a card layer")
        for (id, tile) in built.sorted(by: { $0.key < $1.key }) {
            let changes = StagePaint.changes(reference, StagePaint.of(tile.layer))
            #expect(changes.isEmpty, Comment(rawValue: "\(id): \(changes.count) colours left the window's tier: \(changes.prefix(6))"))
        }
    }
}

/// Reads what a stage layer tree draws, for comparing one update's paint with another's.
@MainActor
enum StagePaint {
    static func resolved(_ color: Color, in tier: NSAppearance.Name) -> CGColor? {
        var cgColor: CGColor?
        NSAppearance(named: tier)?.performAsCurrentDrawingAppearance { cgColor = NSColor(color).cgColor }
        return cgColor
    }

    static func nameColor(_ shell: DisplayShellLayer) -> CGColor? {
        func find(_ layer: CALayer) -> CATextLayer? {
            if let text = layer as? CATextLayer, text.string as? String == shell.display?.name {
                return text
            }
            return (layer.sublayers ?? []).lazy.compactMap(find).first
        }
        return find(shell.layer)?.foregroundColor
    }

    /// A failed display's chip text and glyph, and its name row's dot.
    static func failureChip(of shell: DisplayShellLayer) -> (text: CATextLayer, glyph: CALayer, dot: CAShapeLayer)? {
        guard case let .failed(chip)? = shell.display?.state,
              let group = shell.content.sublayers?.first(where: { layer in
                  layer.sublayers?.contains { ($0 as? CATextLayer)?.string as? String == chip.text } == true
              }),
              let text = group.sublayers?.compactMap({ $0 as? CATextLayer }).first,
              let glyph = group.sublayers?.first(where: { !($0 is CATextLayer) }),
              let dot = shell.layer.sublayers?.compactMap({ $0 as? CAShapeLayer }).first(where: {
                  let width = $0.path?.boundingBox.width ?? 0
                  return width > 0 && width < 12
              }) else { return nil }
        return (text, glyph, dot)
    }

    static func bitmap(_ layer: CALayer) -> Data? {
        guard let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return unsafeDowncast(contents as AnyObject, to: CGImage.self).dataProvider?.data as Data?
    }

    /// Every colour and bitmap a layer tree draws, keyed by its place in the tree.
    static func of(_ root: CALayer) -> [String] {
        func describe(_ color: CGColor?) -> String {
            guard let color else { return "nil" }
            let components = (color.components ?? []).map { String(format: "%.4f", $0) }.joined(separator: " ")
            return "\(color.colorSpace?.name.map { $0 as String } ?? "?")(\(components))"
        }
        var entries: [String] = []
        func visit(_ layer: CALayer, _ path: String) {
            var colors: [(String, CGColor?)] = [
                ("background", layer.backgroundColor), ("border", layer.borderColor), ("shadow", layer.shadowColor),
            ]
            if let shape = layer as? CAShapeLayer {
                colors += [("fill", shape.fillColor), ("stroke", shape.strokeColor)]
            }
            if let text = layer as? CATextLayer {
                colors.append(("foreground", text.foregroundColor))
            }
            if let gradient = layer as? CAGradientLayer {
                colors += (gradient.colors ?? []).enumerated().map { index, color in
                    let cgColor = CFGetTypeID(color as CFTypeRef) == CGColor.typeID ? unsafeDowncast(color as AnyObject, to: CGColor.self) : nil
                    return ("gradient\(index)", cgColor)
                }
            }
            entries += colors.map { "\(path).\($0.0)=\(describe($0.1))" }
            if let bitmap = bitmap(layer) {
                entries.append("\(path).contents=\(bitmap.hashValue)")
            }
            for (index, sublayer) in (layer.sublayers ?? []).enumerated() {
                visit(sublayer, "\(path)/\(index)")
            }
        }
        visit(root, "\(type(of: root))")
        return entries
    }

    static func changes(_ before: [String], _ after: [String]) -> [String] {
        after.count == before.count ? zip(before, after).filter { $0 != $1 }.map(\.1) : ["tree changed shape"]
    }
}
