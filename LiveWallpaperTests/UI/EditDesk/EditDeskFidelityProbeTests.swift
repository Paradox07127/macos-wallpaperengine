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
        var content = WallpaperModalContent(itemID: "probe-item", title: "Painting the Sharks 4K", kind: .scene)
        content.facts = [
            WallpaperFact(kind: .type, value: "Scene"), WallpaperFact(kind: .size, value: "214 MB"),
            WallpaperFact(kind: .resolution, value: "3840 × 2160"),
        ]
        content.preview = preview
        return content
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
            applyTo: { _ in }, applyToAllDisplays: {},
            showInFinder: {}, openInSteam: {},
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
            press: { _ in }, saveOnly: {}, cancelDownload: {}, connectSteam: {},
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
            requestRename: {}, requestDelete: {},
            navigation: ProbeFixtures.navigation,
            windowSize: windowSize,
            titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
            onDismiss: {}, onDrag: { _ in }
        )
    }

    /// The red preview is the anchor: the 16:9 fill fitted into the 4:3 box sits `letterbox` under the
    /// box's top, and the box opens past the side padding and the ← slot, under the title row.
    static func panelOrigin(from preview: CGRect) -> CGPoint {
        let letterbox = (ModalGeometry.previewSize.height - ModalGeometry.previewSize.width * 9 / 16) / 2
        return CGPoint(
            x: preview.minX - ModalGeometry.horizontalPadding - ModalGeometry.iconButtonSize - ModalGeometry.arrowGap,
            y: preview.minY - letterbox - ModalGeometry.contentTop
        )
    }

    /// `ModalGeometry`: at most 920×680, centred, never above 72; a 340×255 box the 16:9 preview fits into.
    @Test("S4 panel and preview at 1280×820")
    func panelAt1280() async throws {
        let size = CGSize(width: 1280, height: 820)
        let image = await ProbeRenderer.render("S4-1280-dark", size: size) {
            ZStack { Color(white: 0.5); modal(windowSize: size) }
        }
        let preview = try #require(image.boundingBox { $0.isRed }, "the modal preview did not render")
        ProbeRenderer.report("S4.1280.previewRect", preview)
        let origin = Self.panelOrigin(from: preview)
        ProbeRenderer.report("S4.1280.panelOrigin", origin)
        expectClose(origin.y, 72, "S4.1280.panel.top", tolerance: 3)
        expectClose(origin.x, 180, "S4.1280.panel.x", tolerance: 3)
        expectClose(preview.height, 191.25, "S4.1280.preview.h", tolerance: 3)
        expectClose(preview.width, 340, "S4.1280.preview.w", tolerance: 3)
        // The contract the render is measured against.
        let contract = ModalGeometry.panelFrame(in: size)
        ProbeRenderer.report("S4.contract.1280", contract)
        expectClose(contract.width, 920, "S4.contract.1280.w", tolerance: 0)
        expectClose(contract.height, 680, "S4.contract.1280.h", tolerance: 0)
        expectClose(contract.minY, 72, "S4.contract.1280.top", tolerance: 0)
    }

    /// Centred, the 600pt panel would start at 50, so it stops at the 72pt floor.
    @Test("S4 panel at 1040×700 stops at the 72pt floor and keeps the 340pt preview box")
    func panelAt1040() async throws {
        let size = CGSize(width: 1040, height: 700)
        let image = await ProbeRenderer.render("S4-1040-dark", size: size) {
            ZStack { Color(white: 0.5); modal(windowSize: size) }
        }
        let preview = try #require(image.boundingBox { $0.isRed })
        let origin = Self.panelOrigin(from: preview)
        ProbeRenderer.report("S4.1040.panelOrigin", origin)
        expectClose(preview.width, 340, "S4.1040.preview.w", tolerance: 3)
        expectClose(origin.y, 72, "S4.1040.panel.top", tolerance: 3)
        expectClose(origin.x, 60, "S4.1040.panel.x", tolerance: 3)
        let contract = ModalGeometry.panelFrame(in: size)
        ProbeRenderer.report("S4.contract.1040", contract)
        expectClose(contract.height, 600, "S4.contract.1040.h", tolerance: 0)
    }

    @Test("S4 light appearance renders for reference")
    func lightReference() async throws {
        let size = CGSize(width: 1280, height: 820)
        let image = await ProbeRenderer.render("S4-1280-light", size: size, appearance: .aqua) {
            ZStack { Color(white: 0.5); modal(windowSize: size) }
        }
        let preview = try #require(image.boundingBox { $0.isRed })
        expectClose(preview.width, 340, "S4.light.preview.w", tolerance: 3)
    }
}

// MARK: - S5 float layer

