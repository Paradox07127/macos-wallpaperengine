import SwiftUI

/// Delay hover-in to avoid activating cards passed during scrolling; leave immediately.
/// This owns hover debounce, so thumbnail playback must not add another delay.
public extension View {
    func settledHover(
        delay: Duration = .milliseconds(150),
        _ action: @escaping (Bool) -> Void
    ) -> some View {
        modifier(SettledHoverModifier(delay: delay, action: action))
    }
}

private struct SettledHoverModifier: ViewModifier {
    let delay: Duration
    let action: (Bool) -> Void

    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                guard hovering else {
                    action(false)
                    return
                }
                pending = Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    action(true)
                }
            }
            .onDisappear {
                pending?.cancel()
                pending = nil
            }
    }
}
