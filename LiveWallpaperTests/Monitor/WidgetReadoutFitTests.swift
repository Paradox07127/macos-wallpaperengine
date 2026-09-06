import AppKit
import CoreText
@testable import LiveWallpaper
import SwiftUI
import XCTest

/// Does a reserved slot actually hold the widest reading that can land in it?
///
/// `Text` with `lineLimit(1)` shrinks only down to its `minimumScaleFactor` and
/// then TRUNCATES, so "fits" here means "needs no more shrink than the floor
/// the view already declares". Every container width in this file was measured,
/// not assumed: the arc-gauge sides came from hosting a line-for-line replica of
/// the CPU widget bodies in an `NSHostingView` at the board's own tile sizes
/// (170×170 / 356×170 / 356×356 pt, `MonitorBoardMetrics`) — a replica because
/// the real body needs a live snapshot; the column widths are the literal
/// `.frame(width:)` expressions read off the views.
final class WidgetReadoutFitTests: XCTestCase {
    // MARK: - Text measurement

    /// SwiftUI's `.system(size:weight:design:.default)` is `NSFont.systemFont`,
    /// and `.monospacedDigit()` selects its tabular-figure variant. `Design`'s
    /// font helpers clamp the size, so the clamp is mirrored here too.
    private func font(_ size: CGFloat, monospacedDigit: Bool, floor: CGFloat = 10) -> NSFont {
        let clamped = max(size, floor)
        return monospacedDigit
            ? .monospacedDigitSystemFont(ofSize: clamped, weight: .semibold)
            : .systemFont(ofSize: clamped, weight: .semibold)
    }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// Rendered width of CPU's hero readout — digits at `heroSize`, "%" at
    /// `heroSize * heroUnitRatio`, `spacing: 0`.
    private func heroWidth(_ digits: String, heroSize: CGFloat) -> CGFloat {
        width(digits, font(heroSize, monospacedDigit: true))
            + width("%", font(heroSize * CPUWidgetView.heroUnitRatio, monospacedDigit: false))
    }

    // MARK: - Fixtures

    /// One CPU tile: the ring's centre box is `side * 0.62` (`ArcGauge`), and
    /// `side` is what the widget actually laid out — measured, since the ring is
    /// `aspectRatio(1, .fit)` and its own frame does not tell you.
    private struct GaugeCase {
        let name: String
        let cellHeight: CGFloat
        let heroFactor: CGFloat
        let measuredSide: CGFloat

        var base: CGFloat {
            Design.TypeScale(cellHeight: cellHeight).hero * heroFactor
        }

        var boxWidth: CGFloat {
            measuredSide * 0.62
        }
    }

    /// `cellHeight` is `tileHeight / 2` (S, M) or `tileHeight / 4` (L), the
    /// divisor `CPUWidgetView.body` applies. Board scale 1.0 is the desktop
    /// board's own tile; 1.6 is a scaled-up display, where the hero size hits
    /// its 46 pt ceiling while the ring stops growing at its 96 pt cap — the
    /// second-worst ratio after M at scale 1.0.
    private let gaugeCases: [GaugeCase] = [
        GaugeCase(name: "S @1.0 (sensor capsule shown)", cellHeight: 85, heroFactor: 0.9, measuredSide: 66.60),
        GaugeCase(name: WidgetReadoutFitTests.mediumTileName, cellHeight: 85, heroFactor: 1.05, measuredSide: 67.70),
        GaugeCase(name: "L @1.0", cellHeight: 89, heroFactor: 0.92, measuredSide: 85.15),
        GaugeCase(name: "S @1.6", cellHeight: 136, heroFactor: 0.9, measuredSide: 126.00),
        GaugeCase(name: "M @1.6", cellHeight: 136, heroFactor: 1.05, measuredSide: 96.00),
        GaugeCase(name: "L @1.6", cellHeight: 142.4, heroFactor: 0.92, measuredSide: 96.00),
    ]

    /// The tile the reported truncation came from.
    private static let mediumTileName = "M @1.0"

    /// The floor `CPUWidgetView.heroReadout` declares.
    private let heroScaleFloor: CGFloat = 0.6

    // MARK: - heroSize is a pure function of the digit count

    func testHeroSizeShrinksOnlyAtThreeDigits() {
        let base: CGFloat = 32.13
        XCTAssertEqual(CPUWidgetView.heroSize(base: base, digits: 1), base)
        XCTAssertEqual(CPUWidgetView.heroSize(base: base, digits: 2), base)
        XCTAssertEqual(CPUWidgetView.heroSize(base: base, digits: 3),
                       base * CPUWidgetView.threeDigitHeroShrink)
    }

    func testWholeNumberReachesThreeDigitsOnlyAtFullLoad() {
        XCTAssertEqual(CPUWidgetView.wholeNumber(0).count, 1)
        XCTAssertEqual(CPUWidgetView.wholeNumber(0.37).count, 2)
        XCTAssertEqual(CPUWidgetView.wholeNumber(0.994).count, 2)
        XCTAssertEqual(CPUWidgetView.wholeNumber(0.996).count, 3)
        XCTAssertEqual(CPUWidgetView.wholeNumber(1), "100")
        // Out-of-range samples clamp rather than widening past three digits.
        XCTAssertEqual(CPUWidgetView.wholeNumber(4.2), "100")
        XCTAssertEqual(CPUWidgetView.wholeNumber(.nan), "0")
    }