@Suite("Fidelity S5 display float layer", .serialized)
@MainActor
struct S5FloatLayerFidelityTests {
    private func layer(width: CGFloat) -> some View {
        DisplayFloatLayer(
            targets: ProbeFixtures.targets(thumbnail: ProbeRenderer.solid(ProbeRenderer.thumbnailBlue)),
            highlighted: nil, windowWidth: width, onTargetFrame: { _ in }, onRunFrame: { _ in }
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
                layer(width: 1280).padding(.top, 14)
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

    /// The caption box is a floor the Spanish text pushes; this frame is the Spanish one.
    @Test("S5 strip in Spanish renders for the caption check")
    func spanishCaption() async {
        let size = CGSize(width: 1280, height: 200)
        let image = await ProbeRenderer.render("S5-1280-dropTarget-es", size: size) {
            ZStack(alignment: .top) {
                Color(white: 0.5)
                layer(width: 1280)
                    .padding(.top, 14)
                    .environment(\.locale, Locale(identifier: "es"))
            }
        }
        #expect(image.runs(inRow: 14 + 52) { $0.isBlue }.count == 2)
    }
}

@Suite("Fidelity S4+S5 overlap at 700 high", .serialized)
@MainActor
struct S4S5OverlapTests {
    /// The library draws the strip only while its preview is dragged, so the panel keeps its own
    /// 72pt floor and the strip covers the panel's top band; the preview stays clear of it.
    @Test("The drag-time float strip covers the top band of the library panel at 1040×700")
    func stripCoversPanelTop() async throws {
        let size = CGSize(width: 1040, height: 700)
        let image = await ProbeRenderer.render("S4-S5-1040x700-overlap-dark", size: size) {
            ZStack(alignment: .top) {
                Color(white: 0.5)
                WallpaperModal(
                    content: ProbeFixtures.libraryContent(preview: ProbeRenderer.solid(ProbeRenderer.previewRed)),
                    targets: ProbeFixtures.targets(thumbnail: ProbeRenderer.solid(ProbeRenderer.thumbnailBlue)),
                    actions: ProbeFixtures.libraryActions, requestRename: {}, requestDelete: {},
                    navigation: ProbeFixtures.navigation,
                    windowSize: size, titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
                    onDismiss: {}, onDrag: { _ in }
                )
                DisplayFloatLayer(
                    targets: ProbeFixtures.targets(thumbnail: ProbeRenderer.solid(ProbeRenderer.thumbnailBlue)),
                    highlighted: nil, windowWidth: size.width, onTargetFrame: { _ in }, onRunFrame: { _ in }
                )
                .padding(.top, FloatLayerGeometry.panelTop)
            }
        }
        let preview = try #require(image.boundingBox { $0.isRed })
        let panelTop = S4ModalFidelityTests.panelOrigin(from: preview).y
        let stripBottom = FloatLayerGeometry.panelTop + FloatLayerGeometry.panelHeight
        ProbeRenderer.report("S4S5.panelTop", panelTop)
        ProbeRenderer.report("S4S5.stripBottom", stripBottom)
        ProbeRenderer.report("S4S5.previewClearance", preview.minY - stripBottom)
        expectClose(panelTop, 72, "S4S5.panelTop", tolerance: 3)
        expectClose(panelTop - stripBottom, -46, "S4S5.verticalClearance", tolerance: 3)
        // At 1280×820 the 680pt panel also stops at 72, so the strip covers the same top 46pt.
        expectClose(
            ModalGeometry.panelFrame(in: CGSize(width: 1280, height: 820)).minY - stripBottom,
            -46, "S4S5.clearance1280", tolerance: 0
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
                intendsToPlay: true
            ),
            heroImage: ProbeRenderer.solid(ProbeRenderer.heroMagenta),
            windowSize: windowSize,
            section: .constant(.wallpaper),
            heroVisible: true,
            actions: ProbeFixtures.detailActions,
            hud: { Color(nsColor: ProbeRenderer.hudCyan) },
            inspector: { _ in Color(nsColor: ProbeRenderer.inspectorYellow) },
            overlayCanvas: { _ in Color.clear },
            wallpaperStatus: { EmptyView() },
            inspectorVisible: .constant(true),
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

    @Test("S6-B facts chip marks a warning with a dark-appearance amber triangle and keeps its text white in a light app")
    func factsChipWarningTint() async throws {
        let size = CGSize(width: 480, height: 270)
        let status = DetailHeroStatus(
            title: "Probe", kindLine: "", intendsToPlay: nil, facts: [DetailFact(text: "████", isWarning: true)]
        )
        let image = await ProbeRenderer.render(nil, size: size, appearance: .aqua, settle: 0.3) {
            DetailHero(status: status, image: ProbeRenderer.solid(.black), size: size, hud: { EmptyView() })
        }
        let dark = await Self.warningSwatch(.darkAqua)
        let light = await Self.warningSwatch(.aqua)
        let triangle = try #require(Self.warmestPixel(in: image), "the chip drew no warning glyph")
        let mark = try #require(image.boundingBox { $0.r - $0.b > 60 })
        // The line's last ink is the warning text's last block; the hero's .25 stroke stays under 128.
        let ink = try #require(image.extent(inRow: mark.midY) { max($0.r, $0.g, $0.b) > 128 })
        let textX = ink.x + ink.width - 2
        let text = image.rgb(px: Int(textX * image.scale), Int(mark.midY * image.scale))
        ProbeRenderer.report("S6.factsChip.warning", "triangle \(triangle), text \(text), dark \(dark), light \(light)")
        #expect(text.matches(ProbeColor(r: 255, g: 255, b: 255), tolerance: 6), "the warning's text drew \(text), not the other facts' white")
        #expect(triangle.matches(dark, tolerance: 6), "the triangle drew \(triangle); the dark-appearance tint is \(dark)")
        #expect(mark.maxX < textX, "the amber mark \(mark) reaches the text at x \(textX) instead of standing before it")
        // mediaChipFill over a white backdrop is the brightest the chip can get.
        let fill = try #require(NSColor(DesignTokens.EditDesk.Colors.mediaChipFill).usingColorSpace(.sRGB))
        let alpha = Double(fill.alphaComponent)
        let brightest = SIMD3(Double(fill.redComponent), Double(fill.greenComponent), Double(fill.blueComponent)) * alpha
            + SIMD3(repeating: 1 - alpha)
        func ratio(_ color: ProbeColor) -> Double {
            WPEMediaArtworkPalette.contrastRatio(SIMD3(Double(color.r), Double(color.g), Double(color.b)) / 255, brightest)
        }
        ProbeRenderer.report("S6.factsChip.contrastOnBrightest", "triangle \(ratio(triangle)), text \(ratio(text))")
        #expect(ratio(triangle) >= 3, "a graphic needs 3:1; the triangle has \(ratio(triangle))")
        #expect(ratio(text) >= 4.5, "text needs 4.5:1; the warning's text has \(ratio(text))")
    }

    private static func warningSwatch(_ appearance: NSAppearance.Name) async -> ProbeColor {
        let image = await ProbeRenderer.render(nil, size: CGSize(width: 16, height: 16), appearance: appearance, settle: 0.1) {
            Rectangle().fill(DesignTokens.EditDesk.Colors.warning)
        }
        return image.rgb(px: image.width / 2, image.height / 2)
    }

    /// The warning glyphs are the only warm marks in the frame, and a fully covered pixel carries the tint itself.
    private static func warmestPixel(in image: ProbeImage) -> ProbeColor? {
        var warmest: ProbeColor?
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let pixel = image.rgb(px: x, y)
                if pixel.r - pixel.b > (warmest.map { $0.r - $0.b } ?? 60) {
                    warmest = pixel
                }
            }
        }
        return warmest
    }
}

// MARK: - S7 overlay (static)

@Suite("Fidelity S7 overlay column and canvas", .serialized)
@MainActor
struct S7OverlayFidelityTests {
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

