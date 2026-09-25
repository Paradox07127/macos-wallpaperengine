import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// The detail modal's body under the chrome's title row: the preview between ← and → with the fact
/// rows and tags under it, the item's sections on the right, and the status line over the centred
/// display buttons at the bottom. Both columns scroll together; the bottom stays put.
@MainActor
struct WallpaperDetailLayout<Preview: View, Sidebar: View, Status: View, Buttons: View>: View {
    let facts: [WallpaperFact]
    /// The last row under the facts.
    var tags: [WallpaperTagChip] = []
    /// Makes the author's name a link; nil leaves it text.
    var authorLink: WallpaperAuthorLink?
    /// Takes a chip's raw tag; nil leaves the chips unclickable.
    var onSelectTag: (@MainActor (String) -> Void)?
    /// nil greys the arrow out and drops its key: there is no item that way.
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let status: () -> Status
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: ModalGeometry.sectionGap) {
            ScrollView {
                HStack(alignment: .top, spacing: ModalGeometry.columnSpacing) {
                    leadingColumn
                    VStack(alignment: .leading, spacing: ModalGeometry.sidebarSpacing) {
                        sidebar()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, ModalGeometry.horizontalPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            VStack(spacing: DesignTokens.Spacing.sm) {
                status()
                buttons()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ModalGeometry.horizontalPadding)
            .padding(.bottom, ModalGeometry.bottomPadding)
        }
        .overlay { arrowKeys }
    }

    /// Zero-sized buttons rather than `onKeyPress`: the stage's `NSView` is usually first responder
    /// and swallows `keyDown` while the modal blocks it.
    private var arrowKeys: some View {
        ZStack {
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

    private var leadingColumn: some View {
        VStack(spacing: ModalGeometry.sectionGap) {
            HStack(spacing: ModalGeometry.arrowGap) {
                GlassIconButton("chevron.left") { onPrevious?() }
                    .frame(width: ModalGeometry.iconButtonSize, height: ModalGeometry.iconButtonSize)
                    .disabled(onPrevious == nil)
                    .help(Text("Show Previous Wallpaper (←)", comment: "Wallpaper modal tooltip; the arrow is the key that does the same."))
                    .accessibilityLabel(Text("Show Previous Wallpaper"))
                preview()
                    .frame(width: ModalGeometry.previewSize.width, height: ModalGeometry.previewSize.height)
                GlassIconButton("chevron.right") { onNext?() }
                    .frame(width: ModalGeometry.iconButtonSize, height: ModalGeometry.iconButtonSize)
                    .disabled(onNext == nil)
                    .help(Text("Show Next Wallpaper (→)", comment: "Wallpaper modal tooltip; the arrow is the key that does the same."))
                    .accessibilityLabel(Text("Show Next Wallpaper"))
            }
            WallpaperFactGrid(facts: facts, tags: tags, authorLink: authorLink, onSelectTag: onSelectTag)
                .frame(width: ModalGeometry.previewSize.width, alignment: .leading)
        }
    }
}

/// The Workshop author's row as a link: `symbol` trails the name, `help` is its tooltip and spoken name.
struct WallpaperAuthorLink {
    let symbol: String
    let help: String
    let open: @MainActor () -> Void
}

/// A detail modal's label / value rows; the tags, when there are any, are the last row.
struct WallpaperFactGrid: View {
    let facts: [WallpaperFact]
    var tags: [WallpaperTagChip] = []
    var authorLink: WallpaperAuthorLink?
    var onSelectTag: (@MainActor (String) -> Void)?

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Spacing.md, verticalSpacing: DesignTokens.Spacing.sm) {
            ForEach(facts) { fact in
                GridRow {
                    label(Text(verbatim: fact.kind.label))
                    value(fact)
                }
            }
            #if !LITE_BUILD
            if !tags.isEmpty {
                GridRow {
                    label(Text("Tags", comment: "Wallpaper detail row: the Workshop item's tags."))
                    WorkshopChipFlow(spacing: 6, lineSpacing: 4) {
                        ForEach(tags) { tag in
                            tagChip(tag)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            #endif
        }
    }

    #if !LITE_BUILD
    @ViewBuilder
    private func tagChip(_ tag: WallpaperTagChip) -> some View {
        let name = tag.label
        if let onSelectTag {
            Button { onSelectTag(tag.raw) } label: {
                StatusChip(verbatim: name, tint: .accentColor)
            }
            .buttonStyle(.plain)
            .help(Text("Browse items tagged \(name)"))
        } else {
            StatusChip(verbatim: name, tint: .secondary)
        }
    }
    #endif

    private func label(_ text: Text) -> some View {
        text
            .font(DesignTokens.EditDesk.Typography.chip)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func value(_ fact: WallpaperFact) -> some View {
        if fact.kind == .author, let authorLink {
            Button(action: authorLink.open) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: fact.value)
                        .lineLimit(1)
                    Image(systemName: authorLink.symbol)
                        .imageScale(.small)
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .font(DesignTokens.EditDesk.Typography.chip)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(Text(verbatim: authorLink.help))
            .accessibilityLabel(Text(verbatim: authorLink.help))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                if fact.kind == .rating {
                    Image(systemName: "star.fill")
                        .imageScale(.small)
                        .foregroundStyle(DesignTokens.Colors.rating)
                }
                Text(verbatim: fact.value)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DesignTokens.EditDesk.Typography.chip)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(FactHelp(text: fact.help))
        }
    }
}

/// `.help(_:)` takes a `Text`, not an optional; this keeps the tooltip off a row with nothing to add.
private struct FactHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(Text(verbatim: text))
        } else {
            content
        }
    }
}

/// A titled section of the detail modal's right column: no box, the title and the spacing group it.
struct WallpaperDetailSection<Content: View>: View {
    let title: Text
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            title.font(DesignTokens.Typography.bodyEmphasized)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if !LITE_BUILD
/// A Workshop transfer as the detail modal shows it over its buttons: status and numbers, then the bar.
struct ModalDownloadStatusLine: View {
    let presentation: WorkshopDownloadPresentation

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
                Text(verbatim: presentation.status)
                    .font(DesignTokens.EditDesk.Typography.body)
                    .foregroundStyle(
                        presentation.isFailure ? DesignTokens.EditDesk.Colors.danger : DesignTokens.EditDesk.Colors.textSecondary
                    )
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.EditDesk.Spacing.s12)
                Text(verbatim: presentation.detail)
                    .font(DesignTokens.EditDesk.Typography.metaMono)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
                    .lineLimit(1)
            }
            switch presentation.progress {
            case .none:
                EmptyView()
            case .indeterminate:
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text("Download progress"))
            case let .fraction(value):
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text("Download progress"))
                    .accessibilityValue(Text(verbatim: presentation.detail))
            }
        }
        .frame(width: ModalGeometry.statusWidth)
    }
}
#endif