    // MARK: - 100% fits the ring's centre box

    func testFullLoadHeroFitsEveryGaugeCentre() {
        for tile in gaugeCases {
            let size = CPUWidgetView.heroSize(base: tile.base, digits: 3)
            let needed = tile.boxWidth / heroWidth("100", heroSize: size)
            XCTAssertGreaterThanOrEqual(
                needed, heroScaleFloor,
                """
                "100%" needs a \(needed) scale in \(tile.name) \
                (box \(tile.boxWidth) pt, text \(heroWidth("100", heroSize: size)) pt), \
                below the \(heroScaleFloor) minimumScaleFactor floor — it truncates.
                """
            )
        }
    }

    /// Control: the same reading at the UNSHRUNK size is what shipped before,
    /// and on the M tile it lands under the floor. Without this the test above
    /// could pass on a box that was never tight.
    func testFullLoadHeroWithoutTheDigitShrinkIsUnderTheFloor() throws {
        let medium = try XCTUnwrap(gaugeCases.first { $0.name == Self.mediumTileName })
        let unshrunk = CPUWidgetView.heroSize(base: medium.base, digits: 2)
        let needed = medium.boxWidth / heroWidth("100", heroSize: unshrunk)
        XCTAssertLessThan(needed, heroScaleFloor)
    }

    /// The shrink must not overshoot into an illegibly small reading: three
    /// digits stay at least half the two-digit size.
    func testDigitShrinkStaysWithinHalfTheBaseSize() {
        XCTAssertGreaterThan(CPUWidgetView.threeDigitHeroShrink, 0.5)
        XCTAssertLessThan(CPUWidgetView.threeDigitHeroShrink, 1.0)
    }

    // MARK: - Reserved columns in the "top process" rows

    /// `MemoryTopProcessRow`'s two right-hand columns are fixed-width slots. The
    /// widest real readings overflow them, so the row's scale floor is the only
    /// thing standing between them and a truncated number.
    func testMemoryTopProcessColumnsHoldTheirWidestRealReadings() throws {
        let caption: CGFloat = 11 // Design.TypeScale(cellHeight: 89).caption
        let slotFont = font(caption * 0.94, monospacedDigit: true)

        // Read from the widget, never retyped: a slot narrowed there has to move
        // this test, and the floor is only real if the row actually declares it.
        let source = try RepositoryRoot.source("LiveWallpaper/Monitor/Widgets/MemoryWidgetView.swift")
        let row = try XCTUnwrap(Self.topProcessRowBody(in: source),
                                "MemoryWidgetView no longer declares MemoryTopProcessRow")
        let floor = try XCTUnwrap(Self.scaleFloor(in: row),
                                  "MemoryTopProcessRow lost its minimumScaleFactor; nothing shrinks these columns")
        let slots = Self.captionSlotMultipliers(in: row)
        XCTAssertEqual(slots.count, 2, "expected the cpu% and GiB slots, found \(slots)")

        // A process saturating 16 cores; the widest string cpuColumnText emits.
        let cpuText = MemoryWidgetView.cpuColumnText(1600)
        XCTAssertEqual(cpuText, "1600%")
        let cpuSlot = caption * slots[0]
        XCTAssertGreaterThan(width(cpuText, slotFont), cpuSlot,
                             "control: if this column stopped overflowing, the floor below is untested")
        XCTAssertGreaterThanOrEqual(cpuSlot / width(cpuText, slotFont), floor)

        // 128 GiB resident on a 192 GB machine, formatted "%.1fG".
        let gibText = String(format: "%.1fG", Format.gib(128 * 1_073_741_824))
        XCTAssertEqual(gibText, "128.0G")
        let gibSlot = caption * slots[1]
        XCTAssertGreaterThan(width(gibText, slotFont), gibSlot,
                             "control: if this column stopped overflowing, the floor below is untested")
        XCTAssertGreaterThanOrEqual(gibSlot / width(gibText, slotFont), floor)
    }

