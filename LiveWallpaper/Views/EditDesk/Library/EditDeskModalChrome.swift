import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// The Edit Desk detail modal's shell: scrim, panel box, the title row that ends in the close button,
/// ← and → beside the panel, open and close motion, and ESC, ⌘n and the arrow keys. The caller draws the
/// body in the closure and keeps its own floating layers, gestures and remaining keys outside.
@MainActor
struct EditDeskModalChrome<Panel: View>: View {
    /// The stage's own `bounds.size`. A `GeometryReader` here would measure one title bar short.
    let windowSize: CGSize
    /// Height the scrim leaves untouched so the traffic lights and window drag still work.
    var titlebarInset: CGFloat = DesignTokens.EditDesk.Spacing.topBar
    /// Leads the row the close button ends; empty leaves the close button alone on it.
    var title = ""
    /// The shown item, whose change fades the title row; nil falls back to `title` to detect a page turn.
    var pageID: String?
    /// Icon buttons between the title and the close button, in order; `ModalHeaderAction.group` splits them into capsules.
    var actions: [ModalHeaderAction] = []
    let onDismiss: () -> Void
    /// True when the panel consumed ESC itself, which keeps the modal open.
    var onEscape: () -> Bool = { false }
    /// The bare ⌘1…⌘9 index; this container never resolves it to a display.
    var onTargetShortcut: ((Int) -> Void)?
    /// nil greys the arrow out and drops its key: there is no item that way.
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var shortcutIdentity: String?
    @ViewBuilder let panel: (CGRect) -> Panel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var targetShortcutIndices: ClosedRange<Int> {
        1 ... 9
    }

    var panelFrame: CGRect {
        ModalGeometry.panelFrame(in: windowSize)
    }

    var body: some View {
        let frame = panelFrame
        ZStack(alignment: .topLeading) {
            DesignTokens.EditDesk.Colors.modalScrim
                .allowsHitTesting(false)
                .transition(.asymmetric(insertion: .opacity.animation(openAnimation), removal: .opacity.animation(closeAnimation)))
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .padding(.top, titlebarInset)
            panelBox(frame)
                .offset(x: frame.minX, y: frame.minY)
                .transition(panelTransition)
            shortcuts
                .id(shortcutIdentity)
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
        VStack(spacing: ModalGeometry.sectionGap) {
            header
            panel(frame)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, ModalGeometry.topPadding)
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
        // On the panel rather than the scrim, so they share its modal element and its open and close motion.
        .overlay(alignment: .topLeading) { arrows(beside: frame.size) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func arrows(beside size: CGSize) -> some View {
        let frames = ModalGeometry.arrowFrames(beside: CGRect(origin: .zero, size: size))
        return ZStack(alignment: .topLeading) {
            GlassIconButton("chevron.left") { onPrevious?() }
                .frame(width: ModalGeometry.iconButtonSize, height: ModalGeometry.iconButtonSize)
                .disabled(onPrevious == nil)
                .help(Text("Show Previous Wallpaper (←)", comment: "Wallpaper modal tooltip; the arrow is the key that does the same."))
                .accessibilityLabel(Text("Show Previous Wallpaper"))
                .offset(x: frames.previous.minX, y: frames.previous.minY)
            GlassIconButton("chevron.right") { onNext?() }
                .frame(width: ModalGeometry.iconButtonSize, height: ModalGeometry.iconButtonSize)
                .disabled(onNext == nil)
                .help(Text("Show Next Wallpaper (→)", comment: "Wallpaper modal tooltip; the arrow is the key that does the same."))
                .accessibilityLabel(Text("Show Next Wallpaper"))
                .offset(x: frames.next.minX, y: frames.next.minY)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text(verbatim: title.translatedWallpaperName)
                .font(DesignTokens.EditDesk.Typography.modalTitle)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: ModalGeometry.iconButtonSize, alignment: .leading)
                .wpeAuthorLabelHelp(title.wallpaperNameHelp)
                .wpeTranslateWallpaperName(title)
            if !actions.isEmpty {
                AdaptiveGlassContainer(spacing: GlassToolbarMetrics.containerSpacing) {
                    HStack(spacing: GlassToolbarMetrics.groupSpacing) {
                        ForEach(Array(ModalHeaderAction.groups(actions).enumerated()), id: \.offset) { _, group in
                            GlassToolbarGroup(size: .compact) {
                                ForEach(group) { action in
                                    GlassToolbarItem(
                                        action.symbol, tint: action.tint, role: action.isDestructive ? .destructive : nil,
                                        action: action.perform
                                    )
                                    .help(Text(verbatim: action.title))
                                    .accessibilityLabel(Text(verbatim: action.title))
                                }
                            }
                        }
                    }
                }
            }
            GlassIconButton("xmark", action: escape)
                .accessibilityLabel(Text("Close"))
                .help(Text("Close"))
                .padding(.leading, DesignTokens.Spacing.sm)
        }
        .contentTransition(.opacity)
        .animation(ModalPageMotion.animation(reduceMotion: reduceMotion), value: pageID ?? title)
        .padding(.horizontal, ModalGeometry.horizontalPadding)
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
            if let onPrevious {
                Button(action: onPrevious) { EmptyView() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            if let onNext {
                Button(action: onNext) { EmptyView() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Motion

    private var openAnimation: Animation {
        DesignTokens.Motion.modalPresentation(reduceMotion: reduceMotion)
    }

    private var closeAnimation: Animation {
        DesignTokens.Motion.modalDismissal(reduceMotion: reduceMotion)
    }

    private var panelTransition: AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: .opacity.animation(openAnimation), removal: .opacity.animation(closeAnimation))
        }
        return .asymmetric(
            insertion: .scale(scale: 0.92).combined(with: .opacity).animation(openAnimation),
            removal: .scale(scale: 0.98).combined(with: .opacity).animation(closeAnimation)
        )
    }
}
