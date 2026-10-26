import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("A click outside a text field ends its editing", .serialized)
@MainActor
struct ClickOutsideEndsEditingTests {
    private final class Record {
        var text = ""
        var query = ""
        var submits = 0
        var taps = 0
        /// The button in its window, title bar included, top-left origin.
        var button: CGRect = .zero
    }

    private struct Page: View {
        let record: Record
        @State private var text = "typed"
        @State private var notes = "notes"
        @State private var query = "query"

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Field", text: $text)
                    .frame(width: 200)
                    .onSubmit { record.submits += 1 }
                    .onChange(of: text, initial: true) { record.text = text }
                Button("Tap") { record.taps += 1 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { record.button = $0 }
                TextEditor(text: $notes)
                    .frame(width: 200, height: 60)
                LibrarySearchField(text: $query, prompt: "Search")
                    .onChange(of: query, initial: true) { record.query = query }
                Spacer()
            }
            .padding(20)
            .frame(width: 600, height: 400, alignment: .topLeading)
        }
    }

    private struct Presenter: View {
        let popover: Bool
        @State private var text = "typed"

        var body: some View {
            Color.clear
                .frame(width: 600, height: 400)
                .overlay {
                    Color.clear.frame(width: 10, height: 10)
                        .popover(isPresented: .constant(popover)) { form }
                }
                .sheet(isPresented: .constant(!popover)) { form }
        }

        private var form: some View {
            TextField("Field", text: $text)
                .frame(width: 200)
                .padding(40)
        }
    }

    private struct Sidebar: View {
        let record: Record
        @State private var searchText = "general"

        var body: some View {
            SettingsSidebar(selection: .constant(.general), searchText: $searchText, pendingSearchAnchor: .constant(nil))
                .frame(width: SettingsWindowMetrics.sidebarColumnWidth, height: 400)
                .onChange(of: searchText, initial: true) { record.query = searchText }
        }
    }

    @MainActor
    private final class Host {
        let window = ParkedTestWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )

        init(_ root: some View) {
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.parkOffScreen()
            window.makeKey()
        }

        func close() {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            window.childWindows?.forEach { $0.close() }
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    // MARK: Page

    @Test("A click on blank page space ends editing, keeps what was typed and submits nothing", .timeLimit(.minutes(1)))
    func blankClickEndsEditing() async throws {
        let record = Record()
        let host = Host(Page(record: record))
        defer { host.close() }
        let field = try await Self.focus(Self.field(holding: "typed", in: host.window), in: host.window)
        let editor = try #require(host.window.firstResponder as? NSTextView)
        editor.moveToEndOfDocument(nil)
        editor.insertText("!", replacementRange: editor.selectedRange())

        try await Self.click(Self.blankPoint(in: host.window, avoiding: field), in: host.window)
        let ended = await Self.settle { !Self.isEditing(field, in: host.window) }
        #expect(ended, "the field kept the keyboard after a click on blank page space")
        #expect(record.text == "typed!", "the click outside dropped what was typed")
        #expect(record.submits == 0, "the click outside submitted the field as Return would")
    }

    @Test("A click on a button ends editing and the button still acts once", .timeLimit(.minutes(1)))
    func buttonClickEndsEditing() async throws {
        let record = Record()
        let host = Host(Page(record: record))
        defer { host.close() }
        let field = try await Self.focus(Self.field(holding: "typed", in: host.window), in: host.window)
        let button = record.button
        try #require(!button.isEmpty, "the button never reported its frame")
        await Self.click(NSPoint(x: button.midX, y: host.window.frame.height - button.midY), in: host.window)
        let ended = await Self.settle { !Self.isEditing(field, in: host.window) }
        #expect(ended, "the field kept the keyboard after a click on a button")
        #expect(record.taps == 1, "the button acted \(record.taps) times instead of once")
    }

    @Test("A click inside the field being edited keeps it editing", .timeLimit(.minutes(1)))
    func clickInsideKeepsEditing() async throws {
        let host = Host(Page(record: Record()))
        defer { host.close() }
        let field = try await Self.focus(Self.field(holding: "typed", in: host.window), in: host.window)

        await Self.click(Self.center(of: field), in: host.window)
        await Self.settle(seconds: 0.3)
        #expect(Self.isEditing(field, in: host.window), "a click inside the field took its keyboard away")
    }

    @Test("A click outside a multi-line editor ends its editing", .timeLimit(.minutes(1)))
    func textEditorEndsEditing() async throws {
        let host = Host(Page(record: Record()))
        defer { host.close() }
        await Self.settle { Self.editables(in: host.window).contains { ($0 as? NSTextView)?.string == "notes" } }
        let found = Self.editables(in: host.window).first { ($0 as? NSTextView)?.string == "notes" }
        let editor = try await Self.focus(#require(found, "the page has no multi-line editor"), in: host.window)

        try await Self.click(Self.blankPoint(in: host.window, avoiding: editor), in: host.window)
        let ended = await Self.settle { !Self.isEditing(editor, in: host.window) }
        #expect(ended, "the multi-line editor kept the keyboard after a click outside it")
    }

    // MARK: Separate windows

    @Test("A click on blank space in a sheet ends the sheet field's editing", .timeLimit(.minutes(1)))
    func sheetBlankClickEndsEditing() async throws {
        let host = Host(Presenter(popover: false))
        defer { host.close() }
        await Self.settle { host.window.attachedSheet != nil }
        let sheet = try #require(host.window.attachedSheet, "the sheet never came up")
        try await Self.endsEditingOnBlankClick(in: sheet)
    }

    @Test("A click on blank space in a popover ends the popover field's editing", .timeLimit(.minutes(1)))
    func popoverBlankClickEndsEditing() async throws {
        let host = Host(Presenter(popover: true))
        defer { host.close() }
        await Self.settle { host.window.childWindows?.isEmpty == false }
        let popover = try #require(host.window.childWindows?.first, "the popover never came up")
        try await Self.endsEditingOnBlankClick(in: popover)
    }

    // MARK: Clear buttons

    @Test("The library search field's clear button empties it and leaves it editing", .timeLimit(.minutes(1)))
    func librarySearchClearKeepsEditing() async throws {
        let record = Record()
        let host = Host(Page(record: record))
        defer { host.close() }
        let field = try await Self.focus(Self.field(holding: "query", in: host.window), in: host.window)

        await Self.click(Self.clearButton(after: field), in: host.window)
        let cleared = await Self.settle { record.query.isEmpty }
        try #require(cleared, "control: the click missed the clear button")
        await Self.settle(seconds: 0.3)
        #expect(Self.isEditing(field, in: host.window), "the clear button took the keyboard away from the search field")
    }

    @Test("The settings sidebar search's clear button empties it and leaves it editing", .timeLimit(.minutes(1)))
    func settingsSearchClearKeepsEditing() async throws {
        let record = Record()
        let host = Host(Sidebar(record: record))
        defer { host.close() }
        let field = try await Self.focus(Self.field(holding: "general", in: host.window), in: host.window)

        await Self.click(Self.clearButton(after: field), in: host.window)
        let cleared = await Self.settle { record.query.isEmpty }
        try #require(cleared, "control: the click missed the clear button")
        await Self.settle(seconds: 0.3)
        #expect(Self.isEditing(field, in: host.window), "the clear button took the keyboard away from the settings search")
    }

    // MARK: Helpers

    private static func endsEditingOnBlankClick(in window: NSWindow) async throws {
        window.makeKey()
        let found = editables(in: window).first
        let field = try await focus(#require(found, "\(type(of: window)) has no text field"), in: window)
        try await click(blankPoint(in: window, avoiding: field), in: window)
        let ended = await settle { !isEditing(field, in: window) }
        #expect(ended, "the field in \(type(of: window)) kept the keyboard after a click on blank space")
    }

    private static func field(holding value: String, in window: NSWindow) async throws -> NSView {
        await settle { editables(in: window).contains { ($0 as? NSTextField)?.stringValue == value } }
        let found = editables(in: window).first { ($0 as? NSTextField)?.stringValue == value }
        return try #require(found, "no text field holds '\(value)'")
    }

    private static func focus(_ view: NSView, in window: NSWindow) async throws -> NSView {
        window.makeFirstResponder(view)
        let focused = await settle { isEditing(view, in: window) }
        try #require(focused, "control: the field never took the keyboard")
        await settle(seconds: 0.3)
        return view
    }

    private static func isEditing(_ view: NSView, in window: NSWindow) -> Bool {
        guard let text = window.firstResponder as? NSTextView else { return false }
        return text === view || (text.delegate as? NSView) === view
    }

    private static func editables(in window: NSWindow) -> [NSView] {
        guard let content = window.contentView else { return [] }
        var found: [NSView] = []
        var pending = [content]
        while let view = pending.popLast() {
            pending += view.subviews
            if (view as? NSTextField)?.isEditable == true || (view as? NSTextView).map({ $0.isEditable && !$0.isFieldEditor }) == true {
                found.append(view)
            }
        }
        return found
    }

    private static func center(of view: NSView) -> NSPoint {
        let frame = view.convert(view.bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// The clear glyph sits one `Spacing.sm` gap after the field and is about 12pt wide.
    private static func clearButton(after field: NSView) -> NSPoint {
        let frame = field.convert(field.bounds, to: nil)
        return NSPoint(x: frame.maxX + DesignTokens.Spacing.sm + 6, y: frame.midY)
    }

    /// A point inset from a content corner whose hit view is neither the field nor one AppKit would focus on its own.
    private static func blankPoint(in window: NSWindow, avoiding field: NSView) throws -> NSPoint {
        let content = try #require(window.contentView)
        let root = try #require(content.superview)
        let bounds = content.convert(content.bounds, to: nil).insetBy(dx: 14, dy: 14)
        let corners = [
            NSPoint(x: bounds.maxX, y: bounds.minY), NSPoint(x: bounds.minX, y: bounds.minY),
            NSPoint(x: bounds.maxX, y: bounds.maxY), NSPoint(x: bounds.minX, y: bounds.maxY),
        ]
        let blank = corners.first { point in
            guard let hit = root.hitTest(point) else { return false }
            return hit.isDescendant(of: content) && !hit.isDescendant(of: field) && !hit.acceptsFirstResponder
        }
        return try #require(blank, "\(type(of: window)) has no blank corner to click")
    }

    /// Through `NSApp`, so local event monitors see the click the way a real one reaches them.
    private static func click(_ point: NSPoint, in window: NSWindow) async {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else {
                Issue.record("could not build a \(type) event")
                return
            }
            NSApp.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Polls until `condition` holds or `seconds` pass; returns whether it held.
    @discardableResult
    private static func settle(seconds: Double = 2, until condition: () -> Bool = { false }) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
