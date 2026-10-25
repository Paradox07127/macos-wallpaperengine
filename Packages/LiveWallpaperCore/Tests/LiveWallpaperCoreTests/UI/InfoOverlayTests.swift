import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Information overlay interaction")
struct InfoOverlayTests {
    @Test("An overlay disables covered controls while keeping its own controls enabled", .timeLimit(.minutes(1)))
    func coveredControlsAreDisabledUntilDismissal() async throws {
        let values = EnablementValues()
        let host = NSHostingView(rootView: fixture(shown: false, values: values))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        for shown in [false, true, false] {
            host.rootView = fixture(shown: shown, values: values)
            let deadline = ContinuousClock.now + .seconds(2)
            while values.background != !shown || (shown && values.overlay != true), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(values.background != nil, "The background control was never hosted")
            #expect(values.background == !shown)
            if shown {
                try #require(values.overlay != nil, "The overlay control was never hosted")
                #expect(values.overlay == true)
            }
        }
    }

    private func fixture(shown: Bool, values: EnablementValues) -> some View {
        EnablementProbe { values.background = $0 }
            .infoOverlay(isPresented: .constant(shown)) { _ in
                EnablementProbe { values.overlay = $0 }.frame(width: 200, height: 100)
            }
    }
}

@MainActor
private final class EnablementValues {
    var background: Bool?
    var overlay: Bool?
}

private struct EnablementProbe: NSViewRepresentable {
    let record: (Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Control", target: nil, action: nil)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
        record(button.isEnabled)
    }
}
