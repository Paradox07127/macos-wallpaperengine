import AppKit
import LiveWallpaperCore
import SwiftUI

extension View {
    /// `.popover` whose content reads the in-app language: a popover does not inherit `\.locale` from the window.
    func appLanguagePopover(
        isPresented: Binding<Bool>, arrowEdge: Edge, @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            AppLanguageScope(defaults: .appScoped()) {
                content()
            }
        }
        .modifier(PopoverEscape(isPresented: isPresented))
    }
}

/// Escape closes the open popover and goes no further: a local monitor sees the key before the window's
/// `.cancelAction` shortcut, which would otherwise close the page under the popover.
private struct PopoverEscape: ViewModifier {
    @Binding var isPresented: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, shown in
                shown ? watch() : stop()
            }
            .onDisappear(perform: stop)
    }

    private func watch() {
        guard monitor == nil else { return }
        let isPresented = $isPresented
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { isPresented.wrappedValue = false }
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
