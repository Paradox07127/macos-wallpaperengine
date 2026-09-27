import SwiftUI

/// The rows a settings search found on the page being shown, by catalog key.
public struct SettingsSearchMarks: Equatable, Sendable {
    public let rows: [String]

    public init(rows: [String]) {
        self.rows = rows
    }
}

/// Where the page scrolls to reach a marked row.
public struct SettingsSearchRowID: Hashable, Sendable {
    public let key: String

    public init(_ key: String) {
        self.key = key
    }
}

/// Catalog keys of the marked rows that are actually on the page; a row hidden by state or hardware reports nothing.
public struct SettingsSearchPresenceKey: PreferenceKey {
    public static let defaultValue: [String] = []

    public static func reduce(value: inout [String], nextValue: () -> [String]) {
        value += nextValue()
    }
}

public extension EnvironmentValues {
    @Entry var settingsSearchMarks: SettingsSearchMarks?
}

public extension View {
    /// Marks this row while a settings search points at `title`, the row's own catalog key; nil never matches.
    func settingsSearchRow(_ title: LocalizedStringKey?) -> some View {
        modifier(SettingsSearchRowMark(title: title))
    }
}

private struct SettingsSearchRowMark: ViewModifier {
    let title: LocalizedStringKey?

    @Environment(\.settingsSearchMarks) private var marks

    private var matchedKey: String? {
        guard let title, let marks else { return nil }
        return marks.rows.first { LocalizedStringKey($0) == title }
    }

    func body(content: Content) -> some View {
        let matchedKey = matchedKey
        return content
            .background {
                if matchedKey != nil {
                    shape
                        .fill(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.selectedFill))
                        .padding(.horizontal, -DesignTokens.Spacing.xs)
                }
            }
            // The stroke sits on top so a row that paints its own background still shows the mark.
            .overlay {
                if let matchedKey {
                    shape
                        .strokeBorder(DesignTokens.Colors.accent.opacity(DesignTokens.Opacity.strongStroke), lineWidth: 1.5)
                        .padding(.horizontal, -DesignTokens.Spacing.xs)
                        .id(SettingsSearchRowID(matchedKey))
                }
            }
            .preference(key: SettingsSearchPresenceKey.self, value: matchedKey.map { [$0] } ?? [])
    }

    private var shape: some InsettableShape {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
    }
}
