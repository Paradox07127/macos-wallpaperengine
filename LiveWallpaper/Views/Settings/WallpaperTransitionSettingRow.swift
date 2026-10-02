import LiveWallpaperCore
import SwiftUI

/// Owns its `@AppStorage` field so `GeneralSettingsView`'s locked root state count does not grow.
struct WallpaperTransitionSettingRow: View {
    @AppStorage(WallpaperTransitionChoice.defaultsKey, store: .appScoped())
    private var choiceRaw = WallpaperTransitionChoice.defaultChoice.rawValue

    var body: some View {
        SettingRow(
            icon: "sparkles.rectangle.stack",
            iconColor: .purple,
            title: "Wallpaper transition",
            info: "Plays when a display switches wallpapers, and more slowly when automation switches them. With Reduce Motion or Low Power Mode on, animated transitions become a short crossfade."
        ) {
            Picker("", selection: selection) {
                ForEach(WallpaperTransitionChoice.allCases) { choice in
                    Text(Self.title(choice)).tag(choice)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Wallpaper transition"))
        }
    }

    private var selection: Binding<WallpaperTransitionChoice> {
        Binding(
            get: { WallpaperTransitionChoice(rawValue: choiceRaw) ?? WallpaperTransitionChoice.defaultChoice },
            set: { choiceRaw = $0.rawValue }
        )
    }

    static func title(_ choice: WallpaperTransitionChoice) -> LocalizedStringKey {
        switch choice {
        case .none: "None"
        case .crossfade: "Crossfade"
        case .meteor: "Meteor"
        case .ink: "Ink Bloom"
        case .leak: "Light Leak"
        case .aurora: "Aurora Curtain"
        case .weave: "Light Weave"
        case .random: "Random"
        }
    }
}
