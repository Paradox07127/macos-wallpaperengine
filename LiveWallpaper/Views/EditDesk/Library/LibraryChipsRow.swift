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
    /// The search follows the shelf/library state without invalidating the whole toolbar each frame.
    let stage: EditDeskStageModel
    @Binding var sort: SavedLibraryModel.Sort
    @Binding var filter: SavedLibraryModel.Filter?
    let onImport: () -> Void

    var body: some View {
        LibraryToolbarRow(centersFilters: true) {
            ForEach(chips) { chip in
                FilterChip(title: Text(chip.title), isSelected: selection == chip.id) {
                    selection = chip.id
                }
                .pageGuideTarget(chip.id == "aerials" ? .aerials : nil)
            }
        } search: {
            AdaptiveLibrarySearch(text: $searchText, prompt: searchPrompt, shortPrompt: searchShortPrompt, stage: stage)
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

/// Search stays compact on the shelf and in narrow library windows. An active query or edit is
/// always visible, so resizing cannot leave a hidden filter or take the field away while typing.
struct AdaptiveLibrarySearch: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    let shortPrompt: LocalizedStringKey
    let stage: EditDeskStageModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var requested = false
    @FocusState private var focused: Bool

    private var isExpanded: Bool {
        requested || focused || !text.isEmpty
            || (stage.snappedIndex == 2 && stage.stageSize.width >= StageGeometry.designWindow.width)
    }

    var body: some View {
        Group {
            if isExpanded {
                LibrarySearchField(text: $text, prompt: prompt, shortPrompt: shortPrompt,
                                   showsFocusRing: true, focus: $focused)
                    .task(id: requested) {
                        if requested { focused = true }
                    }
                    .onExitCommand {
                        text = ""
                        requested = false
                        focused = false
                    }
            } else {
                GlassIconButton("magnifyingglass", size: .large) { requested = true }
                    .help(Text(prompt))
                    .accessibilityLabel(Text(prompt))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
        .onChange(of: focused) { _, hasFocus in
            if !hasFocus, text.isEmpty { requested = false }
        }
        .onChange(of: stage.snappedIndex) { _, index in
            if index != 2 {
                requested = false
                focused = false
            }
        }
        .disabled(stage.snappedIndex == 0)
    }
}

struct LibraryToolbarRow<Filters: View, Search: View, Sort: View, Actions: View>: View {
    var centersFilters = false
    @ViewBuilder let filters: Filters
    @ViewBuilder let search: Search
    @ViewBuilder let sort: Sort
    @ViewBuilder let actions: Actions

    var body: some View {
        if centersFilters {
            CenteredLibraryToolbarLayout {
                search
                HStack(spacing: DesignTokens.Spacing.sm) { filters }
                HStack(spacing: DesignTokens.Spacing.sm) {
                    sort
                    actions
                }
            }
        } else {
            HStack(spacing: DesignTokens.Spacing.sm) {
                search
                filters
                Spacer(minLength: DesignTokens.Spacing.md)
                sort
                actions
            }
        }
    }
}

/// Keep the filters on the row's centre, independently of the unequal controls at its ends.
/// At narrow widths the search gives back its extra width before the filters move off-centre.
private struct CenteredLibraryToolbarLayout: Layout {
    private let gap = DesignTokens.Spacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let minimumWidth = subviews[0].sizeThatFits(.zero).width + sizes[1].width + sizes[2].width + 2 * gap
        return CGSize(
            width: max(minimumWidth, proposal.width ?? sizes.reduce(2 * gap) { $0 + $1.width }),
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let searchMinimum = subviews[0].sizeThatFits(.zero).width
        let searchMaximum = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: bounds.height)).width
        let filters = subviews[1].sizeThatFits(.unspecified)
        let actions = subviews[2].sizeThatFits(.unspecified)
        let searchWidth = min(searchMaximum, max(searchMinimum,
            min((bounds.width - filters.width) / 2 - gap,
                bounds.width - filters.width - actions.width - 2 * gap)))
        let filtersX = max(searchWidth + gap,
            min((bounds.width - filters.width) / 2,
                bounds.width - actions.width - gap - filters.width))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: searchWidth, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + filtersX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(filters))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(actions))
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
            // Menu's relative .primary can inherit a light native trigger style.
            .foregroundStyle(DesignTokens.Colors.textPrimary)
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
