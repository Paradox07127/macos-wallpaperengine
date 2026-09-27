import AppKit
@testable import LiveWallpaper
import SwiftUI
import Testing

/// Escape with an `.appLanguagePopover` open, beside a page's `.cancelAction` the way `DisplayDetailHost` mounts it,
/// driven by real key events in an ordered-in window parked off screen.
@Suite("Popover Escape closes the popover before the page", .serialized)
@MainActor
struct PopoverEscapeTests {
    @Test("The first Escape closes only the open popover; the next one reaches the page", .timeLimit(.minutes(1)))
    func escapeClosesThePopoverFirst() async throws {
        let fixture = PopoverEscapeFixture()
        defer { fixture.close() }
        fixture.probe.presented = true
        try #require(await fixture.settle { fixture.popoverWindow != nil }, "the popover never opened, so this harness proves nothing")
        fixture.escape()
        await fixture.settle { !fixture.probe.presented || fixture.probe.closes > 0 }
        #expect(fixture.probe.closes == 0, "Escape with a popover open closed the page")
        #expect(!fixture.probe.presented, "Escape left the popover open")
        #expect(await fixture.settle { fixture.popoverWindow == nil }, "the popover window stayed on after Escape")
        fixture.escape()
        #expect(await fixture.settle { fixture.probe.closes == 1 }, "Escape after the popover closed did not reach the page")
    }
}

@MainActor
@Observable
private final class PopoverEscapeProbe {
    var presented = false
    var closes = 0
}

@MainActor
private final class PopoverEscapeFixture {
    let probe = PopoverEscapeProbe()
    private let window: NSWindow

    init() {
        let size = CGSize(width: 400, height: 300)
        window = ParkedTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PopoverEscapeHost(probe: probe).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.parkOffScreen()
        // Without it a synthesized key press reaches no key-equivalent handler.
        window.makeKey()
        host.layoutSubtreeIfNeeded()
    }

    var popoverWindow: NSWindow? {
        NSApp.windows.first { $0.parent === window && $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// Turns the run loop a few times, then polls for up to two seconds; a condition that stays false just waits it out.
    @discardableResult
    func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 5 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Through `NSApp`, so local event monitors see it the way a real key press would reach them.
    func escape() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) else {
            Issue.record("could not build the Escape key event")
            return
        }
        NSApp.sendEvent(event)
    }
}

private struct PopoverEscapeHost: View {
    @Bindable var probe: PopoverEscapeProbe

    var body: some View {
        ZStack {
            Button("Anchor") {}
                .appLanguagePopover(isPresented: $probe.presented, arrowEdge: .bottom) {
                    Text(verbatim: "Popover").frame(width: 160, height: 80)
                }
            Button { probe.closes += 1 } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }
}
