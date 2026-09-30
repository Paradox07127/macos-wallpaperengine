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
            LibrarySortControl(label: sortLabel) { dismiss in sortMenu(dismiss: dismiss) }
                .id(stage.snappedIndex)
        } actions: {
            importButton
        }
    }

    private var sortLabel: Text {
        guard let filter else { return Text(Self.sortTitle(sort)) }
        return Text("\(Text(Self.sortTitle(sort))) · \(Self.filterTitle(filter))")
    }

    private func sortMenu(dismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(SavedLibraryModel.Sort.allCases, id: \.self) { order in
                Button(Self.sortTitle(order)) {
                    sort = order
                    dismiss()
                }
            }
            #if !LITE_BUILD
            Divider()
            Text("Filters")
                .font(DesignTokens.Typography.badge)
                .foregroundStyle(.secondary)
            ForEach([SavedLibraryModel.Filter.unsupported] + InstalledStorageKind.allCases.map { .storage($0) }, id: \.self) { option in
                Button {
                    filter = filter == option ? nil : option
                    dismiss()
                } label: {
                    HStack {
                        Self.filterTitle(option)
                        Spacer()
                        if filter == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityAddTraits(filter == option ? .isSelected : [])
            }
            #endif
        }
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
            filters
            Spacer(minLength: DesignTokens.Spacing.md)
            search
            sort
            actions
        }
    }
}

struct LibrarySortControl<Content: View>: View {
    let label: Text
    @ViewBuilder let content: (@escaping () -> Void) -> Content
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                label
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .font(DesignTokens.EditDesk.Typography.body)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
        }
        .adaptiveGlassButton(.regular, shape: .capsule, size: .large)
        .fixedSize()
        .accessibilityLabel(Text("Sort"))
        .accessibilityValue(label)
        .appLanguagePopover(isPresented: $isPresented, arrowEdge: .bottom) {
            content { isPresented = false }
                .frame(maxWidth: .infinity, alignment: .leading)
                .popupMenuOptions(width: 200)
        }
    }
}
