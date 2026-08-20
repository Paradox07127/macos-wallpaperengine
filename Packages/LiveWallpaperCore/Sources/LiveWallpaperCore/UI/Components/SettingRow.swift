import SwiftUI

/// Inspector row pairing an icon-prefixed title with a trailing control.
///
/// Use `info` for "what does this do" explanations and keep `subtitle` for
/// live state ("Browsing data is cleared on each session") so the two roles
/// don't bleed into each other.
/// A small, uniform status seal rendered right after a `SettingRow` title (icon-only).
public struct SettingRowTitleBadge {
    let systemImage: String
    let tint: Color
    let accessibilityLabel: Text
    public init(systemImage: String, tint: Color, accessibilityLabel: Text) {
        self.systemImage = systemImage
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct SettingRow<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: Text
    let titleBadge: SettingRowTitleBadge?
    let subtitle: Text?
    let info: String.LocalizationValue?
    let content: Content
    /// Set for subtitles that carry a runtime value rather than prose. Prose
    /// wraps; a value stays on one line so a long path can't make its row
    /// taller than the rows around it.
    let subtitleIsValue: Bool
    /// Full text of a truncated value subtitle, for hover.
    let subtitleHelp: String?

    public init(
        icon: String,
        iconColor: Color = .accentColor,
        title: LocalizedStringKey,
        titleBadge: SettingRowTitleBadge? = nil,
        subtitle: LocalizedStringKey? = nil,
        info: String.LocalizationValue? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = Text(title, bundle: .main)
        self.titleBadge = titleBadge
        self.subtitle = subtitle.map { Text($0, bundle: .main) }
        self.info = info
        self.content = content()
        self.subtitleIsValue = false
        self.subtitleHelp = nil
    }

    /// Localized title over a runtime value — a file path, an account name.
    /// The value is rendered verbatim (never looked up in the catalog) and
    /// truncated in the middle to one line, with the whole of it on hover.
    public init(
        icon: String,
        iconColor: Color = .accentColor,
        title: LocalizedStringKey,
        valueSubtitle: String?,
        titleBadge: SettingRowTitleBadge? = nil,
        info: String.LocalizationValue? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = Text(title, bundle: .main)
        self.titleBadge = titleBadge
        self.subtitle = valueSubtitle.map { Text(verbatim: $0) }
        self.info = info
        self.content = content()
        self.subtitleIsValue = true
        self.subtitleHelp = valueSubtitle
    }

    /// Verbatim variant for already-resolved runtime/author strings (e.g. a
    /// Wallpaper Engine property display name) that must NOT be re-looked-up in
    /// the localization catalog. Distinct `verbatim*` labels avoid overload
    /// ambiguity with the `LocalizedStringKey` initializer at string-literal call sites.
    public init(
        icon: String,
        iconColor: Color = .accentColor,
        verbatimTitle: String,
        verbatimSubtitle: String? = nil,
        titleBadge: SettingRowTitleBadge? = nil,
        info: String.LocalizationValue? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = Text(verbatim: verbatimTitle)
        self.titleBadge = titleBadge
        self.subtitle = verbatimSubtitle.map { Text(verbatim: $0) }
        self.info = info
        self.content = content()
        self.subtitleIsValue = false
        self.subtitleHelp = nil
    }

    /// Mixed variant: author-supplied title rendered verbatim, app-supplied
    /// subtitle routed through the localization catalog (e.g. a WPE property
    /// row annotated with an app-side "Not supported" note).
    public init(
        icon: String,
        iconColor: Color = .accentColor,
        verbatimTitle: String,
        subtitle: LocalizedStringKey,
        titleBadge: SettingRowTitleBadge? = nil,
        info: String.LocalizationValue? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = Text(verbatim: verbatimTitle)
        self.titleBadge = titleBadge
        self.subtitle = Text(subtitle, bundle: .main)
        self.info = info
        self.content = content()
        self.subtitleIsValue = false
        self.subtitleHelp = nil
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(iconColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    title
                        .font(.body.weight(.medium))
                        .marqueeOnHover(truncationMode: .tail)
                    if let titleBadge {
                        Image(systemName: titleBadge.systemImage)
                            .font(.caption)
                            .foregroundStyle(titleBadge.tint)
                            .accessibilityLabel(titleBadge.accessibilityLabel)
                    }
                    if let info {
                        InfoTooltipButton(text: info)
                    }
                }
                if let subtitle = subtitle {
                    if subtitleIsValue {
                        subtitle
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .marqueeOnHover()
                            .help(Text(verbatim: subtitleHelp ?? ""))
                    } else {
                        subtitle
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            content
        }
        .controlSize(.small)
        .padding(.vertical, 3)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

/// ⓘ glyph that exposes the same explanation through hover (tooltip) and
/// click (popover). Public so inspector rows that don't use `SettingRow`
/// (e.g. compact slider grids) can adopt the same pattern.
public struct InfoTooltipButton: View {
    let text: String.LocalizationValue
    @State private var isPresentingPopover = false
    @AppStorage(AppLanguagePreference.storageKey) private var rawPreference = AppLanguagePreference.system.rawValue

    public init(text: String.LocalizationValue) {
        self.text = text
    }

    public var body: some View {
        Button {
            isPresentingPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(localizedText)
        .accessibilityLabel(Text("More information", bundle: .main))
        .accessibilityHint(Text(verbatim: localizedText))
        .popover(isPresented: $isPresentingPopover, arrowEdge: .top) {
            Text(verbatim: localizedText)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }

    private var localizedText: String {
        let preference = AppLanguagePreference(rawValue: rawPreference) ?? .system
        return String(
            localized: text,
            bundle: preference.localizationBundle(in: .main),
            locale: preference.locale
        )
    }
}
