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
