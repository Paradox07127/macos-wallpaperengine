#if !LITE_BUILD
import AppKit
import CoreGraphics
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

// Offscreen fidelity probe for WP 5.4 / 2.4 / 3.5 / 4.3-static. Renders the Edit Desk surfaces
// through NSHostingView + cacheDisplay and measures the result off the bitmap, so the numbers in
// `.notes/evidence/ui/editdesk/fidelity-2026-09-20/README.md` come from a render, not from reading
// the source. Glass (`glassEffect`, `NSVisualEffectView`) does not composite offscreen: anything
// behind one is reported as 实机 in that table instead of measured here.

// MARK: - Harness

/// RGBA8 view over a rendered bitmap. Coordinates are points from the top-left.
struct ProbeImage {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let buffer: [UInt8]

    init(cgImage: CGImage, viewWidth: CGFloat) {
        width = cgImage.width
        height = cgImage.height
        scale = CGFloat(cgImage.width) / viewWidth
        buffer = Self.rgba(from: cgImage)
    }

    /// Redrawn into a context of known layout: the cached rep's own format varies by backing store.
    private static func rgba(from cgImage: CGImage) -> [UInt8] {
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        return data
    }

    func rgb(px x: Int, _ y: Int) -> ProbeColor {
        guard x >= 0, y >= 0, x < width, y < height else { return ProbeColor(r: -1, g: -1, b: -1) }
        let offset = (y * width + x) * 4
        return ProbeColor(r: Int(buffer[offset]), g: Int(buffer[offset + 1]), b: Int(buffer[offset + 2]))
    }

    /// Bounding box, in points, of every pixel matching `predicate`. nil when nothing matches.
    func boundingBox(_ predicate: (ProbeColor) -> Bool) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where predicate(rgb(px: x, y)) {
                if x < minX {
                    minX = x
                }
                if x > maxX {
                    maxX = x
                }
                if y < minY {
                    minY = y
                }
                if y > maxY {
                    maxY = y
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
    }

    /// Bounding box of matching pixels inside `region` (points), so a marker can be isolated from
    /// identically coloured pixels elsewhere in the frame.
    func boundingBox(in region: CGRect, _ predicate: (ProbeColor) -> Bool) -> CGRect? {
        let x0 = max(0, Int(region.minX * scale)), x1 = min(width, Int(region.maxX * scale))
        let y0 = max(0, Int(region.minY * scale)), y1 = min(height, Int(region.maxY * scale))
        var minX = x1, minY = y1, maxX = -1, maxY = -1
        for y in y0 ..< max(y0, y1) {
            for x in x0 ..< max(x0, x1) where predicate(rgb(px: x, y)) {
                if x < minX {
                    minX = x
                }
                if x > maxX {
                    maxX = x
                }
                if y < minY {
                    minY = y
                }
                if y > maxY {
                    maxY = y
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
    }

    /// Horizontal runs of matching pixels along one row, in points.
    func runs(inRow yPoints: CGFloat, _ predicate: (ProbeColor) -> Bool) -> [ProbeRun] {
        let y = Int((yPoints * scale).rounded(.down))
        var result: [ProbeRun] = []
        var start: Int?
        for x in 0 ..< width {
            if predicate(rgb(px: x, y)) {
                if start == nil {
                    start = x
                }
            } else if let s = start {
                result.append(ProbeRun(x: CGFloat(s) / scale, width: CGFloat(x - s) / scale))
                start = nil
            }
        }
        if let s = start {
            result.append(ProbeRun(x: CGFloat(s) / scale, width: CGFloat(width - s) / scale))
        }
        return result
    }

    /// Leading edge of the first run to the trailing edge of the last, in points. Unlike the widest
    /// run this survives a band the marker colour is interrupted by (a thumbnail, a button, a label).
    func extent(inRow yPoints: CGFloat, _ predicate: (ProbeColor) -> Bool) -> (x: CGFloat, width: CGFloat)? {
        let matched = runs(inRow: yPoints, predicate)
        guard let first = matched.first, let last = matched.last else { return nil }
        return (first.x, last.maxX - first.x)
    }

    /// First and last matching row (points) in one column.
    func verticalSpan(inColumn xPoints: CGFloat, _ predicate: (ProbeColor) -> Bool) -> (top: CGFloat, bottom: CGFloat)? {
        let x = Int((xPoints * scale).rounded(.down))
        var first = -1
        var last = -1
        for y in 0 ..< height where predicate(rgb(px: x, y)) {
            if first < 0 {
                first = y
            }
            last = y
        }
        guard first >= 0 else { return nil }
        return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
    }
}

struct ProbeColor {
    let r: Int
    let g: Int
    let b: Int

    /// Saturated primaries survive the panel's translucency, so each is an unambiguous marker.
    var isRed: Bool {
        r > 150 && g < 90 && b < 90
    }

    var isBlue: Bool {
        b > 150 && r < 90 && g < 90
    }

    var isMagenta: Bool {
        r > 150 && b > 150 && g < 90
    }

    var isCyan: Bool {
        g > 150 && b > 150 && r < 90
    }

    var isYellow: Bool {
        r > 150 && g > 150 && b < 90
    }

    /// The panel's own fill is close to its drop shadow, so the panel is found by matching a seed
    /// pixel rather than by a fixed threshold.
    func matches(_ other: ProbeColor, tolerance: Int) -> Bool {
        r >= 0 && abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }
}

struct ProbeRun {
    let x: CGFloat
    let width: CGFloat

    var maxX: CGFloat {
        x + width
    }
}

@MainActor
enum ProbeRenderer {
    /// The test host is sandboxed, so PNGs land in its container temp directory; the harvesting
    /// shell copies them into `.notes/evidence/ui/editdesk/fidelity-2026-09-20/`.
    static var outputDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editdesk-fidelity-2026-09-20", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A flat image, used as a measurement target in views that only accept a `CGImage`.
    static func solid(_ color: NSColor, size: CGSize = CGSize(width: 64, height: 36)) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    static let previewRed = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let thumbnailBlue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    static let heroMagenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
    static let hudCyan = NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)
    static let inspectorYellow = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)

    /// Renders `view` at `size`, writes `name`.png and returns the pixels. The host lives in an
    /// offscreen window and the run loop is pumped, so SwiftUI `.task` work (the detail's chrome
    /// reveal) actually happens before the frame is cached.
    static func render(
        _ name: String?, size: CGSize, appearance: NSAppearance.Name = .darkAqua,
        settle: TimeInterval = 0.7, @ViewBuilder _ view: () -> some View
    ) async -> ProbeImage {
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .standard) {
            view().frame(width: size.width, height: size.height)
        })
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.appearance = NSAppearance(named: appearance)
        // SwiftUI runs `.task` and `onAppear` only for a view in an on-screen window, and the
        // detail's inspector fades in from one. Parked far outside every display so nothing shows.
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()

        // Awaiting rather than blocking the run loop is what lets SwiftUI's own `.task` work run:
        // a blocked main thread never reaches the continuation that flips the detail's chrome in.
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()

        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let name, let png = bitmap.representation(using: .png, properties: [:]) {
            let out = outputDirectory.appendingPathComponent("\(name).png")
            try? png.write(to: out)
            print("FIDELITY-PNG \(out.path)")
        }
        let image = ProbeImage(cgImage: bitmap.cgImage!, viewWidth: size.width)
        window.orderOut(nil)
        window.contentView = nil
        return image
    }

    static func report(_ key: String, _ value: some Any) {
        print("FIDELITY \(key) = \(value)")
    }
}

/// The rubric's band is ±2pt; rendered edges eaten by a 1pt inner stroke get 3.
@MainActor
func expectClose(
    _ measured: CGFloat, _ expected: CGFloat, _ label: String, tolerance: CGFloat = 2,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    ProbeRenderer.report(label, measured)
    #expect(
        abs(measured - expected) <= tolerance,
        Comment(rawValue: "\(label): measured \(measured), design \(expected), Δ \(measured - expected)"),
        sourceLocation: sourceLocation
    )
}

// MARK: - Fixtures

@MainActor
enum ProbeFixtures {
    static func libraryContent(preview: CGImage?) -> WallpaperModalContent {
        WallpaperModalContent(
            itemID: "probe-item",
            title: "Painting the Sharks 4K",
            kind: .scene,
            tags: ["4K", "Scene"],
            metaParts: ["Workshop", "kaze", "214 MB", "3840×2160"],
            presetName: "Night",
            preview: preview,
            isDraggable: true,
            installed: nil
        )
    }

    /// 16:9 then 16:10 — the two ratios SCREENS S5 quotes thumbnail widths for.
    static func targets(thumbnail: CGImage?) -> [ModalDisplayTarget] {
        [
            ModalDisplayTarget(id: 1, name: "MPG321CX", shortcutIndex: 1, aspectRatio: 1920.0 / 1080.0,
                               thumbnail: thumbnail, isPrimary: true),
            ModalDisplayTarget(id: 2, name: "MacBook Pro", shortcutIndex: 2, aspectRatio: 1728.0 / 1080.0,
                               thumbnail: thumbnail, isPrimary: false),
        ]
    }