    /// Brace-matched body of `MemoryTopProcessRow`.
    private static func topProcessRowBody(in source: String) -> String? {
        guard let start = source.range(of: "struct MemoryTopProcessRow") else { return nil }
        var depth = 0
        var index = start.lowerBound
        var seenOpen = false
        while index < source.endIndex {
            if source[index] == "{" {
                depth += 1
                seenOpen = true
            } else if source[index] == "}" {
                depth -= 1
                if seenOpen, depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The number inside the row's first `minimumScaleFactor(...)`.
    private static func scaleFloor(in body: String) -> CGFloat? {
        guard let match = body.range(of: #"minimumScaleFactor\([0-9.]+\)"#, options: .regularExpression)
        else { return nil }
        return trailingNumber(in: body[match])
    }

    /// Every `.frame(width: scale.caption * N` in the row, in source order.
    private static func captionSlotMultipliers(in body: String) -> [CGFloat] {
        var out: [CGFloat] = []
        var cursor = body.startIndex
        while let match = body.range(
            of: #"\.frame\(width: scale\.caption \* [0-9.]+"#,
            options: .regularExpression,
            range: cursor ..< body.endIndex
        ) {
            if let value = trailingNumber(in: body[match]) { out.append(value) }
            cursor = match.upperBound
        }
        return out
    }

    /// The last run of digits/dot in `text`, e.g. "2.9" from ".frame(width: scale.caption * 2.9".
    private static func trailingNumber(in text: Substring) -> CGFloat? {
        let digits = text.reversed().prefix { $0.isNumber || $0 == "." }.reversed()
        return Double(String(digits)).map(CGFloat.init)
    }

    /// The same shape in the two widgets that already had a floor, so a future
    /// edit that drops one of them is caught here rather than on a busy Mac.
    func testCPUAndProcessesTopRowColumnsHoldTheirWidestRealReadings() {
        let caption: CGFloat = 11
        let floor: CGFloat = 0.7

        // CPUWidgetView.procRows: cpu% in caption*2.1, mem in caption*3.4.
        let cpuText = CPUWidgetView.cpuText(1600)
        XCTAssertEqual(cpuText, "1600")
        XCTAssertGreaterThanOrEqual(
            caption * 2.1 / width(cpuText, font(caption, monospacedDigit: true)), floor
        )
        let memText = Format.bytes(128 * 1_073_741_824 as Double)
        XCTAssertEqual(memText, "128.0 GB")
        XCTAssertGreaterThanOrEqual(
            caption * 3.4 / width(memText, font(caption * 0.94, monospacedDigit: true, floor: 11)),
            floor
        )

        // ProcessesWidgetView: cpu% in caption*3.4, mem in caption*4.0.
        XCTAssertGreaterThanOrEqual(
            caption * 3.4 / width(ProcessesWidgetView.cpuText(1600),
                                  font(caption * 0.94, monospacedDigit: true, floor: 11)),
            floor
        )
        XCTAssertGreaterThanOrEqual(
            caption * 4.0 / width(memText, font(caption * 0.94, monospacedDigit: true, floor: 11)),
            floor
        )
    }

    // MARK: - The gauge column reports the ring, not its cap

    /// `ArcGauge` is `aspectRatio(1, .fit)`, so it draws `min(width, height)`.
    /// Under a `maxWidth` cap the frame still reports the CAP, which is how the
    /// M column reserved 96 pt for a ring that measured 67.7 pt. A `maxHeight`
    /// cap bounds the ring exactly as before while letting the frame report the
    /// ring's own width, handing the difference back to the trend curve.
    @MainActor
    func testHeightCappedGaugeReportsItsOwnWidthAndKeepsItsSize() {
        // The heights the M and L gauge rows actually offer, measured by hosting
        // the real widget bodies at the board's own 356×170 and 356×356 tiles.
        let mediumRow: CGFloat = 67.7
        let largeRow: CGFloat = 85.15
        let wide: CGFloat = 300 // the column is never the narrow axis here

        XCTAssertEqual(
            gaugeSize(proposing: CGSize(width: wide, height: mediumRow)) {
                $0.frame(maxWidth: 96, alignment: .leading)
            },
            CGSize(width: 96, height: mediumRow),
            "a maxWidth cap reports the cap, stranding 96 − 67.7 = 28.3 pt of column"
        )
        XCTAssertEqual(
            gaugeSize(proposing: CGSize(width: wide, height: mediumRow)) {
                $0.frame(maxHeight: 96)
            },
            CGSize(width: mediumRow, height: mediumRow),
            "same ring, and the column is now the ring's width"
        )
        XCTAssertEqual(
            gaugeSize(proposing: CGSize(width: wide, height: largeRow)) {
                $0.frame(width: 96, alignment: .leading)
            },
            CGSize(width: 96, height: largeRow),
            "L's fixed width stranded 96 − 85.15 = 10.85 pt"
        )
        XCTAssertEqual(
            gaugeSize(proposing: CGSize(width: wide, height: largeRow)) {
                $0.frame(maxHeight: 96)
            },
            CGSize(width: largeRow, height: largeRow)
        )
        // The cap still bites on a taller row: the ring must not grow past the
        // 96 pt the old width constants guaranteed.
        XCTAssertEqual(
            gaugeSize(proposing: CGSize(width: wide, height: 140)) { $0.frame(maxHeight: 96) },
            CGSize(width: 96, height: 96)
        )
    }

    /// Lays the real `ArcGauge` out under `cap` against `proposing` and returns
    /// the size it settled on. `ImageRenderer.proposedSize` is the constrained
    /// layout pass; nothing here needs a window or a run loop.
    @MainActor
    private func gaugeSize(
        proposing proposal: CGSize, cap: (ArcGauge<EmptyView>) -> some View
    ) -> CGSize {
        let renderer = ImageRenderer(content: cap(ArcGauge(value: 0.37) { EmptyView() }))
        renderer.proposedSize = ProposedViewSize(width: proposal.width, height: proposal.height)
        return renderer.nsImage?.size ?? .zero
    }
}
