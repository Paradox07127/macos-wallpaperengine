import AppKit
import CoreText
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import XCTest

/// "Fits" here means "needs no more shrink than the floor the view declares":
/// `Text` with `lineLimit(1)` shrinks only to `minimumScaleFactor`, then TRUNCATES.
final class WidgetReadoutFitTests: XCTestCase {
    // MARK: - Text measurement

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

    /// `HeroPercent` lays out with `spacing: 0`, so its width is the plain sum.
    private func heroWidth(_ digits: String, heroSize: CGFloat) -> CGFloat {
        width(digits, font(heroSize, monospacedDigit: true))
            + width("%", font(heroSize * Design.heroUnitRatio, monospacedDigit: false))
    }

    // MARK: - Fixtures

    /// The ring's centre box is `side * 0.62` (`ArcGauge`); `measuredSide` is what the
    /// widget laid out. No GPU rows: its `.frame(width:)` literals are only an upper
    /// bound on the drawn ring, so a fixture built on them would pass while it truncated.
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

    /// `cellHeight` is `tileHeight / 2` (S, M) or `tileHeight / 4` (L), the divisor
    /// `CPUWidgetView.body` applies; @1.0 is the desktop board, @1.6 a scaled-up display.
    private let gaugeCases: [GaugeCase] = [
        GaugeCase(name: "S @1.0 (sensor capsule shown)", cellHeight: 85, heroFactor: 0.9, measuredSide: 66.60),
        GaugeCase(name: WidgetReadoutFitTests.mediumTileName, cellHeight: 85, heroFactor: 1.05, measuredSide: 67.70),
        GaugeCase(name: "L @1.0", cellHeight: 89, heroFactor: 0.92, measuredSide: 85.15),
        GaugeCase(name: "S @1.6", cellHeight: 136, heroFactor: 0.9, measuredSide: 126.00),
        GaugeCase(name: "M @1.6", cellHeight: 136, heroFactor: 1.05, measuredSide: 96.00),
        GaugeCase(name: "L @1.6", cellHeight: 142.4, heroFactor: 0.92, measuredSide: 96.00),
    ]

    private static let mediumTileName = "M @1.0"

    /// The floor `HeroPercent` declares.
    private let heroScaleFloor: CGFloat = 0.6

    // MARK: - heroSize is a pure function of the digit count

    func testHeroSizeShrinksOnlyAtThreeDigits() {
        let base: CGFloat = 32.13
        XCTAssertEqual(Design.heroSize(base: base, digits: 1), base)
        XCTAssertEqual(Design.heroSize(base: base, digits: 2), base)
        XCTAssertEqual(Design.heroSize(base: base, digits: 3),
                       base * Design.threeDigitHeroShrink)
    }

    func testWholeNumberReachesThreeDigitsOnlyAtFullLoad() {
        XCTAssertEqual(Format.wholeNumber(0).count, 1)
        XCTAssertEqual(Format.wholeNumber(0.37).count, 2)
        XCTAssertEqual(Format.wholeNumber(0.994).count, 2)
        XCTAssertEqual(Format.wholeNumber(0.996).count, 3)
        XCTAssertEqual(Format.wholeNumber(1), "100")
        XCTAssertEqual(Format.wholeNumber(4.2), "100")
        XCTAssertEqual(Format.wholeNumber(.nan), "0")
    }

    // MARK: - 100% fits the ring's centre box

