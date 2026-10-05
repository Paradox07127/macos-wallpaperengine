#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct StorageDashboardTile<Value: View, Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let accent: Color
    let subtitle: Text?
    @ViewBuilder var value: () -> Value
    @ViewBuilder var actions: () -> Actions

    init(
        title: LocalizedStringKey,
        systemImage: String,
        accent: Color,
        subtitle: Text? = nil,
        @ViewBuilder value: @escaping () -> Value,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.subtitle = subtitle
        self.value = value
        self.actions = actions
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                            .fill(accent.opacity(0.16))
                            .frame(width: 30, height: 30)
                        Image(systemName: systemImage)
                            .font(DesignTokens.Typography.bodyEmphasized)
                            .foregroundStyle(accent)
                    }
                    .accessibilityHidden(true)

                    Spacer(minLength: DesignTokens.Spacing.sm)

                    HStack(spacing: DesignTokens.Spacing.xs) {
                        actions()
                    }
                }

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    value()
                        .frame(minHeight: 30, alignment: .leading)

                    Text(title)
                        .font(DesignTokens.Typography.bodyEmphasized)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle {
                        subtitle
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .settingsSearchRow(title)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

struct StorageInfoButton<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(Text("Details"))
        .accessibilityLabel(Text("Details"))
        .appLanguagePopover(isPresented: $isPresented, arrowEdge: .bottom) {
            content().padding(DesignTokens.Spacing.cardInset)
        }
    }
}

#endif
