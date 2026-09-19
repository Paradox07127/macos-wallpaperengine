import Foundation
import Testing

@Suite("Edit Desk home chrome — source contract")
struct EditDeskChromeSourceTests {
    private static let ownedFiles = [
        "LiveWallpaper/Views/EditDesk/Shell/NavPill.swift",
        "LiveWallpaper/Views/EditDesk/Shell/StatusCapsule.swift",
        "LiveWallpaper/Views/EditDesk/Shell/TopBar.swift",
        "LiveWallpaper/Views/EditDesk/Shell/EditDeskToastCenter.swift",
        "LiveWallpaper/Views/EditDesk/Shell/HomeHints.swift",
        "LiveWallpaper/Views/EditDesk/Library/LibraryChipsRow.swift",
        "LiveWallpaper/Views/EditDesk/Library/LibrarySegmentPicker.swift",
    ]

    @Test("NavPill and LibrarySegmentPicker build on GlassSegmentedPicker's editDesk shell")
    func navPillAndSegmentPickerUseEditDeskShell() throws {
        for path in [
            "LiveWallpaper/Views/EditDesk/Shell/NavPill.swift",
            "LiveWallpaper/Views/EditDesk/Library/LibrarySegmentPicker.swift",
        ] {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains("GlassSegmentedPicker("), "\(path) does not build on GlassSegmentedPicker")
            #expect(source.contains("shell: .editDesk"), "\(path) does not request the editDesk shell")
        }
    }

    @Test("The library chips row is built from FilterChip")
    func chipsRowUsesFilterChip() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/LibraryChipsRow.swift")
        #expect(source.contains("FilterChip("))
    }

    @Test("The top bar's search field is LibrarySearchField")
    func topBarUsesLibrarySearchField() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/TopBar.swift")
        #expect(source.contains("LibrarySearchField("))
    }

    @Test("No token-bypass literals in the files this package owns")
    func noTokenBypassLiterals() throws {
        for path in Self.ownedFiles {
            let source = try RepositoryRoot.source(path)
            #expect(!source.contains(".font(.system("), "\(path) has an inline .font(.system( literal")
            #expect(!source.contains("Color(red:"), "\(path) has a literal Color(red:")
            #expect(
                source.range(of: #"cornerRadius:\s*[0-9]"#, options: .regularExpression) == nil,
                "\(path) has a literal cornerRadius"
            )
        }
    }

    @Test("The nav pill routes through the router instead of writing the page directly")
    func navPillGoesThroughSelect() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("Binding(get: { router.page }, set: { router.select($0) })"))
        #expect(source.contains("TopBar(\n                page: pageBinding,"))
        #expect(!source.contains("page: $router.page"), "a direct binding skips previousPage and the Workshop check")
    }

    @Test("Drops are applied off the stage's event loop")
    func dropsDoNotBlockTheEventLoop() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("applies.run(for: displayID) { await applyCard(cardID, to: displayID) }"))
        #expect(!source.contains("await applyCard(cardID, to: displayID)\n            case"))
    }

    @Test("The stage's previous-track action reaches the playlist coordinator")
    func previousTrackIsWired() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("screenManager.regressPlaylist(for: screen)"))
    }

    @Test("The display link is rebuilt when the window moves to another screen")
    func displayLinkFollowsTheWindow() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Stage/EditDeskStageView.swift")
        #expect(source.contains("NSWindow.didChangeScreenNotification"))
        #expect(source.contains("self.stopDisplayLink()\n                    self.startDisplayLinkIfNeeded()"))
        #expect(source.contains("screenObserver.map(NotificationCenter.default.removeObserver)"))
    }
}