    static var libraryActions: WallpaperModalActions {
        WallpaperModalActions(
            applyTo: { _ in }, applyToAllDisplays: {}, togglePlayback: {},
            addToPlaylist: { _ in }, schedule: {}, showInFinder: {}, openInSteam: {},
            removeFromSaved: {}, checkForUpdate: {}, cancelUpdate: {}, deleteInstalled: {}
        )
    }

    static var navigation: ModalNavigation {
        ModalNavigation(canGoPrevious: true, canGoNext: true, previous: {}, next: {})
    }

    static func workshopItem() -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: 2_468_489_223,
            rawTitle: "Painting the Sharks 4K",
            shortDescription: String(repeating: "A description long enough to fold. ", count: 12),
            creatorID: "76561198000000000",
            creatorPersonaName: "kaze",
            previewImageURL: nil,
            fileSizeBytes: 214 * 1024 * 1024,
            timeUpdated: Date(timeIntervalSince1970: 1_760_000_000),
            subscriptionCount: 31284,
            rating: .score(0.98, votesUp: 4900, votesDown: 100),
            tags: ["Scene", "3840 x 2160"],
            visibility: .public,
            isBanned: false,
            steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=2468489223")!
        )
    }

    static var workshopActions: WorkshopModalActions {
        WorkshopModalActions(
            selectTarget: { _ in }, primary: {}, saveOnly: {}, cancelDownload: {},
            openInSteam: {}, reveal: {}, openItem: { _ in }, selectTag: { _ in },
            browseCreator: { _, _ in }
        )
    }

    static var detailActions: DetailActions {
        DetailActions(
            back: {}, selectDisplay: { _ in }, saveAsScheme: {}, applyToAll: {}, clearWallpaper: {},
            playback: { _ in }, recapture: {}, copyOverlays: {},
            snapEnabled: .constant(false)
        )
    }
}

// MARK: - S4 wallpaper modal

@Suite("Fidelity S4 wallpaper modal", .serialized)
@MainActor
struct S4ModalFidelityTests {
    private func modal(windowSize: CGSize) -> some View {
        WallpaperModal(
            content: ProbeFixtures.libraryContent(preview: ProbeRenderer.solid(ProbeRenderer.previewRed)),
            targets: ProbeFixtures.targets(thumbnail: nil),
            actions: ProbeFixtures.libraryActions,
            navigation: ProbeFixtures.navigation,
            windowSize: windowSize,
            titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
            onDismiss: {}, onDrag: { _ in }
        )
    }

    /// The red preview is the anchor: the panel is that box grown by the 12pt inset on three sides
    /// plus the 152pt bar underneath. A 1pt inner stroke eats the outermost pixel, hence ±3.
    private func panel(from preview: CGRect) -> CGRect {
        CGRect(
            x: preview.minX - ModalGeometry.previewMargin, y: preview.minY - ModalGeometry.previewMargin - ModalGeometry.headerHeight,
            width: preview.width + 2 * ModalGeometry.previewMargin,
            height: preview.height + ModalGeometry.previewMargin + ModalGeometry.bottomBarHeight + ModalGeometry.headerHeight
        )
    }

    /// SCREENS S4: 880×560 @ top 150, preview inset 12, bottom bar 152.
    @Test("S4 panel and preview at 1280×820")
    func panelAt1280() async throws {
        let size = CGSize(width: 1280, height: 820)
        let image = await ProbeRenderer.render("S4-1280-dark", size: size) {
            ZStack { Color(white: 0.5); modal(windowSize: size) }
        }
        let preview = try #require(image.boundingBox { $0.isRed }, "the modal preview did not render")
        ProbeRenderer.report("S4.1280.previewRect", preview)
        let box = panel(from: preview)
        ProbeRenderer.report("S4.1280.panelRect", box)
        expectClose(box.width, 880, "S4.1280.panel.w", tolerance: 3)
        expectClose(box.height, 560, "S4.1280.panel.h", tolerance: 3)
        expectClose(box.minY, 150, "S4.1280.panel.top", tolerance: 3)
        expectClose(box.minX, 200, "S4.1280.panel.x", tolerance: 3)
        expectClose(preview.height, 360, "S4.1280.preview.h", tolerance: 3)
        expectClose(preview.width, 856, "S4.1280.preview.w", tolerance: 3)
        // The contract the render is measured against.
        let contract = ModalGeometry.panelFrame(in: size)
        ProbeRenderer.report("S4.contract.1280", contract)
        expectClose(contract.width, 880, "S4.contract.1280.w", tolerance: 0)
        expectClose(contract.height, 560, "S4.contract.1280.h", tolerance: 0)
        expectClose(contract.minY, 150, "S4.contract.1280.top", tolerance: 0)
    }

    /// 1040×700 cannot hang the panel at 150; it stops 12pt under the float strip instead.
    @Test("S4 panel at 1040×700 drops to the float strip's clearance rather than hanging at 150")
    func panelAt1040() async throws {
        let size = CGSize(width: 1040, height: 700)
        let image = await ProbeRenderer.render("S4-1040-dark", size: size) {
            ZStack { Color(white: 0.5); modal(windowSize: size) }
        }
        let preview = try #require(image.boundingBox { $0.isRed })
        let box = panel(from: preview)
        ProbeRenderer.report("S4.1040.panelRect", box)
        expectClose(box.width, 880, "S4.1040.panel.w", tolerance: 3)
        expectClose(box.minY, 130, "S4.1040.panel.top", tolerance: 3)
        expectClose(box.minX, 80, "S4.1040.panel.x", tolerance: 3)
        let contract = ModalGeometry.panelFrame(in: size)
        ProbeRenderer.report("S4.contract.1040", contract)
        expectClose(contract.height, 554, "S4.contract.1040.h", tolerance: 0)
    }

    @Test("S4 light appearance renders for reference")
    func lightReference() async throws {
        let size = CGSize(width: 1280, height: 820)
        let image = await ProbeRenderer.render("S4-1280-light", size: size, appearance: .aqua) {
            ZStack { Color(white: 0.5); modal(windowSize: size) }
        }
        let preview = try #require(image.boundingBox { $0.isRed })
        expectClose(panel(from: preview).width, 880, "S4.light.panel.w", tolerance: 3)
    }
}

// MARK: - S5 float layer

@Suite("Fidelity S5 display float layer", .serialized)
@MainActor
struct S5FloatLayerFidelityTests {
    private func layer(mode: FloatLayerMode, width: CGFloat) -> some View {
        DisplayFloatLayer(
            targets: ProbeFixtures.targets(thumbnail: ProbeRenderer.solid(ProbeRenderer.thumbnailBlue)),
            mode: mode, highlighted: nil, windowWidth: width,
            onSelect: { _ in }, onApplyAll: {}, onTargetFrame: { _ in }, onRunFrame: { _ in }
        )
    }

    /// SCREENS S5: h104 at top 14, thumbnails 84 tall; the implementation derives the width from
    /// the aspect ratio instead of the quoted 150/130, which is the deviation this measures.
    @Test("S5 drop-target strip geometry")
    func dropTargetStrip() async throws {
        let size = CGSize(width: 1280, height: 200)
        let image = await ProbeRenderer.render("S5-1280-dropTarget-dark", size: size) {
            ZStack(alignment: .top) {
                Color(white: 0.5)
                layer(mode: .dropTarget, width: 1280).padding(.top, 14)
            }
        }
        let thumbs = image.runs(inRow: 14 + 52) { $0.isBlue }
        ProbeRenderer.report("S5.thumbnailRuns", thumbs.map { "x=\($0.x) w=\($0.width)" })
        #expect(thumbs.count == 2, "expected one thumbnail per display, got \(thumbs.count)")
        // The stroke is drawn inside the tile, so the blue fill measures up to 2pt short of the
        // laid-out width. The width itself is asserted exactly off the geometry.
        expectClose(FloatLayerGeometry.thumbnailWidth(aspect: 1920.0 / 1080.0), 149, "S5.thumb.16x9.layout", tolerance: 0)
        expectClose(FloatLayerGeometry.thumbnailWidth(aspect: 1728.0 / 1080.0), 134, "S5.thumb.16x10.layout", tolerance: 0)
        expectClose(thumbs[0].width, 149, "S5.thumb.16x9.w", tolerance: 2)
        expectClose(thumbs[1].width, 134, "S5.thumb.16x10.w", tolerance: 2)
        expectClose(thumbs[1].x - thumbs[0].maxX, 12, "S5.thumb.gap")

        let span = try #require(image.verticalSpan(inColumn: thumbs[0].x + 4) { $0.isBlue })
        expectClose(span.bottom - span.top, 84, "S5.thumb.h")
        // 104pt panel with the 84pt thumbnail centred: 10pt of panel above it.
        expectClose(span.top, 24, "S5.thumb.topInWindow")
        expectClose(FloatLayerGeometry.panelHeight, 104, "S5.panel.h", tolerance: 0)
    }

