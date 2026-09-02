import AppKit
import LiveWallpaperCore
import SwiftUI

/// Picking what to hand to macOS.
///
/// This was a popover listing candidate videos by filename. Choosing a wallpaper
/// from a column of text is the one thing a wallpaper picker must not ask you to
/// do — the whole library elsewhere in the app is a grid of posters, and this was
/// the only place that wasn't. It is also a step with real consequences (macOS
/// keeps playing the copy after Loomscreen quits), which a menu's one-click-and-
/// gone shape hides.
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
                subtitle: "Loomscreen hands macOS its own copy of the video, so it keeps playing after you quit the app."
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
                title: "Nothing here to hand over yet",
                message: "Bookmark a video and it shows up here. You can also choose a file directly."
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

    /// Kept above the grid rather than inside it: it is a different kind of act —
    /// reaching outside the app — and a tile among posters would read as one more
    /// wallpaper you already have.
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
        .help(Text("Pick a video from disk"))
    }

    private func toggle(_ candidate: SystemWallpaperCandidate) {
        if selection.contains(candidate.id) {
            selection.remove(candidate.id)
        } else {
            selection.insert(candidate.id)
        }
    }

    /// Failures are collected and left on screen rather than dismissed over: a
    /// later success clears the service's `lastError`, so a per-item `try?` loop
    /// reported "all done" for a batch that half failed.
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
