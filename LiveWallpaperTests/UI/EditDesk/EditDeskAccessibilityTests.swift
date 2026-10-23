#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Observation
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
        #expect(filled.accessibilityCustomActions()?.map(\.name) == [label("Clear Wallpaper")])
        try #require(actions[0].handler?() == true)
        #expect(await events.next() == .emptyActionTapped(1, .chooseFile))
        try #require(actions[1].handler?() == true)
        #expect(await events.next() == .emptyActionTapped(1, .pasteURL))
        // Return / VoiceOver press still opens the display itself.
        #expect(empty.accessibilityPerformPress())
        #expect(await events.next() == .displayTapped(1))
    }

    @Observable final class SearchState {
        var text = ""
    }

    @Test("Adaptive search expands, focuses, keeps a visible query and exits through Escape")
    func adaptiveSearchFollowsWindowAndEditing() async throws {
        let stage = EditDeskStageModel()
        stage.reduceMotion = true
        stage.setProgress(1, animated: false)
        let state = SearchState()
        let host = NSHostingView(rootView: AdaptiveLibrarySearch(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            prompt: "Search by name", shortPrompt: "Search", stage: stage
        ).frame(width: 300, height: 60, alignment: .leading))
        let window = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: 300, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        func editableField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap(editableField).first
        }
        func settle(_ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            return condition()
        }
        host.layoutSubtreeIfNeeded()
        #expect(editableField(in: host) == nil, "the empty shelf should show the search button")
        stage.setProgress(2, animated: false)
        stage.report(stageSize: CGSize(width: 1440, height: 960))
        try #require(await settle { editableField(in: host) != nil }, "the wide library did not expand search")
        stage.report(stageSize: StageGeometry.minimumWindow)
        try #require(await settle { editableField(in: host) == nil }, "the narrow idle field did not collapse")

        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 14, y: 30), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
        try #require(await settle { editableField(in: host)?.currentEditor() != nil },
                 "clicking the search icon did not expand and focus its field")
        let field = try #require(editableField(in: host))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("blue", replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(await settle { state.text == "blue" })
        stage.report(stageSize: CGSize(width: 1440, height: 960))
        stage.report(stageSize: StageGeometry.minimumWindow)
        #expect(editableField(in: host)?.stringValue == "blue", "resizing hid the active query")
        let editing = try #require(field.currentEditor() as? NSTextView)
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        // Feed the native field editor's key interpretation directly: an offscreen test
        // window cannot become the system's key window while another app is active.
        editing.interpretKeyEvents([escape])
        #expect(await settle { state.text.isEmpty && editableField(in: host) == nil },
                "Escape left query \(state.text), field \(String(describing: editableField(in: host)?.stringValue))")
    }
}
#endif
