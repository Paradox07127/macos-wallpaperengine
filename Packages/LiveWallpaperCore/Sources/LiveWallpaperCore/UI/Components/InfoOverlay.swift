import SwiftUI

public extension View {
    /// Read-only detail presented as a dismissible overlay instead of a modal sheet:
    /// clicking the scrim or pressing Escape closes it.
    ///
    /// `@Environment(\.dismiss)` does nothing useful in this content — outside a real
    /// presentation it closes the window instead — so the closure hands the content an
    /// explicit dismissal to call.
    func infoOverlay<Item: Identifiable>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item, @escaping () -> Void) -> some View
    ) -> some View {
        modifier(InfoOverlayModifier(
            isShown: item.wrappedValue != nil,
            dismiss: { item.wrappedValue = nil },
            overlayContent: { dismiss in
                if let value = item.wrappedValue {
                    content(value, dismiss)
                }
            }
        ))
    }

    /// Boolean-gated counterpart of `infoOverlay(item:content:)`.
    func infoOverlay(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping (@escaping () -> Void) -> some View
    ) -> some View {
        modifier(InfoOverlayModifier(
            isShown: isPresented.wrappedValue,
            dismiss: { isPresented.wrappedValue = false },
            overlayContent: content
        ))
    }
}

private struct InfoOverlayModifier<OverlayContent: View>: ViewModifier {
    let isShown: Bool
    let dismiss: () -> Void
    @ViewBuilder let overlayContent: (@escaping () -> Void) -> OverlayContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if isShown {
                    InfoOverlayHost(dismiss: dismiss, content: overlayContent)
                        // Opacity only: the scrim spans the window, so scaling the host
                        // would pull its edges inward and reveal the content behind it.
                        .transition(.opacity)
                }
            }
            .animation(
                DesignTokens.motion(reduceMotion, .easeOut(duration: DesignTokens.Motion.enterDuration)),
                value: isShown
            )
    }
}

private struct InfoOverlayHost<Content: View>: View {
    let dismiss: () -> Void
    @ViewBuilder let content: (@escaping () -> Void) -> Content

    @Environment(\.colorScheme) private var colorScheme

    /// Dark needs the heavier value: over a dark window a light scrim barely dims the
    /// white text behind it, which then competes with the card's own text.
    private var scrimOpacity: Double {
        colorScheme == .dark ? 0.45 : 0.28
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.sheet, style: .continuous)
    }

    var body: some View {
        ZStack {
            // Decorative scrim: literal alpha by design, like the other media scrims.
            // Deliberately inside the safe area: this window draws its content under a
            // transparent titlebar, so a scrim that ignored it would swallow clicks on the
            // close/minimise/zoom buttons. A real sheet leaves the titlebar alone too.
            Color.black.opacity(scrimOpacity)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            content(dismiss)
                // An overlay is proposed the whole window, where a sheet would have sized
                // itself to the content's ideal; without this the card fills the window.
                .fixedSize()
                // One opaque fill under the whole card, not glass: a real sheet is
                // `windowBackgroundColor`, and any content that paints its own background
                // would otherwise leave the footer strip a different shade.
                .background(DesignTokens.Colors.pageBackground)
                .clipShape(shape)
                // A sheet gets AppKit's window shadow for free; an in-window card draws its
                // own or it reads as a flat sticker over the content. A real sheet has no
                // border, so the shadow alone separates the edge.
                .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
                // Zero-sized rather than `.hidden()`: a hidden view stops taking key
                // equivalents, and Escape is the half of the contract the scrim can't cover.
                .background {
                    Button(action: dismiss) { EmptyView() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
        }
    }
}
