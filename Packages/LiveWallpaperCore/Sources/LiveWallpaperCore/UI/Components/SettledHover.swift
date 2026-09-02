import SwiftUI

/// `onHover` that only reports "in" once the pointer has settled, and reports
/// "out" immediately.
///
/// Scrolling a grid drags every cell under a stationary pointer, so plain
/// `onHover` fires a hover-in/hover-out pair per cell. On a gallery card that
/// pair starts three pieces of work at once — the tile's scale + shadow spring,
/// the title band growing from one line to two (a *layout* change inside a
/// `LazyVGrid`), and a marquee — none of which the user asked for and none of
/// which finishes before the next cell arrives. `AnimatedGIFThumbnail` already
/// solved its half of this with a 250 ms decode debounce; this closes the rest
/// by settling the hover state itself, so every consumer benefits at once.
///
/// Asymmetric on purpose: delaying the "out" edge would leave chrome lit on a
/// card the pointer has already left, which reads as a stuck frame.
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