    /// R-24 ③: the Workshop strip picks one target, so it drops "All Displays" and its rule.
    @Test("S5 select-target strip drops the All Displays button")
    func selectTargetHidesApplyAll() async {
        #expect(FloatLayerGeometry.showsApplyAll(for: .dropTarget))
        #expect(!FloatLayerGeometry.showsApplyAll(for: .selectTarget))

        let size = CGSize(width: 1280, height: 200)
        let drop = await ProbeRenderer.render(nil, size: size) {
            ZStack(alignment: .top) { Color(white: 0.5); layer(mode: .dropTarget, width: 1280).padding(.top, 14) }
        }
        let select = await ProbeRenderer.render("S5-1280-selectTarget-dark", size: size) {
            ZStack(alignment: .top) { Color(white: 0.5); layer(mode: .selectTarget, width: 1280).padding(.top, 14) }
        }
        // The strip is the panel's full dark extent across the row; the thumbnails interrupt it, so
        // the leading-to-trailing extent is the measurement, not the widest single run.
        let isStrip: (ProbeColor) -> Bool = { $0.r >= 0 && $0.r < 90 && $0.g < 90 && $0.b < 100 }
        let dropWidth = drop.extent(inRow: 14 + 52, isStrip)?.width ?? 0
        let selectWidth = select.extent(inRow: 14 + 52, isStrip)?.width ?? 0
        ProbeRenderer.report("S5.dropStripWidth", dropWidth)
        ProbeRenderer.report("S5.selectStripWidth", selectWidth)
        ProbeRenderer.report("S5.applyAllButtonCost", dropWidth - selectWidth)
        #expect(selectWidth < dropWidth, "the select strip still draws the All Displays button")
        // Caption 70 + 12 + (149 + 12 + 134) + 2×14 padding = 405 for the button-less strip.
        expectClose(selectWidth, 405, "S5.selectStripWidth", tolerance: 3)
    }

    /// The caption box is a fixed 70pt in every language; this frame is the Spanish one.
    @Test("S5 select-target strip in Spanish renders for the caption check")
    func spanishCaption() async {
        let size = CGSize(width: 1280, height: 200)
        let image = await ProbeRenderer.render("S5-1280-selectTarget-es", size: size) {
            ZStack(alignment: .top) {
                Color(white: 0.5)
                layer(mode: .selectTarget, width: 1280)
                    .padding(.top, 14)
                    .environment(\.locale, Locale(identifier: "es"))
            }
        }
        #expect(image.runs(inRow: 14 + 52) { $0.isBlue }.count == 2)
    }
}

@Suite("Fidelity S4+S5 clearance at 700 high", .serialized)
@MainActor
struct S4S5OverlapTests {
    /// R-24 ⑤: at 700pt the panel can no longer hang at 150, so it stops under the strip.
    @Test("The float strip and the modal panel clear each other at 1040×700")
    func stripClearsPanel() async throws {
        let size = CGSize(width: 1040, height: 700)
        let image = await ProbeRenderer.render("S4-S5-1040x700-overlap-dark", size: size) {
            ZStack(alignment: .top) {
                Color(white: 0.5)
                WallpaperModal(
                    content: ProbeFixtures.libraryContent(preview: ProbeRenderer.solid(ProbeRenderer.previewRed)),
                    targets: ProbeFixtures.targets(thumbnail: ProbeRenderer.solid(ProbeRenderer.thumbnailBlue)),
                    actions: ProbeFixtures.libraryActions, navigation: ProbeFixtures.navigation,
                    windowSize: size, titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
                    onDismiss: {}, onDrag: { _ in }
                )
                DisplayFloatLayer(
                    targets: ProbeFixtures.targets(thumbnail: ProbeRenderer.solid(ProbeRenderer.thumbnailBlue)),
                    mode: .dropTarget, highlighted: nil, windowWidth: size.width,
                    onSelect: { _ in }, onApplyAll: {}, onTargetFrame: { _ in }, onRunFrame: { _ in }
                )
                .padding(.top, FloatLayerGeometry.panelTop)
            }
        }
        let preview = try #require(image.boundingBox { $0.isRed })
        let panelTop = preview.minY - ModalGeometry.previewMargin - ModalGeometry.headerHeight
        let stripBottom = FloatLayerGeometry.panelTop + FloatLayerGeometry.panelHeight
        ProbeRenderer.report("S4S5.panelTop", panelTop)
        ProbeRenderer.report("S4S5.stripBottom", stripBottom)
        expectClose(panelTop, 130, "S4S5.panelTop", tolerance: 3)
        expectClose(panelTop - stripBottom, 12, "S4S5.verticalClearance", tolerance: 3)
        // At 1280×820 the panel hangs at 150 and the two clear each other by 32pt.
        expectClose(
            ModalGeometry.panelFrame(in: CGSize(width: 1280, height: 820)).minY - stripBottom,
            32, "S4S5.clearance1280", tolerance: 0
        )
    }
}

// MARK: - S6-B display detail

@Suite("Fidelity S6-B display detail", .serialized)
@MainActor
struct S6DetailFidelityTests {
    private func detail(windowSize: CGSize) -> some View {
        DisplayDetail(
            displayName: "MPG321CX OLED",
            tags: [
                DetailDisplayTag(id: 1, name: "MPG321CX OLED", thumbnail: nil, isCurrent: true),
                DetailDisplayTag(id: 2, name: "MacBook Pro", thumbnail: nil, isCurrent: false),
            ],
            hero: DetailHeroStatus(
                title: "Painting the Sharks 4K", kindLine: "Scene · auto-detected",
                isPlaying: true, performanceLine: "▶ 60 FPS · GPU 18%"
            ),
            heroImage: ProbeRenderer.solid(ProbeRenderer.heroMagenta),
            backdropImage: nil,
            windowSize: windowSize,
            section: .constant(.wallpaper),
            heroVisible: true,
            actions: ProbeFixtures.detailActions,
            hud: { Color(nsColor: ProbeRenderer.hudCyan) },
            inspector: { _ in Color(nsColor: ProbeRenderer.inspectorYellow) },
            overlayLogicalSize: CGSize(width: 3840, height: 2160),
            overlayCanvas: { _ in Color.clear },
            inspectorVisible: .constant(true), layersVisible: .constant(true),
            inspectorWidth: .constant(372), liveInspectorWidth: .constant(nil)
        )
    }

    /// GAP §8.2 layout B: top bar 56, inspector 372, hero a fixed 16:9 centred in what is left.
    @Test("S6-B hero, inspector and HUD slot at 1280×820")
    func layoutAt1280() async throws {
        let size = CGSize(width: 1280, height: 820)
        // The inspector fades in 0.25s after the hero, then animates for 0.25s.
        let image = await ProbeRenderer.render("S6B-1280-dark", size: size, settle: 1.4) { detail(windowSize: size) }

        let inspector = try #require(image.boundingBox { $0.isYellow }, "the inspector column never became visible")
        ProbeRenderer.report("S6.1280.inspectorRect", inspector)
        expectClose(inspector.width, 372, "S6.1280.inspector.w")
        expectClose(inspector.minX, 908, "S6.1280.inspector.x")
        expectClose(inspector.minY, 56, "S6.1280.inspector.top")
        expectClose(inspector.height, 764, "S6.1280.inspector.h")

        let contract = DetailGeometry.heroFrame(in: size)
        let hero = try #require(image.boundingBox { $0.isMagenta }, "the hero still never rendered")
        ProbeRenderer.report("S6.1280.heroRect", hero)
        ProbeRenderer.report("S6.contract.hero1280", contract)
        expectClose(hero.width, contract.width, "S6.1280.hero.w.vsContract", tolerance: 3)
        expectClose(hero.height, contract.height, "S6.1280.hero.h.vsContract", tolerance: 3)
        expectClose(hero.minX, contract.minX, "S6.1280.hero.x.vsContract", tolerance: 3)
        expectClose(hero.minY, contract.minY, "S6.1280.hero.y.vsContract", tolerance: 3)
        // The contract itself against GAP §8.2 / the rubric's "860×484 @ x24".
        expectClose(contract.width, 860, "S6.contract.hero1280.w", tolerance: 0.01)
        expectClose(contract.minX, 24, "S6.contract.hero1280.x", tolerance: 0.01)
        expectClose(contract.width / contract.height, 16.0 / 9.0, "S6.contract.hero1280.aspect", tolerance: 0.001)
        expectClose((1280 - 372) - contract.maxX, 24, "S6.contract.hero1280.rightGap", tolerance: 0.01)

        let hud = try #require(image.boundingBox { $0.isCyan }, "the HUD slot never rendered")
        ProbeRenderer.report("S6.1280.hudRect", hud)
        expectClose(hud.height, 44, "S6.1280.hud.h")
        expectClose(hero.maxY - hud.maxY, 12, "S6.1280.hud.bottomInset", tolerance: 3)
        expectClose(hud.midX, hero.midX, "S6.1280.hud.centre", tolerance: 2)
        expectClose(hud.width, hero.width - 24, "S6.1280.hud.w", tolerance: 3)
    }

