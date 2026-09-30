#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

struct BrowseFilterRibbon: View {
    let viewModel: BrowseViewModel
    let hasWebAPIKey: Bool
    @Binding var showsLikes: Bool

    @State private var isFilterPanelExpanded = false
    @State private var filterRowsHeight: CGFloat = 240

    /// Cap on the chip area; beyond it the rows scroll internally rather than growing the ribbon unbounded — at narrow widths Genre wraps onto many rows that would otherwise overrun the layout.
    private static let maxRowsHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            // The grid under the ribbon opens with its own `LibraryGrid.verticalPadding`, which makes up the rest of the gap.
            topRow
                .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
                .padding(.top, DesignTokens.EditDesk.Spacing.filterRowInset)
                .padding(.bottom, DesignTokens.EditDesk.Spacing.filterRowToCards - DesignTokens.LibraryGrid.verticalPadding)

            if isFilterPanelExpanded {
                filterPanel
                    .disabled(controlsDisabled)
            }
        }
    }

    // MARK: - Top row

    private var topRow: some View {
        LibraryToolbarRow {
            WorkshopFiltersToggle(
                isExpanded: $isFilterPanelExpanded,
                activeFilterCount: activeFilterCount,
                isDisabled: controlsDisabled
            )
            // Likes are local: this stays live while the Steam-backed controls are disabled.
            WorkshopLikedToggle(isOn: $showsLikes)
        } search: {
            searchField
            searchTargetMenu
        } sort: {
            sortMenu
            timeFrameMenu
        } actions: {
            EmptyView()
        }
    }

    private var sortMenu: some View {
        LibrarySortControl(label: Text(verbatim: sortLabel(viewModel.preferredSort))) {
            Picker("Sort Order", selection: Binding(
                get: { viewModel.preferredSort },
                set: { viewModel.updateSort($0) }
            )) {
                ForEach(sortOptions) { option in
                    Text(verbatim: sortLabel(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        }
        .disabled(controlsDisabled)
        .help(Text("Sort criteria"))
        .accessibilityLabel(Text("Sort Order"))
    }

    /// Drawn like the library's sort button: `.large` glass is `LibraryFilterBar.controlHeight` tall around a 13pt label.
    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Text(verbatim: title)
            Text(verbatim: "▾")
        }
        .font(DesignTokens.EditDesk.Typography.body)
    }

    /// Search text scope belongs beside the field, as a compact icon action.
    private var searchTargetMenu: some View {
        Menu {
            Section {
                Picker(selection: Binding(
                    get: { viewModel.searchTextTarget },
                    set: { viewModel.searchTextTarget = $0 }
                )) {
                    ForEach(WorkshopSearchTextTarget.allCases) { target in
                        Text(verbatim: target.title).tag(target)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            } header: {
                Text(verbatim: WorkshopSearchTextTarget.menuTitle)
            }
        } label: {
            Image(systemName: viewModel.searchTextTarget == .all ? "text.magnifyingglass" : "doc.text.magnifyingglass")
                .font(DesignTokens.EditDesk.Typography.chip)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .adaptiveGlassButton(.regular, shape: .capsule, size: .regular)
        .fixedSize()
        .disabled(controlsDisabled)
        .help(Text(verbatim: WorkshopSearchTextTarget.menuTitle))
        .accessibilityLabel(Text(verbatim: WorkshopSearchTextTarget.menuTitle))
        .accessibilityValue(Text(verbatim: viewModel.searchTextTarget.title))
    }

    private var timeFrameMenu: some View {
        Menu {
            Picker("Time Frame", selection: Binding(
                get: { timeFrameSelection },
                set: { viewModel.updateTimeFrame($0) }
            )) {
                ForEach(WorkshopTimeFrame.allCases) { option in
                    Text(verbatim: option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            menuLabel(timeFrameSelection.title)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .adaptiveGlassButton(.regular, shape: .capsule, size: .large)
        .fixedSize()
        .disabled(controlsDisabled || !timeFrameApplies)
        .help(Text("Time frame applies to Most Popular"))
        .accessibilityLabel(Text("Time Frame"))
        .accessibilityValue(Text(verbatim: timeFrameSelection.title))
    }

    // MARK: - Expanding filter panel

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    WorkshopFilterRow("Type") {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            ForEach(WorkshopContentTypeFilter.selectableCases) { type in
                                WorkshopFilterChip(
                                    title: Text(type.displayName),
                                    isSelected: viewModel.selectedTypes.contains(type),
                                    onIsolate: { viewModel.isolateType(type) }
                                ) {
                                    viewModel.toggleType(type)
                                }
                            }
                        }
                    }

                    WorkshopFilterRow("Maturity") {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            ForEach(WorkshopAgeRatingFilter.allCases) { rating in
                                WorkshopFilterChip(
                                    title: Text(verbatim: rating.displayName),
                                    isSelected: viewModel.selectedAgeRatings.contains(rating),
                                    onIsolate: { viewModel.isolateAgeRating(rating) }
                                ) {
                                    viewModel.toggleAgeRating(rating)
                                }
                            }
                        }
                    }

                    WorkshopFilterRow("Resolution") {
                        chipFlow {
                            ForEach(WorkshopResolutionFilter.selectableCases) { resolution in
                                WorkshopFilterChip(
                                    title: Text(verbatim: resolution.displayName),
                                    isSelected: viewModel.selectedResolutions.contains(resolution),
                                    onIsolate: { viewModel.isolateResolution(resolution) }
                                ) {
                                    viewModel.toggleResolution(resolution)
                                }
                            }
                        }
                    }

                    WorkshopFilterRow("Genre") {
                        chipFlow {
                            ForEach(WorkshopGenre.allTags, id: \.self) { tag in
                                WorkshopFilterChip(
                                    title: Text(verbatim: WorkshopTagLocalization.displayName(tag)),
                                    isSelected: viewModel.selectedGenres.contains(tag),
                                    onIsolate: { viewModel.isolateGenre(tag) }
                                ) {
                                    viewModel.toggleGenre(tag)
                                }
                            }
                        }
                    }

                    WorkshopFilterRow("Miscellaneous") {
                        chipFlow {
                            ForEach(WorkshopMiscellaneousFilter.allTags, id: \.self) { tag in
                                WorkshopFilterChip(
                                    title: Text(verbatim: WorkshopTagLocalization.displayName(tag)),
                                    isSelected: viewModel.selectedMiscellaneous.contains(tag),
                                    isOptIn: true
                                ) {
                                    viewModel.toggleMiscellaneous(tag)
                                }
                            }
                        }
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: FilterRowsHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(height: min(filterRowsHeight, Self.maxRowsHeight))
            .onPreferenceChange(FilterRowsHeightKey.self) { filterRowsHeight = $0 }

            if activeFilterCount > 0 {
                Button("Clear filters") { viewModel.resetFilters() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.leading, WorkshopFilterLayout.labelWidth + DesignTokens.Spacing.sm)
            }
        }
        .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func chipFlow(@ViewBuilder content: () -> some View) -> some View {
        WorkshopChipFlow(spacing: DesignTokens.Spacing.sm, lineSpacing: DesignTokens.Spacing.sm) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Search / refresh / status

    private var searchField: some View {
        LibrarySearchField(
            text: Binding(
                get: { viewModel.searchInput },
                set: { viewModel.searchInput = $0 }
            ),
            prompt: "Search the Workshop",
            isDisabled: controlsDisabled,
            onSubmit: { Task { await viewModel.submitSearch() } },
            onClear: { Task { await viewModel.clearSearch() } }
        )
    }

    // MARK: - Helpers

    private var controlsDisabled: Bool {
        !hasWebAPIKey || viewModel.isRateLimited
    }

    /// Counts categories moved away from their default — selecting everything is no
    /// filter, Miscellaneous starts empty, and maturity starts at Everyone, so a
    /// fresh browse reads as zero.
    var activeFilterCount: Int {
        var count = 0
        if !viewModel.selectedMiscellaneous.isEmpty {
            count += 1
        }
        if WorkshopFilterMath.isNarrowing(viewModel.selectedTypes, total: WorkshopContentTypeFilter.selectableCases.count) {
            count += 1
        }
        if viewModel.selectedAgeRatings != WorkshopAgeRatingFilter.defaultSelection {
            count += 1
        }
        if WorkshopFilterMath.isNarrowing(viewModel.selectedResolutions, total: WorkshopResolutionFilter.selectableCases.count) {
            count += 1
        }
        if WorkshopFilterMath.isNarrowing(viewModel.selectedGenres, total: WorkshopGenre.allTags.count) {
            count += 1
        }
        return count
    }

    private var timeFrameApplies: Bool {
        viewModel.preferredSort == .mostPopular
    }

    private var timeFrameSelection: WorkshopTimeFrame {
        timeFrameApplies ? viewModel.preferredTimeFrame : .allTime
    }

    // MARK: - Sort / time frame options

    private static let browseSortOptions: [WorkshopSortMode] = [
        .mostPopular, .topRated, .newest, .lastUpdated, .mostSubscribed,
    ]

    /// Relevance only ranks against a search text. Trimmed like the request layer:
    /// whitespace-only input would show "Relevance" over a Top Rated query.
    private var sortOptions: [WorkshopSortMode] {
        viewModel.searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.browseSortOptions
            : Self.browseSortOptions + [.search]
    }

    private func sortLabel(_ sort: WorkshopSortMode) -> String {
        guard sort == .mostPopular else { return sort.title }
        return String(
            localized: "workshop.sort.most_popular_with_window",
            defaultValue: "\(sort.title) (\(viewModel.preferredTimeFrame.title))",
            bundle: .appLanguage, comment: "Workshop sort button: sort name, then the Most Popular window (Steam's Workshop_BrowseSort_Combined)."
        )
    }
}

extension WorkshopSortMode {
    var title: String {
        switch self {
        case .mostPopular: String(localized: "Most Popular", bundle: .appLanguage, comment: "Workshop sort (Steam's Workshop_BrowseSort_MostPopular).")
        case .topRated: String(localized: "Top Rated All Time", bundle: .appLanguage, comment: "Workshop sort (Steam's Workshop_BrowseSort_TopRated).")
        case .newest: String(localized: "Most Recent", bundle: .appLanguage, comment: "Workshop sort (Steam's Workshop_BrowseSort_MostRecent).")
        case .lastUpdated: String(localized: "Last Updated", bundle: .appLanguage, comment: "Workshop sort (Steam's Workshop_BrowseSort_LastUpdated).")
        case .mostSubscribed: String(localized: "Total Unique Subscribers", bundle: .appLanguage, comment: "Workshop sort (Steam's Workshop_BrowseSort_TotalUniqueSubscribers).")
        case .search: String(localized: "Search Relevance", bundle: .appLanguage, comment: "Workshop sort offered while a search text is typed (Steam's Workshop_BrowseSort_SearchRelevance).")
        }
    }
}

extension WorkshopSearchTextTarget {
    static var menuTitle: String {
        String(localized: "Specify what text fields of the item you want to search:", bundle: .appLanguage, comment: "Workshop search-target menu header (Steam's Workshop_SearchTarget_MenuTitle).")
    }

    var title: String {
        switch self {
        case .all: String(localized: "Title & Description", bundle: .appLanguage, comment: "Workshop search target: full text (Steam's Workshop_SearchTarget_All).")
        case .titleOnly: String(localized: "Title Only", bundle: .appLanguage, comment: "Workshop search target (Steam's Workshop_SearchTarget_Title).")
        case .descriptionOnly: String(localized: "Description Only", bundle: .appLanguage, comment: "Workshop search target (Steam's Workshop_SearchTarget_Description).")
        }
    }
}

extension WorkshopTimeFrame {
    var title: String {
        switch self {
        case .today: String(localized: "Today", bundle: .appLanguage, comment: "Workshop Most Popular window (Steam's SharedFiles_Browse_Trend_Option_Today).")
        case .oneWeek: String(localized: "One Week", bundle: .appLanguage, comment: "Workshop Most Popular window (Steam's SharedFiles_Browse_Trend_Option_Week).")
        case .thirtyDays: String(localized: "Thirty Days", bundle: .appLanguage, comment: "Workshop Most Popular window (Steam's SharedFiles_Browse_Trend_Option_Month).")
        case .threeMonths: String(localized: "Three Months", bundle: .appLanguage, comment: "Workshop Most Popular window (Steam's SharedFiles_Browse_Trend_Option_ThreeMonths).")
        case .sixMonths: String(localized: "Six Months", bundle: .appLanguage, comment: "Workshop Most Popular window (Steam's SharedFiles_Browse_Trend_Option_SixMonths).")
        case .oneYear: String(localized: "One Year", bundle: .appLanguage, comment: "Workshop Most Popular window (Steam's SharedFiles_Browse_Trend_Option_OneYear).")
        case .allTime: String(localized: "All Time", bundle: .appLanguage, comment: "Workshop time menu: switches Most Popular to Top Rated (Steam's SharedFiles_Browse_Trend_Option_AllTime).")
        }
    }
}

/// Filter chip in the *deselect-to-hide* model: every option is selected (shown) by default, and tapping a chip deselects it to exclude that tag.
struct WorkshopFilterChip: View {
    let title: Text
    let isSelected: Bool
    /// How many library entries this option matches. `nil` on categories where a
    /// count says nothing (Browse's server-side sort, day range).
    var count: Int?
    /// Option-click: collapse the category to just this option. `nil` disables
    /// the shortcut (and its hint).
    var onIsolate: (() -> Void)?
    /// Opt-in rows (Miscellaneous) start with nothing selected, so an
    /// unselected chip is "off", not "hidden": no strike-through, no dimming.
    var isOptIn = false
    let action: () -> Void

    var body: some View {
        Button {
            if let onIsolate, NSEvent.modifierFlags.contains(.option) {
                onIsolate()
            } else {
                action()
            }
        } label: {
            HStack(spacing: 5) {
                title
                    .lineLimit(1)
                    .strikethrough(!isSelected && !isOptIn, color: .secondary)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                }
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .opacity(isSelected || isOptIn ? 1 : 0.5)
            .padding(.horizontal, 10)
            .frame(minHeight: DesignTokens.LibraryFilterBar.controlHeight)
            .filterChipBackground(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .help(onIsolate != nil
            ? Text("Click to show/hide · Option-click to show only this")
            : Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isOptIn ? (isSelected ? Text("On") : Text("Off")) : (isSelected ? Text("Shown") : Text("Hidden")))
    }
}

private struct FilterRowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat {
        0
    }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#endif
