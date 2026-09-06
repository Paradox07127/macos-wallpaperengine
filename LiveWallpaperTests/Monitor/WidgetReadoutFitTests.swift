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
        let slots = Self.trailingTextSlotMultipliers(in: row)
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
                    return String(source[start.lowerBound ... index])
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
            if let value = trailingNumber(in: body[match]) {
                out.append(value)
            }
            cursor = match.upperBound
        }
        return out
    }

    /// Only the slots that hold right-aligned text. `MemoryTopProcessRow` also
    /// sizes a status dot and an inline bar off `scale.caption`, so taking every
    /// match by position would read the dot's 0.5 as the cpu% column.
    private static func trailingTextSlotMultipliers(in body: String) -> [CGFloat] {
        var out: [CGFloat] = []
        var cursor = body.startIndex
        while let match = body.range(
            of: #"\.frame\(width: scale\.caption \* [0-9.]+, alignment: \.trailing\)"#,
            options: .regularExpression,
            range: cursor ..< body.endIndex
        ) {
            let head = body[match].prefix { $0 != "," }
            if let value = trailingNumber(in: head) {
                out.append(value)
            }
            cursor = match.upperBound
        }
        return out
    }

    /// The last run of digits/dot in `text`, e.g. "2.9" from ".frame(width:
    /// scale.caption * 2.9" and "0.7" from "minimumScaleFactor(0.7)". The
    /// leading `drop` is what makes the second one work: without it a match that
    /// ends in `)` scanned no digits at all and returned nil, which silently
    /// turned `scaleFloor` into "this row has no floor" on every caller.
    private static func trailingNumber(in text: Substring) -> CGFloat? {
        var digits = ""
        var seenDigit = false
        for character in text.reversed() {
            if character.isNumber || (character == "." && seenDigit) {
                seenDigit = seenDigit || character.isNumber
                digits.insert(character, at: digits.startIndex)
            } else if seenDigit {
                break
            }
        }
        return Double(digits).map { CGFloat($0) }
    }

    /// Brace-matched body of whatever declaration starts with `declaration`.
    private static func declarationBody(_ declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
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
                    return String(source[start.lowerBound ... index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The multiplier in `let <name> = base * N`, the shape `processTable` uses.
    private static func baseMultiplier(_ name: String, in body: String) -> CGFloat? {
        guard let match = body.range(of: #"let \#(name) = base \* [0-9.]+"#,
                                     options: .regularExpression)
        else { return nil }
        return trailingNumber(in: body[match])
    }

    /// The same shape in the two widgets that already had a floor. Both sets of
    /// slots and both floors are read out of the widgets for the same reason as
    /// `MemoryTopProcessRow` above — narrowing a slot there has to move this
    /// test, and a floor is only real if the row still declares it.
    func testCPUAndProcessesTopRowColumnsHoldTheirWidestRealReadings() throws {
        let caption: CGFloat = 11 // Design.TypeScale(cellHeight: 89).caption
        let memText = Format.bytes(128 * 1_073_741_824 as Double)
        XCTAssertEqual(memText, "128.0 GB")
        let memFont = font(caption * 0.94, monospacedDigit: true, floor: 11)

        // CPUWidgetView.procRows: the inline bar, then the cpu% and mem slots.
        let cpuSource = try RepositoryRoot.source("LiveWallpaper/Monitor/Widgets/CPUWidgetView.swift")
        let procRows = try XCTUnwrap(Self.declarationBody("private func procRows(", in: cpuSource),
                                     "CPUWidgetView no longer declares procRows")
        let cpuFloor = try XCTUnwrap(Self.scaleFloor(in: procRows),
                                     "procRows lost its minimumScaleFactor; nothing shrinks these columns")
        let cpuSlots = Self.captionSlotMultipliers(in: procRows)
        XCTAssertEqual(cpuSlots.count, 3, "expected the bar, cpu% and mem slots, found \(cpuSlots)")

        let cpuText = CPUWidgetView.cpuText(1600)
        XCTAssertEqual(cpuText, "1600")
        let cpuWidth = width(cpuText, font(caption, monospacedDigit: true))
        XCTAssertGreaterThan(cpuWidth, caption * cpuSlots[1],
                             "control: if this column stopped overflowing, the floor below is untested")
        XCTAssertGreaterThanOrEqual(caption * cpuSlots[1] / cpuWidth, cpuFloor)

        XCTAssertGreaterThan(width(memText, memFont), caption * cpuSlots[2],
                             "control: if this column stopped overflowing, the floor below is untested")
        XCTAssertGreaterThanOrEqual(caption * cpuSlots[2] / width(memText, memFont), cpuFloor)

        // ProcessesWidgetView.processTable sizes its columns off `base`, and the
        // two floors live one level down in the cells that draw them.
        let procSource = try RepositoryRoot.source("LiveWallpaper/Monitor/Widgets/ProcessesWidgetView.swift")
        let table = try XCTUnwrap(Self.declarationBody("private func processTable(", in: procSource),
                                  "ProcessesWidgetView no longer declares processTable")
        let valueSlot = try XCTUnwrap(Self.baseMultiplier("cpuValueWidth", in: table),
                                      "processTable no longer sizes cpuValueWidth off base")
        let memSlot = try XCTUnwrap(Self.baseMultiplier("memColWidth", in: table),
                                    "processTable no longer sizes memColWidth off base")
        let cpuCellFloor = try XCTUnwrap(
            Self.declarationBody("private func cpuCell(", in: procSource).flatMap { Self.scaleFloor(in: $0) },
            "ProcessesWidgetView.cpuCell lost its minimumScaleFactor"
        )
        let rowFloor = try XCTUnwrap(
            Self.declarationBody("private func processRow(", in: procSource).flatMap { Self.scaleFloor(in: $0) },
            "ProcessesWidgetView.processRow lost its minimumScaleFactor"
        )

        // This one is wide enough to need no shrink at all, so it is pinned at
        // the stronger claim; the floor stays asserted in case that stops holding.
        let procCPUText = ProcessesWidgetView.cpuText(1600)
        XCTAssertEqual(procCPUText, "1600")
        let procCPUWidth = width(procCPUText, memFont)
        XCTAssertGreaterThanOrEqual(caption * valueSlot / procCPUWidth, 1)
        XCTAssertGreaterThanOrEqual(caption * valueSlot / procCPUWidth, cpuCellFloor)

        XCTAssertGreaterThan(width(memText, memFont), caption * memSlot,
                             "control: if this column stopped overflowing, the floor below is untested")
        XCTAssertGreaterThanOrEqual(caption * memSlot / width(memText, memFont), rowFloor)
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

    // MARK: - The gauge column is a declared width, not a measured one

    /// Every ring height the M and L rows offer, measured by hosting replicas of
    /// the two bodies (`WidgetContainer` chrome, identity row, composition
    /// legend / bar, core strip, process rows) at the board's own tile sizes over
    /// board scales 0.7 … 2.0. `cellHeight` is `tileHeight / 2` (M) or `/ 4` (L);
    /// `offeredHeight` is what the row leaves the ring before any cap, which is
    /// the whole problem: it is not proportional to the tile (the container's
    /// 11 pt inset and the 10…12 pt label clamp are fixed costs), so a column
    /// that reported it could not be predicted from anything.
    private struct GaugeRow {
        let name: String
        let cellHeight: CGFloat
        let rows: Int
        let identity: Bool
        let legend: Bool
        let offeredHeight: CGFloat
    }

    /// The six board scales, in each configuration that changes what is stacked
    /// above or below the M ring; L's chrome also moves with its core strip and
    /// process list, which is why it does not get a bound of its own.
    private let gaugeRows: [GaugeRow] = [
        GaugeRow(name: "M @0.7", cellHeight: 59.50, rows: 1, identity: true, legend: true, offeredHeight: 20.70),
        GaugeRow(name: "M @0.85", cellHeight: 72.25, rows: 1, identity: true, legend: true, offeredHeight: 45.20),
        GaugeRow(name: "M @1.0", cellHeight: 85.00, rows: 1, identity: true, legend: true, offeredHeight: 67.70),
        GaugeRow(name: "M @1.25", cellHeight: 106.25, rows: 1, identity: true, legend: true, offeredHeight: 104.81),
        GaugeRow(name: "M @1.6", cellHeight: 136.00, rows: 1, identity: true, legend: true, offeredHeight: 153.24),
        GaugeRow(name: "M @2.0", cellHeight: 170.00, rows: 1, identity: true, legend: true, offeredHeight: 221.24),

        GaugeRow(name: "M @0.7 no legend", cellHeight: 59.50, rows: 1, identity: true, legend: false, offeredHeight: 59.00),
        GaugeRow(name: "M @0.85 no legend", cellHeight: 72.25, rows: 1, identity: true, legend: false, offeredHeight: 83.50),
        GaugeRow(name: "M @1.0 no legend", cellHeight: 85.00, rows: 1, identity: true, legend: false, offeredHeight: 106.00),
        GaugeRow(name: "M @1.25 no legend", cellHeight: 106.25, rows: 1, identity: true, legend: false, offeredHeight: 143.88),
        GaugeRow(name: "M @1.6 no legend", cellHeight: 136.00, rows: 1, identity: true, legend: false, offeredHeight: 196.00),
        GaugeRow(name: "M @2.0 no legend", cellHeight: 170.00, rows: 1, identity: true, legend: false, offeredHeight: 264.00),

        GaugeRow(name: "M @0.7 no identity", cellHeight: 59.50, rows: 1, identity: false, legend: true, offeredHeight: 39.70),
        GaugeRow(name: "M @0.85 no identity", cellHeight: 72.25, rows: 1, identity: false, legend: true, offeredHeight: 65.20),
        GaugeRow(name: "M @1.0 no identity", cellHeight: 85.00, rows: 1, identity: false, legend: true, offeredHeight: 90.70),
        GaugeRow(name: "M @1.25 no identity", cellHeight: 106.25, rows: 1, identity: false, legend: true, offeredHeight: 132.12),
        GaugeRow(name: "M @1.6 no identity", cellHeight: 136.00, rows: 1, identity: false, legend: true, offeredHeight: 185.24),
        GaugeRow(name: "M @2.0 no identity", cellHeight: 170.00, rows: 1, identity: false, legend: true, offeredHeight: 253.24),

        GaugeRow(name: "M @0.7 bare", cellHeight: 59.50, rows: 1, identity: false, legend: false, offeredHeight: 78.00),
        GaugeRow(name: "M @0.85 bare", cellHeight: 72.25, rows: 1, identity: false, legend: false, offeredHeight: 103.50),
        GaugeRow(name: "M @1.0 bare", cellHeight: 85.00, rows: 1, identity: false, legend: false, offeredHeight: 129.00),
        GaugeRow(name: "M @1.25 bare", cellHeight: 106.25, rows: 1, identity: false, legend: false, offeredHeight: 171.19),
        GaugeRow(name: "M @1.6 bare", cellHeight: 136.00, rows: 1, identity: false, legend: false, offeredHeight: 228.00),
        GaugeRow(name: "M @2.0 bare", cellHeight: 170.00, rows: 1, identity: false, legend: false, offeredHeight: 296.00),

        GaugeRow(name: "L @0.7", cellHeight: 62.30, rows: 2, identity: true, legend: true, offeredHeight: 39.22),
        GaugeRow(name: "L @0.85", cellHeight: 75.65, rows: 2, identity: true, legend: true, offeredHeight: 59.95),
        GaugeRow(name: "L @1.0", cellHeight: 89.00, rows: 2, identity: true, legend: true, offeredHeight: 85.15),
        GaugeRow(name: "L @1.25", cellHeight: 111.25, rows: 2, identity: true, legend: true, offeredHeight: 121.08),
        GaugeRow(name: "L @1.6", cellHeight: 142.40, rows: 2, identity: true, legend: true, offeredHeight: 176.80),
        GaugeRow(name: "L @2.0", cellHeight: 178.00, rows: 2, identity: true, legend: true, offeredHeight: 248.00),
        // L with its core strip and process list gone — the row that makes the
        // cap the only bound L can take.
        GaugeRow(name: "L @0.7 bare", cellHeight: 62.30, rows: 2, identity: false, legend: false, offeredHeight: 101.10),
    ]

    private func gaugeSide(_ row: GaugeRow) -> CGFloat {
        CPUWidgetView.gaugeSide(
            cellHeight: row.cellHeight, rows: row.rows,
            hasIdentityRow: row.identity, hasCompositionLegend: row.legend
        )
    }

    /// The column may only ever be wider than the ring it holds. If it is ever
    /// narrower the ring becomes width-limited and shrinks below what shipped.
    func testGaugeSideNeverNarrowsTheRingItReserves() {
        for row in gaugeRows {
            let ring = min(CPUWidgetView.gaugeSideCap, row.offeredHeight)
            XCTAssertGreaterThanOrEqual(
                gaugeSide(row), ring,
                "\(row.name): the column reserves \(gaugeSide(row)) pt for a \(ring) pt ring, which clips it"
            )
        }
        // Control: the assertion above only bites on rows where the cap is NOT
        // what sizes the ring, and there have to be some.
        let tight = gaugeRows.filter { $0.offeredHeight < CPUWidgetView.gaugeSideCap }
        XCTAssertGreaterThanOrEqual(tight.count, 10,
                                    "every measured row is cap-limited; nothing above is tested")
    }

    /// What the column strands, tile by tile. The `maxWidth: 96` this replaced
    /// stranded 28.30 pt on the desktop board's own M tile.
    func testGaugeSideStrandsFarLessThanTheOldFixedWidth() throws {
        let medium = try XCTUnwrap(gaugeRows.first { $0.name == "M @1.0" })
        XCTAssertEqual(CPUWidgetView.gaugeSideCap - medium.offeredHeight, 28.30, accuracy: 0.01)
        XCTAssertLessThanOrEqual(gaugeSide(medium) - medium.offeredHeight, 13)
        // The ring is untouched, so a narrower column is exactly what it hands
        // back to the trend curve. Most M rows land under the old fixed width;
        // the rest are rows where the ring itself reaches the cap.
        let narrowed = gaugeRows.filter { $0.rows == 1 && gaugeSide($0) < CPUWidgetView.gaugeSideCap }
        XCTAssertGreaterThanOrEqual(
            narrowed.count, 8,
            "only \(narrowed.count) of the M rows got a narrower column than the 96 pt it replaced"
        )
    }

    /// L takes the cap flat because its ring reaches it: with the core strip and
    /// the process list gone the row offered 101.10 pt at board scale 0.7, above
    /// the cap at the smallest tile there is.
    func testLargeGaugeSideIsTheCapAtEveryInput() {
        for row in gaugeRows where row.rows == 2 {
            for identity in [true, false] {
                for legend in [true, false] {
                    XCTAssertEqual(
                        CPUWidgetView.gaugeSide(cellHeight: row.cellHeight, rows: 2,
                                                hasIdentityRow: identity, hasCompositionLegend: legend),
                        CPUWidgetView.gaugeSideCap
                    )
                }
            }
        }
    }

    /// The composition legend — not the ring — is what the M column reports
    /// below board scale 1.25, and its own width swings with the reading
    /// ("USER 5%" … "USER 100%"). Widths measured headless at its widest.
    func testGaugeSideReservesTheWidestCompositionLegend() {
        let measured: [(cellHeight: CGFloat, label: CGFloat, legend: CGFloat)] = [
            (59.50, 10, 80.00), (72.25, 10, 80.00), (85.00, 10, 80.00),
            (106.25, 10.625, 81.72), (136.00, 12, 91.90), (170.00, 12, 91.90),
        ]
        for tile in measured {
            XCTAssertEqual(Design.TypeScale(cellHeight: tile.cellHeight).label, tile.label, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(
                CPUWidgetView.gaugeSide(cellHeight: tile.cellHeight, rows: 1,
                                        hasIdentityRow: true, hasCompositionLegend: true),
                tile.legend,
                "the legend truncates at cellHeight \(tile.cellHeight)"
            )
        }
        // Control: on the desktop board's own M tile the ring term alone is
        // under the legend, so the legend floor is what pins the column there.
        let ringTerm = 85 * 2 - CPUWidgetView.gaugeChromeBase
            - CPUWidgetView.gaugeChromeIdentityRow - CPUWidgetView.gaugeChromeCompositionLegend
        XCTAssertEqual(ringTerm, 71.70, accuracy: 0.01)
        XCTAssertLessThan(ringTerm, 80.00)
    }

    /// The whole point: the column reports the declared width whatever height
    /// the row happens to offer. The height still comes from the row, which is
    /// why the ring is unchanged — `gaugeSide` only ever bounds the width.
    @MainActor
    func testPinnedGaugeColumnReportsGaugeSideAtEveryOfferedHeight() {
        let side = CPUWidgetView.gaugeSide(cellHeight: 85, rows: 1,
                                           hasIdentityRow: true, hasCompositionLegend: true)
        for offered: CGFloat in [20.70, 45.20, 67.70, 96, 140, 300] {
            let size = gaugeSize(proposing: CGSize(width: 300, height: offered)) {
                $0.frame(maxHeight: CPUWidgetView.gaugeSideCap)
                    .frame(width: side, alignment: .leading)
            }
            XCTAssertEqual(size.width, side, accuracy: 0.01,
                           "column moved to \(size.width) pt when the row offered \(offered) pt")
            XCTAssertEqual(size.height, min(CPUWidgetView.gaugeSideCap, offered), accuracy: 0.01)
        }
    }

    /// The pinned column must not make the gauge frame taller than the row it
    /// sits in, or the M tile overflows. It cannot: `gaugeSide` only stays under
    /// the cap while the row's own offer is under it too, so the height the cap
    /// lets through is always the row's.
    func testMediumGaugeSideIsNeverUnderWhatItsRowOffers() {
        for row in gaugeRows where row.rows == 1 {
            XCTAssertGreaterThanOrEqual(
                gaugeSide(row), min(CPUWidgetView.gaugeSideCap, row.offeredHeight),
                "\(row.name): a \(gaugeSide(row)) pt column under a \(row.offeredHeight) pt row"
            )
        }
    }

    /// Both bodies have to actually apply it; without this the function above
    /// could be perfect and unused.
    func testMediumAndLargeBodiesPinTheirGaugeColumn() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Monitor/Widgets/CPUWidgetView.swift")
        for declaration in ["private func mediumBody(", "private func largeBody("] {
            let body = try XCTUnwrap(Self.declarationBody(declaration, in: source),
                                     "CPUWidgetView no longer declares \(declaration)")
            XCTAssertTrue(
                body.contains("width: Self.gaugeSide("),
                "\(declaration) no longer pins its gauge column, so the row moves with the ring again"
            )
        }
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
