#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Steam does not return remaining quota, so we can only truthfully show an "issued from this Mac today" count — never a "remaining" figure.
enum WorkshopRequestCounter {
    private static let countKey = "loomscreen.workshop.requestsToday.count"
    private static let dateKey = "loomscreen.workshop.requestsToday.date"

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func countForToday(defaults: UserDefaults = .appScoped()) -> Int {
        guard defaults.string(forKey: dateKey) == todayString() else { return 0 }
        return defaults.integer(forKey: countKey)
    }

    static func increment(defaults: UserDefaults = .appScoped()) {
        let today = todayString()
        if defaults.string(forKey: dateKey) == today {
            defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
        } else {
            defaults.set(today, forKey: dateKey)
            defaults.set(1, forKey: countKey)
        }
    }
}

/// Filter ribbon for the Workshop (online) tab.
struct BrowseFilterRibbon: View {
    let viewModel: BrowseViewModel
    let hasWebAPIKey: Bool

    @State private var isFilterPanelExpanded = false
    @State private var filterRowsHeight: CGFloat = 240

    /// Cap on the chip area; beyond it the rows scroll internally rather than growing the ribbon unbounded — at narrow widths Genre wraps onto many rows that would otherwise overrun the layout.
    private static let maxRowsHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
                .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)

            if isFilterPanelExpanded {
                filterPanel
                    .disabled(controlsDisabled)
            }
        }
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
            searchField
            searchTargetMenu

            WorkshopFiltersToggle(
                isExpanded: $isFilterPanelExpanded,
                activeFilterCount: activeFilterCount,
                isDisabled: controlsDisabled
            )

            Spacer(minLength: DesignTokens.Spacing.sm)

            sortMenu
            timeFrameMenu
        }
    }

    private var sortMenu: some View {
        Picker("Sort Order", selection: Binding(
            get: { viewModel.preferredSort },
            set: { viewModel.updateSort($0) }
        )) {
            ForEach(sortOptions) { option in
                Text(verbatim: sortLabel(option)).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .disabled(controlsDisabled)
        .help(Text("Sort criteria"))
    }

    /// Steam's own "Specify what text fields…" menu, next to the search box.
    /// The gear fills while a narrower target is active — a `Menu` label
    /// ignores `foregroundStyle`, so a tint could not say it.
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
            Image(systemName: viewModel.searchTextTarget == .all ? "gearshape" : "gearshape.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(controlsDisabled)
        .help(Text(verbatim: WorkshopSearchTextTarget.menuTitle))
        .accessibilityLabel(Text(verbatim: WorkshopSearchTextTarget.menuTitle))
        .accessibilityValue(Text(verbatim: viewModel.searchTextTarget.title))
    }

    private var timeFrameMenu: some View {
        Picker("Time Frame", selection: Binding(
            get: { timeFrameSelection },
            set: { viewModel.updateTimeFrame($0) }
        )) {
            ForEach(WorkshopTimeFrame.allCases) { option in
                Text(verbatim: option.title).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .disabled(controlsDisabled || !timeFrameApplies)
        .help(Text("Time frame applies to Most Popular"))
    }

    // MARK: - Expanding filter panel

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    WorkshopFilterRow("Type") {
                        HStack(spacing: 6) {
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
                        HStack(spacing: 6) {
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
                    .padding(.leading, 74 + DesignTokens.Spacing.sm)
            }
        }
        .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Wrapping chip row (replaces a horizontal scroll that hid most options
    /// off-screen) — every tag stays visible across as many lines as it takes.
    private func chipFlow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        WorkshopChipFlow(spacing: 6, lineSpacing: 6) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Search / refresh / status

    private var searchField: some View {
        // Typing auto-searches after the view-model's debounce; clicking the
        // glass or pressing Return (`onSubmit`) skips the wait and runs it now.
        LibrarySearchField(
            text: Binding(
                get: { viewModel.searchInput },
                set: { viewModel.searchInput = $0 }
            ),
            prompt: "Search the Workshop",
            isDisabled: controlsDisabled,
            showsFocusRing: true,
            onSubmit: { Task { await viewModel.submitSearch() } },
            onClear: { Task { await viewModel.clearSearch() } }
        )
    }

    // MARK: - Helpers

    private var controlsDisabled: Bool {
        !hasWebAPIKey || viewModel.isRateLimited
    }

    /// Count of categories the user moved away from their default — selecting
    /// everything is no filter, Miscellaneous starts empty, and maturity starts
    /// at Everyone, so a fresh browse reads as zero. Surfaced as the Filters
    /// badge, which is also what offers "Clear filters".
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
        .mostPopular, .topRated, .newest, .lastUpdated, .mostSubscribed
    ]

    /// Relevance only ranks against a search text, so it appears while one is
    /// typed. Trimmed, because the request layer also trims: offering it for
    /// whitespace-only input would show "Relevance" over a Top Rated query.
    private var sortOptions: [WorkshopSortMode] {
        viewModel.searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.browseSortOptions
            : Self.browseSortOptions + [.search]
    }

    /// The page's sort button reads "Most Popular (One Week)": the window is
    /// part of that one sort, so it is named with it.
    private func sortLabel(_ sort: WorkshopSortMode) -> String {
        guard sort == .mostPopular else { return sort.title }
        return String(
            localized: "workshop.sort.most_popular_with_window",
            defaultValue: "\(sort.title) (\(viewModel.preferredTimeFrame.title))",
            bundle: .appLanguage, comment: "Workshop sort button: sort name, then the Most Popular window (Steam's Workshop_BrowseSort_Combined)."
        )
    }
}

/// Steam's own labels (Workshop_BrowseSort_* / SharedFiles_Browse_Trend_Option_*),
/// so a Wallpaper Engine user recognises each option from the Workshop page.
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

/// Steam's Workshop_SearchTarget_* copy.
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
                    // The library's composition, read straight off the chips that
                    // filter by it — one place instead of a ratio in the search
                    // bar that said how many were showing but not of what.
                    Text(verbatim: "\(count)")
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                }
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .opacity(isSelected || isOptIn ? 1 : 0.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
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

/// Carries the chip rows' natural height up so the panel sizes its scroll to
/// content (capped at `maxRowsHeight`).
private struct FilterRowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#endif
