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

    @Test("Wide tiles fill each row evenly while preserving their 16:9 ratio")
    func tileFrames() {
        for (width, columns) in [(CGFloat(1040), 3), (1280, 4), (1600, 5)] {
            let available = width - 2 * DesignTokens.LibraryGrid.horizontalPadding
            let frames = (0 ..< columns).map {
                DesignTokens.LibraryGrid.tileFrame(index: $0, size: .medium, aspect: .wide, fitting: available, tileAspectRatio: 16 / 9)
            }
            #expect(abs((frames.last?.maxX ?? 0) - available) < 0.01)
            #expect(frames.allSatisfy { abs($0.width / $0.height - 16 / 9) < 0.001 })
            #expect(frames.first?.minX == 0)
        }
    }

    @Test("Every wide-card size fits at least three columns in the minimum window")
    func threeColumnsAtMinimumWidth() {
        for size in Self.steps {
            #expect(DesignTokens.LibraryGrid.columns(for: size, aspect: .wide, fitting: 1040 - 2 * DesignTokens.LibraryGrid.horizontalPadding).count >= 3)
        }
    }

    @Test("The Edit Desk Workshop preset shares the row: five columns at 1040, six at 1280, eight at 1728")
    func workshopPresetSharesTheRow() {
        let preset = DesignTokens.LibraryGrid.workshopBrowseColumnWidth
        let spacing = DesignTokens.LibraryGrid.spacing
        #expect(preset == 186)
        let inset = 2 * DesignTokens.Settings.formHorizontalMargin
        // An always-visible scroller takes its width out of the row.
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        for (window, expected) in [(CGFloat(1040), 5), (1280, 6), (1728, 8)] {
            for available in [window - inset, window - inset - scroller] {
                // The page ignores the tile-size preference.
                for size in Self.steps {
                    let columns = DesignTokens.LibraryGrid.columns(
                        for: size, aspect: .square, fitting: available, columnWidth: preset
                    )
                    #expect(columns.count == expected, Comment(rawValue: "\(available) wide packed \(columns.count) columns"))
                    let widths = columns.compactMap { item -> CGFloat? in
                        guard case let .fixed(width) = item.size else { return nil }
                        return width
                    }
                    #expect(widths.count == columns.count, "the preset did not produce fixed columns")
                    #expect(widths.allSatisfy { $0 >= preset && $0 == widths.first })
                    let packed = widths.reduce(0, +) + spacing * CGFloat(columns.count - 1)
                    #expect(abs(packed - available) < 0.01, Comment(rawValue: "\(available) wide left \(available - packed) at the trailing edge"))
                    #expect(columns.allSatisfy { $0.spacing == spacing })
                }
            }
        }
    }

    @Test("The old window's square ladder keeps fixed columns")
    func squareLadderKeepsFixedColumns() {
        // The old window at 1160 / 1280 / 1728 less its 220pt sidebar; Browse insets its grid 18 a side, Installed 24.
        let expected: [(page: CGFloat, counts: [LibraryTileSize: Int])] = [
            (940, [.small: 5, .medium: 3, .large: 2]),
            (1060, [.small: 6, .medium: 4, .large: 3]),
            (1508, [.small: 8, .medium: 6, .large: 4]),
        ]
        for (page, counts) in expected {
            for inset in [DesignTokens.Settings.formHorizontalMargin, DesignTokens.LibraryGrid.horizontalPadding] {
                for (size, count) in counts {
                    let column = DesignTokens.LibraryGrid.columnWidth(for: size, aspect: .square)
                    let columns = DesignTokens.LibraryGrid.columns(for: size, aspect: .square, fitting: page - 2 * inset)
                    #expect(columns.count == count, Comment(rawValue: "\(size) at \(page) less \(inset) a side: \(columns.count) columns"))
                    for item in columns {
                        guard case let .fixed(width) = item.size else {
                            Issue.record("\(size) is not a fixed column")
                            continue
                        }
                        #expect(width == column, Comment(rawValue: "\(size) at \(page): \(width) instead of \(column)"))
                    }
                }
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
                        if case .square = aspect {
                            #expect(width == column)
                        } else if expected.width > 0 {
                            #expect(abs(width * CGFloat(columns.count) + spacing * CGFloat(columns.count - 1) - expected.width) < 0.01)
                        }
                        #expect(item.spacing == spacing)
                    }
                }
            }
        }
    }
}
