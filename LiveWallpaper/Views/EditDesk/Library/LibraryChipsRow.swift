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
    /// Drives the search field's reveal; the rest of the row rides the shelf in `ShelfChromeRide`.
    let stage: EditDeskStageModel
    @Binding var sort: SavedLibraryModel.Sort
    let onImport: () -> Void

    @State private var sortPresented = false

    var body: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            ForEach(chips) { chip in
                FilterChip(title: Text(chip.title), isSelected: selection == chip.id) {
                    selection = chip.id
                }
            }
            Spacer(minLength: DesignTokens.EditDesk.Spacing.s12)
            LibrarySearchField(text: $searchText, prompt: searchPrompt)
                .modifier(LibrarySearchReveal(stage: stage))
            sortControl
            importButton
        }
    }

    private var sortControl: some View {
        Button { sortPresented.toggle() } label: {
            HStack(spacing: 2) {
                Text(Self.sortTitle(sort))
                Text(verbatim: "▾")
            }
            .font(DesignTokens.EditDesk.Typography.chip)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
        }
        .adaptiveGlassButton(.regular, shape: .capsule, size: .regular)
        .fixedSize()
        .accessibilityLabel(Text("Sort"))
        .accessibilityValue(Text(Self.sortTitle(sort)))
        .appLanguagePopover(isPresented: $sortPresented, arrowEdge: .bottom) { sortMenu }
        .onChange(of: stage.snappedIndex) { sortPresented = false }
    }

    private var sortMenu: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach([SavedLibraryModel.Sort.recentlyUsed, .name, .type], id: \.self) { order in
                Button(Self.sortTitle(order)) {
                    sort = order
                    sortPresented = false
                }
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPopoverChrome(width: 200)
    }

    private var importButton: some View {
        GlassIconButton("plus", size: .regular, action: onImport)
            .help(Text("Add to Library"))
            .accessibilityLabel(Text("Add to Library"))
    }

    private static func sortTitle(_ sort: SavedLibraryModel.Sort) -> LocalizedStringKey {
        switch sort {
        case .recentlyUsed: "Recently Used"
        case .name: "Name"
        case .type: "Type"
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
