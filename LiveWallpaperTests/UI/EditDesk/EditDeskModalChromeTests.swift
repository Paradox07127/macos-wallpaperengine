import AppKit
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

}

#if !LITE_BUILD
/// ← → as the user meets them: real clicks and key presses on both detail modals, in a window parked offscreen.
@Suite("Detail modal ← → beside the panel, in a window", .serialized)
@MainActor
struct ModalArrowWindowTests {
    enum Modal: CaseIterable {
        case library, workshop
    }

    @MainActor
    final class Presses {
        var previous = 0
        var next = 0
        var dismissals = 0
    }

    /// The smallest Edit Desk window: the panel leaves a 60pt gutter each side, 372 is its middle.
    private static let size = CGSize(width: 1040, height: 700)
    private static let previousArrow = CGPoint(x: 30, y: 372)
    private static let nextArrow = CGPoint(x: 1010, y: 372)
    /// Where ← stood inside the panel: past the side padding, level with the middle of the preview box.
    private static let formerPreviousArrow = CGPoint(x: 98, y: 259.5)
    /// Bare scrim in the same gutter, above ←: a click here closes the modal.
    private static let scrim = CGPoint(x: 30, y: 150)

    @Test("Clicking beside the panel pages; where ← stood inside the panel no longer does", .timeLimit(.minutes(1)), arguments: Modal.allCases)
    func clicksBesideThePanelPage(_ modal: Modal) async {
        let presses = Presses()
        let window = ArrowWindow(size: Self.size, modal: modal, presses: presses, canGoPrevious: true, canGoNext: true)
        defer { window.close() }
        await window.click(Self.formerPreviousArrow)
        await window.settle { presses.previous > 0 }
        #expect(presses.previous == 0, Comment(rawValue: "\(modal): ← still pages from inside the panel"))
        await window.click(Self.previousArrow)
        await window.settle { presses.previous > 0 }
        await window.click(Self.nextArrow)
        await window.settle { presses.next > 0 }
        #expect(presses.previous == 1, Comment(rawValue: "\(modal): ← beside the panel paged \(presses.previous) times"))
        #expect(presses.next == 1, Comment(rawValue: "\(modal): → beside the panel paged \(presses.next) times"))
        #expect(presses.dismissals == 0, Comment(rawValue: "\(modal): a click beside the panel closed the modal"))
    }

    @Test("A greyed arrow neither pages nor closes the modal", .timeLimit(.minutes(1)), arguments: Modal.allCases)
    func greyedArrowSwallowsTheClick(_ modal: Modal) async throws {
        let presses = Presses()
        let window = ArrowWindow(size: Self.size, modal: modal, presses: presses, canGoPrevious: false, canGoNext: true)
        defer { window.close() }
        await window.click(Self.previousArrow)
        // Control: the live arrow on the other side takes the same kind of click.
        await window.click(Self.nextArrow)
        await window.settle { presses.next > 0 }
        try #require(presses.next == 1, Comment(rawValue: "\(modal): control: → never paged, so no click landed"))
        #expect(presses.previous == 0 && presses.dismissals == 0, Comment(rawValue: "\(modal): the greyed ← paged \(presses.previous), closed \(presses.dismissals)"))
        // Control: a click that does reach the scrim is seen closing the modal.
        await window.click(Self.scrim)
        await window.settle { presses.dismissals > 0 }
        #expect(presses.dismissals == 1, Comment(rawValue: "\(modal): control: the bare scrim closed the modal \(presses.dismissals) times"))
    }

    @Test("← and → page as before, and do nothing past either end", .timeLimit(.minutes(1)), arguments: Modal.allCases)
    func arrowKeysPage(_ modal: Modal) async {
        let presses = Presses()
        let atEnd = ArrowWindow(size: Self.size, modal: modal, presses: presses, canGoPrevious: true, canGoNext: false)
        atEnd.press(.left)
        atEnd.press(.right)
        await atEnd.settle { presses.previous > 0 }
        atEnd.close()
        #expect(presses.previous == 1 && presses.next == 0, Comment(rawValue: "\(modal) at the last item: ← \(presses.previous), → \(presses.next)"))
        let atStart = ArrowWindow(size: Self.size, modal: modal, presses: presses, canGoPrevious: false, canGoNext: true)
        defer { atStart.close() }
        atStart.press(.right)
        atStart.press(.left)
        await atStart.settle { presses.next > 0 }
        #expect(presses.next == 1 && presses.previous == 1, Comment(rawValue: "\(modal) at the first item: → \(presses.next), ← \(presses.previous)"))
        #expect(presses.dismissals == 0)
    }
}

