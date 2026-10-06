import LiveWallpaperCore
import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.defaultsKey, store: .appScoped()) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(LibraryTileSize.preferencesKey, store: .appScoped()) private var libraryTileSizeRaw = LibraryTileSize.defaultSize.rawValue

    var body: some View {
        Form {
            Section {
                SettingRow(
                    icon: "circle.righthalf.filled",
                    iconColor: .indigo,
                    title: "Appearance",
                    info: "Desktop controls and media previews always use dark appearance."
                ) {
                    appearancePicker
                }

                MainWindowBackgroundRow()
            } header: {
                SettingsSearchSectionHeader("Window", anchor: .appearanceWindow)
            }

            Section {
                SettingRow(
                    icon: "square.grid.2x2",
                    iconColor: .orange,
                    title: "Library tile size",
                    info: "Applies to every wallpaper grid."
                ) {
                    libraryTileSizePicker
                }

                ShelfSettingsRows()
            } header: {
                SettingsSearchSectionHeader("Library & Shelf", anchor: .appearanceLibrary)
            }
        }
        .settingsFormChrome()
    }

    private var appearancePicker: some View {
        GlassSegmentedPicker(
            selection: appearanceSelection,
            values: AppAppearance.allCases,
            shell: .flat,
            title: { Self.appearanceTitle($0) }
        )
        .frame(width: 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Appearance"))
    }

    private static func appearanceTitle(_ appearance: AppAppearance) -> LocalizedStringKey {
        switch appearance {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private var appearanceSelection: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRawValue) ?? .system },
            set: {
                appearanceRawValue = $0.rawValue
                $0.apply()
            }
        )
    }

    private var libraryTileSizePicker: some View {
        GlassSegmentedPicker(
            selection: libraryTileSizeSelection,
            values: LibraryTileSize.allCases,
            shell: .flat,
            title: { $0.title }
        )
        .frame(width: 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Library tile size"))
    }

    private var libraryTileSizeSelection: Binding<LibraryTileSize> {
        Binding(
            get: { LibraryTileSize(rawValue: libraryTileSizeRaw) ?? .defaultSize },
            set: { libraryTileSizeRaw = $0.rawValue }
        )
    }
}
