import LiveWallpaperCore
import SwiftUI

/// Which badges the Workshop grids draw on their thumbnails — Browse Online and
/// the installed / Scene cards. Positions are fixed; this only decides what
/// appears. Other libraries (Aerials, Bookmarks) keep their own badges.
struct WorkshopBadgeSection: View {
    @AppStorage(CardBadgeSettings.showsRating, store: .appScoped()) private var showsRating = true
    @AppStorage(CardBadgeSettings.showsType, store: .appScoped()) private var showsType = true
    @AppStorage(CardBadgeSettings.showsResolution, store: .appScoped()) private var showsResolution = true
    @AppStorage(CardBadgeSettings.showsInLibrary, store: .appScoped()) private var showsInLibrary = true
    @AppStorage(CardBadgeSettings.showsUpdate, store: .appScoped()) private var showsUpdate = true
    @AppStorage(CardBadgeSettings.showsInUse, store: .appScoped()) private var showsInUse = true
    @AppStorage(CardBadgeSettings.typeStyle, store: .appScoped()) private var typeStyle: CardTypeBadgeStyle = .icon

    var body: some View {
        Section {
            SettingRow(
                icon: "square.stack.3d.up",
                iconColor: .indigo,
                title: "Wallpaper type",
                subtitle: "Show Scene, Video, or Web on the thumbnail"
            ) {
                Toggle("", isOn: $showsType)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Wallpaper type badge"))
            }

            SettingRow(
                icon: "textformat",
                iconColor: .indigo,
                title: "Type badge style",
                subtitle: "Whether the type badge shows its icon, its name, or both"
            ) {
                Picker("", selection: $typeStyle) {
                    Text("Icon").tag(CardTypeBadgeStyle.icon)
                    Text("Name").tag(CardTypeBadgeStyle.text)
                    Text("Icon and name").tag(CardTypeBadgeStyle.iconAndText)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!showsType)
                .accessibilityLabel(Text("Type badge style"))
            }

            SettingRow(
                icon: "star",
                iconColor: .yellow,
                title: "Rating",
                subtitle: "Show the Workshop star rating"
            ) {
                Toggle("", isOn: $showsRating)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Rating badge"))
            }

            SettingRow(
                icon: "ruler",
                iconColor: .teal,
                title: "Resolution",
                subtitle: "Show 4K, 1440p, and other resolution labels"
            ) {
                Toggle("", isOn: $showsResolution)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Resolution badge"))
            }

            SettingRow(
                icon: "checkmark.circle",
                iconColor: .green,
                title: "Already installed",
                subtitle: "Mark Workshop results you have downloaded"
            ) {
                Toggle("", isOn: $showsInLibrary)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Already installed badge"))
            }

            SettingRow(
                icon: "arrow.triangle.2.circlepath",
                iconColor: .orange,
                title: "Update available",
                subtitle: "Flag installed items with a newer version on Steam"
            ) {
                Toggle("", isOn: $showsUpdate)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Update available badge"))
            }

            SettingRow(
                icon: "play.circle",
                iconColor: .green,
                title: "Currently in use",
                subtitle: "Mark the wallpaper a display is showing right now"
            ) {
                Toggle("", isOn: $showsInUse)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Currently in use badge"))
            }
        } header: {
            SettingsSearchSectionHeader("Thumbnail badges", anchor: .workshopBadges)
        }
    }
}