    func testFullLoadHeroFitsEveryGaugeCentre() {
        for tile in gaugeCases {
            let size = Design.heroSize(base: tile.base, digits: 3)
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

    /// Control: without this, the test above could pass on a box that was never tight —
    /// the same reading at the UNSHRUNK size lands under the floor on the M tile.
    func testFullLoadHeroWithoutTheDigitShrinkIsUnderTheFloor() throws {
        let medium = try XCTUnwrap(gaugeCases.first { $0.name == Self.mediumTileName })
        let unshrunk = Design.heroSize(base: medium.base, digits: 2)
        let needed = medium.boxWidth / heroWidth("100", heroSize: unshrunk)
        XCTAssertLessThan(needed, heroScaleFloor)
    }

    // MARK: - Every gauge centre draws the shared readout

    func testDigitShrinkStaysWithinHalfTheBaseSize() {
        XCTAssertGreaterThan(Design.threeDigitHeroShrink, 0.5)
        XCTAssertLessThan(Design.threeDigitHeroShrink, 1.0)
    }

    // MARK: - Reserved columns in the "top process" rows

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

    private static func scaleFloor(in body: String) -> CGFloat? {
        guard let match = body.range(of: #"minimumScaleFactor\([0-9.]+\)"#, options: .regularExpression)
        else { return nil }
        return trailingNumber(in: body[match])
    }

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

    /// Only right-aligned slots: the row also sizes a status dot and an inline bar off
    /// `scale.caption`, so taking every match by position would read the dot's 0.5 as cpu%.
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

    /// Skipping the trailing non-digits is load-bearing: a match ending in ")" would scan
    /// no digits and return nil, silently turning `scaleFloor` into "this row has no floor".
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

    private static func baseMultiplier(_ name: String, in body: String) -> CGFloat? {
        guard let match = body.range(of: #"let \#(name) = base \* [0-9.]+"#,
                                     options: .regularExpression)
        else { return nil }
        return trailingNumber(in: body[match])
    }

    func testCPUAndProcessesTopRowColumnsHoldTheirWidestRealReadings() throws {
        let caption: CGFloat = 11 // Design.TypeScale(cellHeight: 89).caption
        let memText = Format.bytes(128 * 1_073_741_824 as Double)
        XCTAssertEqual(memText, "128.0 GB")
        let memFont = font(caption * 0.94, monospacedDigit: true, floor: 11)

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

    /// `ArcGauge` is `aspectRatio(1, .fit)`: under a `maxWidth` cap the frame still reports
    /// the CAP, while under a `maxHeight` cap it reports the ring's own width.
    @MainActor
    func testHeightCappedGaugeReportsItsOwnWidthAndKeepsItsSize() {
        // The heights the M and L gauge rows offer at the board's 356×170 and 356×356 tiles.
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
        XCTAssertEqual(
            gaugeSize(proposing: CGSize(width: wide, height: 140)) { $0.frame(maxHeight: 96) },
            CGSize(width: 96, height: 96)
        )
    }

    // MARK: - The gauge column is a declared width, not a measured one

    /// `cellHeight` is `tileHeight / 2` (M) or `/ 4` (L), over board scales 0.7 … 2.0.
    /// `largeOfferedHeight` is what the L row leaves its ring; M rows measure theirs (`offeredHeight(_:)`).
    private struct GaugeRow {
        let name: String
        let cellHeight: CGFloat
        let rows: Int
        let identity: Bool
        let legend: Bool
        var largeOfferedHeight: CGFloat = 0
    }

    private static let mediumBoards: [(scale: String, cellHeight: CGFloat)] = [
        ("0.7", 59.50), ("0.85", 72.25), ("1.0", 85.00), ("1.25", 106.25), ("1.6", 136.00), ("2.0", 170.00),
    ]

    private let gaugeRows: [GaugeRow] = WidgetReadoutFitTests.mediumBoards.flatMap { board in
        [(true, true, ""), (true, false, " no legend"), (false, true, " no identity"), (false, false, " bare")]
            .map { identity, legend, suffix in
                GaugeRow(name: "M @\(board.scale)\(suffix)", cellHeight: board.cellHeight, rows: 1,
                         identity: identity, legend: legend)
            }
    } + [
        GaugeRow(name: "L @0.7", cellHeight: 62.30, rows: 2, identity: true, legend: true, largeOfferedHeight: 39.22),
        GaugeRow(name: "L @0.85", cellHeight: 75.65, rows: 2, identity: true, legend: true, largeOfferedHeight: 59.95),
        GaugeRow(name: "L @1.0", cellHeight: 89.00, rows: 2, identity: true, legend: true, largeOfferedHeight: 85.15),
        GaugeRow(name: "L @1.25", cellHeight: 111.25, rows: 2, identity: true, legend: true, largeOfferedHeight: 121.08),
        GaugeRow(name: "L @1.6", cellHeight: 142.40, rows: 2, identity: true, legend: true, largeOfferedHeight: 176.80),
        GaugeRow(name: "L @2.0", cellHeight: 178.00, rows: 2, identity: true, legend: true, largeOfferedHeight: 248.00),
        // The row that makes the cap the only bound L can take.
        GaugeRow(name: "L @0.7 bare", cellHeight: 62.30, rows: 2, identity: false, legend: false, largeOfferedHeight: 101.10),
    ]

    private func gaugeSide(_ row: GaugeRow) -> CGFloat {
        CPUWidgetView.gaugeSide(
            cellHeight: row.cellHeight, rows: row.rows,
            hasIdentityRow: row.identity, hasCompositionLegend: row.legend
        )
    }

    /// A column narrower than its ring would make the ring width-limited and shrink it.
    @MainActor
    func testGaugeSideNeverNarrowsTheRingItReserves() {
        for row in gaugeRows {
            let ring = min(CPUWidgetView.gaugeSideCap, offeredHeight(row))
            XCTAssertGreaterThanOrEqual(
                gaugeSide(row), ring,
                "\(row.name): the column reserves \(gaugeSide(row)) pt for a \(ring) pt ring, which clips it"
            )
        }
        let tight = gaugeRows.filter { offeredHeight($0) < CPUWidgetView.gaugeSideCap }
        XCTAssertGreaterThanOrEqual(tight.count, 10,
                                    "every measured row is cap-limited; nothing above is tested")
    }

    @MainActor
    func testGaugeSideStrandsFarLessThanTheOldFixedWidth() throws {
        let medium = try XCTUnwrap(gaugeRows.first { $0.name == "M @1.0" })
        let offered = offeredHeight(medium)
        let stranded = gaugeSide(medium) - offered
        XCTAssertLessThanOrEqual(stranded, 13)
        XCTAssertLessThan(stranded, CPUWidgetView.gaugeSideCap - offered)
        // Not all of them: the rest are rows where the ring itself reaches the cap.
        let narrowed = gaugeRows.filter { $0.rows == 1 && gaugeSide($0) < CPUWidgetView.gaugeSideCap }
        XCTAssertGreaterThanOrEqual(
            narrowed.count, 8,
            "only \(narrowed.count) of the M rows got a narrower column than the 96 pt it replaced"
        )
    }

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

    /// The legend chip's width at its widest reading, measured from the text the view draws.
    @MainActor
    private func widestCompositionLegend(label: CGFloat, environment: EnvironmentValues = EnvironmentValues()) -> CGFloat {
        // Swatch, its spacing, and the chip's horizontal padding (`legendValue`, `monitorChip`).
        let chrome = label * (0.6 + 0.35 + 2 * 0.5)
        let keys: [String.LocalizationValue] = ["USER", "SYS"]
        return keys.map { key -> CGFloat in
            let text = CPUWidgetView.compositionLegendText(key, percent: 100)._resolveText(in: environment)
            // Rounded up to whole points, the coarsest pixel grid a board is drawn on.
            return width(text, font(label * 0.95, monospacedDigit: true)).rounded(.up) + chrome
        }.max() ?? 0
    }

    /// Below board scale 1.25 the M column reports the composition legend, not the ring.
    @MainActor
    func testGaugeSideReservesTheWidestCompositionLegend() {
        for cellHeight: CGFloat in [59.50, 72.25, 85.00, 106.25, 136.00, 170.00] {
            let legend = widestCompositionLegend(label: Design.TypeScale(cellHeight: cellHeight).label)
            XCTAssertGreaterThanOrEqual(
                CPUWidgetView.gaugeSide(cellHeight: cellHeight, rows: 1,
                                        hasIdentityRow: true, hasCompositionLegend: true),
                legend,
                "the legend truncates at cellHeight \(cellHeight)"
            )
        }
        // Control: on the desktop board's own M tile the ring term alone is
        // under the legend, so the legend floor is what pins the column there.
        let desktop = GaugeRow(name: "M @1.0", cellHeight: 85, rows: 1, identity: true, legend: true)
        let ringTerm = offeredHeight(desktop)
        XCTAssertLessThan(ringTerm, widestCompositionLegend(label: Design.TypeScale(cellHeight: 85).label))
    }

    /// The M legend chip is `lineLimit(1)` with no scale floor, so a translation wider than
    /// the column `gaugeSide` reserves truncates instead of shrinking.
    @MainActor
    func testCompositionLegendFitsItsColumnInEveryLanguage() {
        var environment = EnvironmentValues()
        for cellHeight: CGFloat in [85, 106.25, 136] {
            let label = Design.TypeScale(cellHeight: cellHeight).label
            for language in AppLanguagePreference.allCases where language != .system {
                environment.locale = language.locale
                let (column, needed) = AppLanguageOverride.with(language) {
                    (CPUWidgetView.gaugeSide(cellHeight: cellHeight, rows: 1,
                                             hasIdentityRow: true, hasCompositionLegend: true),
                     widestCompositionLegend(label: label, environment: environment))
                }
                XCTAssertLessThanOrEqual(
                    needed, column + 0.01,
                    "\(language.rawValue) legend needs \(needed) pt; the M column at cellHeight \(cellHeight) reserves \(column) pt"
                )
            }
        }
    }

    @MainActor
    func testPinnedGaugeColumnReportsGaugeSideAtEveryOfferedHeight() {
        let side = CPUWidgetView.gaugeSide(cellHeight: 85, rows: 1,
                                           hasIdentityRow: true, hasCompositionLegend: true)
        let measured = gaugeRows.filter { $0.rows == 1 && $0.identity && $0.legend }.prefix(3).map(offeredHeight)
        for offered in measured + [96, 140, 300] {
            let size = gaugeSize(proposing: CGSize(width: 300, height: offered)) {
                $0.frame(maxHeight: CPUWidgetView.gaugeSideCap)
                    .frame(width: side, alignment: .leading)
            }
            XCTAssertEqual(size.width, side, accuracy: 0.01,
                           "column moved to \(size.width) pt when the row offered \(offered) pt")
            XCTAssertEqual(size.height, min(CPUWidgetView.gaugeSideCap, offered), accuracy: 0.01)
        }
    }

    /// The pinned column must not make the gauge frame taller than its row, or the M tile
    /// overflows.
    @MainActor
    func testMediumGaugeSideIsNeverUnderWhatItsRowOffers() {
        for row in gaugeRows where row.rows == 1 {
            let offered = offeredHeight(row)
            XCTAssertGreaterThanOrEqual(
                gaugeSide(row), min(CPUWidgetView.gaugeSideCap, offered),
                "\(row.name): a \(gaugeSide(row)) pt column under a \(offered) pt row"
            )
        }
    }

    // MARK: - M chrome, measured off SwiftUI layout

    @MainActor
    private func idealHeight(_ view: some View, width: CGFloat = 400) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.nsImage?.size.height ?? 0
    }

    /// The real `WidgetContainer` around a fixed-height body: its inset, header, and the spacing under it.
    @MainActor
    private func measuredBaseChrome(cellHeight: CGFloat) -> CGFloat {
        let body: CGFloat = 50
        let container = WidgetContainer(
            label: WidgetFactory.displayName(.cpu), systemImage: WidgetFactory.icon(.cpu),
            cellHeight: cellHeight, status: { LoadStateDot(fraction: 0.37) },
            content: { Color.clear.frame(height: body) }
        )
        return idealHeight(container) - body
    }

    /// The identity row and legend chip are private to `CPUWidgetView`; these rebuild them from its fonts and spacings.
    @MainActor
    private func measuredMediumChrome(_ row: GaugeRow) -> CGFloat {
        let scale = Design.TypeScale(cellHeight: row.cellHeight)
        var chrome = measuredBaseChrome(cellHeight: row.cellHeight)
        if row.identity {
            chrome += idealHeight(HStack(alignment: .firstTextBaseline, spacing: scale.label * 0.5) {
                Text(verbatim: "Apple M5 Pro").font(Design.subFont(size: scale.sub * 0.92))
                Text(verbatim: "· 18 cores (6 Super + 12 Performance)").font(Design.labelFont(size: scale.label))
            }) + scale.label * 0.5
        }
        if row.legend {
            let chip = VStack(alignment: .leading, spacing: scale.label * 0.3) {
                ForEach(["USER 100%", "SYS 100%"], id: \.self) { text in
                    HStack(spacing: scale.label * 0.35) {
                        Rectangle().frame(width: scale.label * 0.6, height: scale.label * 0.6)
                        Text(verbatim: text).font(Design.labelFont(size: scale.label * 0.95)).monospacedDigit()
                    }
                }
            }
            .lineLimit(1)
            .monitorChip(scale)
            chrome += idealHeight(chip) + scale.label * 0.45
        }
        return chrome
    }

    /// What the row leaves the ring before any cap: M from the measured chrome, L from its laid-out tile.
    @MainActor
    private func offeredHeight(_ row: GaugeRow) -> CGFloat {
        row.rows == 1 ? row.cellHeight * 2 - measuredMediumChrome(row) : row.largeOfferedHeight
    }

    /// Below the cap and above the legend floor, an M column wider than the ring its row offers strands that width.
    @MainActor
    func testMediumGaugeSideLeavesRoomForTheMeasuredChrome() {
        for row in gaugeRows where row.rows == 1 {
            let legend = row.legend
                ? widestCompositionLegend(label: Design.TypeScale(cellHeight: row.cellHeight).label)
                : 0
            let offered = offeredHeight(row)
            let side = gaugeSide(row)
            XCTAssertLessThanOrEqual(
                side, max(legend, min(CPUWidgetView.gaugeSideCap, offered)) + 0.01,
                "\(row.name): a \(side) pt column over a \(offered) pt ring under a \(legend) pt legend"
            )
        }
    }

    /// `ImageRenderer.proposedSize` is the constrained layout pass: no window, no run loop.
    @MainActor
    private func gaugeSize(
        proposing proposal: CGSize, cap: (ArcGauge<EmptyView>) -> some View
    ) -> CGSize {
        let renderer = ImageRenderer(content: cap(ArcGauge(value: 0.37) { EmptyView() }))
        renderer.proposedSize = ProposedViewSize(width: proposal.width, height: proposal.height)
        return renderer.nsImage?.size ?? .zero
    }
}
