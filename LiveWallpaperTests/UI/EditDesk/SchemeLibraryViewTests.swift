import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Scheme library view", .serialized)
struct SchemeLibraryViewTests {
    @Test("The scheme date order reads Recent, while the wallpaper library keeps Recently Used")
    func dateOrderTitle() {
        #expect(SchemeLibraryView.sortTitle(.recentlyUsed) == LocalizedStringKey("Recent"), "schemes claim a use order nothing records")
        #expect(SchemeLibraryView.sortTitle(.name) == LibraryChipsRow.sortTitle(.name))
        #expect(LibraryChipsRow.sortTitle(.recentlyUsed) == LocalizedStringKey("Recently Used"))
    }

    @Test("Leaving the view lets go of what the detail modal's apply captured")
    func leavingReleasesTheApplyCapture() async {
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
        defer { manager.tearDownForTermination() }
        let details = SchemeDetailPresenter()
        let mount = SchemeLibraryViewTestMount()
        weak var released: LibraryDragController?
        do {
            let drag = LibraryDragController()
            released = drag
            mount.drag = drag
        }
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .standard) {
            SchemeLibraryMount(mount: mount, details: details)
                .environment(manager)
                .frame(width: 1280, height: 820)
        })
        let window = ParkedTestWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let appeared = ContinuousClock.now + .seconds(2)
        while !mount.appeared, ContinuousClock.now < appeared {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(mount.appeared, "the view never appeared, so leaving it proves nothing")

        mount.drag = nil
        let gone = ContinuousClock.now + .seconds(2)
        while released != nil, ContinuousClock.now < gone {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(mount.disappeared, "the view never disappeared, so nothing reset the apply")
        #expect(released == nil, "the presenter still holds the departed view through requestApply")
    }
}

@MainActor @Observable
final class SchemeLibraryViewTestMount {
    var drag: LibraryDragController?
    var appeared = false
    var disappeared = false
}

/// Reads `mount.drag` in its own body so dropping it removes the library view.
private struct SchemeLibraryMount: View {
    let mount: SchemeLibraryViewTestMount
    let details: SchemeDetailPresenter

    var body: some View {
        if let drag = mount.drag {
            SchemeLibraryView(drag: drag, details: details) { _, _ in }
                .task { mount.appeared = true }
                .onDisappear { mount.disappeared = true }
        }
    }
}
