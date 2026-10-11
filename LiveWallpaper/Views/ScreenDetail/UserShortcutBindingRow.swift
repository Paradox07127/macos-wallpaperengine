#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Edits the device-local binding only; never writes a scene override, so presets and change marks ignore it.
struct UserShortcutBindingRow: View {
    let wallpaperID: String
    let propertyKey: String
    let title: String
    var iconColor: Color = .accentColor

    @State private var current: UserShortcutBinding?
    @State private var isResolvable = true
    @State private var editing: UserShortcutEditorKind?

    private var isEditing: Binding<Bool> {
        Binding(get: { editing != nil }, set: { shown in
            if !shown {
                editing = nil
            }
        })
    }

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
                Button("File or App", systemImage: "doc") { choose(directory: false) }
                Button("Folder", systemImage: "folder") { choose(directory: true) }
                if current?.isApplication == true {
                    Button("Edit Arguments", systemImage: "text.cursor") { editing = .arguments }
                }
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
                if current != nil, !isResolvable {
                    Text("Choose Again")
                        .help(Text("The file or folder can't be found. Choose it again."))
                } else if let current {
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
            .appLanguagePopover(isPresented: isEditing, arrowEdge: .bottom) {
                if let editing {
                    UserShortcutEditorPopover(kind: editing, key: key, current: current)
                }
            }
        }
        .help(Text("Runs when the wallpaper's script asks for it after you click the wallpaper, including clicks on desktop icons."))
        .onAppear(perform: refresh)
        .onChange(of: key) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UserShortcutBindingStore.didChange)) { _ in refresh() }
    }

    private func refresh() {
        current = UserShortcutBindingStore.shared.binding(for: key)
        isResolvable = current.map(UserShortcutExecutor.isResolvable) ?? true
    }

    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if directory {
                try UserShortcutBindingStore.shared.setDirectory(url, for: key)
            } else {
                try UserShortcutBindingStore.shared.setFile(url, arguments: nil, for: key)
                if UserShortcutBinding.isApplication(url) {
                    editing = .arguments
                }
            }
        } catch {
            Logger.error("User shortcut: couldn't save the chosen item: \((error as NSError).code)", category: .settings)
        }
    }
}

private enum UserShortcutEditorKind: Identifiable {
    case website, shortcut, arguments

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
    @State private var targetMissing = false

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
            case .arguments:
                field("Arguments") {
                    TextField("Arguments", text: $input, prompt: Text("Optional"))
                }
            }

            if let failure {
                errorText(Self.message(for: failure))
            } else if targetMissing {
                errorText("The file or folder can't be found. Choose it again.")
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

    private func errorText(_ message: LocalizedStringKey) -> some View {
        Text(message)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.Status.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func prefill() {
        // Read the store, not `current`: right after a pick the row's snapshot can still be the previous binding.
        guard let binding = kind == .arguments ? UserShortcutBindingStore.shared.binding(for: key) : current else { return }
        switch (kind, binding.kind) {
        case (.website, .web):
            url = binding.target
        case (.shortcut, .cmd):
            name = binding.target
            input = binding.arguments ?? ""
        case (.arguments, .file):
            input = binding.arguments ?? ""
            targetMissing = !UserShortcutExecutor.isResolvable(binding)
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
            case .arguments:
                // The bookmark is re-resolved on every save: a cached scoped URL loses its access.
                guard let binding = UserShortcutBindingStore.shared.binding(for: key),
                      case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(binding.bookmark, target: .transient)
                else {
                    targetMissing = true
                    return
                }
                try SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                    try UserShortcutBindingStore.shared.setFile(resolved.url, arguments: input, for: key)
                }
            }
            dismiss()
        } catch let error as UserShortcutValidationError {
            failure = error
        } catch {
            targetMissing = true
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
