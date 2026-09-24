import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Edit Desk shelf preferences")
struct EditDeskPreferencesTests {
    @Test("Defaults match the work package spec")
    func defaultsMatchSpec() {
        #expect(EditDeskPreferences.shelfStyleDefault == .facingIn)
        // The settings picker lists the cases in this order, the default first.
        #expect(ShelfStyle.allCases.map(\.rawValue) == ["facingIn", "crate", "folders", "fan", "focusRow"])
        #expect(EditDeskPreferences.shelfCapacityDefault == 20)
        #expect(EditDeskPreferences.backgroundDefault == .opaque)
        #expect(EditDeskPreferences.background == "loomscreen.editDesk.background")
        #expect(EditDeskBackground.allCases.map(\.rawValue) == ["opaque", "frosted"])
        #expect(EditDeskPreferences.hoverAutoplayPreviewDefault == true)
        #expect(EditDeskPreferences.statusCapsuleContentDefault == .systemHealth)
        #expect(EditDeskPreferences.homeDefaultStateDefault == .hidden)
    }

    @Test("Every reader of the library tile-size preference falls back to the one shared default")
    func tileSizeReadersShareOneDefault() throws {
        var offenders: [String] = []
        var readers = 0
        for file in RepositoryRoot.swiftFiles(under: "LiveWallpaper") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains("LibraryTileSize") || line.contains("libraryTileSize") {
                readers += line.contains(".defaultSize") ? 1 : 0
                if ["small", "medium", "large"].contains(where: { line.contains("LibraryTileSize.\($0).rawValue") || line.contains("?? .\($0)") }) {
                    offenders.append(RepositoryRoot.relativePath(of: file) + ": " + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
        #expect(readers >= 5, "the scan no longer finds the preference's readers")
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

    @Test("Every shelf style lays the row out differently and reaches the stage")
    func shelfStylesAreDistinct() throws {
        let placements = ShelfStyle.allCases.map {
            StageGeometry.cardPlacement(
                style: $0, index: 3, count: 14, progress: 1, focus: 0, windowSize: StageGeometry.designWindow
            )
        }
        #expect(Set(placements.map(\.frame.minX)).count == ShelfStyle.allCases.count)
        // The fan turns in the screen's plane where the others lean about their vertical axis.
        #expect(Set(placements.map { [$0.rotationYDegrees, $0.rotationZDegrees] }).count == ShelfStyle.allCases.count)
        #expect(placements.allSatisfy { $0.translateZ <= 0 })
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("stage.shelfStyle = shelfStyle"), "HomePage does not forward the shelf style")
    }

    /// The `.flat` shell is 2pt of padding round equal segments with no gap and no inner padding, so
    /// a title fits when its one-line width is at most an equal share of what is left.
    @MainActor
    @Test("The shelf style picker fits every title, selected or not, in all five languages")
    func shelfStylePickerFitsEveryTitle() throws {
        let keys: [ShelfStyle: String] = [
            .facingIn: "Facing In", .crate: "Crate", .folders: "Folders", .fan: "Fan", .focusRow: "Focus Row",
        ]
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Settings/ShelfSettingsRows.swift")
        for style in ShelfStyle.allCases {
            let key = try #require(keys[style], "no title for \(style)")
            #expect(source.contains("case .\(style): \"\(key)\""), "ShelfSettingsRows titles \(style) with another key")
        }
        let segment = (ShelfSettingsRows.shelfStylePickerWidth - 4) / CGFloat(ShelfStyle.allCases.count)
        var widest: (width: CGFloat, title: String) = (0, "")
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "es"] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in keys.values.sorted() {
                let title = NSLocalizedString(key, bundle: bundle, comment: "")
                for font in [DesignTokens.Typography.body, DesignTokens.Typography.bodyEmphasized] {
                    let width = NSHostingView(rootView: Text(verbatim: title).font(font).fixedSize()).fittingSize.width
                    print("SHELFPICKER \(language) \(title) \(width)")
                    if width > widest.width {
                        widest = (width, "\(language) \(title)")
                    }
                    #expect(width <= segment, Comment(rawValue: "\(language) “\(title)” needs \(width)pt, a segment holds \(segment)pt"))
                }
            }
        }
        let needed = CGFloat(ShelfStyle.allCases.count) * widest.width + 4
        print("SHELFPICKER widest \(widest.title) \(widest.width): picker needs \(needed), segment \(segment)")
    }
}