    @Test("S6-B hero at 1040×700 keeps 16:9 and the 372 inspector")
    func layoutAt1040() async throws {
        let size = CGSize(width: 1040, height: 700)
        let image = await ProbeRenderer.render("S6B-1040-dark", size: size, settle: 1.4) { detail(windowSize: size) }
        let hero = try #require(image.boundingBox { $0.isMagenta })
        let inspector = try #require(image.boundingBox { $0.isYellow })
        let contract = DetailGeometry.heroFrame(in: size)
        ProbeRenderer.report("S6.1040.heroRect", hero)
        ProbeRenderer.report("S6.contract.hero1040", contract)
        expectClose(inspector.width, 372, "S6.1040.inspector.w")
        expectClose(hero.width, contract.width, "S6.1040.hero.w.vsContract", tolerance: 3)
        expectClose(contract.width, 620, "S6.contract.hero1040.w", tolerance: 0.01)
        expectClose(contract.minX, 24, "S6.contract.hero1040.x", tolerance: 0.01)
        expectClose(contract.width / contract.height, 16.0 / 9.0, "S6.contract.hero1040.aspect", tolerance: 0.001)
    }

    /// The 09-20 token package re-cut the three text greys and the four stroke tiers; the rubric's
    /// two ⚠️ rows were left as "needs re-measuring" against the old neutral greys.
    @Test("S6-B text greys and stroke tiers after the 09-20 token package")
    func textAndStrokeTiers() throws {
        var greys: [String: String] = [:]
        var strokes: [String: CGFloat] = [:]
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            for (name, color) in [
                ("textPrimary", DesignTokens.EditDesk.Colors.textPrimary),
                ("textSecondary", DesignTokens.EditDesk.Colors.textSecondary),
                ("textTertiary", DesignTokens.EditDesk.Colors.textTertiary),
            ] {
                guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { continue }
                let channels = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
                greys[name] = "#" + channels.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
            }
            for (name, color) in [
                ("strokeShell", DesignTokens.EditDesk.Colors.strokeShell),
                ("strokePanel", DesignTokens.EditDesk.Colors.strokePanel),
                ("strokeRegular", DesignTokens.EditDesk.Colors.strokeRegular),
                ("strokeEmptyShell", DesignTokens.EditDesk.Colors.strokeEmptyShell),
                ("fillNavPill", DesignTokens.EditDesk.Colors.fillNavPill),
            ] {
                strokes[name] = NSColor(color).cgColor.alpha
            }
        }
        ProbeRenderer.report("S6.tokens.greys", greys)
        ProbeRenderer.report("S6.tokens.strokes", strokes)
        // SCREENS S6's three greys, now exact rather than the old single-channel neutrals.
        #expect(greys["textPrimary"] == "#e8e8ec", Comment(rawValue: greys["textPrimary"] ?? "nil"))
        #expect(greys["textSecondary"] == "#9a9aa3", Comment(rawValue: greys["textSecondary"] ?? "nil"))
        #expect(greys["textTertiary"] == "#8a8a93", Comment(rawValue: greys["textTertiary"] ?? "nil"))
        // The hero's stroke is `.25` and the panel's `.12`, the two the rubric had at +.07 / +.02.
        #expect(strokes["strokeShell"] == 0.25, Comment(rawValue: "\(strokes["strokeShell"] ?? -1)"))
        #expect(strokes["strokePanel"] == 0.12, Comment(rawValue: "\(strokes["strokePanel"] ?? -1)"))
        // The unselected display tag, the rubric's other +.01 row.
        #expect(strokes["fillNavPill"] == 0.05, Comment(rawValue: "\(strokes["fillNavPill"] ?? -1)"))
        let hero = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DetailHero.swift")
        #expect(hero.contains("Colors.strokeShell"), "the hero must still draw the .25 tier")
    }

    @Test("S6-B top bar is 56 and the shell reserves it")
    func topBarHeight() {
        expectClose(DetailGeometry.topBarHeight, 56, "S6.contract.topBar", tolerance: 0)
        expectClose(DetailGeometry.inspectorWidth, 372, "S6.contract.inspector", tolerance: 0)
        expectClose(DesignTokens.EditDesk.Spacing.topBar, 56, "S6.token.topBar", tolerance: 0)
        // The stage the hero is centred in starts under the bar and stops at the inspector.
        let stage = DetailGeometry.stageRect(in: CGSize(width: 1280, height: 820))
        ProbeRenderer.report("S6.contract.stage1280", stage)
        expectClose(stage.minY, 56, "S6.contract.stage.top", tolerance: 0)
        expectClose(stage.width, 908, "S6.contract.stage.w", tolerance: 0)
    }
}

// MARK: - S7 overlay (static)

@Suite("Fidelity S7 overlay column and canvas", .serialized)
@MainActor
struct S7OverlayFidelityTests {
    /// R-1…R-8: layers (capped at six rows), inspector (elastic, floor 200), drawer (collapsed 30).
    @Test("Right column height budget at 764 and 644")
    func columnHeights() {
        for (total, label) in [(CGFloat(764), "1280x820"), (CGFloat(644), "1040x700")] {
            let heights = OverlayColumnLayout.heights(total: total, rowCount: 3, drawerExpanded: false)
            ProbeRenderer.report("S7.\(label).heights", heights)
            expectClose(heights.drawer, 30, "S7.\(label).drawer", tolerance: 0)
            expectClose(heights.layers, 120, "S7.\(label).layers", tolerance: 0)
            expectClose(heights.layers + heights.inspector + heights.drawer, total, "S7.\(label).sum", tolerance: 0.01)
            #expect(heights.inspector >= OverlayColumnLayout.minInspectorHeight)
        }
        // Six rows is the cap; a seventh does not grow the list.
        let six = OverlayColumnLayout.heights(total: 764, rowCount: 6, drawerExpanded: false)
        let seven = OverlayColumnLayout.heights(total: 764, rowCount: 7, drawerExpanded: false)
        #expect(six == seven)
        expectClose(six.layers, 210, "S7.layers.cap", tolerance: 0)

        // An expanded drawer takes its 190 from the inspector, never from the list.
        let expanded = OverlayColumnLayout.heights(total: 644, rowCount: 3, drawerExpanded: true)
        expectClose(expanded.drawer, 190, "S7.drawerExpanded", tolerance: 0)
        expectClose(expanded.layers, 120, "S7.drawerExpanded.layers", tolerance: 0)
        expectClose(expanded.inspector, 334, "S7.drawerExpanded.inspector", tolerance: 0.01)
    }

    /// R-1: the canvas aspect-fits the display's own ratio inside the fixed 16:9 hero box.
    @Test("Canvas aspect-fits into the hero box")
    func canvasFit() {
        for window in [CGSize(width: 1280, height: 820), CGSize(width: 1040, height: 700)] {
            let hero = DetailGeometry.heroFrame(in: window)
            for logical in [CGSize(width: 3840, height: 2160), CGSize(width: 2560, height: 1600), CGSize(width: 1080, height: 1920)] {
                let box = OverlayGeometry.aspectFit(logicalSize: logical, in: hero)
                ProbeRenderer.report("S7.canvas.\(Int(window.width)).\(Int(logical.width))x\(Int(logical.height))", box)
                #expect(box.width <= hero.width + 0.01 && box.height <= hero.height + 0.01, "the canvas escaped the hero box")
                expectClose(box.midX, hero.midX, "S7.canvas.cx.\(Int(window.width)).\(Int(logical.width))", tolerance: 0.01)
                expectClose(box.midY, hero.midY, "S7.canvas.cy.\(Int(window.width)).\(Int(logical.width))", tolerance: 0.01)
                expectClose(box.width / box.height, logical.width / logical.height,
                            "S7.canvas.aspect.\(Int(window.width)).\(Int(logical.width))", tolerance: 0.01)
            }
            // 16:9 content fills the 16:9 hero exactly.
            let sixteenNine = OverlayGeometry.aspectFit(logicalSize: CGSize(width: 3840, height: 2160), in: hero)
            expectClose(sixteenNine.width, hero.width, "S7.canvas.16x9.fills.\(Int(window.width))", tolerance: 0.5)
        }
    }

    /// SCREENS S7 wants 50pt grid lines on screen whatever the canvas scale is.
    @Test("Grid spacing is 50 screen points after the canvas scale")
    func gridSpacing() {
        for scale in [CGFloat(0.26875), 0.1615, 1, 2.5] {
            let logical = OverlayGeometry.gridSpacing(forRenderScale: scale)
            expectClose(logical * scale, 50, "S7.grid.screenSpacing.\(scale)", tolerance: 0.01)
        }
        // A degenerate scale falls back to 1 rather than an infinite spacing.
        expectClose(OverlayGeometry.gridSpacing(forRenderScale: 0), 50, "S7.grid.zeroScale", tolerance: 0)
        expectClose(OverlayGeometry.decorationLineWidth(forRenderScale: 2) * 2, 1, "S7.grid.lineWidth", tolerance: 0.001)
    }
}

