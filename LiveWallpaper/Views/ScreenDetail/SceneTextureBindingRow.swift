#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI
import UniformTypeIdentifiers

/// Edits the device-local image binding only; never writes a scene override, so presets and change marks ignore it.
struct SceneTextureBindingRow: View {
    let wallpaperID: String
    let propertyKey: String
    let title: String
    var iconColor: Color = .accentColor

    @State private var current: UserShortcutBinding?
    @State private var isResolvable = true
    @State private var saveFailed = false

    private var key: UserShortcutBindingKey {
        UserShortcutBindingKey(wallpaperID: wallpaperID, propertyKey: propertyKey)
    }

    var body: some View {
        SettingRow(
            icon: WPEPropertyRowIcon.symbol(for: .sceneTexture),
            iconColor: iconColor,
            verbatimTitle: title,
            verbatimSubtitle: saveFailed ? String(
                localized: "Couldn't save the chosen image.",
                bundle: .appLanguage,
                comment: "Shown under a scene image row when choosing or clearing the image couldn't be saved."
            ) : nil
        ) {
            Menu {
                Button("Choose Image", systemImage: "photo") { chooseImage() }
                Divider()
                Button("Clear", systemImage: "xmark.circle", role: .destructive) {
                    saveFailed = !UserShortcutBindingStore.shared.clear(key)
                }
                .disabled(current == nil)
            } label: {
                if current != nil, !isResolvable {
                    Text("Choose Again")
                        .help(Text("The image can't be found. Choose it again."))
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
        }
        .help(Text("Replaces this image in the wallpaper. Clear it to show the author's image again."))
        .onAppear(perform: refresh)
        .onChange(of: key) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UserShortcutBindingStore.didChange)) { _ in refresh() }
    }

    private func refresh() {
        let binding = UserShortcutBindingStore.shared.binding(for: key)
        if binding != current {
            saveFailed = false
        }
        current = binding
        isResolvable = current.map(UserShortcutExecutor.isResolvable) ?? true
    }

    private func chooseImage() {
        saveFailed = false
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                saveFailed = try !UserShortcutBindingStore.shared.setFile(url, arguments: nil, for: key)
            } catch {
                Logger.error("Scene image: couldn't save the chosen file: \((error as NSError).code)", category: .settings)
                saveFailed = true
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
#endif