    /// Seven equal tiles a row, both rows, and nothing under them but the 12pt inset.
    @Test("Add strip lays fourteen tiles out as 7×2 at 1040 and 1280")
    func addStripGrid() async {
        for width in [CGFloat(1040), 1280] {
            let fixture = S7OverlayFixture()
            let height = AddOverlayDrawer.expandedHeight
            let image = await ProbeRenderer.render("S7-add-strip-\(Int(width))", size: CGSize(width: width, height: height)) {
                ZStack(alignment: .top) {
                    DesignTokens.EditDesk.Colors.background
                    AddOverlayDrawer(session: fixture.session, isExpanded: .constant(true), height: height) { _ in }
                }
            }
            fixture.close()
            let base = image.rgb(px: 2, image.height - 2)
            let pitch = AddOverlayDrawer.tileWidth(containerWidth: width, count: OverlayLayerList.addItems.count) + 8
            for (row, top) in [(0, CGFloat(38)), (1, 38 + 46 + 8)] {
                let edges = image.runs(inRow: top + 3) { S7OverlayFixture.differs($0, from: base, by: 10) }
                let lefts = stride(from: 0, to: edges.count, by: 2).map { edges[$0].x }
                ProbeRenderer.report("S7.addStrip.\(Int(width)).row\(row).lefts", lefts)
                #expect(lefts.count == 7, "row \(row) at \(Int(width)) drew \(lefts.count) tiles")
                if lefts.count == 7 {
                    expectClose((lefts[6] - lefts[0]) / 6, pitch, "S7.addStrip.\(Int(width)).row\(row).pitch", tolerance: 1)
                }
            }
            let bottom = S7OverlayFixture.lastInkRow(image, width: width, base: base)
            expectClose(bottom, height - 12, "S7.addStrip.\(Int(width)).contentBottom", tolerance: 1)
        }
    }

