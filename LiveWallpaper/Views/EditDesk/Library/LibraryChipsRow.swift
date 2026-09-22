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

struct LibraryChipsRow<SortMenu: View>: View {
    let chips: [LibraryChip]
    @Binding var selection: String
    let sortTitle: LocalizedStringKey
    @ViewBuilder let sortMenu: () -> SortMenu
    let onImport: () -> Void
    var showsActions = true

    var body: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            ForEach(chips) { chip in
                FilterChip(title: Text(chip.title), isSelected: selection == chip.id) {
                    selection = chip.id
                }
            }
            Spacer(minLength: DesignTokens.EditDesk.Spacing.s12)
            if showsActions {
                sortControl
                importButton
            }
        }
    }

    private var sortControl: some View {
        Menu {
            sortMenu()
        } label: {
            HStack(spacing: 2) {
                Text(sortTitle)
                Text(verbatim: "▾")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .font(DesignTokens.EditDesk.Typography.chip)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
        .fixedSize()
    }

    private var importButton: some View {
        Button(action: onImport) {
            Text("+ Import")
                .font(DesignTokens.EditDesk.Typography.chip)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(DesignTokens.EditDesk.Colors.fillNavPill))
        }
        .buttonStyle(.plain)
    }
}
