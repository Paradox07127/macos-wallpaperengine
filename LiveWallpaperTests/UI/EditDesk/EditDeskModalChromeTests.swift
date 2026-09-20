import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Edit Desk modal chrome — geometry, ESC and ⌘n dispatch")
@MainActor
struct EditDeskModalChromeTests {
    private func chrome(
        windowSize: CGSize = CGSize(width: 1280, height: 820),
        onDismiss: @escaping () -> Void = {},
        onEscape: @escaping () -> Bool = { false },
        onTargetShortcut: ((Int) -> Void)? = nil
    ) -> EditDeskModalChrome<EmptyView> {
        EditDeskModalChrome(
            windowSize: windowSize,
            onDismiss: onDismiss,
            onEscape: onEscape,
            onTargetShortcut: onTargetShortcut
        ) { _ in EmptyView() }
    }

    // MARK: Geometry

    @Test("The panel the closure receives is ModalGeometry's own rect, not a second copy of the box")
    func panelFrameMatchesModalGeometry() {
        for size in [CGSize(width: 1280, height: 820), CGSize(width: 1040, height: 700), CGSize(width: 800, height: 600)] {
            let frame = chrome(windowSize: size).panelFrame
            #expect(frame == ModalGeometry.panelFrame(in: size), Comment(rawValue: "\(size) → \(frame)"))
        }
        #expect(chrome().panelFrame == CGRect(x: 200, y: 150, width: 880, height: 560))
    }

    @Test("The scrim leaves the title bar clickable by default")
    func titlebarInsetDefaultsToTheTopBar() {
        #expect(chrome().titlebarInset == DesignTokens.EditDesk.Spacing.topBar)
    }

    // MARK: ESC

    @Test("A panel that consumed ESC keeps the modal open; a panel that declined it dismisses")
    func escapeReachesThePanelBeforeTheDismiss() {
        var dismissals = 0
        var panelConsumesEscape = false
        let subject = chrome(onDismiss: { dismissals += 1 }, onEscape: { panelConsumesEscape })

        subject.escape()
        #expect(dismissals == 1, Comment(rawValue: "A declined ESC must close the modal"))

        panelConsumesEscape = true
        subject.escape()
        #expect(dismissals == 1, Comment(rawValue: "ESC consumed by the panel still dismissed the modal"))
    }

    @Test("Without an escape handler ESC always dismisses")
    func escapeDefaultsToDismissing() {
        var dismissals = 0
        chrome(onDismiss: { dismissals += 1 }).escape()
        #expect(dismissals == 1)
    }

    // MARK: ⌘n

    @Test("The container installs the whole ⌘1…⌘9 range and leaves the lookup to its owner")
    func targetShortcutRange() {
        #expect(EditDeskModalChrome<EmptyView>.targetShortcutIndices == 1 ... 9)
    }

    // MARK: Source contract

    private static let chromePath = "LiveWallpaper/Views/EditDesk/Library/EditDeskModalChrome.swift"
    private static let modalPath = "LiveWallpaper/Views/EditDesk/Library/WallpaperModal.swift"

    @Test("The scrim, the panel box and the modal traits live in the chrome")
    func chromeOwnsTheShell() throws {
        let source = try RepositoryRoot.source(Self.chromePath)
        #expect(source.contains("ModalGeometry.panelFrame(in: windowSize)"))
        #expect(source.contains("DesignTokens.EditDesk.Colors.modalScrim"))
        #expect(source.contains("ModalBackdrop(preview: backdrop)"))
        #expect(source.contains("accessibilityElement(children: .contain)"))
        #expect(source.contains("accessibilityAddTraits(.isModal)"))
        #expect(source.contains("DesignTokens.EditDesk.Shadow.modal"))
    }

    @Test("WallpaperModal no longer draws the scrim or measures the panel itself")
    func modalDelegatesTheShell() throws {
        let source = try RepositoryRoot.source(Self.modalPath)
        #expect(source.contains("EditDeskModalChrome("), "the modal does not build on the shared chrome")
        #expect(!source.contains("modalScrim"), "the modal still paints its own scrim")
        #expect(!source.contains("ModalGeometry.panelFrame("), "the modal still measures its own panel")
        #expect(!source.contains("accessibilityAddTraits(.isModal)"), "the modal still declares the modal trait")
    }

    @Test("The library modal keeps ⌘n on applyTo and keeps ESC cancelling a drag")
    func modalKeepsItsOwnBusiness() throws {
        let source = try RepositoryRoot.source(Self.modalPath)
        #expect(source.contains("onTargetShortcut:"))
        #expect(source.contains("ModalKeyMap.target(forShortcut:"))
        #expect(source.contains("onEscape:"))
        #expect(source.contains("onDrag(.cancelled)"))
        // Space and ← → are the library's own, not the container's.
        #expect(source.contains("keyboardShortcut(.space"))
        #expect(source.contains("keyboardShortcut(.leftArrow"))
    }

    @Test("No token-bypass literals in the files this package adds")
    func noTokenBypassLiterals() throws {
        for path in [
            Self.chromePath,
            "LiveWallpaper/Views/EditDesk/Workshop/MatureRevealState.swift",
        ] {
            let source = try RepositoryRoot.source(path)
            #expect(!source.contains(".font(.system("), "\(path) has an inline .font(.system( literal")
            #expect(!source.contains("Color(red:"), "\(path) has a literal Color(red:")
            #expect(
                source.range(of: #"cornerRadius:\s*[0-9]"#, options: .regularExpression) == nil,
                "\(path) has a literal cornerRadius"
            )
        }
    }
}
