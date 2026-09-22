import LiveWallpaperCore
import SwiftUI

/// Bottom section of the overlay column. Collapsed it is one row; expanded it offers every
/// object this display can carry, each added by click at the board's first free slot.
struct AddOverlayDrawer: View {
    let session: OverlayEditorSession
    @Binding var isExpanded: Bool
    let height: CGFloat
    var horizontal = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var category: OverlayAddCategory = .all
    @State private var boardFull = false
    @State private var noticeGeneration = 0

    private static let columns = 4
    private static let cellHeight: CGFloat = 46
    /// SCREENS.md S7 says 22; 26 is the minimum hit target from INTERACTIONS.md.
    private static let chipHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.EditDesk.Spacing.s8) {
            toggleRow
            if isExpanded {
                chips
                if horizontal {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(OverlayLayerList.addItems(in: category)) { item in
                                cell(item).frame(width: 100)
                            }
                        }.padding(.bottom, 8)
                    }
                } else {
                    grid
                }
            }
        }
        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s12)
        .frame(height: height, alignment: .top)
        .clipped()
        .task(id: noticeGeneration) {
            guard boardFull else { return }
            try? await Task.sleep(for: .seconds(2))
            boardFull = false
        }
    }

    private var toggleRow: some View {
        Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.82)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
                Text(verbatim: "\(isExpanded ? "−" : "+") \(String(localized: "Add Overlay", bundle: .appLanguage))")
                    .font(DesignTokens.EditDesk.Typography.body)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                Spacer(minLength: 0)
                if boardFull {
                    Text("Board is full")
                        .font(DesignTokens.EditDesk.Typography.badgeMono)
                        .foregroundStyle(DesignTokens.EditDesk.Colors.warning)
                }
            }
            .lineLimit(1)
            .frame(height: OverlayColumnLayout.drawerCollapsedHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add Overlay"))
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
                ForEach(OverlayAddCategory.allCases) { item in
                    chip(item)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: Self.chipHeight)
    }

    private func chip(_ item: OverlayAddCategory) -> some View {
        Button { category = item } label: {
            Text(title(item))
                .font(DesignTokens.EditDesk.Typography.chip)
                .foregroundStyle(
                    category == item
                        ? DesignTokens.EditDesk.Colors.textPrimary
                        : DesignTokens.EditDesk.Colors.textSecondary
                )
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .frame(height: Self.chipHeight)
                .background(
                    Capsule().fill(
                        category == item
                            ? DesignTokens.EditDesk.Colors.fillSelectedChip
                            : DesignTokens.EditDesk.Colors.fillNavPill
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: DesignTokens.EditDesk.Spacing.s8),
                    count: Self.columns
                ),
                spacing: DesignTokens.EditDesk.Spacing.s8
            ) {
                ForEach(OverlayLayerList.addItems(in: category)) { item in
                    cell(item)
                }
            }
            .padding(.bottom, DesignTokens.EditDesk.Spacing.s8)
        }
    }

    private func cell(_ item: OverlayAddItem) -> some View {
        Button { add(item) } label: {
            VStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: icon(item))
                    .font(DesignTokens.EditDesk.Typography.stageTitle)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                Text(verbatim: name(item))
                    .font(DesignTokens.EditDesk.Typography.badgeMono)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.cellHeight)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.gridCard, style: .continuous)
                    .fill(DesignTokens.EditDesk.Colors.fillShell)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.gridCard, style: .continuous)
                    .strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item == .effect && !session.canEditEffect)
        .accessibilityLabel(Text(verbatim: name(item)))
    }

    private func add(_ item: OverlayAddItem) {
        switch item {
        case let .widget(kind):
            guard session.addWidget(kind: kind) else {
                boardFull = true
                noticeGeneration += 1
                return
            }
        case .music:
            session.setMusicEnabled(true)
            session.select(.music)
        case .clock:
            session.setClockEnabled(true)
            session.select(.clock)
        case .effect:
            session.setEffectVisible(true)
            session.select(.effect)
        }
    }

    private func title(_ item: OverlayAddCategory) -> LocalizedStringKey {
        switch item {
        case .all: "All"
        case .system: "System"
        case .weather: "Weather"
        case .music: "Music"
        case .clock: "Clock"
        case .effect: "Effect"
        case .agent: "Agent"
        }
    }

    private func name(_ item: OverlayAddItem) -> String {
        switch item {
        case let .widget(kind): WidgetFactory.displayName(kind)
        case .music: String(localized: "Music", bundle: .appLanguage)
        case .clock: String(localized: "Clock", bundle: .appLanguage)
        case .effect: String(localized: "Effect Layer", bundle: .appLanguage)
        }
    }

    private func icon(_ item: OverlayAddItem) -> String {
        switch item {
        case let .widget(kind): WidgetFactory.icon(kind)
        case .music: "music.note"
        case .clock: "clock"
        case .effect: "sparkles"
        }
    }
}
