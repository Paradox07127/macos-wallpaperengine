#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI
import UniformTypeIdentifiers

/// Edits the device-local image or video binding only; never writes a scene override, so presets and change marks ignore it.
struct SceneTextureBindingRow: View {
    let wallpaperID: String
    let propertyKey: String
    let title: String
    var iconColor: Color = .accentColor

    @State private var current: UserShortcutBinding?
    @State private var isResolvable = true
    @State private var saveFailed = false

    static let allowedContentTypes: [UTType] = [.image, .movie]
        + SceneTextureVideo.extensions.sorted().compactMap { UTType(filenameExtension: $0) }

    @State private var videoProblem: SceneTextureVideo.Problem?

    private var key: UserShortcutBindingKey {
        UserShortcutBindingKey(wallpaperID: wallpaperID, propertyKey: propertyKey)
    }

    private var subtitle: String? {
        if saveFailed {
            return String(
                localized: "Couldn't save the chosen image.",
                bundle: .appLanguage,
                comment: "Shown under a scene image row when choosing or clearing the image couldn't be saved."
            )
        }
        switch videoProblem {
        case .unsupportedFormat:
            return String(
                localized: "This video format can't play on Mac. The author's image is shown instead.",
                bundle: .appLanguage,
                comment: "Shown under a scene image row when the chosen video's format (WebM, MKV, AVI or WMV) can't play on macOS."
            )
        case .unreadable:
            return String(
                localized: "This video can't be opened. The author's image is shown instead.",
                bundle: .appLanguage,
                comment: "Shown under a scene image row when the chosen video file is damaged or unreadable."
            )
        case nil:
            return nil
        }
    }

    var body: some View {
        SettingRow(
            icon: WPEPropertyRowIcon.symbol(for: .sceneTexture),
            iconColor: iconColor,
            verbatimTitle: title,
            verbatimSubtitle: subtitle
        ) {
            Menu {
                Button("Choose Image or Video", systemImage: "photo") { chooseImage() }
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
        .task(id: current) {
            guard let current else {
                videoProblem = nil
                return
            }
            videoProblem = await SceneTextureVideo.problem(for: current)
        }
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
        panel.allowedContentTypes = Self.allowedContentTypes
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
