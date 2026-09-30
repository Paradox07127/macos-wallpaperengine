import Foundation
import Testing

/// Named after `.ignoresSafeArea()`, the space starts a safe-area inset below the window's top edge while the drag
/// overlay draws from that edge, so the ghost floats that far above the pointer.
@Suite("Edit Desk coordinate space — named before the safe area is ignored")
struct EditDeskCoordinateSpaceOrderTests {
    @Test("The drag pages name their coordinate space before they ignore the safe area", arguments: [
        "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift",
        "LiveWallpaper/Views/EditDesk/Shell/SchemesPage.swift",
    ])
    func coordinateSpaceComesFirst(path: String) throws {
        let source = try RepositoryRoot.source(path)
        let space = try #require(source.range(of: ".coordinateSpace(name: EditDeskCoordinateSpace.name)"), "\(path) names no Edit Desk space")
        let ignores = try #require(source.range(of: ".ignoresSafeArea()"), "\(path) no longer ignores the safe area")
        #expect(space.lowerBound < ignores.lowerBound, "\(path): the space is named inside the safe area, so the ghost sits above the pointer")
    }
}
