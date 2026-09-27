import LiveWallpaperCore
import SwiftUI

/// The display's wallpaper as a Wallpaper Library entry, for the top bar's bookmark.
@MainActor
enum DetailBookmark {
    /// Exact content: a scene's overrides and preset are part of it, so a changed look is a separate entry.
    static func existing(for configuration: ScreenConfiguration?, in store: BookmarkStore) -> WallpaperBookmark? {
        configuration.flatMap { store.equivalentBookmark(content: $0.activeWallpaper) }
    }

    /// `videoName` resolves a video's file name, which the content alone does not carry.
    static func sourceDisplayName(for content: WallpaperContent, videoName: (Data) -> String?) -> String? {
        if case let .video(bookmarkData, _) = content {
            return videoName(bookmarkData)
        }
        return BookmarkStore.nonResolvingSourceDisplayName(for: content)
    }

    /// The origin travels with the entry: a scene's files live in the Steam library and are found only through it.
    @discardableResult
    static func save(
        _ configuration: ScreenConfiguration, label: String, sourceDisplayName: String?, in store: BookmarkStore
    ) -> WallpaperBookmark {
        store.add(
            label: label, content: configuration.activeWallpaper,
            sourceDisplayName: sourceDisplayName, wpeOrigin: configuration.wpeOrigin
        )
    }

    static func remove(_ id: UUID, from store: BookmarkStore, undo: EditDeskUndoStack?) {
        guard let index = store.bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let removed = store.bookmarks[index]
        store.remove(id)
        undo?.recordRemoval(of: removed, at: index)
    }
}

/// What the host hands the top bar's bookmark; nil in `DetailActions` while the display has no wallpaper.
struct DetailBookmarkTarget {
    /// The entry already holding this exact wallpaper, if any.
    let existing: WallpaperBookmark?
    let defaultLabel: String
    var save: (String) -> Void
    var update: (WallpaperBookmark, String) -> Void
    var remove: (WallpaperBookmark) -> Void
}

struct DetailBookmarkPopover: View {
    let target: DetailBookmarkTarget?
    let close: () -> Void
    @State private var nameDraft = ""

    var body: some View {
        Group {
            if let target {
                form(target)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    header("bookmark", Text("Bookmark"))
                    Text("Configure a wallpaper first to bookmark it.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsPopoverChrome(width: 260)
    }

    private func form(_ target: DetailBookmarkTarget) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if target.existing == nil {
                header("bookmark", Text("Save Bookmark"))
            } else {
                header("bookmark.fill", Text("Bookmarked"))
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Name")
                    .font(DesignTokens.Typography.badge)
                    .foregroundStyle(.secondary)
                TextField(target.defaultLabel, text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.body)
                    .onSubmit { commit(target) }
            }
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let existing = target.existing {
                    Button(role: .destructive) {
                        target.remove(existing)
                        close()
                    } label: {
                        Label("Remove Bookmark", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .destructiveControlTint()
                }
                Spacer()
                Button { commit(target) } label: {
                    if target.existing == nil {
                        Label("Save", systemImage: "plus")
                    } else {
                        Label("Update", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .adaptiveGlassButton(.prominent, size: .small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { nameDraft = target.existing?.label ?? "" }
    }

    private func header(_ systemImage: String, _ title: Text) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: systemImage)
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(.tint)
            title
                .font(DesignTokens.Typography.bodyEmphasized)
            Spacer()
        }
    }

    private func commit(_ target: DetailBookmarkTarget) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = target.existing {
            target.update(existing, name)
        } else {
            target.save(name)
        }
        close()
    }
}
