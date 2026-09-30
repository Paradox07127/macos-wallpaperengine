#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Five nearby pages, with shortcuts to the first and (when known) last page.
enum BrowsePageWindow {
    nonisolated static func pages(currentPage: Int, totalPages: Int?, hasNextPage: Bool, windowSize: Int = 5) -> [Int] {
        let current = min(max(1, currentPage), BrowseViewModel.maxQueryPage)
        let upper = min(BrowseViewModel.maxQueryPage, max(current, totalPages ?? (current + (hasNextPage ? 1 : 0))))
        let count = min(max(1, windowSize), upper)
        let start = max(1, min(current - count / 2, upper - count + 1))
        var pages = Array(start ..< start + count)
        if start > 1 {
            pages.insert(1, at: 0)
        }
        if totalPages != nil, let last = pages.last, last < upper {
            pages.append(upper)
        }
        return pages
    }
}

struct BrowsePagination: View {
    let currentPage: Int
    let totalPages: Int?
    let hasNextPage: Bool
    var isBusy = false
    var isRateLimited = false
    /// Returns the committed page, including after a failed or clamped jump.
    let onSelectPage: (Int) async -> Int

    @State private var pageJumpText = "1"
    @State private var showsPageJump = false

    private var controlsDisabled: Bool {
        isBusy || isRateLimited
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            navigation(showsLabels: true)
            navigation(showsLabels: false)
            navigation(showsLabels: false, windowSize: 3)
        }
        .onAppear { pageJumpText = String(currentPage) }
        .onChange(of: currentPage) { _, page in pageJumpText = String(page) }
    }

    private func navigation(showsLabels: Bool, windowSize: Int = 5) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button { selectPage(currentPage - 1) } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "chevron.left")
                    if showsLabels {
                        Text("Previous Page")
                    }
                }
                .font(DesignTokens.Typography.caption)
            }
            .adaptiveGlassButton(.regular, size: .regular)
            .disabled(controlsDisabled || currentPage <= 1)
            .accessibilityLabel(Text("Previous Page"))

            pageButtons(windowSize: windowSize)

            Button { selectPage(currentPage + 1) } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if showsLabels {
                        Text("Next Page")
                    }
                    Image(systemName: "chevron.right")
                }
                .font(DesignTokens.Typography.caption)
            }
            .adaptiveGlassButton(.regular, size: .regular)
            .disabled(controlsDisabled || !hasNextPage)
            .accessibilityLabel(Text("Next Page"))

            GlassIconButton("ellipsis", size: .regular) {
                pageJumpText = String(currentPage)
                showsPageJump.toggle()
            }
            .disabled(controlsDisabled)
            .help(Text("Page"))
            .accessibilityLabel(Text("Page"))
            .appLanguagePopover(isPresented: $showsPageJump, arrowEdge: .bottom) {
                jumpControls
                    .padding(DesignTokens.Spacing.md)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pageButtons(windowSize: Int) -> some View {
        let pages = BrowsePageWindow.pages(currentPage: currentPage, totalPages: totalPages, hasNextPage: hasNextPage, windowSize: windowSize)
        return HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                if index > 0, page - pages[index - 1] > 1 {
                    Button { showsPageJump = true } label: {
                        Text(verbatim: "…")
                            .font(DesignTokens.Typography.caption)
                    }
                    .buttonStyle(.plain)
                    .disabled(controlsDisabled)
                    .accessibilityLabel(Text("Page"))
                }
                Button { selectPage(page) } label: {
                    Text(verbatim: String(page))
                        .font(page == currentPage ? DesignTokens.Typography.captionEmphasized : DesignTokens.Typography.caption)
                        .monospacedDigit()
                        .frame(minWidth: DesignTokens.Spacing.lg)
                }
                .adaptiveGlassButton(page == currentPage ? .prominent : .regular, size: .regular)
                .disabled(controlsDisabled)
                .accessibilityLabel(Text("Page"))
                .accessibilityValue(Text(verbatim: String(page)))
                .accessibilityAddTraits(page == currentPage ? .isSelected : [])
            }
        }
    }

    private var jumpControls: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("Page")
                .foregroundStyle(.secondary)
            TextField("Page", text: $pageJumpText)
                .labelsHidden()
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .monospacedDigit()
                .frame(width: (DesignTokens.Spacing.xl + DesignTokens.Spacing.sm) + DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .adaptiveGlassSurface(.capsule)
                .disabled(controlsDisabled)
                .onSubmit { jumpToTypedPage() }
                .accessibilityLabel(Text("Page"))
            if let totalPages {
                Text("of \(totalPages)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(DesignTokens.Typography.caption)
        .fixedSize()
        .overlay(alignment: .trailing) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, -(DesignTokens.Spacing.xl + DesignTokens.Spacing.sm))
            }
        }
    }

    private func selectPage(_ page: Int) {
        guard !controlsDisabled, page != currentPage else { return }
        Task {
            let committed = await onSelectPage(page)
            pageJumpText = String(committed)
        }
    }

    private func jumpToTypedPage() {
        guard let page = Int(pageJumpText.trimmingCharacters(in: .whitespacesAndNewlines)), page != currentPage else {
            pageJumpText = String(currentPage)
            return
        }
        selectPage(page)
        showsPageJump = false
    }
}

#Preview("Pagination · Dark") {
    VStack(spacing: DesignTokens.Spacing.xl) {
        BrowsePagination(currentPage: 1, totalPages: 5, hasNextPage: true) { $0 }
        BrowsePagination(currentPage: 50, totalPages: 1000, hasNextPage: true) { $0 }
        BrowsePagination(currentPage: 1000, totalPages: 1000, hasNextPage: false) { $0 }
        BrowsePagination(currentPage: 3, totalPages: nil, hasNextPage: true, isBusy: true) { $0 }
    }
    .padding(DesignTokens.Spacing.xl)
    .frame(width: 900)
    .preferredColorScheme(.dark)
}

#Preview("Pagination · Compact Light") {
    BrowsePagination(currentPage: 50, totalPages: 1000, hasNextPage: true) { $0 }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 500)
        .preferredColorScheme(.light)
}
#endif
