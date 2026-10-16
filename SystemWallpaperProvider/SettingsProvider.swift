import Foundation

/// Turns the app-published manifest into the view-model tree the wallpaper
/// panel renders (contract §1).
struct SettingsProvider {
    let store: SharedLibraryStore
    let providerID: String

    func makeViewModels() -> SettingsViewModels {
        let manifest = store.loadManifest()
        let provider = ChoiceProviderID(rawValue: providerID)

        let item = manifest.item(for: SystemWallpaperManifest.selectedChoiceID)
        let placeholder = Bundle.main.url(forResource: "SelectedWallpaper", withExtension: "png")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/SelectedWallpaper.png")
        let thumbnailURL = item?.thumbnailFileName.map { store.videosDirectory().appendingPathComponent($0) }
        let thumbnail = Thumbnail.image(url: thumbnailURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? placeholder)
        let brand = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Loomscreen"
        let title = brand + " — " + String(localized: "Selected Wallpaper")
        let identifier = SystemWallpaperManifest.selectedChoiceID
        let choiceID = ChoiceID(id: identifier, descriptor: ChoiceIDDescriptor(
            provider: provider, identifier: identifier,
            files: item.map { [store.videoURL(for: $0)] } ?? [], configuration: Data(identifier.utf8)
        ))
        let items = [SettingsItem(
            id: choiceID, localizedName: title, thumbnail: thumbnail,
            choice: ChoiceDescriptor(id: choiceID, provider: provider, identifier: identifier, name: title,
                                     localizedDescription: String(localized: "Follows the wallpaper selected inside Loomscreen"),
                                     thumbnail: thumbnail, isDownloaded: true, options: []),
            contentBadge: .video, showInTopLevel: true, sortOrder: 0, disposability: .none
        )]

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
        let preferred = Locale.preferredLanguages.first ?? "en"
        let title = brand + " " + String(localized: "Wallpapers")
        return SystemWallpaperProviderStaleness.panelGroupTitle(
            title,
            verdict: ProviderStaleness.declaredVerdict(store: store),
            preferredLanguage: preferred
        )
    }
}
