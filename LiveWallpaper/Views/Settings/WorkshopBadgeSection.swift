import LiveWallpaperCore
import SwiftUI

/// Controls Workshop thumbnail badges; other libraries retain their own badge settings.
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
                title: "Wallpaper type"
            ) {
                Toggle("", isOn: $showsType)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Wallpaper type badge"))
            }

            SettingRow(
                icon: "textformat",
                iconColor: .indigo,
                title: "Type badge style"
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
                title: "Rating"
            ) {
                Toggle("", isOn: $showsRating)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Rating badge"))
            }

            SettingRow(
                icon: "ruler",
                iconColor: .teal,
                title: "Resolution"
            ) {
                Toggle("", isOn: $showsResolution)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Resolution badge"))
            }

            SettingRow(
                icon: "checkmark.circle",
                iconColor: .green,
                title: "Already installed"
            ) {
                Toggle("", isOn: $showsInLibrary)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Already installed badge"))
            }

            SettingRow(
                icon: "arrow.triangle.2.circlepath",
                iconColor: .orange,
                title: "Update available"
            ) {
                Toggle("", isOn: $showsUpdate)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Update available badge"))
            }

            SettingRow(
                icon: "play.circle",
                iconColor: .green,
                title: "Currently in use"
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
