import LiveWallpaperCore
import SwiftUI

/// Owns its `@AppStorage` field so `GeneralSettingsView`'s locked root state count does not grow.
struct WallpaperOpeningSettingRow: View {
    @AppStorage(WallpaperOpeningChoice.defaultsKey, store: .appScoped())
    private var choiceRaw = WallpaperOpeningChoice.defaultChoice.rawValue

    var body: some View {
        SettingRow(
            icon: "play.rectangle.on.rectangle",
            iconColor: .purple,
            title: "Opening animation",
            info: "Plays once when your wallpapers first appear after launch. With Reduce Motion or Low Power Mode on, it becomes a short fade-in."
        ) {
            Picker("", selection: selection) {
                ForEach(WallpaperOpeningChoice.allCases) { choice in
                    Text(Self.title(choice)).tag(choice)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Opening animation"))
        }
    }

    private var selection: Binding<WallpaperOpeningChoice> {
        Binding(
            get: { WallpaperOpeningChoice(rawValue: choiceRaw) ?? WallpaperOpeningChoice.defaultChoice },
            set: { choiceRaw = $0.rawValue }
        )
    }

    static func title(_ choice: WallpaperOpeningChoice) -> LocalizedStringKey {
        switch choice {
        case .off: "Off"
        case .loom: "Loom Line"
        case .frame: "Frame Unfold"
        case .dawn: "Daybreak"
        case .random: "Random"
        }
    }
}
