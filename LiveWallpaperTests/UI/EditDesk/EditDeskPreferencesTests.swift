import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Edit Desk shelf preferences")
struct EditDeskPreferencesTests {
    @Test("Defaults match the work package spec")
    func defaultsMatchSpec() {
        #expect(EditDeskPreferences.shelfStyleDefault == .crate)
        #expect(EditDeskPreferences.shelfCapacityDefault == 20)
        #expect(EditDeskPreferences.backgroundDefault == .opaque)
        #expect(EditDeskPreferences.background == "loomscreen.editDesk.background")
        #expect(EditDeskBackground.allCases.map(\.rawValue) == ["opaque", "frosted"])
        #expect(EditDeskPreferences.hoverAutoplayPreviewDefault == true)
        #expect(EditDeskPreferences.statusCapsuleContentDefault == .systemHealth)
        #expect(EditDeskPreferences.homeDefaultStateDefault == .hidden)
    }

    @Test("Storage keys are namespaced under loomscreen.editDesk")
    func storageKeysAreNamespaced() {
        #expect(EditDeskPreferences.shelfStyle == "loomscreen.editDesk.shelfStyle")
        #expect(EditDeskPreferences.shelfCapacity == "loomscreen.editDesk.shelfCapacity")
        #expect(EditDeskPreferences.hoverAutoplayPreview == "loomscreen.editDesk.hoverAutoplayPreview")
        #expect(EditDeskPreferences.statusCapsuleContent == "loomscreen.editDesk.statusCapsuleContent")
        #expect(EditDeskPreferences.homeDefaultState == "loomscreen.editDesk.homeDefaultState")
    }

    @Test("StatusCapsuleContent raw values")
    func statusCapsuleContentRawValues() {
        #expect(StatusCapsuleContent.systemHealth.rawValue == "systemHealth")
        #expect(StatusCapsuleContent.wallpapersOnly.rawValue == "wallpapersOnly")
        #expect(StatusCapsuleContent.hidden.rawValue == "hidden")
        #expect(StatusCapsuleContent.allCases.count == 3)
    }

    @Test("HomeDefaultState raw values")
    func homeDefaultStateRawValues() {
        #expect(HomeDefaultState.hidden.rawValue == "hidden")
        #expect(HomeDefaultState.halfOpen.rawValue == "halfOpen")
        #expect(HomeDefaultState.allCases.count == 2)
    }

    @Test("GeneralSection mounts ShelfSettingsRows exactly once")
    func generalSectionMountsShelfSettingsRowsOnce() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Settings/GeneralSection.swift")
        let occurrences = source.components(separatedBy: "ShelfSettingsRows()").count - 1
        #expect(occurrences == 1)
    }

    @Test("ShelfSettingsRows reads every Edit Desk key through .appScoped()")
    func shelfSettingsRowsReadsAllKeysScoped() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Settings/ShelfSettingsRows.swift")
        let keys = [
            EditDeskPreferences.shelfStyle,
            EditDeskPreferences.background,
            EditDeskPreferences.shelfCapacity,
            EditDeskPreferences.hoverAutoplayPreview,
            EditDeskPreferences.statusCapsuleContent,
            EditDeskPreferences.homeDefaultState,
        ]
        for key in keys {
            let needle = "@AppStorage(EditDeskPreferences.\(key.split(separator: ".").last ?? ""), store: .appScoped())"
            #expect(source.contains(needle), "Missing scoped @AppStorage for \(key)")
        }
    }

    @Test("All three shelf styles lay the row out differently and reach the stage")
    func shelfStylesAreDistinct() throws {
        let placements = ShelfStyle.allCases.map {
            StageGeometry.cardPlacement(
                style: $0, index: 3, count: 14, progress: 1, focus: 0, windowSize: StageGeometry.designWindow
            )
        }
        #expect(Set(placements.map(\.frame.minX)).count == ShelfStyle.allCases.count)
        #expect(Set(placements.map(\.rotationYDegrees)).count == ShelfStyle.allCases.count)
        #expect(placements.allSatisfy { $0.translateZ <= 0 })
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("stage.shelfStyle = shelfStyle"), "HomePage does not forward the shelf style")
    }
}
