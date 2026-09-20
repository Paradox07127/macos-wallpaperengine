@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Library grid metrics")
struct LibraryGridMetricsTests {
    private static let steps: [LibraryTileSize] = [.small, .medium, .large]
    private static var aspects: [DesignTokens.LibraryGrid.Aspect] {
        [.square, .wide]
    }

    @Test("A wide step is wider than the square step it shares a name with")
    func wideStepsOuttankSquareSteps() {
        for size in Self.steps {
            let square = DesignTokens.LibraryGrid.columnWidth(for: size, aspect: .square)
            let wide = DesignTokens.LibraryGrid.columnWidth(for: size, aspect: .wide)
            #expect(wide > square, "wide \(size) \(wide) vs square \(square)")
        }
    }

    @Test("Both ladders climb")
    func laddersClimb() {
        for aspect in Self.aspects {
            let widths = Self.steps.map { DesignTokens.LibraryGrid.columnWidth(for: $0, aspect: aspect) }
            #expect(widths[0] < widths[1], "\(aspect) small is not below medium")
            #expect(widths[1] < widths[2], "\(aspect) medium is not below large")
        }
    }

    @Test("The grid inset matches the filter bar's")
    func gridInsetMatchesTheFilterBar() {
        #expect(DesignTokens.LibraryGrid.horizontalPadding == DesignTokens.LibraryFilterBar.horizontalPadding)
    }

    @Test("Tile frames use the fixed columns and the tile's actual aspect ratio")
    func tileFrames() {
        for (width, columns) in [(CGFloat(1040), 2), (1280, 3), (1600, 3)] {
            for index in [0, 1, 2, 3, 7, 11] {
                let frame = DesignTokens.LibraryGrid.tileFrame(
                    index: index, size: .medium, aspect: .wide,
                    fitting: width - 2 * DesignTokens.LibraryGrid.horizontalPadding, tileAspectRatio: 16 / 9
                )
                #expect(frame == CGRect(
                    x: CGFloat(index % columns) * 398, y: CGFloat(index / columns) * 230,
                    width: 384, height: 216
                ))
            }
        }
        let taller = DesignTokens.LibraryGrid.tileFrame(
            index: 3, size: .medium, aspect: .wide, fitting: 1232, tileAspectRatio: 4 / 3
        )
        #expect(taller == CGRect(x: 0, y: 302, width: 384, height: 288))
    }

    @Test("The Edit Desk Workshop preset gives six columns at 1280 and four at 1040")
    func workshopPresetPacksSixColumns() {
        let preset = DesignTokens.LibraryGrid.workshopBrowseColumnWidth
        #expect(preset == 194)
        let inset = 2 * DesignTokens.Settings.formHorizontalMargin
        for (window, expected) in [(CGFloat(1280), 6), (1040, 4)] {
            let columns = DesignTokens.LibraryGrid.columns(
                for: .medium, aspect: .square, fitting: window - inset, columnWidth: preset
            )
            #expect(columns.count == expected, Comment(rawValue: "\(window) wide packed \(columns.count) columns"))
            for item in columns {
                guard case let .fixed(width) = item.size else {
                    Issue.record("the preset did not produce fixed columns")
                    continue
                }
                #expect(width == preset)
                #expect(item.spacing == DesignTokens.LibraryGrid.spacing)
            }
        }
    }

    @Test("Columns are fixed at the ladder's width and pack as many as the width holds")
    func columnsPackFixedTilesIntoTheWidth() {
        let spacing = DesignTokens.LibraryGrid.spacing
        for aspect in Self.aspects {
            for size in Self.steps {
                let column = DesignTokens.LibraryGrid.columnWidth(for: size, aspect: aspect)
                let exactlyThree = column * 3 + spacing * 2
                let cases: [(width: CGFloat, count: Int)] = [
                    (exactlyThree, 3),
                    (exactlyThree - 1, 2),
                    (column, 1),
                    (column / 2, 1),
                    (0, 1),
                ]
                for expected in cases {
                    let columns = DesignTokens.LibraryGrid.columns(for: size, aspect: aspect, fitting: expected.width)
                    #expect(columns.count == expected.count, "\(aspect) \(size) at \(expected.width): \(columns.count) columns")
                    for item in columns {
                        guard case let .fixed(width) = item.size else {
                            Issue.record("\(aspect) \(size) is not a fixed column")
                            continue
                        }
                        #expect(width == column)
                        #expect(item.spacing == spacing)
                    }
                }
            }
        }
    }
}
