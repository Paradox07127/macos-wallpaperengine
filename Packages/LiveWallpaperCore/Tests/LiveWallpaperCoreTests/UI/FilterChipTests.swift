import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Filter chip")
struct FilterChipTests {
    @Test("A chip is a filter-bar control's height, selected or not")
    func chipIsTheFilterBarControlHeight() {
        for isSelected in [false, true] {
            let host = NSHostingView(rootView: FilterChip(title: Text(verbatim: "Recent"), isSelected: isSelected) {}.fixedSize())
            #expect(
                host.fittingSize.height == DesignTokens.LibraryFilterBar.controlHeight,
                Comment(rawValue: "selected \(isSelected): the chip is \(host.fittingSize.height)pt tall")
            )
        }
    }
}
