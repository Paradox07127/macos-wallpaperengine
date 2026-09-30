#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Installed library error toast")
struct InstalledLibraryErrorToastTests {
    @Test("A Workshop delete failure becomes one failure toast and the message is taken")
    func errorBecomesFailureToast() throws {
        let model = InstalledLibraryModel()
        let center = EditDeskToastCenter()
        model.errorMessage = "Removed Fixture from the library, but its files couldn't be deleted."

        HomePage.postInstalledLibraryError(model, to: center)

        let toast = try #require(center.toasts.first, "the failure never reached the toast center")
        #expect(center.toasts.count == 1)
        #expect(toast.text == "Removed Fixture from the library, but its files couldn't be deleted.")
        #expect(toast.style == .failure)
        #expect(model.errorMessage == nil, "the message stays set, so the next render would post it again")

        HomePage.postInstalledLibraryError(model, to: center)
        #expect(center.toasts.count == 1, "a cleared message posted a second toast")
    }

    @Test("The home page posts the installed library's error whenever it changes")
    func homePageWiring() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains(
            ".onChange(of: page.installedLibrary.errorMessage, initial: true) {"
        ), "no view reads InstalledLibraryModel.errorMessage, so a failed delete is silent")
        #expect(source.contains("HomePage.postInstalledLibraryError(page.installedLibrary, to: page.toasts)"))
    }
}
#endif