// MARK: - S8a Workshop grid

@Suite("Fidelity S8a Workshop grid", .serialized)
@MainActor
struct S8aGridFidelityTests {
    private static let inset = DesignTokens.Settings.formHorizontalMargin

    /// R-22: 194pt columns, 14 gap, 18 side inset — six at 1280 and four at 1040.
    @Test("Column arithmetic packs 6 at 1280 and 4 at 1040")
    func columnArithmetic() {
        expectClose(DesignTokens.LibraryGrid.workshopBrowseColumnWidth, 194, "S8a.columnWidth", tolerance: 0)
        expectClose(DesignTokens.LibraryGrid.spacing, 14, "S8a.gap", tolerance: 0)
        expectClose(Self.inset, 18, "S8a.sideInset", tolerance: 0)
        for (window, expected) in [(CGFloat(1280), 6), (CGFloat(1040), 4)] {
            let columns = DesignTokens.LibraryGrid.columns(
                for: .medium, aspect: .square, fitting: window - 2 * Self.inset,
                columnWidth: DesignTokens.LibraryGrid.workshopBrowseColumnWidth
            )
            ProbeRenderer.report("S8a.columns.\(Int(window))", columns.count)
            #expect(columns.count == expected, "\(window) packed \(columns.count) columns")
        }
        // R-22's other half: the 24pt gutter the rest of the app uses would drop 1280 to five.
        let atGutter = DesignTokens.LibraryGrid.columns(
            for: .medium, aspect: .square, fitting: 1280 - 2 * DesignTokens.Spacing.xl,
            columnWidth: DesignTokens.LibraryGrid.workshopBrowseColumnWidth
        )
        ProbeRenderer.report("S8a.columnsIfGutterWere24", atGutter.count)
        #expect(atGutter.count == 5)
    }

    /// The same grid rendered: count, pitch and leading inset come off the bitmap.
    @Test("Rendered grid lays out 6 columns at 1280 and 4 at 1040")
    func renderedGrid() async throws {
        for (window, expected) in [(CGFloat(1280), 6), (CGFloat(1040), 4)] {
            let size = CGSize(width: window, height: 400)
            let image = await ProbeRenderer.render("S8a-\(Int(window))-grid-dark", size: size) {
                ZStack {
                    DesignTokens.EditDesk.Colors.background
                    ScrollView {
                        LibraryGalleryGrid(
                            size: .medium, aspect: .square, initialWidth: window - 2 * Self.inset,
                            columnWidth: DesignTokens.LibraryGrid.workshopBrowseColumnWidth
                        ) {
                            ForEach(0 ..< 12, id: \.self) { _ in
                                Color(nsColor: ProbeRenderer.thumbnailBlue).aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .padding(.horizontal, Self.inset)
                        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
                    }
                }
            }
            let tiles = image.runs(inRow: 60) { $0.isBlue }
            ProbeRenderer.report("S8a.\(Int(window)).tileRuns", tiles.map { "x=\($0.x) w=\($0.width)" })
            #expect(tiles.count == expected, "\(window) rendered \(tiles.count) columns, expected \(expected)")
            let first = try #require(tiles.first)
            expectClose(first.width, 194, "S8a.\(Int(window)).tile.w")
            expectClose(first.x, Self.inset, "S8a.\(Int(window)).leadingInset")
            if tiles.count >= 2 {
                expectClose(tiles[1].x - tiles[0].maxX, 14, "S8a.\(Int(window)).gap")
            }
            // Tiles pack from the leading edge; the slack stays on the trailing side.
            let last = try #require(tiles.last)
            ProbeRenderer.report("S8a.\(Int(window)).trailingSlack", window - Self.inset - last.maxX)
        }
    }

    /// One card at its real column width, rendered, so the S8 skin is measured rather than assumed.
    @Test("A single Edit Desk BrowseCard renders square at 194")
    func singleCard() async throws {
        let width = DesignTokens.LibraryGrid.workshopBrowseColumnWidth
        let image = await ProbeRenderer.render("S8a-card-editDesk-dark", size: CGSize(width: 240, height: 240)) {
            ZStack {
                Color.white
                BrowseCard(
                    item: ProbeFixtures.workshopItem(), isInLibrary: true, isSelected: false,
                    cardPreferences: GalleryCardPreferences(), reduceMotion: true,
                    canDownload: true, presentation: .editDesk, isRevealed: false
                )
                .frame(width: width)
            }
        }
        // The card rests on a `.6` drop shadow now, which over a mid-grey page is as dark as the
        // card itself. A white page keeps the darkest shadow pixel near 178 and the card under 90.
        let isCard: (ProbeColor) -> Bool = { $0.r >= 0 && $0.r < 90 && $0.g < 90 && $0.b < 95 }
        ProbeRenderer.report("S8a.card.runs", image.runs(inRow: 120, isCard).map { "x=\($0.x) w=\($0.width)" })
        let row = try #require(image.extent(inRow: 120, isCard))
        expectClose(row.width, width, "S8a.card.w", tolerance: 4)
        let span = try #require(image.verticalSpan(inColumn: row.x + row.width / 2, isCard))
        expectClose(span.bottom - span.top, width, "S8a.card.h", tolerance: 4)
    }

    /// The S8 skin's own numbers, which the design quotes differently from the shared tokens.
    @Test("S8a card skin constants")
    func cardSkinConstants() throws {
        expectClose(DesignTokens.EditDesk.Corner.panel, 10, "S8a.card.radius", tolerance: 0)
        expectClose(DesignTokens.EditDesk.Shadow.workshopCard.radius, 8, "S8a.card.shadow.radius", tolerance: 0)
        expectClose(DesignTokens.EditDesk.Shadow.workshopCard.y, 3, "S8a.card.shadow.y", tolerance: 0)
        expectClose(DesignTokens.EditDesk.Spacing.workshopCardBandTop, 24, "S8a.card.band.top", tolerance: 0)
        expectClose(DesignTokens.EditDesk.Spacing.workshopCardBandInset, 10, "S8a.card.band.inset", tolerance: 0)
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowseCard.swift")
        #expect(source.contains("strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular"), "border is not .08")
        #expect(source.contains("Typography.workshopCardTitle"), "title is not the 12pt step")
        #expect(source.contains("gradientWorkshopCardBottom"), "band gradient is not .85")
        #expect(source.contains("appearance: .solid("), "the in-library check is still the glass badge")
        ProbeRenderer.report("S8a.card.borderToken", "strokeRegular = ink .08")
        ProbeRenderer.report("S8a.card.titleFont", "Typography.workshopCardTitle = 12 semibold")
        ProbeRenderer.report("S8a.card.bandPadding", "top 24 / sides 10 / bottom 10")
        ProbeRenderer.report("S8a.card.presenceCheck", "18×18 circle, solid .9 fill, black glyph")
    }
}

// MARK: - S8b Workshop modal

@Suite("Fidelity S8b Workshop modal", .serialized)
@MainActor
struct S8bModalFidelityTests {
    private func doctor() -> SteamCMDDoctorService {
        SteamCMDDoctorService(defaults: UserDefaults(suiteName: "fidelity-probe-\(UUID().uuidString)")!)
    }

    private func modal(windowSize: CGSize, doctor: SteamCMDDoctorService) -> some View {
        WorkshopModal(
            content: WorkshopModalContent(item: ProbeFixtures.workshopItem(), installed: nil),
            doctor: doctor,
            targets: ProbeFixtures.targets(thumbnail: nil),
            download: WorkshopDownloadPresentation(
                progress: .fraction(0.64), status: "Downloading · 64%",
                detail: "264 MB / 412 MB · 12 MB/s", isFailure: false
            ),
            primaryTitle: "Apply to MPG321CX when done",
            isPrimaryEnabled: true,
            isRevealed: false,
            matureReveal: nil,
            windowSize: windowSize,
            titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
            onDismiss: {}, actions: ProbeFixtures.workshopActions
        )
        // `WorkshopModal` is documented as value-only, but its details column reaches into the
        // environment for `WorkshopServices`; without one the render traps.
        .environment(WorkshopServices())
    }

    /// The 340pt square is the anchor, the way the red preview is in S4: it is a flat fill, it sits
    /// 12pt inside the panel's top-left corner, and nothing else in that corner shares its colour.
    /// The panel's own fill shades into its drop shadow, so its edges are reported, not asserted.
    private func measure(_ image: ProbeImage, seededBy expected: CGRect, label: String) throws -> (panelOrigin: CGPoint, gif: CGRect) {
        let gifSeed = image.rgb(px: Int((expected.minX + 180) * image.scale), Int((expected.minY + 300) * image.scale))
        ProbeRenderer.report("\(label).gifSeedColour", "\(gifSeed.r),\(gifSeed.g),\(gifSeed.b)")
        // Bounded on three sides: the drop shadow outside the corner and a section fill in the
        // details column (which starts 372pt in) both land on the placeholder's own grey.
        let corner = CGRect(x: expected.minX + 8, y: expected.minY + 8, width: 358, height: 380)
        let gif = try #require(
            image.boundingBox(in: corner) { $0.matches(gifSeed, tolerance: 3) },
            "the square preview did not render"
        )
        ProbeRenderer.report("\(label).gifRect", gif)

        let panelSeed = image.rgb(px: Int((expected.minX + 6) * image.scale), Int(expected.midY * image.scale))
        ProbeRenderer.report("\(label).panelSeedColour", "\(panelSeed.r),\(panelSeed.g),\(panelSeed.b)")
        if let row = image.extent(inRow: expected.midY, { $0.matches(panelSeed, tolerance: 2) }) {
            ProbeRenderer.report("\(label).panelFillExtent", "x=\(row.x) w=\(row.width)")
        }
        return (CGPoint(x: gif.minX - ModalGeometry.previewMargin, y: gif.minY - ModalGeometry.previewMargin - ModalGeometry.headerHeight), gif)
    }

    /// SCREENS S8b: the same 880×560 chrome as S4, a 340pt square preview left, 84pt bar.
    @Test("S8b panel origin, 340 square and 38pt primary button at 1280×820")
    func panelAt1280() async throws {
        let size = CGSize(width: 1280, height: 820)
        let service = doctor()
        let image = await ProbeRenderer.render("S8b-1280-dark", size: size) {
            ZStack { Color(white: 0.5); modal(windowSize: size, doctor: service) }
        }
        let contract = ModalGeometry.panelFrame(in: size)
        let boxes = try measure(image, seededBy: contract, label: "S8b.1280")
        expectClose(boxes.panelOrigin.x, 200, "S8b.1280.panel.x", tolerance: 3)
        expectClose(boxes.panelOrigin.y, 150, "S8b.1280.panel.top", tolerance: 3)
        expectClose(boxes.gif.width, 340, "S8b.1280.gif.w", tolerance: 3)
        expectClose(boxes.gif.height, 340, "S8b.1280.gif.h", tolerance: 3)
        // The chrome's own box, already proved by the S4 render of the same container.
        expectClose(contract.width, 880, "S8b.1280.chrome.w", tolerance: 0)
        expectClose(contract.height, 560, "S8b.1280.chrome.h", tolerance: 0)

        // The primary button is the only pure-white fill inside the 84pt bar in dark mode.
        let bar = CGRect(x: contract.minX, y: contract.maxY - 84, width: contract.width, height: 84)
        let button = try #require(
            image.boundingBox(in: bar) { $0.r > 240 && $0.g > 240 && $0.b > 240 },
            "the primary bar button did not render inside the 84pt bar"
        )
        ProbeRenderer.report("S8b.1280.primaryButtonRect", button)
        expectClose(button.height, 38, "S8b.1280.primaryButton.h", tolerance: 2)
        ProbeRenderer.report("S8b.1280.buttonBottomToPanelBottom", contract.maxY - button.maxY)
        ProbeRenderer.report("S8b.1280.buttonTrailingReserve", contract.maxX - button.maxX)
    }

