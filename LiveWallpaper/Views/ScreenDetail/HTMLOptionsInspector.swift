import SwiftUI
import AppKit
import LiveWallpaperCore

/// Toggle-style behavior settings, kept visually separate from the continuous geometry controls in `HTMLTransformInspector`.
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
                    javaScriptRow
                    Divider()
                    mouseInteractionRow
                    Divider()
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

    private var javaScriptRow: some View {
        SettingRow(
            icon: "curlybraces",
            iconColor: .orange,
            title: "JavaScript"
        ) {
            Toggle("", isOn: configBinding(\.allowJavaScript))
                .labelsHidden()
                .accessibilityLabel(Text("JavaScript"))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var mouseInteractionRow: some View {
        SettingRow(
            icon: "cursorarrow.click",
            iconColor: .blue,
            title: "Interaction",
            info: "When on, clicks and scrolls reach the wallpaper but desktop icons and the Dock become unclickable. Off lets you use Finder normally."
        ) {
            Toggle("", isOn: configBinding(\.allowMouseInteraction))
                .labelsHidden()
                .accessibilityLabel(Text("Interaction"))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var physicalPixelRow: some View {
        SettingRow(
            icon: "rectangle.split.2x1",
            iconColor: .indigo,
            title: "Physical-pixel layout",
            info: "Renders CSS-naive HTML canvas content at retina resolution. Auto-enabled only for imported project folders that do not already use devicePixelRatio."
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
            title: "Auto Refresh",
            info: "Reloads the page at the chosen interval. Useful for dashboards or feeds; off keeps the page rendering continuously without reloads."
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
