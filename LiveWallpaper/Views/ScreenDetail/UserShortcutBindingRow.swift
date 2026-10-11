#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Edits the device-local binding only; never writes a scene override, so presets and change marks ignore it.
struct UserShortcutBindingRow: View {
    let wallpaperID: String
    let propertyKey: String
    let title: String
    var iconColor: Color = .accentColor

    @State private var current: UserShortcutBinding?
    @State private var editing: UserShortcutEditorKind?

    private var key: UserShortcutBindingKey {
        UserShortcutBindingKey(wallpaperID: wallpaperID, propertyKey: propertyKey)
    }

    var body: some View {
        SettingRow(
            icon: WPEPropertyRowIcon.symbol(for: .userShortcut),
            iconColor: iconColor,
            verbatimTitle: title
        ) {
            Menu {
                Button("Website", systemImage: "safari") { editing = .website }
                Button("Apple Shortcut", systemImage: "square.2.layers.3d") { editing = .shortcut }
                Divider()
                Button("Test", systemImage: "play") {
                    if let current {
                        _ = UserShortcutExecutor.execute(current)
                    }
                }
                .disabled(current == nil)
                Button("Clear", systemImage: "xmark.circle", role: .destructive) {
                    UserShortcutBindingStore.shared.clear(key)
                }
                .disabled(current == nil)
            } label: {
                if let current {
                    Text(verbatim: current.displayName)
                } else {
                    Text("Not Set")
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 96, alignment: .trailing)
            .layoutPriority(1)
            .accessibilityLabel(title)
            .popover(item: $editing, arrowEdge: .bottom) { kind in
                UserShortcutEditorPopover(kind: kind, key: key, current: current)
            }
        }
        .help(Text("Runs when the wallpaper's script asks for it after you click the wallpaper."))
        .onAppear(perform: refresh)
        .onChange(of: key) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UserShortcutBindingStore.didChange)) { _ in refresh() }
    }

    private func refresh() {
        current = UserShortcutBindingStore.shared.binding(for: key)
    }
}

private enum UserShortcutEditorKind: Identifiable {
    case website, shortcut

    var id: Self {
        self
    }
}

private struct UserShortcutEditorPopover: View {
    let kind: UserShortcutEditorKind
    let key: UserShortcutBindingKey
    let current: UserShortcutBinding?

    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var input = ""
    @State private var failure: UserShortcutValidationError?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            switch kind {
            case .website:
                field("URL") {
                    TextField("URL", text: $url, prompt: Text(verbatim: "https://"))
                }
            case .shortcut:
                field("Shortcut Name") {
                    TextField("Shortcut Name", text: $name)
                }
                field("Input Text") {
                    TextField("Input Text", text: $input, prompt: Text("Optional"))
                }
            }

            if let failure {
                Text(Self.message(for: failure))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Save", action: save)
                    .adaptiveGlassButton(.prominent, size: .small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .settingsPopoverChrome(width: 280)
        .onAppear(perform: prefill)
    }

    private func field(_ label: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(label)
                .font(DesignTokens.Typography.badge)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(DesignTokens.Typography.body)
                .onSubmit(save)
        }
    }

    private func prefill() {
        guard let current else { return }
        switch (kind, current.kind) {
        case (.website, .web):
            url = current.target
        case (.shortcut, .cmd):
            name = current.target
            input = current.arguments ?? ""
        default:
            break
        }
    }

    private func save() {
        do {
            switch kind {
            case .website:
                try UserShortcutBindingStore.shared.setWebsite(url, for: key)
            case .shortcut:
                try UserShortcutBindingStore.shared.setShortcut(name: name, arguments: input, for: key)
            }
            dismiss()
        } catch {
            failure = error as? UserShortcutValidationError
        }
    }

    private static func message(for error: UserShortcutValidationError) -> LocalizedStringKey {
        switch error {
        case .empty: "Enter a value."
        case .tooLong: "This entry is too long."
        case .malformedURL, .missingHost: "Enter a valid web address."
        case .unsupportedScheme: "Only http and https addresses are supported."
        case .credentialsInURL: "Remove the user name and password from the address."
        case .controlCharacters: "Contains characters that are not allowed."
        }
    }
}
#endif
