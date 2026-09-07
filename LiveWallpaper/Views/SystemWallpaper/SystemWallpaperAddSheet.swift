import AppKit
import LiveWallpaperCore
import SwiftUI

/// Selects videos to add to System Wallpaper in a batch.
@available(macOS 26.0, *)
struct SystemWallpaperAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WallpaperExportService.self) private var service
    @Environment(\.libraryTileSize) private var tileSize

    @State private var store = BookmarkStore.shared
    @State private var selection: Set<SystemWallpaperCandidate.ID> = []
    @State private var isPublishing = false
    @State private var failures: [String] = []

    private var candidates: [SystemWallpaperCandidate] {
        SystemWallpaperCandidate.all(bookmarks: store.bookmarks, service: service)
    }

    var body: some View {
        VStack(spacing: 0) {
            SteamSheetHeader(
                icon: "macwindow.on.rectangle",
                title: "Add to System Wallpaper",
                iconTint: .accentColor,
                subtitle: "macOS saves a video copy that can play with Loomscreen closed."
            )
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.top, DesignTokens.Settings.formVerticalMargin)

            chooseFilesRow
                .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                .padding(.vertical, DesignTokens.Spacing.md)

            Divider()
            body(for: candidates)
            if !failures.isEmpty {
                Text(verbatim: failures.joined(separator: "\n"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            }

            Divider()

            SheetFooterBar(
                primaryTitle: "Add",
                primaryAction: publishSelection,
                primaryDisabled: selection.isEmpty || isPublishing,
                cancelTitle: "Cancel",
                cancelAction: { dismiss() }
            )
        }
        .frame(width: 620, height: 560)
        .background(DesignTokens.Colors.pageBackground)
    }

    @ViewBuilder
    private func body(for candidates: [SystemWallpaperCandidate]) -> some View {
        if candidates.isEmpty {
            IllustratedEmptyState(
                symbol: "film.stack",
                title: "No saved videos"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: DesignTokens.LibraryGrid.columns(for: tileSize),
                    spacing: DesignTokens.LibraryGrid.spacing
                ) {
                    ForEach(candidates) { candidate in
                        SystemWallpaperCandidateTile(
                            candidate: candidate,
                            isSelected: selection.contains(candidate.id),
                            onToggle: { toggle(candidate) }
                        )
                    }
                }
                .padding(DesignTokens.Spacing.lg)
            }
        }
    }

    private var chooseFilesRow: some View {
        Button {
            SystemWallpaperVideoImport.present(publishingInto: service)
            dismiss()
        } label: {
            Label("Choose Files…", systemImage: "folder.badge.plus")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func toggle(_ candidate: SystemWallpaperCandidate) {
        if selection.contains(candidate.id) {
            selection.remove(candidate.id)
        } else {
            selection.insert(candidate.id)
        }
    }

    /// Accumulate per-item errors because later successes clear the service's `lastError`.
    private func publishSelection() {
        let chosen = candidates.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        isPublishing = true
        failures = []
        Task { @MainActor in
            var collected: [String] = []
            for candidate in chosen {
                do {
                    try await candidate.publish(using: service)
                    selection.remove(candidate.id)
                } catch {
                    collected.append("\(candidate.title): \(error.localizedDescription)")
                }
            }
            isPublishing = false
            failures = collected
            if collected.isEmpty {
                dismiss()
            }
        }
    }
}
