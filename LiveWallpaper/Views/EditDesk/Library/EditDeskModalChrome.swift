import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// SCREENS.md S4's modal shell with none of the library's own content: scrim, panel box, open and
/// close motion, and the two key equivalents every Edit Desk modal shares. The caller draws its
/// panel in the closure and keeps its own floating layers, gestures and remaining keys outside.
@MainActor
struct EditDeskModalChrome<Panel: View>: View {
    /// The stage's own `bounds.size`. A `GeometryReader` here would measure one title bar short.
    let windowSize: CGSize
    /// Height the scrim leaves untouched so the traffic lights and window drag still work.
    var titlebarInset: CGFloat = DesignTokens.EditDesk.Spacing.topBar
    /// Source image for the wash behind the panel fill; nil draws the fill alone.
    var backdrop: CGImage?
    var panelFrameOverride: CGRect?
    let onDismiss: () -> Void
    /// True when the panel consumed ESC itself, which keeps the modal open.
    var onEscape: () -> Bool = { false }
    /// The bare ⌘1…⌘9 index; this container never resolves it to a display.
    var onTargetShortcut: ((Int) -> Void)?
    @ViewBuilder let panel: (CGRect) -> Panel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var targetShortcutIndices: ClosedRange<Int> {
        1 ... 9
    }

    var panelFrame: CGRect {
        panelFrameOverride ?? ModalGeometry.panelFrame(in: windowSize)
    }

    var body: some View {
        let frame = panelFrame
        ZStack(alignment: .topLeading) {
            DesignTokens.EditDesk.Colors.modalScrim
                .allowsHitTesting(false)
                .transition(.opacity.animation(openAnimation))
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .padding(.top, titlebarInset)
            panelBox(frame)
                .offset(x: frame.minX, y: frame.minY)
                .transition(panelTransition)
            shortcuts
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func escape() {
        guard !onEscape() else { return }
        onDismiss()
    }

    // MARK: Panel

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.modal, style: .continuous)
    }

    private func panelBox(_ frame: CGRect) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                GlassIconButton("xmark", action: escape)
                    .accessibilityLabel(Text("Close"))
                    .help(Text("Close"))
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: ModalGeometry.headerHeight)
            panel(frame)
                .frame(height: frame.height - ModalGeometry.headerHeight)
        }
        .frame(width: frame.width, height: frame.height)
        .background {
            ZStack {
                DesignTokens.Colors.pageBackground
            }
            .clipShape(panelShape)
        }
        .overlay(panelShape.strokeBorder(DesignTokens.EditDesk.Colors.strokePanel, lineWidth: 1))
        .compositingGroup()
        .shadow(
            color: DesignTokens.EditDesk.Shadow.modal.color,
            radius: DesignTokens.EditDesk.Shadow.modal.radius,
            y: DesignTokens.EditDesk.Shadow.modal.y
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Keyboard

    /// Key equivalents ride zero-sized buttons rather than `onKeyPress`: the stage's `NSView` is
    /// usually first responder and swallows `keyDown` while the modal blocks it.
    private var shortcuts: some View {
        ZStack {
            Button(action: escape) { EmptyView() }
                .keyboardShortcut(.cancelAction)
            if let onTargetShortcut {
                ForEach(Self.targetShortcutIndices, id: \.self) { index in
                    Button { onTargetShortcut(index) } label: { EmptyView() }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Motion

    private var openAnimation: Animation {
        reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.82)
    }

    private var panelTransition: AnyTransition {
        if reduceMotion {
            return .opacity.animation(openAnimation)
        }
        return .scale(scale: 0.92).combined(with: .opacity).animation(openAnimation)
    }
}
