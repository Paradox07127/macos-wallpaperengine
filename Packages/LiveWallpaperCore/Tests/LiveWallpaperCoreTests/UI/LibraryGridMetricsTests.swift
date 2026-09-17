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
