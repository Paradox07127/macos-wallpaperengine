#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// WP 6.4 §4: what VoiceOver is handed by the views this milestone added. Read off a live AX tree
/// where the view can be hosted offscreen, and off the source where it cannot — the Steam wizard
/// needs two services, and focus order and the rotor have no offscreen representation at all.
@MainActor
@Suite("Edit Desk accessibility", .serialized)
struct EditDeskAccessibilityTests {
    private func label(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .appLanguage)
    }

    /// 6.1c's two entry points are drawn into a CALayer, so the display element carries them as
    /// custom actions; that is the whole keyboard and VoiceOver path to them.
    @Test("An empty display carries Choose File and Paste URL as custom actions, and presses open it")
    func emptyDisplayActions() async throws {
        let model = EditDeskStageModel()
        model.reduceMotion = true
        model.displays = [
            StageDisplay(
                id: 1, fingerprint: "a", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                isBuiltin: false, name: "External", badgeText: "EXTERNAL", statusText: "Main", cover: nil, state: .empty
            ),
            StageDisplay(
                id: 2, fingerprint: "b", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                isBuiltin: false, name: "Second", badgeText: "EXTERNAL", statusText: "", cover: nil, state: .ok
            ),
        ]
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        var events = model.events.makeAsyncIterator()
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        let empty = try #require(children.first { $0.accessibilityLabel() == "External, Main" })
        let filled = try #require(children.first { $0.accessibilityLabel() == "Second" })
        let actions = try #require(empty.accessibilityCustomActions())
        #expect(actions.map(\.name) == [label("Choose File"), label("Paste URL")])
        // A display that already has a wallpaper must not offer them.
        #expect(filled.accessibilityCustomActions()?.isEmpty == true)
        try #require(actions[0].handler?() == true)
        #expect(await events.next() == .emptyActionTapped(1, .chooseFile))
        try #require(actions[1].handler?() == true)
        #expect(await events.next() == .emptyActionTapped(1, .pasteURL))
        // Return / VoiceOver press still opens the display itself.
        #expect(empty.accessibilityPerformPress())
        #expect(await events.next() == .displayTapped(1))
    }

    /// The filter row's search field stays mounted on the shelf, faded out, so the edit a return
    /// swipe leaves behind has to end there rather than keep the keys typed over the shelf.
    @Test("The library's search field gives up the keyboard once it is too faint to click", arguments: [1.0, 1.4])
    func fadedSearchFieldEndsItsEdit(progress: Double) async throws {
        // 1.4: still drawn, but under the row's click threshold.
        #expect(LibrarySearchReveal.opacity(progress) <= ShelfChromeRide.interactiveOpacity)
        let stage = EditDeskStageModel()
        stage.setProgress(2, animated: false)
        let host = NSHostingView(rootView: LibrarySearchField(text: .constant(""), prompt: "Search by name")
            .modifier(LibrarySearchReveal(stage: stage)))
        let window = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: 320, height: 60), styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        func editableField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable {
                return field
            }
            return view.subviews.lazy.compactMap(editableField).first
        }
        let field = try #require(editableField(in: host))
        #expect(window.makeFirstResponder(field))
        try #require(field.currentEditor() != nil, "control: the field never took the keyboard")

        stage.setProgress(progress, animated: false)
        let deadline = ContinuousClock.now + .seconds(1)
        while field.currentEditor() != nil, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(field.currentEditor() == nil, "the faded field still takes the keys typed over the shelf")
    }
}
#endif
