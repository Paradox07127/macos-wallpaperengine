import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Scheme drag — the shared display strip")
@MainActor
struct SchemeDragSourceTests {
    @Test("Scheme tiles drag through the library's drag source, and the Schemes page hangs its strip")
    func schemesUseTheSharedDrag() throws {
        let library = try RepositoryRoot.source("LiveWallpaper/Views/Schemes/SchemeLibraryView.swift")
        #expect(library.contains(".libraryDragSource("), "scheme tiles do not start a library drag")
        #expect(!library.contains(".onDrag"), "scheme tiles still start a system drag")
        #expect(!library.contains("Apply to \\("), "the context menu still lists an apply row per display")

        let page = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/SchemesPage.swift")
        #expect(page.contains("LibraryDragOverlay("), "the Schemes page shows no strip for a scheme drag")
        #expect(page.contains(".coordinateSpace(name: EditDeskCoordinateSpace.name)"), "the drag's points are in no space the strip shares")
    }

    @Test("A payload without All Displays never lands there and applies nothing on release over it")
    func noAllDisplaysTarget() {
        var applied: [CGDirectDisplayID] = []
        let drag = LibraryDragController()
        drag.thumbnailFrames = [1: CGRect(x: 300, y: 24, width: 149, height: 84)]
        drag.runFrame = CGRect(x: 290, y: 24, width: 170, height: 84)
        drag.applyAllFrame = CGRect(x: 500, y: 51, width: 120, height: 30)
        let payload = LibraryDragController.Payload(
            item: nil, image: nil, applyTo: { applied.append($0) }, applyToAllDisplays: nil
        )

        drag.begin(payload, at: CGPoint(x: 400, y: 420))
        drag.move(to: CGPoint(x: 550, y: 66))
        #expect(drag.target == nil, "a scheme drag lit the All Displays tile")
        drag.end(at: CGPoint(x: 550, y: 66))
        #expect(applied.isEmpty)

        drag.clear()
        drag.begin(payload, at: CGPoint(x: 400, y: 420))
        drag.end(at: CGPoint(x: 370, y: 66))
        #expect(applied == [1], "a scheme dropped on a display did not apply there")
    }
}