    @Test("S8b at 1040×700 keeps the 340 square and stops at the strip's 130 clearance")
    func panelAt1040() async throws {
        let size = CGSize(width: 1040, height: 700)
        let service = doctor()
        let image = await ProbeRenderer.render("S8b-1040-dark", size: size) {
            ZStack { Color(white: 0.5); modal(windowSize: size, doctor: service) }
        }
        let contract = ModalGeometry.panelFrame(in: size)
        let boxes = try measure(image, seededBy: contract, label: "S8b.1040")
        expectClose(boxes.panelOrigin.x, 80, "S8b.1040.panel.x", tolerance: 3)
        expectClose(boxes.panelOrigin.y, 130, "S8b.1040.panel.top", tolerance: 3)
        expectClose(boxes.gif.width, 340, "S8b.1040.gif.w", tolerance: 3)
        expectClose(boxes.gif.height, 340, "S8b.1040.gif.h", tolerance: 3)
    }

    /// R-24 ②③④ and the bar's wording, read off the source: the GIF hero, the two-line description
    /// and the mature gate have no measurable colour of their own in an offscreen frame.
    @Test("S8b source contract: 340 hero, 2/120 description, four bar controls, shared mature gate")
    func sourceContract() throws {
        let modalSource = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModal.swift")
        #expect(modalSource.contains("descriptionCollapsedLineLimit: 2"))
        #expect(modalSource.contains("descriptionExpandedMaxHeight: 120"))
        #expect(modalSource.contains("previewSide: CGFloat = 340"))
        #expect(modalSource.contains("bottomBarHeight: CGFloat = 84"))
        #expect(modalSource.contains("buttonHeight: CGFloat = 38"))
        #expect(modalSource.contains("Save only"))
        #expect(modalSource.contains("Cancel download"))
        #expect(modalSource.contains("Open in Steam"))
        #expect(!modalSource.contains("applyToAllDisplays"), "the Workshop modal offers an apply-to-all it must not have")

        // The description honours both limits rather than dropping them on the floor.
        let collapsible = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/DetailSheet.swift")
        #expect(collapsible.contains("var collapsedLineLimit: Int?"))
        #expect(collapsible.contains("var expandedMaxHeight: CGFloat?"))
        #expect(collapsible.contains("if let expandedMaxHeight, isExpanded"), "the expanded cap is declared but never applied")

        // The mature gate: every surface reads the same preference and the same age confirmation.
        for path in [
            "LiveWallpaper/Views/EditDesk/Workshop/WorkshopModal.swift",
            "LiveWallpaper/Views/Workshop/DetailRequiredItemsSection.swift",
            "LiveWallpaper/Views/Workshop/DetailPresetsSection.swift",
        ] {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains("MatureContentSettings.blursThumbnails"), "\(path) skips the shared blur preference")
            #expect(source.contains("MatureContentSettings.isConfirmed"), "\(path) skips the shared age confirmation")
        }
        let paneSource = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")
        #expect(paneSource.contains("matureReveal?.isRevealed(item.id)"), "the grid card is not on the page's reveal state")
        let hostSource = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalHost.swift")
        #expect(hostSource.contains("session.matureReveal.isRevealed(item.id)"), "the modal hero is not on the page's reveal state")
        // R-24 ④: dependencies and presets read the page's set when the host hands them one.
        for path in [
            "LiveWallpaper/Views/Workshop/DetailRequiredItemsSection.swift",
            "LiveWallpaper/Views/Workshop/DetailPresetsSection.swift",
        ] {
            let section = try RepositoryRoot.source(path)
            #expect(section.contains("matureReveal?.isRevealed("), Comment(rawValue: "\(path) is off the page's reveal state"))
        }
        ProbeRenderer.report("S8b.matureReveal.sharedAcrossColumn", true)
    }
}

// MARK: - Five languages

