import AppKit
import SwiftUI

/// Where the banner sits, which decides its container. DESIGN.md rule 11 tiers
/// glass by position, not by role: chrome floating over/under a preview takes
/// glass, a banner in the content column takes a native content surface.
/// Below this the message column stops being readable and the banner stacks
/// instead. Measured: at 420pt with three recovery buttons the side-by-side
/// layout wrapped the title to one word per line.
private let minimumNoticeMessageWidth: CGFloat = 200

public enum NoticeBannerSurface: Sendable {
    /// Inside a preview stage / HUD.
    case chrome
    /// In the content column, above or beside page content.
    case content
}

/// Icon + title + message + optional copyable code, with up to two trailing
/// actions. The one shape for inline notices — three near-identical hand-rolled
/// copies of it had drifted apart in typography, container and severity colour.
public struct InlineNoticeBanner<Actions: View>: View {
    private let tint: Color
    private let symbol: String
    private let title: Text
    private let message: Text?
    private let detail: String?
    private let code: String?
    private let surface: NoticeBannerSurface
    private let accessibilityDetail: String?
    private let actions: Actions

    /// - Parameters:
    ///   - detail: A secondary technical line (path, URL) shown middle-truncated.
    ///   - code: Stable error code. Rendered as a copyable chip — the code is
    ///     what a bug report needs, so it must be reachable by pointer and by
    ///     VoiceOver, not painted into decoration.
    public init(
        tint: Color,
        symbol: String,
        title: Text,
        message: Text? = nil,
        detail: String? = nil,
        code: String? = nil,
        surface: NoticeBannerSurface = .content,
        accessibilityDetail: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.tint = tint
        self.symbol = symbol
        self.title = title
        self.message = message
        self.detail = detail
        self.code = code
        self.surface = surface
        self.accessibilityDetail = accessibilityDetail
        self.actions = actions()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                glyph
                messageColumn
                    // `idealWidth` is what ViewThatFits measures. Without it a
                    // wrapping Text reports its single-line width, so a merely
                    // long message made the side-by-side layout look impossible
                    // and every banner stacked.
                    .frame(
                        minWidth: minimumNoticeMessageWidth,
                        idealWidth: minimumNoticeMessageWidth,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                Spacer(minLength: DesignTokens.Spacing.sm)
                actionRow
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    glyph
                    messageColumn
                }
                actionRow
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NoticeBannerBackground(surface: surface, tint: tint))
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(DesignTokens.Typography.sectionTitle)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private var messageColumn: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                title
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    message
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(DesignTokens.Typography.codeCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // Kept out of the combined element so the chip stays its own
            // focusable control for VoiceOver.
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(verbatim: accessibilityDetail ?? detail ?? ""))

            // Under the diagnosis, not in the action row: competing with the
            // buttons for the trailing edge truncated it to "WPE_RESOU…", and
            // a code you cannot read is not a code you can report.
            if let code, !code.isEmpty {
                ErrorCodeChip(code: code, tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The recovery buttons keep their intrinsic width; the message column is
    /// what wraps, and when even that stops fitting the whole banner stacks.
    private var actionRow: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            actions
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The stable error code, as something a reader can actually take away: it is
/// what a bug report needs, so it must be reachable by pointer and by VoiceOver
/// rather than painted into decoration.
public struct ErrorCodeChip: View {
    private let code: String
    private let tint: Color
    @State private var didCopy = false

    public init(code: String, tint: Color) {
        self.code = code
        self.tint = tint
    }

    public var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(code, forType: .string)
            didCopy = true
        } label: {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .imageScale(.small)
                Text(verbatim: code)
                    .font(DesignTokens.Typography.codeCaption)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .background(Capsule().fill(tint.opacity(DesignTokens.Opacity.selectedFill)))
        }
        .buttonStyle(.borderless)
        .animation(.snappy, value: didCopy)
        // Latching on the checkmark leaves no affordance for a second copy after
        // something else has taken the clipboard.
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
        .help(Text("Copy the error code", bundle: .appLanguage, comment: "Tooltip on a copyable error-code chip."))
        .accessibilityLabel(Text("Error code \(code)", bundle: .appLanguage, comment: "A11y label for the error-code chip. The placeholder is a stable error code such as WPE_SCENE_PARSE."))
        .accessibilityHint(Text("Copies the error code to the clipboard", bundle: .appLanguage, comment: "A11y hint for the error-code chip."))
    }
}

public extension InlineNoticeBanner where Actions == EmptyView {
    init(
        tint: Color,
        symbol: String,
        title: Text,
        message: Text? = nil,
        detail: String? = nil,
        code: String? = nil,
        surface: NoticeBannerSurface = .content,
        accessibilityDetail: String? = nil
    ) {
        self.init(
            tint: tint,
            symbol: symbol,
            title: title,
            message: message,
            detail: detail,
            code: code,
            surface: surface,
            accessibilityDetail: accessibilityDetail
        ) { EmptyView() }
    }
}

/// Split out so the `.chrome` branch's glass and the `.content` branch's opaque
/// surface stay one decision in one place.
private struct NoticeBannerBackground: ViewModifier {
    let surface: NoticeBannerSurface
    let tint: Color

    func body(content: Content) -> some View {
        switch surface {
        case .chrome:
            content
                .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.md), tint: tint)
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                        .strokeBorder(tint.opacity(DesignTokens.Opacity.quietStroke), lineWidth: 1)
                }
        case .content:
            content
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                        .fill(DesignTokens.Colors.surfaceRaised)
                        .overlay {
                            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                                .fill(tint.opacity(DesignTokens.Opacity.activeFill))
                        }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                        .strokeBorder(tint.opacity(DesignTokens.Opacity.quietStroke), lineWidth: 1)
                }
        }
    }
}
