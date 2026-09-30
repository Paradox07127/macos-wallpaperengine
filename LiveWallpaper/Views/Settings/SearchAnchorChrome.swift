import LiveWallpaperCore
import SwiftUI

private struct HighlightedSettingsSearchAnchorKey: EnvironmentKey {
    static let defaultValue: SettingsSearchAnchor? = nil
}

extension EnvironmentValues {
    var highlightedSettingsSearchAnchor: SettingsSearchAnchor? {
        get { self[HighlightedSettingsSearchAnchorKey.self] }
        set { self[HighlightedSettingsSearchAnchorKey.self] = newValue }
    }

    /// The settings sidebar's search text, so the page shown beside it can mark what it found.
    @Entry var settingsSearchQuery = ""
    /// Counts the search results picked in the settings sidebar; each pick asks the page to find its row again.
    @Entry var settingsSearchRequest = 0
}

extension View {
    func settingsSearchAnchorScroller(
        page: SettingsNavigation,
        pendingSearchAnchor: Binding<SettingsSearchAnchor?>
    ) -> some View {
        modifier(SettingsSearchAnchorScrollModifier(page: page, pendingSearchAnchor: pendingSearchAnchor))
    }

    func settingsSearchAnchorTarget(
        _ anchor: SettingsSearchAnchor,
        cornerRadius: CGFloat = DesignTokens.Corner.sm
    ) -> some View {
        modifier(SettingsSearchAnchorTargetModifier(anchor: anchor, cornerRadius: cornerRadius))
    }
}

struct SettingsSearchSectionHeader: View {
    private let titleKey: String
    private let anchor: SettingsSearchAnchor

    @Environment(\.highlightedSettingsSearchAnchor) private var highlightedAnchor

    init(_ titleKey: String, anchor: SettingsSearchAnchor) {
        self.titleKey = titleKey
        self.anchor = anchor
    }

    var body: some View {
        Text(LocalizedStringKey(titleKey))
            .font(DesignTokens.Typography.sectionTitle)
            .id(anchor)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                        .fill(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.selectedFill))
                        .padding(.horizontal, -6)
                        .padding(.vertical, -3)
                }
            }
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                        .stroke(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.quietStroke), lineWidth: 0.5)
                        .padding(.horizontal, -6)
                        .padding(.vertical, -3)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: isHighlighted)
    }

    private var isHighlighted: Bool {
        highlightedAnchor == anchor
    }
}

private struct SettingsSearchAnchorScrollModifier: ViewModifier {
    let page: SettingsNavigation
    @Binding var pendingSearchAnchor: SettingsSearchAnchor?

    @State private var highlightedAnchor: SettingsSearchAnchor?
    @State private var marks: SettingsSearchMarks?
    @State private var presentRows: [String] = []
    @State private var scrollTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsSearchQuery) private var query
    @Environment(\.settingsSearchRequest) private var searchRequest
    @Environment(\.featureCatalog) private var featureCatalog

    /// Long enough to find the row by eye with nothing moving; the mark is static for all of it.
    private static let emphasisDuration: Duration = .seconds(3)
    /// One render pass, for the rows the marks reach to report that they are on the page.
    private static let markSettleDelay: Duration = .milliseconds(100)

    private var item: SettingsNavigationItem? {
        SettingsNavigation.allItems.first { $0.destination == page }
    }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(\.highlightedSettingsSearchAnchor, highlightedAnchor)
                .environment(\.settingsSearchMarks, marks)
                .onPreferenceChange(SettingsSearchPresenceKey.self) { presentRows = $0 }
                .onAppear {
                    if pendingSearchAnchor != nil || !query.isEmpty {
                        schedule(with: proxy)
                    }
                }
                // Clearing the anchor below lands here too; that is not a new request.
                .onChange(of: pendingSearchAnchor) { _, anchor in
                    if anchor != nil {
                        schedule(with: proxy)
                    }
                }
                // A pick on the page already showing changes neither the page nor, for a result without a section, the anchor.
                .onChange(of: searchRequest) {
                    schedule(with: proxy)
                }
                .onDisappear {
                    scrollTask?.cancel()
                }
        }
    }

    private func schedule(with proxy: ScrollViewProxy) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            let handled = item?.searchTargets(capabilities: .pro.withWorkshopOnline()).map(\.anchor) ?? []
            let anchor = pendingSearchAnchor.flatMap { handled.contains($0) ? $0 : nil }
            if anchor != nil {
                pendingSearchAnchor = nil
            }
            // A deep link into a section the query did not land in gets the section alone.
            let focus = item?.searchFocus(matching: query, capabilities: featureCatalog.capabilities)
                .flatMap { anchor == nil || $0.anchor == anchor ? $0 : nil }
            guard anchor != nil || focus != nil else { return }

            marks = focus.map { SettingsSearchMarks(rows: $0.rows) }
            highlightedAnchor = nil
            try? await Task.sleep(for: Self.markSettleDelay)
            guard !Task.isCancelled else { return }
            if let row = focus?.scrollRow, presentRows.contains(row) {
                move { proxy.scrollTo(SettingsSearchRowID(row), anchor: .center) }
            } else if let section = anchor ?? focus?.anchor {
                move {
                    proxy.scrollTo(section, anchor: .top)
                    highlightedAnchor = section
                }
            }

            try? await Task.sleep(for: Self.emphasisDuration)
            guard !Task.isCancelled else { return }
            move {
                marks = nil
                highlightedAnchor = nil
            }
        }
    }

    private func move(_ change: () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(.easeInOut(duration: 0.22), change)
        }
    }
}

private struct SettingsSearchAnchorTargetModifier: ViewModifier {
    let anchor: SettingsSearchAnchor
    let cornerRadius: CGFloat

    @Environment(\.highlightedSettingsSearchAnchor) private var highlightedAnchor

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.dragFill))
                }
            }
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.quietStroke), lineWidth: 1)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: isHighlighted)
    }

    private var isHighlighted: Bool {
        highlightedAnchor == anchor
    }
}
