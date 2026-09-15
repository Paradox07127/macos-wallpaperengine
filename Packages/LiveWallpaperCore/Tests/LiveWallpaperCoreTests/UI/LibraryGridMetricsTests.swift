@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Library grid metrics")
struct LibraryGridMetricsTests {
    private static let steps: [LibraryTileSize] = [.small, .medium, .large]

    @Test("A wide step is wider than the square step it shares a name with")
    func wideStepsOuttankSquareSteps() {
        for size in Self.steps {
            let square = DesignTokens.LibraryGrid.columnWidths(for: size, aspect: .square)
            let wide = DesignTokens.LibraryGrid.columnWidths(for: size, aspect: .wide)
            #expect(wide.min > square.min, "wide \(size) min \(wide.min) vs square \(square.min)")
            #expect(wide.max > square.max, "wide \(size) max \(wide.max) vs square \(square.max)")
        }
    }

    @Test("Both ladders climb, and every step can flex")
    func laddersClimbAndEveryStepCanFlex() {
        for aspect in [DesignTokens.LibraryGrid.Aspect.square, .wide] {
            let widths = Self.steps.map { DesignTokens.LibraryGrid.columnWidths(for: $0, aspect: aspect) }
            for step in widths {
                #expect(step.min < step.max, "\(aspect) step \(step) cannot flex")
            }
            #expect(widths[0].min < widths[1].min, "\(aspect) small is not below medium")
            #expect(widths[1].min < widths[2].min, "\(aspect) medium is not below large")
        }
    }

    @Test("The grid inset matches the filter bar's")
    func gridInsetMatchesTheFilterBar() {
        #expect(DesignTokens.LibraryGrid.horizontalPadding == DesignTokens.LibraryFilterBar.horizontalPadding)
    }

    @Test("Columns carry the ladder's own widths")
    func columnsCarryTheLaddersWidths() {
        for aspect in [DesignTokens.LibraryGrid.Aspect.square, .wide] {
            for size in Self.steps {
                let expected = DesignTokens.LibraryGrid.columnWidths(for: size, aspect: aspect)
                let columns = DesignTokens.LibraryGrid.columns(for: size, aspect: aspect)
                #expect(columns.count == 1)
                guard case let .adaptive(minimum, maximum) = columns[0].size else {
                    Issue.record("\(aspect) \(size) is not an adaptive column")
                    continue
                }
                #expect(minimum == expected.min)
                #expect(maximum == expected.max)
                #expect(columns[0].spacing == DesignTokens.LibraryGrid.spacing)
            }
        }
    }
}