@Suite("Fidelity S8b five-language chrome", .serialized)
@MainActor
struct S8bLocalizationWidthTests {
    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "es"]

    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "no \(language).lproj in the app bundle")
        return try #require(Bundle(path: path))
    }

    /// The bar's own font and padding, so the number is a laid-out width, not a character count.
    private func buttonWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 15, weight: .bold)
        return (text as NSString).size(withAttributes: [.font: font]).width + 2 * 14
    }

    /// `LocalizationCoverageTests` only proves a key exists; this asks whether the translated bar
    /// still fits the 880pt panel.
    @Test("Every S8b bar button fits the 880pt panel in all five languages")
    func barFitsInEveryLanguage() throws {
        let barWidth: CGFloat = 880 - 2 * 20
        for language in Self.languages {
            let localized = try bundle(language)
            let primary = String(
                format: NSLocalizedString("Apply to %@ when done", bundle: localized, comment: ""),
                "MPG321CX OLED"
            )
            let saveOnly = NSLocalizedString("Save only", bundle: localized, comment: "")
            let cancel = NSLocalizedString("Cancel download", bundle: localized, comment: "")
            let total = buttonWidth(primary) + buttonWidth(saveOnly) + buttonWidth(cancel) + 38 + 3 * 12
            ProbeRenderer.report(
                "S8b.bar.\(language)",
                "primary=\(buttonWidth(primary)) saveOnly=\(buttonWidth(saveOnly)) cancel=\(buttonWidth(cancel)) total=\(total) left=\(barWidth - total)"
            )
            #expect(total <= barWidth, Comment(rawValue: "\(language): the bar needs \(total)pt of \(barWidth)pt"))
        }
    }

    /// The caption box is a 70pt floor the text can push, so no translation is clipped. This goes
    /// red if the box goes back to a cap, and if the strip stops budgeting for the wider ones.
    @Test("The float strip caption box fits every translation and widens the strip with it")
    func floatCaptionFits() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var overflowing: Set<String> = []
        for language in Self.languages {
            let localized = try bundle(language)
            for key in ["Drag to a display\nto apply", "After downloading\napply to"] {
                let text = NSLocalizedString(key, bundle: localized, comment: "")
                let widest = text.components(separatedBy: "\n")
                    .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                    .max() ?? 0
                let box = FloatLayerGeometry.captionWidth(ofCaption: text)
                ProbeRenderer.report("S5.caption.\(language).\(key.prefix(6))", "text=\(widest) box=\(box)")
                #expect(widest > 0, "the caption string did not resolve")
                #expect(box >= FloatLayerGeometry.captionMinWidth, Comment(rawValue: "\(language): box \(box)"))
                // The strip's run-in is the caption plus its gutters, not the old fixed 120.
                #expect(
                    FloatLayerGeometry.stripWidth(count: 5, windowWidth: 4000, captionWidth: box) == 5 * 160 + box + 40,
                    Comment(rawValue: "\(language): the strip budget dropped the caption")
                )
                if widest > box {
                    overflowing.insert(language)
                }
            }
        }
        ProbeRenderer.report("S5.caption.overflowingLanguages", overflowing.sorted())
        #expect(overflowing.isEmpty, Comment(rawValue: "clipped captions: \(overflowing.sorted())"))
        // en and es are the two that needed the box to grow.
        let english = try bundle("en")
        let englishCaption = NSLocalizedString("Drag to a display\nto apply", bundle: english, comment: "")
        #expect(FloatLayerGeometry.captionWidth(ofCaption: englishCaption) > FloatLayerGeometry.captionMinWidth)
    }
}

extension LocalizedStringKey {
    /// The key itself, which `LocalizedStringKey` does not expose. The onboarding content is
    /// authored as keys, and the probe has to look each one up in a specific `.lproj`.
    var probeKey: String {
        Mirror(reflecting: self).children.first { $0.label == "key" }?.value as? String ?? ""
    }
}

// MARK: - S9 onboarding, five languages

