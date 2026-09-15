import SwiftUI

public struct LibraryFilterBar<Filters: View>: View {
    @Binding private var searchText: String
    private let searchPrompt: LocalizedStringKey
    private let isDisabled: Bool
    private let filters: Filters

    public init(
        searchText: Binding<String>,
        searchPrompt: LocalizedStringKey = "Search",
        isDisabled: Bool = false,
        @ViewBuilder filters: () -> Filters
    ) {
        _searchText = searchText
        self.searchPrompt = searchPrompt
        self.isDisabled = isDisabled
        self.filters = filters()
    }

    public var body: some View {
        HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
            LibrarySearchField(text: $searchText, prompt: searchPrompt)

            filters
        }
        // Not a trailing `Spacer`: it would split the slack with the filters' own
        // `maxWidth: .infinity` and pull the sort picker off the right edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
        .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)
        .disabled(isDisabled)
    }
}

public extension LibraryFilterBar where Filters == EmptyView {
    init(
        searchText: Binding<String>,
        searchPrompt: LocalizedStringKey = "Search",
        isDisabled: Bool = false
    ) {
        self.init(
            searchText: searchText,
            searchPrompt: searchPrompt,
            isDisabled: isDisabled,
            filters: { EmptyView() }
        )
    }
}
