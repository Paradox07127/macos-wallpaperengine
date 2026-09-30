import LiveWallpaperCore
import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsNavigation?
    @Binding var searchText: String
    @Binding var pendingSearchAnchor: SettingsSearchAnchor?
    /// Bumped on every pick of a search result, including one that changes neither the page nor the anchor.
    var searchRequest: Binding<Int> = .constant(0)

    @Environment(\.featureCatalog) private var featureCatalog

    private var results: [SettingsNavigationSearchResult] {
        SettingsNavigation.filteredResults(
            matching: searchText,
            capabilities: featureCatalog.capabilities,
            includeWorkshopOnline: featureCatalog.isEnabled(.workshopOnline)
        )
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sidebarSelection: Binding<SettingsNavigation?> {
        Binding(
            get: { isSearching ? nil : selection },
            set: { newSelection in
                if isSearching, let newSelection {
                    pendingSearchAnchor = results.first { $0.destination == newSelection }?.anchor
                    searchRequest.wrappedValue += 1
                }
                selection = newSelection
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSidebarSearchField(text: $searchText)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.sm)

            List(selection: sidebarSelection) {
                // Search ranks across the whole window, so its hits stay one flat list;
                // grouping them would scatter the best match down the column.
                if isSearching {
                    Section {
                        if results.isEmpty {
                            emptySearchRow
                        } else {
                            rows(for: results)
                        }
                    } header: {
                        SidebarSectionHeader(title: "Search Results")
                    }
                } else {
                    ForEach(SettingsNavigationGroup.allCases) { group in
                        let groupResults = results.filter { $0.item.group == group }
                        if !groupResults.isEmpty {
                            Section {
                                rows(for: groupResults)
                            } header: {
                                SidebarSectionHeader(title: group.title)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .navigationSplitViewColumnWidth(
            min: SettingsWindowMetrics.sidebarColumnWidth,
            ideal: SettingsWindowMetrics.sidebarColumnWidth,
            max: SettingsWindowMetrics.sidebarColumnMaxWidth
        )
        .onAppear {
            if selection == nil {
                selection = results.first?.destination ?? .general
            }
        }
    }

    private func rows(for results: [SettingsNavigationSearchResult]) -> some View {
        ForEach(results) { result in
            // A tag, not a NavigationLink: the Edit Desk hosts this list outside any navigation container, where links draw disabled.
            SettingsSidebarRow(result: result)
                .tag(result.destination)
                .accessibilityHint(Text("Open settings category"))
        }
    }

    private var emptySearchRow: some View {
        Label("No settings found", systemImage: "magnifyingglass")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

private struct SettingsSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: SettingsSidebarMetrics.searchContentSpacing) {
            Image(systemName: "magnifyingglass")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Input(text: $text)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DesignTokens.Typography.captionEmphasized)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(Text("Clear search"))
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: SettingsSidebarMetrics.searchMinHeight)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: 1)
        }
    }

    private struct Input: NSViewRepresentable {
        @Binding var text: String

        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(frame: .zero)
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .preferredFont(forTextStyle: .body)
            field.isAutomaticTextCompletionEnabled = false
            field.cell?.usesSingleLineMode = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.delegate = context.coordinator
            return field
        }

        func updateNSView(_ field: NSTextField, context: Context) {
            context.coordinator.text = $text
            if field.stringValue != text {
                field.stringValue = text
            }
            let prompt = String(localized: "Search Settings", bundle: .appLanguage)
            field.placeholderString = prompt
            field.setAccessibilityLabel(prompt)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(text: $text)
        }

        final class Coordinator: NSObject, NSTextFieldDelegate {
            var text: Binding<String>

            init(text: Binding<String>) {
                self.text = text
            }

            func controlTextDidChange(_ notification: Notification) {
                guard let field = notification.object as? NSTextField else { return }
                text.wrappedValue = field.stringValue
            }
        }
    }
}

private struct SettingsSidebarRow: View {
    let result: SettingsNavigationSearchResult

    var body: some View {
        HStack(spacing: SettingsSidebarMetrics.rowContentSpacing) {
            Image(systemName: result.systemImage)
                .frame(width: SettingsSidebarMetrics.rowIconWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(LocalizedStringKey(result.title))
                    .marqueeOnHover(truncationMode: .tail)

                if let matchHint = result.matchHint {
                    Text("Matched: \(matchHint)")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .marqueeOnHover(truncationMode: .tail)
                }
            }
        }
        // Explicit: left to the list, the row dims to the secondary colour whenever the window is not key.
        .foregroundStyle(.primary)
    }
}

private enum SettingsSidebarMetrics {
    static let searchContentSpacing: CGFloat = 7
    static let searchMinHeight: CGFloat = 30
    static let rowContentSpacing: CGFloat = 7
    static let rowIconWidth: CGFloat = 18
}

struct SidebarSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption)
            .bold()
            .foregroundStyle(.secondary)
            .padding(.top, DesignTokens.Sidebar.sectionHeaderTopPadding)
            .padding(.bottom, DesignTokens.Sidebar.sectionHeaderBottomPadding)
    }
}