/// The S9 / S8b / 6.1c strings are all new this milestone, so nothing has measured them outside
/// English. Same method as `S8bLocalizationWidthTests`: lay the translation out in the font and
/// box the view actually gives it, and fail on the ones that do not fit.
@Suite("Fidelity S9 five-language onboarding", .serialized)
@MainActor
struct S9LocalizationWidthTests {
    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "es"]

    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "no \(language).lproj")
        return try #require(Bundle(path: path))
    }

    private func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    /// Lines the text needs inside `boxWidth`, in the font the view sets. Measured as a ratio
    /// against the same string on one line, so whatever `boundingRect` adds cancels out.
    private func lines(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, boxWidth: CGFloat) -> Int {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight)]
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        func height(_ width: CGFloat) -> CGFloat {
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options, attributes: attributes
            ).height
        }
        let single = height(.greatestFiniteMagnitude)
        guard single > 0 else { return 0 }
        return Int((height(boxWidth) / single).rounded())
    }

    /// SCREENS S9's card: a two-line message in a 460pt box, a 30pt button row, a two-line footnote.
    @Test("Every onboarding card's message, buttons and footnote fit their S9 boxes in all five languages")
    func cardChromeFits() throws {
        // The narrowest the card ever is: the 1040 window minus both gutters and the detail
        // page's 372pt inspector.
        let narrowBox = StageGeometry.minimumWindow.width - 2 * OnboardingCardMetrics.gutter - DetailGeometry.inspectorWidth
        var overflowing: [String] = []
        for language in Self.languages {
            let localized = try bundle(language)
            for page in OnboardingProgress.Page.allCases {
                let content = OnboardingCardContent.of(page)
                let message = NSLocalizedString(content.message.probeKey, bundle: localized, comment: "")
                let messageLines = lines(
                    message, size: 15, weight: .semibold, boxWidth: OnboardingCardMetrics.messageMaxWidth
                )
                let buttons = content.buttons.map {
                    width(NSLocalizedString($0.title.probeKey, bundle: localized, comment: ""), size: 12, weight: .bold)
                        + 2 * DesignTokens.EditDesk.Spacing.s14
                }
                let row = buttons.reduce(0, +)
                    + CGFloat(max(0, buttons.count - 1)) * DesignTokens.EditDesk.Spacing.s8
                let skip = width(NSLocalizedString("Skip", bundle: localized, comment: ""), size: 11)
                let footnote = NSLocalizedString(content.footnote.probeKey, bundle: localized, comment: "")
                let footnoteLines = lines(
                    footnote, size: 11, boxWidth: narrowBox - skip - DesignTokens.EditDesk.Spacing.s12
                )
                ProbeRenderer.report(
                    "S9.card.\(language).\(page)",
                    "messageLines=\(messageLines) buttonRow=\(row) footnoteLines=\(footnoteLines)"
                )
                if messageLines > 2 || footnoteLines > 2 || row > narrowBox {
                    overflowing.append("\(language)/\(page)")
                }
            }
        }
        #expect(overflowing.isEmpty, Comment(rawValue: "clipped by lineLimit(2) or the button row: \(overflowing)"))
    }

    /// The wizard is a fixed 446×526 sheet, so a longer translation has nowhere to go.
    @Test("The Steam wizard's column and footer fit 446×526 in all five languages")
    func wizardFits() throws {
        let column = SteamWizardMetrics.size.width - 2 * DesignTokens.Spacing.xl
        let footerRow = SteamWizardMetrics.size.width - 2 * DesignTokens.Spacing.lg
        // The status card's own row, inside its 12pt padding: title, glyph, and the detail after it.
        let rowBox = column - 2 * DesignTokens.Spacing.md
        var overflowing: [String] = []
        for language in Self.languages {
            let localized = try bundle(language)
            func localizedString(_ key: String) -> String {
                NSLocalizedString(key, bundle: localized, comment: "")
            }
            let title = lines(
                localizedString("Download Workshop wallpapers with your own Steam account"),
                size: 22, weight: .bold, boxWidth: column
            )
            let body = lines(
                localizedString("Loomscreen downloads through SteamCMD, never through a third-party server. You need to own Wallpaper Engine."),
                size: 13, boxWidth: column
            )
            let note = lines(
                localizedString("Already have a Wallpaper Engine library? Choose Import a Local Folder instead — no sign-in needed."),
                size: 11, boxWidth: column
            )
            // Bordered buttons: the title plus AppKit's own 12pt-a-side padding at the regular size.
            let footer = ["← Back", "Import a Local Folder", "Sign In →"]
                .map { width(localizedString($0), size: 13) + 24 }
            let footerWidth = footer.reduce(0, +) + 2 * DesignTokens.Spacing.md
            let rows = ["SteamCMD", "Steam Account", "Steam Token (2FA)"].map { key -> CGFloat in
                width(localizedString(key), size: 13) + 2 * DesignTokens.EditDesk.Spacing.s8 + 12
            }
            let widestRow = rows.max() ?? 0
            let columnHeight = CGFloat(title) * 26 + CGFloat(body) * 16 + CGFloat(note) * 14
                + 3 * (SteamWizardMetrics.fieldRowHeight + DesignTokens.Spacing.md)
                + 4 * DesignTokens.Spacing.md + 2 * DesignTokens.Spacing.xl + 56
            ProbeRenderer.report(
                "S9.wizard.\(language)",
                "titleLines=\(title) bodyLines=\(body) noteLines=\(note) footer=\(footerWidth) widestRow=\(widestRow) column≈\(columnHeight)"
            )
            if footerWidth > footerRow || widestRow > rowBox || columnHeight > SteamWizardMetrics.size.height {
                overflowing.append(language)
            }
        }
        #expect(overflowing.isEmpty, Comment(rawValue: "the 446×526 sheet does not hold: \(overflowing)"))
    }

    /// 6.1c's two buttons live inside a display's content layer, which is at its smallest when the
    /// 1040 window has to fit three of them.
    @Test("The empty screen's two buttons and hint fit the smallest shell in all five languages")
    func emptyScreenFitsTheSmallestShell() throws {
        let arrangements: [(String, [CGRect])] = [
            ("single", [CGRect(x: 0, y: 0, width: 1920, height: 1080)]),
            ("three", (0 ..< 3).map { CGRect(x: CGFloat($0) * 1920, y: 0, width: 1920, height: 1080) }),
        ]
        var failures: [String] = []
        for language in Self.languages {
            let localized = try bundle(language)
            let choose = NSLocalizedString("Choose File…", bundle: localized, comment: "")
            let paste = NSLocalizedString("Paste URL", bundle: localized, comment: "")
            let hint = NSLocalizedString(
                "Types are detected automatically · mp4 / mov / html / folder / Wallpaper Engine project",
                bundle: localized, comment: ""
            )
            for (name, frames) in arrangements {
                let content = StageGeometry.arrangement(
                    frames: frames, in: StageGeometry.stageRect(windowSize: StageGeometry.minimumWindow)
                ).contentRects[0].size
                let layout = StageGeometry.emptyScreenLayout(
                    content: content,
                    chooseFileTextWidth: StageLayerStyle.width(choose, size: 12, weight: .semibold),
                    pasteURLTextWidth: StageLayerStyle.width(paste, size: 12, weight: .semibold)
                )
                let hintWidth = StageLayerStyle.width(hint, size: 11)
                ProbeRenderer.report(
                    "S9.empty.\(language).\(name)",
                    "content=\(content) buttons=\(layout != nil) hint=\(hintWidth)"
                )
                guard let layout else {
                    failures.append("\(language)/\(name): no room for the buttons")
                    continue
                }
                let bounds = CGRect(origin: .zero, size: content).insetBy(
                    dx: StageGeometry.emptyScreenMargin, dy: StageGeometry.emptyScreenMargin
                )
                if !bounds.contains(layout.chooseFile) || !bounds.contains(layout.pasteURL) {
                    failures.append("\(language)/\(name): the button row escapes the content layer")
                }
                // The hint truncates rather than overflows; record which translations do.
                if hintWidth > layout.hint.width {
                    ProbeRenderer.report("S9.empty.\(language).\(name).truncates", true)
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures)"))
    }
}

// MARK: - Reduce Motion / Increase Contrast / Reduce Transparency

/// What an offscreen probe can and cannot say about the three accessibility modes. SwiftUI's
/// `accessibilityReduceMotion`, `accessibilityReduceTransparency` and `colorSchemeContrast` are
/// read-only, and AppKit hands a token provider plain `darkAqua` under
/// `NSAppearance(named: .accessibilityHighContrastDarkAqua)` while the system setting is off — so
/// the only modes with a rendered before/after here are the ones the stage takes as explicit
/// inputs. The rest are source contracts plus the 实机 list.
@Suite("Fidelity accessibility three modes", .serialized)
@MainActor
struct AccessibilityModeFidelityTests {
    private static let newViews = [
        "LiveWallpaper/Views/EditDesk/Onboarding/OnboardingCard.swift",
        "LiveWallpaper/Views/EditDesk/Onboarding/OnboardingCapsule.swift",
        "LiveWallpaper/Views/EditDesk/Onboarding/SteamWizard.swift",
        "LiveWallpaper/Views/EditDesk/Shell/EditDeskBackdrop.swift",
        "LiveWallpaper/Views/EditDesk/Shell/TopBar.swift",
        "LiveWallpaper/Views/EditDesk/Shell/TopBarBudget.swift",
    ]

    private func makeModel() -> EditDeskStageModel {
        let model = EditDeskStageModel()
        model.reduceMotion = true
        model.displays = [
            StageDisplay(
                id: 1, fingerprint: "external", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                isBuiltin: false, name: "MPG321CX", badgeText: "EXTERNAL · 32″", statusText: "Main",
                cover: ProbeRenderer.solid(ProbeRenderer.previewRed), state: .ok
            ),
            StageDisplay(
                id: 2, fingerprint: "builtin", frame: CGRect(x: 1920, y: 0, width: 1728, height: 1117),
                isBuiltin: true, name: "MacBook Pro", badgeText: "BUILT-IN · 16″", statusText: "",
                cover: nil, state: .empty
            ),
        ]
        return model
    }

    @Test("Increase Contrast redraws the stage at both window steps", arguments: [
        StageGeometry.designWindow, StageGeometry.minimumWindow,
    ])
    func contrastRedrawsTheStage(window: CGSize) async throws {
        var images: [Bool: ProbeImage] = [:]
        for increased in [false, true] {
            let model = makeModel()
            model.increaseContrast = increased
            let name = "A11y-stage-contrast\(increased ? "On" : "Off")-\(Int(window.width))"
            images[increased] = await ProbeRenderer.render(name, size: window, settle: 0.4) {
                ZStack {
                    EditDeskBackdrop(frosted: false)
                    EditDeskStageRepresentable(model: model)
                }
            }
        }
        let off = try #require(images[false])
        let on = try #require(images[true])
        // The wallpapered display drew at all: its cover is the probe's red.
        #expect(off.boundingBox { $0.isRed } != nil, "the stage never rendered into the bitmap")
        var changed = 0
        for y in stride(from: 0, to: off.height, by: 2) {
            for x in stride(from: 0, to: off.width, by: 2) where !off.rgb(px: x, y).matches(on.rgb(px: x, y), tolerance: 1) {
                changed += 1
            }
        }
        let shells = off.boundingBox { $0.isRed }
        ProbeRenderer.report(
            "A11y.stage.\(Int(window.width))",
            "bitmap=\(off.width)×\(off.height) cover=\(shells.map(\.debugDescription) ?? "none") changedPixels=\(changed)"
        )
        #expect(changed > 0, "Increase Contrast changed nothing on the stage")
    }

    /// Reduce Transparency's whole effect on the new shell is this branch, so the flat fill is the
    /// thing to show: the blur itself never composites offscreen and is 实机 either way.
    @Test("Reduce Transparency's backdrop is the flat token fill")
    func reduceTransparencyBackdrop() async {
        let size = StageGeometry.designWindow
        let flat = await ProbeRenderer.render("A11y-backdrop-reduceTransparency", size: size, settle: 0.3) {
            EditDeskBackdrop(frosted: false)
        }
        _ = await ProbeRenderer.render("A11y-backdrop-frosted", size: size, settle: 0.3) {
            EditDeskBackdrop(frosted: true)
        }
        var expected = ProbeColor(r: -1, g: -1, b: -1)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            let resolved = NSColor(DesignTokens.EditDesk.Colors.background).usingColorSpace(.sRGB)
            expected = ProbeColor(
                r: Int(((resolved?.redComponent ?? 0) * 255).rounded()),
                g: Int(((resolved?.greenComponent ?? 0) * 255).rounded()),
                b: Int(((resolved?.blueComponent ?? 0) * 255).rounded())
            )
        }
        // Off the dot grid: the tile puts a 2pt dot at the middle of every 24pt cell.
        let sample = flat.rgb(px: Int(4 * flat.scale), Int(4 * flat.scale))
        ProbeRenderer.report("A11y.backdrop.flat", "\(sample.r),\(sample.g),\(sample.b) vs \(expected.r),\(expected.g),\(expected.b)")
        #expect(sample.matches(expected, tolerance: 2), "the Reduce Transparency fallback is not the background token")
    }

    @Test("The new views carry no glass, and take Reduce Motion and Reduce Transparency from the environment")
    func sourceContracts() throws {
        for path in Self.newViews {
            let source = try RepositoryRoot.source(path)
            #expect(!source.contains("ultraThinMaterial"), "\(path) has a material Reduce Transparency cannot switch off")
            #expect(!source.contains("glassEffect("), "\(path) has a glass effect Reduce Transparency cannot switch off")
            #expect(!source.contains("NSVisualEffectView") || path.hasSuffix("EditDeskBackdrop.swift"))
        }
        let backdrop = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/EditDeskBackdrop.swift")
        #expect(backdrop.contains("accessibilityReduceTransparency"))
        #expect(backdrop.contains("if frosted, !reduceTransparency"), "the blur must be gated on the setting")
        let card = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Onboarding/OnboardingCard.swift")
        #expect(card.contains("accessibilityReduceMotion"))
        #expect(card.contains("guard !reduceMotion else { return .opacity }"), "R-36: the card's transition must fade only")
        let home = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(home.contains("stage.increaseContrast = page.contrast == .increased"), "the stage never hears about contrast")
    }
}

@Suite("Settings background consistency", .serialized)
@MainActor
struct SettingsBackgroundFidelityTests {
    @Test("Sidebar, search header and grouped form share one background", arguments: [false, true])
    func sharedBackground(dark: Bool) async {
        let image = await ProbeRenderer.render(
            "settings-background-\(dark ? "dark" : "light")",
            size: CGSize(width: 1040, height: 752), appearance: dark ? .darkAqua : .aqua
        ) {
            HStack(spacing: 0) {
                SettingsSidebar(selection: .constant(.general), searchText: .constant(""),
                                pendingSearchAnchor: .constant(nil), onBack: {})
                    .frame(width: 220)
                Form {
                    Section("General") {
                        Text("Language")
                    }
                }
                .settingsFormChrome()
            }
        }
        let background = image.rgb(px: Int(1025 * image.scale), Int(700 * image.scale))
        for point in [CGPoint(x: 210, y: 15), CGPoint(x: 210, y: 700), CGPoint(x: 230, y: 700)] {
            let pixel = image.rgb(px: Int(point.x * image.scale), Int(point.y * image.scale))
            #expect(pixel.matches(background, tolerance: 2),
                    "The native list or header introduced a second page background")
        }
    }
}
#endif
