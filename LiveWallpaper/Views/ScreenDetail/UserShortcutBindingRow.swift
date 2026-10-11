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
    @State private var testFailed = false
    @State private var isDropTargeted = false

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
            verbatimTitle: title,
            verbatimSubtitle: testFailed ? String(
                localized: "Couldn't open it. Check the website, shortcut name or file.",
                bundle: .appLanguage,
                comment: "Shown under a user shortcut row after its Test action failed to open the bound item."
            ) : nil
        ) {
            Menu {
                Button("Website", systemImage: "safari") { select { editing = .website } }
                Button("Apple Shortcut", systemImage: "square.2.layers.3d") { select { editing = .shortcut } }
                Button("File or App", systemImage: "doc") { select { choose(directory: false) } }
                Button("Folder", systemImage: "folder") { select { choose(directory: true) } }
                if current?.isApplication == true {
                    Button("Edit Arguments", systemImage: "text.cursor") { select { editing = .arguments } }
                }
                Divider()
                Button("Test", systemImage: "play") {
                    select {
                        if let current {
                            let failed = $testFailed
                            _ = UserShortcutExecutor.execute(current, onFailure: { failed.wrappedValue = true })
                        }
                    }
                }
                .disabled(current == nil)
                Button("Clear", systemImage: "xmark.circle", role: .destructive) {
                    select { UserShortcutBindingStore.shared.clear(key) }
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
        .background {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                    .fill(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.dragFill))
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                    .stroke(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.quietStroke), lineWidth: 1)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls)
        } isTargeted: { isDropTargeted = $0 }
        .help(Text("Runs when the wallpaper's script asks for it after you click the wallpaper, including clicks on desktop icons."))
        .onAppear(perform: refresh)
        .onChange(of: key) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UserShortcutBindingStore.didChange)) { _ in refresh() }
    }

    enum DropTarget: Equatable {
        case file(asksForArguments: Bool)
        case directory
    }

    /// An `.app` is a package directory but binds as a file, like the File or App menu item.
    static func dropTarget(for url: URL) -> DropTarget? {
        guard url.isFileURL else { return nil }
        if UserShortcutBinding.isApplication(url) {
            return .file(asksForArguments: true)
        }
        let isDirectory = url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDirectory ? .directory : .file(asksForArguments: false)
    }

    /// Binds only the first URL; nil = rejected and the store is unchanged.
    @discardableResult
    static func bindDropped(_ urls: [URL], to key: UserShortcutBindingKey, in store: UserShortcutBindingStore) throws -> DropTarget? {
        guard let url = urls.first, let target = dropTarget(for: url) else { return nil }
        switch target {
        case .directory:
            try store.setDirectory(url, for: key)
        case .file:
            try store.setFile(url, arguments: nil, for: key)
        }
        return target
    }

    /// The menu has no open callback, so any item picked from it dismisses a previous Test failure.
    private func select(_ action: () -> Void) {
        testFailed = false
        action()
    }

    private func drop(_ urls: [URL]) -> Bool {
        do {
            guard let target = try Self.bindDropped(urls, to: key, in: .shared) else { return false }
            if target == .file(asksForArguments: true) {
                editing = .arguments
            }
            return true
        } catch {
            Logger.error("User shortcut: couldn't save the dropped item: \((error as NSError).code)", category: .settings)
            return false
        }
    }

    private func refresh() {
        let binding = UserShortcutBindingStore.shared.binding(for: key)
        if binding != current {
            testFailed = false
        }
        current = binding
        isResolvable = current.map(UserShortcutExecutor.isResolvable) ?? true
    }

    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
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
        // Not `NSApp.windows.first`: that can be a wallpaper window.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
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
                    shortcutNameHint
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

    private var shortcutNameHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text("Use the exact name shown in the Shortcuts app.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let shortcutsApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                Spacer(minLength: 0)
                Button("Open Shortcuts") {
                    NSWorkspace.shared.openApplication(at: shortcutsApp, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                }
                .buttonStyle(.borderless)
            }
        }
        .font(DesignTokens.Typography.caption)
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