    /// Every object's groups start on the wallpaper inspector's edge, 12pt under the 44pt header.
    @Test("Inspector groups share one left edge and top at 372")
    func inspectorEdges() async throws {
        let fixture = S7OverlayFixture(widgets: [MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.3, y: 0.4)])
        let cpu = try #require(fixture.session.interaction.placements.first)
        let edge = DesignTokens.Inspector.horizontalPadding(for: 372)
        let cases: [(String, OverlaySelection)] = [
            ("board", .board), ("widget", .widget(cpu.id)), ("music", .music), ("clock", .clock), ("effect", .effect),
        ]
        for (name, selection) in cases {
            fixture.session.select(selection)
            let image = await ProbeRenderer.render("S7-inspector-\(name)-372", size: CGSize(width: 372, height: 604)) {
                fixture.inspector(width: 372)
            }
            let base = image.rgb(px: Int(image.scale * 370), Int(image.scale * 600))
            // Past the group's 10pt corner radius, where its top edge runs straight.
            let top = S7OverlayFixture.firstInkRow(image, column: edge + 30, from: ObjectInspector.headerHeight, base: base)
            expectClose(top, ObjectInspector.headerHeight + 12, "S7.inspector.\(name).groupTop", tolerance: 1)
            let left = image.runs(inRow: top + 20) { S7OverlayFixture.differs($0, from: base, by: 6) }.first?.x ?? -1
            expectClose(left, edge, "S7.inspector.\(name).groupLeft", tolerance: 1)
        }
        fixture.close()
    }

    /// A title that wraps grows its row, so the music card's first group keeps its height only if nothing wrapped.
    @Test("At its 340pt minimum the music inspector wraps no row")
    func inspectorMinimumWidth() async {
        let fixture = S7OverlayFixture()
        fixture.session.select(.music)
        var heights: [CGFloat] = []
        for width in [CGFloat(340), 440] {
            let image = await ProbeRenderer.render("S7-inspector-music-\(Int(width))", size: CGSize(width: width, height: 604)) {
                fixture.inspector(width: width)
            }
            let base = image.rgb(px: Int(image.scale * (width - 2)), Int(image.scale * 2))
            let column = DesignTokens.Inspector.horizontalPadding(for: width) + 4
            let top = S7OverlayFixture.firstInkRow(image, column: column, from: ObjectInspector.headerHeight, base: base)
            let bottom = S7OverlayFixture.firstBaseRow(image, column: column, from: top + 1, base: base)
            ProbeRenderer.report("S7.inspector.music.\(Int(width)).firstGroup", "\(top)–\(bottom)")
            heights.append(bottom - top)
        }
        fixture.close()
        expectClose(heights[0], heights[1], "S7.inspector.music.340.firstGroupHeight", tolerance: 1)
    }
}

/// An overlay session on a 1728×1117 display with music, clock and the effect off, so no tile carries a mark.
@MainActor
private final class S7OverlayFixture {
    let screen = Screen(nsScreen: S7OverlayTestScreen())
    let manager: ScreenManager
    let store: S7OverlayStore
    let session = OverlayEditorSession(defaults: UserDefaults(suiteName: "S7OverlayFidelityTests") ?? .standard)

    init(widgets: [MonitorWidgetPlacement] = []) {
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro), originReconciler: PreservingOriginReconciler()
        ))
        store = S7OverlayStore(widgets: widgets)
        manager.monitorOverlays[screen.displayFingerprint] = store.snapshot.overlay
        session.transition(to: store.identity, store: store, editing: true)
    }

    func inspector(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            DesignTokens.EditDesk.Colors.background
            ObjectInspector(session: session, screen: screen, screenManager: manager,
                            placements: session.interaction.placements, height: 604, width: width)
        }
        .environment(manager)
    }

    func close() {
        session.detach()
        manager.tearDownForTermination()
    }

    static func differs(_ color: ProbeColor, from base: ProbeColor, by delta: Int) -> Bool {
        color.r >= 0 && (abs(color.r - base.r) > delta || abs(color.g - base.g) > delta || abs(color.b - base.b) > delta)
    }

    /// Lowest row, in points, that holds anything but the background.
    static func lastInkRow(_ image: ProbeImage, width: CGFloat, base: ProbeColor) -> CGFloat {
        for y in stride(from: image.height - 1, through: 0, by: -1) {
            for x in 0 ..< Int(width * image.scale) where differs(image.rgb(px: x, y), from: base, by: 10) {
                return CGFloat(y + 1) / image.scale
            }
        }
        return 0
    }

    static func firstInkRow(_ image: ProbeImage, column: CGFloat, from start: CGFloat, base: ProbeColor) -> CGFloat {
        let x = Int(column * image.scale)
        for y in Int(start * image.scale) ..< image.height where differs(image.rgb(px: x, y), from: base, by: 6) {
            return CGFloat(y) / image.scale
        }
        return -1
    }

    static func firstBaseRow(_ image: ProbeImage, column: CGFloat, from start: CGFloat, base: ProbeColor) -> CGFloat {
        let x = Int(column * image.scale)
        for y in Int(start * image.scale) ..< image.height where !differs(image.rgb(px: x, y), from: base, by: 3) {
            return CGFloat(y) / image.scale
        }
        return -1
    }
}

