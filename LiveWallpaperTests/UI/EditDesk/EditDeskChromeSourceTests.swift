import Foundation
import Testing

@Suite("Edit Desk home chrome — source contract")
struct EditDeskChromeSourceTests {

    @Test("The wallpaper library's import entries, a drop on the shelf among them, only add to the library")
    func libraryImportEntriesOnlyAdd() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("onImport: promptLibraryImport"), "the row's + still applies the file to a display")
        let panel = try #require(source.range(of: "private func promptLibraryImport()"))
        let panelBody = try #require(String(source[panel.lowerBound...]).components(separatedBy: "\n    }").first)
        #expect(panelBody.contains("importToLibrary(panel.urls)"), "the panel and the shelf import on two separate paths")
        #expect(!panelBody.contains("promptImport("))
        #expect(!panelBody.contains("applies.run"))
        let importer = try #require(source.range(of: "private func importToLibrary(_ urls:"))
        let importBody = try #require(String(source[importer.lowerBound...]).components(separatedBy: "\n    }").first)
        #expect(importBody.contains("LibraryImporter(") && importBody.contains(".add(urls)"))
        #expect(!importBody.contains("applies.run"), "adding to the library must not apply to a display")
        let drop = try #require(source.range(of: "case let .filesDroppedOnShelf(urls):"), "a drop on the shelf is ignored")
        let branch = try #require(String(source[drop.upperBound...]).components(separatedBy: "\n            case ").first)
        #expect(branch.contains("importToLibrary(urls)"), "a drop on the shelf never joins the library")
        #expect(!branch.contains("applies.run"), "a drop on the shelf applies the files to a display")
        let treeStart = try #require(source.range(of: "        ZStack(alignment: .top) {"))
        let tree = try #require(String(source[treeStart.lowerBound...]).components(separatedBy: "\n        }").first)
        let stage = try #require(tree.range(of: "EditDeskStageRepresentable(model: stage)"))
        let highlight = try #require(tree.range(of: "ShelfDropHighlight(stage: stage)"), "the shelf band never lights for a drop")
        #expect(stage.upperBound <= highlight.lowerBound, "declared under the stage, the band's light hides behind the cards")
    }

    @Test("Orphan covers are swept once, when the window builds the library model, sparing those undo can bring back")
    func libraryModelSweepsCoversOnce() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift")
        #expect(source.contains("let library = SavedLibraryModel(screenManager: screenManager)"))
        #expect(source.contains("library.prepareLibrary(alsoKeeping: undo.retainedCoverFileNames)"))
        #expect(
            source.components(separatedBy: "prepareLibrary(").count - 1 == 1,
            "the cover sweep must not run again on every library rebuild"
        )
        let homeSweeps = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift").contains("prepareLibrary(")
        #expect(!homeSweeps, "the sweep would run again each time a page switch remounts HomePage")
    }

    @Test("The library's delete confirmation and rename alert have one presenter, which finds the entry by the ID it opened for")
    func libraryItemDialogsHaveOnePresenter() throws {
        // ← → keep paging the modal under a dialog, so a dialog the modal presented would act on the entry shown by then.
        var presenters: [String: [String]] = [:]
        for file in RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for modifier in [".wallpaperDeleteConfirmation(", ".wallpaperRenameAlert("] {
                let count = source.components(separatedBy: modifier).count - 1
                presenters[modifier, default: []] += Array(repeating: RepositoryRoot.relativePath(of: file), count: count)
            }
        }
        let home = "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift"
        #expect(presenters[".wallpaperDeleteConfirmation("] == [home])
        #expect(presenters[".wallpaperRenameAlert("] == [home])
        let source = try RepositoryRoot.source(home)
        let start = try #require(source.range(of: "private struct LibraryItemCommands: ViewModifier {"))
        let commands = try #require(source[start.upperBound...].components(separatedBy: "\n    }\n").first)
        #expect(!commands.contains("_ in"), "a dialog action that drops its ID acts on whichever entry is current")
    }

}
