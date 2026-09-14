import SwiftUI

public struct LibraryFilterBar<Filters: View>: View {
    @Binding private var searchText: String
    private let searchPrompt: LocalizedStringKey
    private let resultCount: Int?
    private let totalCount: Int?
    private let isDisabled: Bool
    private let filters: Filters

    public init(
        searchText: Binding<String>,
        searchPrompt: LocalizedStringKey = "Search",
        resultCount: Int? = nil,
        totalCount: Int? = nil,
        isDisabled: Bool = false,
        @ViewBuilder filters: () -> Filters
    ) {
        self._searchText = searchText
        self.searchPrompt = searchPrompt
        self.resultCount = resultCount
        self.totalCount = totalCount
        self.isDisabled = isDisabled
        self.filters = filters()
    }

    public var body: some View {
        HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
            LibrarySearchField(text: $searchText, prompt: searchPrompt)

            filters

            Spacer(minLength: DesignTokens.LibraryFilterBar.contentSpacing)

            // `resultCount: nil` = the page states its own composition elsewhere, so only
            // the library size shows here.
            if let totalCount {
                resultCounter(resultCount, totalCount)
            }
        }
        .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
        .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)
        .disabled(isDisabled)
    }

    // MARK: - Result counter

    private func resultCounter(_ visible: Int?, _ total: Int) -> some View {
        let narrowed = visible.map { $0 != total } ?? false
        return Text(verbatim: narrowed ? "\(visible ?? total)/\(total)" : "\(total)")
            .font(DesignTokens.Typography.metric)
            .foregroundStyle(.secondary)
            .help(narrowed
                ? Text("\(visible ?? total) of \(total) shown")
                : Text("\(total) items"))
    }
}

extension LibraryFilterBar where Filters == EmptyView {
    public init(
        searchText: Binding<String>,
        searchPrompt: LocalizedStringKey = "Search",
        resultCount: Int? = nil,
        totalCount: Int? = nil,
        isDisabled: Bool = false
    ) {
        self.init(
            searchText: searchText,
            searchPrompt: searchPrompt,
            resultCount: resultCount,
            totalCount: totalCount,
            isDisabled: isDisabled,
            filters: { EmptyView() }
        )
    }
}
