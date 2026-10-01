import LiveWallpaperCore
import SwiftUI

struct LibraryChip: Identifiable, Hashable {
    let id: String
    let title: LocalizedStringKey

    /// `LocalizedStringKey` is only `Equatable`, so `Hashable` cannot be synthesized —
    /// equality and hashing both key off `id`, matching `Identifiable`.
    static func == (lhs: LibraryChip, rhs: LibraryChip) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct LibraryChipsRow: View {
    let chips: [LibraryChip]
    @Binding var selection: String
    @Binding var searchText: String
    let searchPrompt: LocalizedStringKey
    let searchShortPrompt: LocalizedStringKey
    /// Drives the search field's reveal; the rest of the row rides the shelf in `ShelfChromeRide`.
    let stage: EditDeskStageModel
    @Binding var sort: SavedLibraryModel.Sort
    @Binding var filter: SavedLibraryModel.Filter?
    let onImport: () -> Void

    var body: some View {
        LibraryToolbarRow {
            ForEach(chips) { chip in
                FilterChip(title: Text(chip.title), isSelected: selection == chip.id) {
                    selection = chip.id
                }
            }
        } search: {
            LibrarySearchField(text: $searchText, prompt: searchPrompt, shortPrompt: searchShortPrompt)
                .modifier(LibrarySearchReveal(stage: stage))
        } sort: {
            LibrarySortControl(label: sortLabel) { sortMenu }
                .id(stage.snappedIndex)
        } actions: {
            importButton
        }
    }

    private var sortLabel: Text {
        guard let filter else { return Text(Self.sortTitle(sort)) }
        return Text("\(Text(Self.sortTitle(sort))) · \(Self.filterTitle(filter))")
    }

    @ViewBuilder
    private var sortMenu: some View {
        Picker("Sort", selection: $sort) {
            ForEach(SavedLibraryModel.Sort.allCases, id: \.self) { order in
                Text(Self.sortTitle(order)).tag(order)
            }
        }
        .labelsHidden()
        .pickerStyle(.inline)
        #if !LITE_BUILD
        Section("Filters") {
            ForEach([SavedLibraryModel.Filter.unsupported] + InstalledStorageKind.allCases.map { .storage($0) }, id: \.self) { option in
                Toggle(isOn: Binding(
                    get: { filter == option },
                    set: { filter = $0 ? option : nil }
                )) { Self.filterTitle(option) }
            }
        }
        #endif
    }

    private var importButton: some View {
        GlassIconButton("plus", size: .large, action: onImport)
            .help(Text("Add to Library"))
            .accessibilityLabel(Text("Add to Library"))
    }

    static func sortTitle(_ sort: SavedLibraryModel.Sort) -> LocalizedStringKey {
        switch sort {
        case .recentlyUsed: "Recently Used"
        case .name: "Name"
        case .type: "Type"
        case .size: "Size"
        #if !LITE_BUILD
        case .needsUpdate: "Needs Update"
        #endif
        }
    }

    private static func filterTitle(_ filter: SavedLibraryModel.Filter) -> Text {
        switch filter {
        case .unsupported: Text("Unsupported")
        #if !LITE_BUILD
        case let .storage(kind): Text(verbatim: kind.title)
        #endif
        }
    }
}

/// Fades the search field in over the rise to the library, whose grid it filters. `progress` is read
/// here for the reason `ShelfChromeRide` gives.
struct LibrarySearchReveal: ViewModifier {
    let stage: EditDeskStageModel

    static func opacity(_ progress: Double) -> Double {
        HomeHints.ramp(progress, from: 1, to: 2)
    }

    func body(content: Content) -> some View {
        let opacity = Self.opacity(stage.progress)
        return content
            .opacity(opacity)
            .allowsHitTesting(opacity > ShelfChromeRide.interactiveOpacity)
            .accessibilityHidden(opacity <= ShelfChromeRide.interactiveOpacity)
            // Still mounted on the shelf: a field left focused there would take the keys typed over the
            // shelf, and disabling it ends the edit.
            .disabled(opacity <= ShelfChromeRide.interactiveOpacity)
    }
}

struct LibraryToolbarRow<Filters: View, Search: View, Sort: View, Actions: View>: View {
    @ViewBuilder let filters: Filters
    @ViewBuilder let search: Search
    @ViewBuilder let sort: Sort
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            search
            filters
            Spacer(minLength: DesignTokens.Spacing.md)
            sort
            actions
        }
    }
}

struct LibrarySortControl<Content: View>: View {
    let label: Text
    @ViewBuilder let content: () -> Content

    var body: some View {
        NativeMenuButton {
            content()
        } label: {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                label
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .font(DesignTokens.EditDesk.Typography.body)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: DesignTokens.LibraryFilterBar.controlHeight)
            .adaptiveGlassSurface(.capsule, interactive: true)
        }
        .fixedSize()
        .accessibilityLabel(Text("Sort"))
        .accessibilityValue(label)
    }
}

#Preview("Library toolbar · search leading") {
    VStack(spacing: 24) {
        ForEach([CGFloat(920), CGFloat(760)], id: \.self) { width in
            LibraryToolbarRow {
                FilterChip(title: Text("All"), isSelected: true) {}
                FilterChip(title: Text("Video"), isSelected: false) {}
                FilterChip(title: Text("Scene"), isSelected: false) {}
                FilterChip(title: Text("Web"), isSelected: false) {}
            } search: {
                LibrarySearchField(text: .constant(""), prompt: "Search wallpapers")
            } sort: {
                LibrarySortControl(label: Text("Recently Used")) {
                    Button("Recently Used") {}
                    Button("Name") {}
                }
            } actions: {
                GlassIconButton("plus", size: .large) {}
            }
            .frame(width: width)
        }
    }
    .padding(24)
    .background(DesignTokens.Colors.surfaceRaised)
}
