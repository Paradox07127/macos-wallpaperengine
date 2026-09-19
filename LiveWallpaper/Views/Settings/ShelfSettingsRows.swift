import LiveWallpaperCore
import SwiftUI

/// Owns its `@AppStorage` fields itself so `GeneralSettingsView`'s locked root state count
/// (UI-08) does not grow.
struct ShelfSettingsRows: View {
    @AppStorage(EditDeskPreferences.shelfStyle, store: .appScoped())
    private var shelfStyleRaw = EditDeskPreferences.shelfStyleDefault.rawValue
    @AppStorage(EditDeskPreferences.background, store: .appScoped())
    private var backgroundRaw = EditDeskPreferences.backgroundDefault.rawValue
    @AppStorage(EditDeskPreferences.shelfCapacity, store: .appScoped())
    private var shelfCapacity = EditDeskPreferences.shelfCapacityDefault
    @AppStorage(EditDeskPreferences.hoverAutoplayPreview, store: .appScoped())
    private var hoverAutoplayPreview = EditDeskPreferences.hoverAutoplayPreviewDefault
    @AppStorage(EditDeskPreferences.statusCapsuleContent, store: .appScoped())
    private var statusCapsuleRaw = EditDeskPreferences.statusCapsuleContentDefault.rawValue
    @AppStorage(EditDeskPreferences.homeDefaultState, store: .appScoped())
    private var homeDefaultRaw = EditDeskPreferences.homeDefaultStateDefault.rawValue

    var body: some View {
        if EditDeskFlag.isEnabled {
            rows
        }
    }

    @ViewBuilder
    private var rows: some View {
        SettingRow(icon: "shippingbox", iconColor: .brown, title: "Shelf style") {
            shelfStylePicker
        }

        SettingRow(icon: "circle.lefthalf.filled", iconColor: .indigo, title: "Main window background") {
            backgroundPicker
        }

        SettingRow(
            icon: "square.stack.3d.up",
            iconColor: .cyan,
            title: "Cards rendered at once",
            info: "Higher counts use more memory and GPU time."
        ) {
            shelfCapacityStepper
        }

        SettingRow(icon: "play.circle", iconColor: .mint, title: "Autoplay preview on hover") {
            Toggle("", isOn: $hoverAutoplayPreview)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Autoplay preview on hover"))
        }

        SettingRow(icon: "gauge", iconColor: .yellow, title: "Status capsule shows") {
            statusCapsulePicker
        }

        SettingRow(icon: "rectangle.bottomthird.inset.filled", iconColor: .teal, title: "Home opens as") {
            homeDefaultPicker
        }
    }

    /// `@AppStorage` keeps these as raw strings so an unknown value falls back instead of
    /// crashing; every picker needs the same two-line bridge back to its enum.
    private func choice<T: RawRepresentable<String>>(_ raw: Binding<String>, or fallback: T) -> Binding<T> {
        Binding(get: { T(rawValue: raw.wrappedValue) ?? fallback }, set: { raw.wrappedValue = $0.rawValue })
    }

    private var shelfStylePicker: some View {
        GlassSegmentedPicker(
            selection: choice($shelfStyleRaw, or: EditDeskPreferences.shelfStyleDefault),
            values: ShelfStyle.allCases,
            shell: .flat,
            title: { Self.shelfStyleTitle($0) }
        )
        .frame(width: 240)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Shelf style"))
    }

    private static func shelfStyleTitle(_ style: ShelfStyle) -> LocalizedStringKey {
        switch style {
        case .crate: "Crate"
        case .folders: "Folders"
        case .coverFlow: "Cover Flow"
        }
    }

    private var backgroundPicker: some View {
        GlassSegmentedPicker(
            selection: choice($backgroundRaw, or: EditDeskPreferences.backgroundDefault),
            values: EditDeskBackground.allCases,
            shell: .flat,
            title: { Self.backgroundTitle($0) }
        )
        .frame(width: 200)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Main window background"))
    }

    private static func backgroundTitle(_ background: EditDeskBackground) -> LocalizedStringKey {
        switch background {
        case .opaque: "Solid"
        case .frosted: "Frosted"
        }
    }

    private var shelfCapacityStepper: some View {
        Stepper(value: $shelfCapacity, in: 6 ... 24, step: 2) {
            Text(verbatim: "\(shelfCapacity)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityLabel(Text("Cards rendered at once"))
        .accessibilityValue(Text(verbatim: "\(shelfCapacity)"))
    }

    private var statusCapsulePicker: some View {
        Picker("", selection: choice($statusCapsuleRaw, or: EditDeskPreferences.statusCapsuleContentDefault)) {
            ForEach(StatusCapsuleContent.allCases, id: \.self) { option in
                Text(Self.statusCapsuleTitle(option)).tag(option)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("Status capsule shows"))
    }

    private static func statusCapsuleTitle(_ option: StatusCapsuleContent) -> LocalizedStringKey {
        switch option {
        case .systemHealth: "System health (CPU · GPU · memory · temperature)"
        case .wallpapersOnly: "Wallpapers only"
        case .hidden: "Hidden"
        }
    }

    private var homeDefaultPicker: some View {
        Picker("", selection: choice($homeDefaultRaw, or: EditDeskPreferences.homeDefaultStateDefault)) {
            ForEach(HomeDefaultState.allCases, id: \.self) { option in
                Text(Self.homeDefaultTitle(option)).tag(option)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("Home opens as"))
    }

    private static func homeDefaultTitle(_ state: HomeDefaultState) -> LocalizedStringKey {
        switch state {
        case .hidden: "Hidden shelf"
        case .halfOpen: "Half-open shelf"
        }
    }
}
