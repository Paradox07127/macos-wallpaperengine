import LiveWallpaperCore
import SwiftUI

/// The display's wallpaper as a Wallpaper Library entry, for the top bar's bookmark.
@MainActor
enum DetailBookmark {
    /// `itemID` comes from `SavedLibraryModel.itemID(showing:)`. `captureCover` takes the saved entry whose cover the display's frame becomes.
    static func target(
        for configuration: ScreenConfiguration, itemID: LibraryItem.ID?, sourceDisplayName: String?,
        store: BookmarkStore, marks: LibraryBookmarkStore, undo: EditDeskUndoStack?,
        captureCover: @escaping (UUID) -> Void
    ) -> DetailBookmarkTarget {
        DetailBookmarkTarget(
            itemID: itemID,
            isBookmarked: itemID.map { marks.contains($0) } ?? false,
            saved: store.bookmarks.first { itemID == "bookmark:\($0.id)" },
            defaultLabel: BookmarkStore.defaultLabel(for: configuration.activeWallpaper, sourceDisplayName: sourceDisplayName),
            save: { label in
                if let itemID {
                    marks.add(itemID)
                    return
                }
                let saved = save(configuration, label: label, sourceDisplayName: sourceDisplayName, in: store)
                marks.add("bookmark:\(saved.id)")
                captureCover(saved.id)
            },
            update: { existing, label in
                if label != existing.label {
                    store.rename(existing.id, to: label)
                    undo?.recordRename(of: existing)
                }
                captureCover(existing.id)
            },
            remove: {
                if let itemID {
                    marks.remove(itemID)
                }
            }
        )
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
}

/// What the host hands the top bar's bookmark; nil in `DetailActions` while the display has no wallpaper.
struct DetailBookmarkTarget {
    /// The library row running this wallpaper; nil while none does.
    let itemID: LibraryItem.ID?
    let isBookmarked: Bool
    /// The saved entry that is that row, the only kind of row that can be renamed.
    let saved: WallpaperBookmark?
    let defaultLabel: String
    /// Marks the row, adding a saved entry under this name first when there is no row.
    var save: (String) -> Void
    var update: (WallpaperBookmark, String) -> Void
    /// Unmarks the row; the row stays in the library.
    var remove: () -> Void
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
        // Named when saving adds the entry, renamed once a marked row is a saved entry; any other row keeps its name.
        let renamed = target.isBookmarked ? target.saved : nil
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if target.isBookmarked {
                header("bookmark.fill", Text("Bookmarked"))
            } else {
                header("bookmark", Text("Save Bookmark"))
            }
            if target.itemID == nil || renamed != nil {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Name")
                        .font(DesignTokens.Typography.badge)
                        .foregroundStyle(.secondary)
                    TextField(target.defaultLabel, text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(DesignTokens.Typography.body)
                        .onSubmit { commit(target) }
                }
            }
            HStack(spacing: DesignTokens.Spacing.xs) {
                if target.isBookmarked {
                    Button(role: .destructive) {
                        target.remove()
                        close()
                    } label: {
                        Label("Remove Bookmark", systemImage: "bookmark.slash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .destructiveControlTint()
                }
                Spacer()
                if !target.isBookmarked || renamed != nil {
                    Button { commit(target) } label: {
                        if target.isBookmarked {
                            Label("Update", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Save", systemImage: "plus")
                        }
                    }
                    .adaptiveGlassButton(.prominent, size: .small)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { nameDraft = renamed?.label ?? "" }
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
        if !target.isBookmarked {
            target.save(name)
        } else if let saved = target.saved {
            target.update(saved, name)
        }
        close()
    }
}
