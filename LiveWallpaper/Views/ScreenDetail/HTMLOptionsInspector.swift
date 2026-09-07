import SwiftUI
import AppKit
import LiveWallpaperCore

/// Web compatibility and reload settings; canvas controls live on the preview bar.
struct HTMLOptionsInspector: View {
    var screen: Screen
    @Binding var config: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager
    @AppStorage("Inspector.HTMLOptionsExpanded") private var isExpanded = true
    @State private var customCSSPresented: Bool = false
    @State private var draftCustomCSS: String = ""

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Web Options",
                systemImage: "globe",
                isExpanded: $isExpanded
            ) {
                VStack(spacing: 8) {
                    physicalPixelRow
                    Divider()
                    autoRefreshRow
                    Divider()
                    customCSSRow
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    // MARK: - Rows

    private var physicalPixelRow: some View {
        SettingRow(
            icon: "rectangle.split.2x1",
            iconColor: .indigo,
            title: "Physical-pixel layout",
            info: "Uses screen pixels for pages that do not adapt to high-resolution displays."
        ) {
            Toggle("", isOn: configBinding(\.physicalPixelLayout))
                .labelsHidden()
                .accessibilityLabel(Text("Physical-pixel layout"))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    /// `0` (Off) is the default — most wallpaper content is animation/canvas-driven
    /// and doesn't benefit from a reload.
    private var autoRefreshRow: some View {
        SettingRow(
            icon: "arrow.clockwise",
            iconColor: .cyan,
            title: "Auto Refresh"
        ) {
            Picker(
                "",
                selection: configBinding(\.refreshIntervalSeconds, normalize: HTMLConfig.clampedRefreshInterval)
            ) {
                Text("Off").tag(0)
                Text("Every 1 min").tag(60)
                Text("Every 5 min").tag(300)
                Text("Every 30 min").tag(1800)
                Text("Every 1 hour").tag(3600)
                Text("Every 6 hours").tag(21600)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Auto-refresh interval"))
        }
    }

    /// Editor opens in a popover to keep the inspector list compact.
    private var customCSSRow: some View {
        let isActive = !(config.customCSS ?? "").isEmpty
        return SettingRow(
            icon: isActive ? "paintbrush.fill" : "paintbrush",
            iconColor: .pink,
            title: "Custom CSS",
            subtitle: isActive ? "Style overrides active" : nil
        ) {
            Button {
                customCSSPresented = true
            } label: {
                Text("Edit")
            }
            .fixedSize()
            .popover(isPresented: $customCSSPresented, arrowEdge: .leading) {
                AppLanguageScope(defaults: .appScoped()) {
                    customCSSEditor
                }
            }
        }
        .onAppear { scheduleCustomCSSDraftSync(config.customCSS) }
        .onChange(of: config.customCSS) { _, newValue in
            scheduleCustomCSSDraftSync(newValue)
        }
        // The view is not rebuilt per screen, so an uncommitted draft typed on
        // a previous screen would otherwise still be sitting in
        // `draftCustomCSS` when this one appears for a screen whose committed
        // CSS is unchanged (the `config.customCSS`-keyed sync above would not
        // fire in that case).
        .onChange(of: screen.id) {
            scheduleCustomCSSDraftSync(config.customCSS)
        }
    }

    private var customCSSEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Custom CSS", systemImage: "paintbrush")
                .font(.headline)

            TextEditor(text: $draftCustomCSS)
                .font(DesignTokens.Typography.code)
                .frame(width: 380, height: 200)
                .scrollContentBackground(.hidden)
                .background(DesignTokens.Colors.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))

            HStack {
                Button("Reset") {
                    draftCustomCSS = config.customCSS ?? ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(draftCustomCSS == (config.customCSS ?? ""))

                Spacer()

                Button("Close") { customCSSPresented = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    let next = draftCustomCSS.isEmpty ? nil : draftCustomCSS
                    if config.customCSS != next {
                        config.customCSS = next
                        screenManager.updateHTMLConfig(config, for: screen)
                    }
                    customCSSPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(draftCustomCSS == (config.customCSS ?? ""))
            }
        }
        .padding(DesignTokens.Spacing.cardInset)
    }

    // MARK: - Bindings

    private func configBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<HTMLConfig, Value>,
        normalize: @escaping (Value) -> Value = { $0 }
    ) -> Binding<Value> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { rawValue in
                let newValue = normalize(rawValue)
                guard config[keyPath: keyPath] != newValue else { return }
                var next = config
                next[keyPath: keyPath] = newValue
                config = next
                screenManager.updateHTMLConfig(next, for: screen)
            }
        )
    }

    // MARK: - Helpers

    private func scheduleCustomCSSDraftSync(_ customCSS: String?) {
        DispatchQueue.main.async {
            Task { @MainActor in
                let nextValue = customCSS ?? ""
                if draftCustomCSS != nextValue {
                    draftCustomCSS = nextValue
                }
            }
        }
    }
}