@MainActor
private final class ArrowWindow {
    enum Key {
        case left, right
    }

    let window: NSWindow
    private let size: CGSize
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModalArrowWindowTests-\(UUID().uuidString)")

    init(size: CGSize, modal: ModalArrowWindowTests.Modal, presses: ModalArrowWindowTests.Presses, canGoPrevious: Bool, canGoNext: Bool) {
        self.size = size
        let navigation = ModalNavigation(
            canGoPrevious: canGoPrevious, canGoNext: canGoNext,
            previous: { presses.previous += 1 }, next: { presses.next += 1 }
        )
        let content = switch modal {
        case .library:
            AnyView(WallpaperModal(
                content: ProbeFixtures.libraryContent(
                    preview: ProbeRenderer.solid(ProbeRenderer.previewRed, size: CGSize(width: 680, height: 382))
                ),
                targets: ProbeFixtures.targets(thumbnail: nil), actions: ProbeFixtures.libraryActions,
                requestRename: {}, requestDelete: {}, navigation: navigation, windowSize: size,
                titlebarInset: DesignTokens.EditDesk.Spacing.topBar, onDismiss: { presses.dismissals += 1 }, onDrag: { _ in }
            ))
        case .workshop:
            AnyView(Self.workshopModal(size: size, navigation: navigation, presses: presses, directory: directory))
        }
        window = ParkedTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FirstMouseHost(rootView: AppLanguageScope(defaults: .standard) { content.frame(width: size.width, height: size.height) })
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        // Clicks reach only an ordered window; parked outside every display, nothing shows.
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        // Without it a synthesized key press reaches no key-equivalent handler.
        window.makeKey()
        host.layoutSubtreeIfNeeded()
    }

    /// Keyless and offline, so the presets section asks nothing of Steam.
    private static func workshopModal(
        size: CGSize, navigation: ModalNavigation, presses: ModalArrowWindowTests.Presses, directory: URL
    ) -> some View {
        let item = ProbeFixtures.workshopItem()
        let keychain = WorkshopKeychainStore(directory: directory, slot: WorkshopKeychainSlotSpy().slot())
        let cache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache"))
        let services = WorkshopServices(
            keychain: keychain, cache: cache, queryService: WorkshopQueryService(keychain: keychain, cache: cache, countIssuedRequest: {})
        )
        return WorkshopModal(
            content: WorkshopModalContent(item: item, installed: nil),
            doctor: SteamCMDDoctorService(defaults: UserDefaults(suiteName: "ModalArrowWindowTests") ?? .standard),
            facts: WorkshopModalContent.facts(item: item, importedAt: nil, now: Date(), locale: AppLanguagePreference.current.locale),
            row: WorkshopModalButtonRow.make(
                targets: ProbeFixtures.targets(thumbnail: nil), isInstalled: false, canRun: true, ticketState: .waiting,
                queuedScreenID: nil, isBanned: false, isDownloadReady: true, isBusy: false
            ),
            download: WorkshopDownloadPresentation(), unsupportedOrigin: nil, isRevealed: false, matureReveal: nil,
            navigation: navigation, windowSize: size, titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
            onDismiss: { presses.dismissals += 1 }, actions: ProbeFixtures.workshopActions
        )
        .environment(services)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Polls for up to two seconds; a condition that stays false just waits it out.
    func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        try? await Task.sleep(for: .milliseconds(50))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// `point` has a top-left origin; window coordinates start bottom-left.
    func click(_ point: CGPoint) async {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: point.x, y: size.height - point.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ) else {
                Issue.record("could not build a \(type) event")
                return
            }
            window.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Through `NSApp`, the way a real key press reaches the window's key equivalents.
    func press(_ key: Key) {
        let (code, scalar): (UInt16, Int) = key == .left ? (123, NSLeftArrowFunctionKey) : (124, NSRightArrowFunctionKey)
        let characters = UnicodeScalar(UInt32(scalar)).map { String(Character($0)) } ?? ""
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ) else {
            Issue.record("could not build the \(key) key event")
            return
        }
        NSApp.sendEvent(event)
    }
}
#endif
