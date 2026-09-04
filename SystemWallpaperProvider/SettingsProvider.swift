import Foundation

/// Turns the app-published manifest into the view-model tree the wallpaper
/// panel renders (contract §1).
struct SettingsProvider {
    let store: SharedLibraryStore
    let providerID: String

    func makeViewModels() -> SettingsViewModels {
        let manifest = store.loadManifest()
        let provider = ChoiceProviderID(rawValue: providerID)

        let items: [SettingsItem] = manifest.items.compactMap { item in
            // No thumbnail means nothing to draw in the panel — skip rather
            // than ship a blank tile.
            guard let thumbName = item.thumbnailFileName else { return nil }
            let thumbURL = SystemWallpaperPaths.videosDirectory(hostBundleID: store.hostBundleID)
                .appendingPathComponent(thumbName)
            guard FileManager.default.fileExists(atPath: thumbURL.path) else { return nil }

            let videoURL = store.videoURL(for: item)
            // A tile whose video is gone would be selectable but never play —
            // skip it; the app-side sweep reclaims whatever is left on disk.
            guard FileManager.default.fileExists(atPath: videoURL.path) else { return nil }
            let descriptor = ChoiceIDDescriptor(
                provider: provider,
                identifier: item.id,
                files: [videoURL],
                configuration: Data(item.id.utf8)
            )
            let choiceID = ChoiceID(id: item.id, descriptor: descriptor)
            let thumbnail = Thumbnail.image(url: thumbURL)

            return SettingsItem(
                id: choiceID,
                localizedName: item.title,
                thumbnail: thumbnail,
                choice: ChoiceDescriptor(
                    id: choiceID,
                    provider: provider,
                    identifier: item.id,
                    name: item.title,
                    localizedDescription: item.title,
                    thumbnail: thumbnail,
                    isDownloaded: true,
                    options: []
                ),
                contentBadge: .video,
                showInTopLevel: true,
                sortOrder: 0,
                // `.none`, not `.removable`: with a removable third-party choice
                // macOS 27.0's own wallpaper pane traps in its Remove button
                // handler (EXC_BREAKPOINT in Wallpaper.appex, 2026-08-18) and
                // the request never reaches us. Removal lives in Loomscreen,
                // which is the side that owns the files anyway.
                disposability: .none
            )
        }

        let group = SettingsGroup(
            id: GroupID(id: providerID),
            items: items,
            localizedName: groupTitle(),
            disposability: .none,
            sortOrder: -100,
            sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
            allChoiceID: nil,
            shouldHideItemLabels: false,
            contextMenu: nil,
            thumbnail: nil
        )

        let model = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
        return SettingsViewModels(desktop: model, screenSaver: nil)
    }

    /// The panel takes a plain string, so localize on our side against the
    /// user's preferred language. The brand half comes from the appex's own
    /// display name so Pro and Lite never render two identical group titles
    /// when both are installed.
    private func groupTitle() -> String {
        let brand = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? "Loomscreen"
        let suffix: [String: String] = [
            "zh-Hans": "视频壁纸",
            "zh-Hant": "影片桌布",
            "ja": "ビデオ壁紙",
            "es": "Fondos de vídeo",
        ]
        let preferred = Locale.preferredLanguages.first ?? "en"
        for (prefix, text) in suffix where preferred.hasPrefix(prefix) {
            return "\(brand) \(text)"
        }
        return "\(brand) Video Wallpapers"
    }
}