@MainActor
private final class S7OverlayStore: OverlayEditorStore {
    let identity = OverlayEditorIdentity(displayID: 0x57A7_0001, fingerprint: "s7-overlay-fidelity")
    var snapshot: OverlayEditorSnapshot

    init(widgets: [MonitorWidgetPlacement]) {
        let configuration = ScreenConfiguration(
            screenID: identity.displayID, wallpaper: .html(source: .inline("Test"), config: .default), particleEffect: ParticleEffect.none
        )
        snapshot = OverlayEditorSnapshot(
            overlay: MonitorOverlayConfiguration(enabled: true, board: MonitorBoardConfiguration(widgets: widgets)),
            configuration: configuration, logicalSize: CGSize(width: 1728, height: 1117), safeArea: .none
        )
    }

    var displays: [OverlayEditorIdentity] {
        [identity]
    }

    func read(_ identity: OverlayEditorIdentity) -> OverlayEditorSnapshot? {
        identity == self.identity ? snapshot : nil
    }

    func writeBoard(_ board: MonitorBoardConfiguration, for _: OverlayEditorIdentity) {
        snapshot.overlay.board = board
    }

    func writeOverlayEnabled(_ enabled: Bool, for _: OverlayEditorIdentity) {
        snapshot.overlay.enabled = enabled
    }

    func writeMusic(_ music: MusicOverlayConfiguration, for _: OverlayEditorIdentity) {
        snapshot.overlay.music = music
    }

    func writeClock(_ clock: ClockOverlayConfiguration, for _: OverlayEditorIdentity) {
        snapshot.overlay.clock = clock
    }

    func writeEffect(_ effect: ParticleEffect, for _: OverlayEditorIdentity) {
        snapshot.configuration?.particleEffect = effect
    }

    func copy(_: OverlayKind, from _: OverlayEditorIdentity) {}
}

private final class S7OverlayTestScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 1728, height: 1117)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0x57A7_0001)]
    }

    override var localizedName: String {
        "S7 overlay fidelity"
    }

    /// `getScreenRefreshRate` falls back to this; AppKit traps when an `init()`-built screen is asked.
    override var maximumFramesPerSecond: Int {
        60
    }
}

// MARK: - S8a Workshop grid

@Suite("Fidelity S8a Workshop grid", .serialized)
@MainActor
struct S8aGridFidelityTests {
    private static let inset = DesignTokens.Settings.formHorizontalMargin
    private static let windows: [(width: CGFloat, columns: Int)] = [(1040, 5), (1280, 6), (1728, 8)]

    /// 186pt preferred columns shared out across the row, 14 gap, 18 side inset.
    @Test("Column arithmetic packs 5 at 1040, 6 at 1280 and 8 at 1728, with or without a legacy scroller")
    func columnArithmetic() {
        expectClose(DesignTokens.LibraryGrid.workshopBrowseColumnWidth, 186, "S8a.columnWidth", tolerance: 0)
        expectClose(DesignTokens.LibraryGrid.spacing, 14, "S8a.gap", tolerance: 0)
        expectClose(Self.inset, 18, "S8a.sideInset", tolerance: 0)
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        for (window, expected) in Self.windows {
            for gutter in [2 * Self.inset, 2 * Self.inset + scroller] {
                let columns = DesignTokens.LibraryGrid.columns(
                    for: .medium, aspect: .square, fitting: window - gutter,
                    columnWidth: DesignTokens.LibraryGrid.workshopBrowseColumnWidth
                )
                ProbeRenderer.report("S8a.columns.\(Int(window)).less\(Int(gutter))", columns.count)
                #expect(columns.count == expected, "\(window) less \(gutter) packed \(columns.count) columns")
            }
        }
        // Why the inset is 18: the 24pt gutter the rest of the app uses, with a legacy scroller, drops 1040 to four.
        let atGutter = DesignTokens.LibraryGrid.columns(
            for: .medium, aspect: .square, fitting: 1040 - 2 * DesignTokens.Spacing.xl - scroller,
            columnWidth: DesignTokens.LibraryGrid.workshopBrowseColumnWidth
        )
        ProbeRenderer.report("S8a.columnsIfGutterWere24", atGutter.count)
        #expect(atGutter.count == 4)
    }

    /// The same grid rendered: count, width, pitch and both insets come off the bitmap.
    @Test("Rendered grid fills the row with 5 columns at 1040, 6 at 1280 and 8 at 1728")
    func renderedGrid() async throws {
        // The scroll view gives a legacy scroller's width out of the row when the system shows one.
        let scroller = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        for (window, expected) in Self.windows {
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
            let row = window - 2 * Self.inset - scroller
            let shared = (row - CGFloat(expected - 1) * DesignTokens.LibraryGrid.spacing) / CGFloat(expected)
            expectClose(first.width, shared, "S8a.\(Int(window)).tile.w")
            expectClose(first.x, Self.inset, "S8a.\(Int(window)).leadingInset")
            if tiles.count >= 2 {
                expectClose(tiles[1].x - tiles[0].maxX, 14, "S8a.\(Int(window)).gap")
            }
            // The columns share the row: past the last tile there is only the side inset.
            let last = try #require(tiles.last)
            expectClose(window - Self.inset - scroller - last.maxX, 0, "S8a.\(Int(window)).trailingSlack")
        }
    }

    /// One card at its real column width, rendered, so the S8 skin is measured rather than assumed.
    @Test("A single Edit Desk BrowseCard renders square at the preset width")
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
        let item = ProbeFixtures.workshopItem()
        return WorkshopModal(
            content: WorkshopModalContent(item: item, installed: nil),
            doctor: doctor,
            facts: WorkshopModalContent.facts(item: item, importedAt: nil, now: Date(), locale: AppLanguagePreference.current.locale),
            row: WorkshopModalButtonRow.make(
                targets: ProbeFixtures.targets(thumbnail: nil), isInstalled: false, canRun: true, ticketState: .waiting,
                queuedScreenID: 1, isBanned: false, isDownloadReady: true, isBusy: true
            ),
            download: WorkshopDownloadPresentation(
                progress: .fraction(0.64), status: "Will apply to MPG321CX when done",
                detail: "64% · 264 MB / 412 MB · 12 MB/s", isFailure: false
            ),
            unsupportedOrigin: nil,
            isRevealed: false,
            matureReveal: nil,
            navigation: ProbeFixtures.navigation,
            windowSize: windowSize,
            titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
            onDismiss: {}, actions: ProbeFixtures.workshopActions
        )
        // `WorkshopModal` is documented as value-only, but its author row and presets reach into the
        // environment for `WorkshopServices`; without one the render traps.
        .environment(WorkshopServices())
    }

    /// Where the layout puts the 4:3 preview box: past the side padding and the ← slot, under the title row.
    static func previewBox(in panel: CGRect) -> CGRect {
        CGRect(
            x: panel.minX + ModalGeometry.horizontalPadding + ModalGeometry.iconButtonSize + ModalGeometry.arrowGap,
            y: panel.minY + ModalGeometry.contentTop,
            width: ModalGeometry.previewSize.width, height: ModalGeometry.previewSize.height
        )
    }

    /// The GIF placeholder fills the whole box: seeded low on the left, clear of the corner chip and the
    /// centre glyph, and searched only around the box, so neither the shadow nor the ← button joins it.
    private func workshopBox(_ image: ProbeImage, around expected: CGRect, label: String) throws -> CGRect {
        let seed = image.rgb(px: Int((expected.minX + 30) * image.scale), Int((expected.minY + 200) * image.scale))
        ProbeRenderer.report("\(label).seedColour", "\(seed.r),\(seed.g),\(seed.b)")
        let fill = try #require(
            image.boundingBox(in: expected.insetBy(dx: -8, dy: -8)) { $0.matches(seed, tolerance: 3) },
            "the Workshop preview did not render"
        )
        ProbeRenderer.report("\(label).fillRect", fill)
        // The 1pt stroke over the grey no longer matches the seed, so the fill ends 1pt inside the box;
        // the red library preview still reads as red under the same stroke.
        return fill.insetBy(dx: -1, dy: -1)
    }

    /// SCREENS S4 ≡ S8b: the library modal (a 4:3 red preview, so the red is the whole box) and the
    /// Workshop modal put the same panel and the same 340×255 box in the same place.
    @Test(
        "S8b and S4 draw the same panel and preview box",
        arguments: [CGSize(width: 1280, height: 820), CGSize(width: 1040, height: 896), CGSize(width: 1040, height: 700)]
    )
    func sameBoxAsTheLibrary(window: CGSize) async throws {
        let tag = "\(Int(window.width))x\(Int(window.height))"
        let panel = ModalGeometry.panelFrame(in: window)
        let expected = Self.previewBox(in: panel)
        let service = doctor()
        let workshopImage = await ProbeRenderer.render("S8b-\(tag)-dark", size: window) {
            ZStack { Color(white: 0.5); modal(windowSize: window, doctor: service) }
        }
        let workshop = try workshopBox(workshopImage, around: expected, label: "S8b.\(tag)")
        let libraryImage = await ProbeRenderer.render("S4-\(tag)-4x3-dark", size: window) {
            ZStack {
                Color(white: 0.5)
                WallpaperModal(
                    content: ProbeFixtures.libraryContent(
                        preview: ProbeRenderer.solid(ProbeRenderer.previewRed, size: CGSize(width: 64, height: 48))
                    ),
                    targets: ProbeFixtures.targets(thumbnail: nil),
                    actions: ProbeFixtures.libraryActions, requestRename: {}, requestDelete: {},
                    navigation: ProbeFixtures.navigation,
                    windowSize: window, titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
                    onDismiss: {}, onDrag: { _ in }
                )
            }
        }
        let library = try #require(libraryImage.boundingBox { $0.isRed }, "the library preview did not render")
        ProbeRenderer.report("S4.\(tag).previewRect", library)
        ProbeRenderer.report("S8b.\(tag).previewRect", workshop)
        for (name, measured, reference) in [
            ("x", workshop.minX, library.minX), ("y", workshop.minY, library.minY),
            ("w", workshop.width, library.width), ("h", workshop.height, library.height),
        ] {
            expectClose(measured, reference, "S8b≡S4.\(tag).preview.\(name)", tolerance: 1)
        }
        expectClose(workshop.minX, expected.minX, "S8b.\(tag).preview.x", tolerance: 3)
        expectClose(workshop.minY, expected.minY, "S8b.\(tag).preview.y", tolerance: 3)
        expectClose(workshop.width, 340, "S8b.\(tag).preview.w", tolerance: 3)
        expectClose(workshop.height, 255, "S8b.\(tag).preview.h", tolerance: 3)
        ProbeRenderer.report("S8b.\(tag).panel", panel)
    }

    /// R-24 ②③④ and the row's wording, read off the source: the GIF fit, the four-line description
    /// and the mature gate have no measurable colour of their own in an offscreen frame.
    @Test("S8b source contract: the shared 4:3 box fitted, a four-line description that grows in place, the shared row, shared mature gate")
    func sourceContract() throws {
        let modalSource = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModal.swift")
        #expect(modalSource.contains("collapsedLineLimit: 4"))
        #expect(!modalSource.contains("expandedMaxHeight"), "the expanded description is still capped")
        #expect(modalSource.contains("contentMode: .fit"), "the animated preview is still cropped to fill its box")
        #expect(!modalSource.contains("previewSide"), "the modal sizes its own preview instead of the shared 4:3 box")
        #expect(!modalSource.contains("bottomBarHeight"), "the modal keeps a fixed-height bar of its own")
        #expect(modalSource.contains("ModalDisplayButtons("))
        #expect(!modalSource.contains("applyToAll"), "the Workshop modal offers an apply-to-all it must not have")
        // The buttons after the displays are worded by the contract; the row draws whichever it is handed.
        let contractSource = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalContract.swift")
        for key in ["Save only", "Cancel Auto-Apply", "Cancel download", "Connect Steam"] {
            #expect(contractSource.contains("\"\(key)\""), Comment(rawValue: "the contract does not word \(key)"))
        }

        // The line limit folds the description; nothing caps it once it is open.
        let collapsible = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/DetailSheet.swift")
        #expect(collapsible.contains("var collapsedLineLimit: Int?"))
        #expect(!collapsible.contains("expandedMaxHeight"), "the expanded description is still capped")

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

    /// Inside the 920pt panel's side padding: all the centred bottom row gets.
    private static let rowBudget = ModalGeometry.maximumSize.width - 2 * ModalGeometry.horizontalPadding
    private static let displayName = "MPG321CX OLED"

    /// Laid out by AppKit rather than estimated from a font: the glass button's own control size and padding.
    private func width(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view.fixedSize()).fittingSize.width
    }

    private func button(_ title: String, symbol: String? = nil) -> CGFloat {
        width(
            Button {} label: {
                if let symbol {
                    Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                } else {
                    Text(verbatim: title)
                }
            }
            .adaptiveGlassButton(.regular, size: .large)
        )
    }

    /// `ModalDisplayButtons`: 8pt between items, 12pt more before the buttons after the displays.
    private func row(caption: String, displays: Int, symbol: String, trailing: [CGFloat] = [], extras: [String] = []) -> CGFloat {
        let items = [width(Text(verbatim: caption).font(DesignTokens.EditDesk.Typography.chip))]
            + Array(repeating: button(Self.displayName, symbol: symbol), count: displays) + trailing
        var total = items.reduce(0, +) + CGFloat(items.count - 1) * DesignTokens.Spacing.sm
        if !extras.isEmpty {
            let buttons = extras.map { button($0) }
            total += DesignTokens.Spacing.sm + DesignTokens.Spacing.md
                + buttons.reduce(0, +) + CGFloat(buttons.count - 1) * DesignTokens.Spacing.sm
        }
        return total
    }

    /// `LocalizationCoverageTests` only proves a key exists; this asks whether the translated row
    /// still fits the panel.
    @Test("The bottom row fits the 872pt panel in all five languages: three displays and All Displays, two displays and both cancels")
    func rowFitsInEveryLanguage() throws {
        for language in Self.languages {
            let localized = try bundle(language)
            func text(_ key: String) -> String {
                NSLocalizedString(key, bundle: localized, comment: "")
            }
            let download = text("Download and apply to")
            let library = row(
                caption: text("Apply to"), displays: 3, symbol: "display",
                trailing: [button(text("All Displays"), symbol: "rectangle.on.rectangle")]
            )
            let queued = row(
                caption: download, displays: 2, symbol: "arrow.down.circle",
                extras: [text("Cancel Auto-Apply"), text("Cancel download")]
            )
            // Reported, not asserted: the same row with a third display, idle, and blocked by a setup step.
            let queuedThree = row(
                caption: download, displays: 3, symbol: "arrow.down.circle",
                extras: [text("Cancel Auto-Apply"), text("Cancel download")]
            )
            let idle = row(caption: download, displays: 3, symbol: "arrow.down.circle", extras: [text("Save only")])
            let blocked = row(
                caption: download, displays: 3, symbol: "arrow.down.circle", extras: [text("Save only"), text("Connect Steam")]
            )
            ProbeRenderer.report(
                "S8b.row.\(language)",
                "library=\(library) queued=\(queued) queued3=\(queuedThree) idle3=\(idle) blocked3=\(blocked) budget=\(Self.rowBudget)"
            )
            #expect(!download.isEmpty && download != "Download and apply to" || language == "en", "no \(language) translation")
            #expect(library <= Self.rowBudget, Comment(rawValue: "\(language): the library row needs \(library)pt of \(Self.rowBudget)pt"))
            #expect(queued <= Self.rowBudget, Comment(rawValue: "\(language): the queued row needs \(queued)pt of \(Self.rowBudget)pt"))
        }
    }

    /// The caption box is a 70pt floor the text can push, so no translation is clipped. This goes
    /// red if the box goes back to a cap, and if the strip stops budgeting for the wider ones.
    @Test("The float strip caption box fits every translation and widens the strip with it")
    func floatCaptionFits() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var overflowing: Set<String> = []
        for language in Self.languages {
            let text = try NSLocalizedString(FloatLayerGeometry.captionKey, bundle: bundle(language), comment: "")
            let widest = text.components(separatedBy: "\n")
                .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            let box = FloatLayerGeometry.captionWidth(ofCaption: text)
            ProbeRenderer.report("S5.caption.\(language)", "text=\(widest) box=\(box)")
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
    @Test(
        "Every onboarding card's message, buttons and footnote fit their S9 boxes in all five languages",
        arguments: [true, false]
    )
    func cardChromeFits(sceneCapable: Bool) throws {
        // The narrowest the card ever is: the 1040 window minus both gutters and the detail
        // page's 372pt inspector.
        let narrowBox = StageGeometry.minimumWindow.width - 2 * OnboardingCardMetrics.gutter - DetailGeometry.inspectorWidth
        var overflowing: [String] = []
        for language in Self.languages {
            let localized = try bundle(language)
            for page in OnboardingProgress.Page.allCases {
                let content = OnboardingCardContent.of(page, sceneCapable: sceneCapable)
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
                    "S9.card.\(sceneCapable ? "pro" : "lite").\(language).\(page)",
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
            // The primary button takes one of four titles, so the footer is measured with the widest.
            let primary = ["Install SteamCMD", "Choose folder", "Sign In →", "Done"]
                .map { width(localizedString($0), size: 13) + 24 }
                .max() ?? 0
            let footer = ["← Back", "Import a Local Folder"]
                .map { width(localizedString($0), size: 13) + 24 } + [primary]
            let footerWidth = footer.reduce(0, +) + 2 * DesignTokens.Spacing.md
            let rows = ["SteamCMD", "Steam Library access", "Steam Account", "Steam Token (2FA)"].map { key -> CGFloat in
                width(localizedString(key), size: 13) + 2 * DesignTokens.EditDesk.Spacing.s8 + 12
            }
            let widestRow = rows.max() ?? 0
            // The card also carries at most one two-line step note (11pt lines, `sm` below it).
            let columnHeight = CGFloat(title) * 26 + CGFloat(body) * 16 + CGFloat(note) * 14
                + 4 * (SteamWizardMetrics.fieldRowHeight + DesignTokens.Spacing.md)
                + 2 * 14 + DesignTokens.Spacing.sm
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
