import LiveWallpaperCore
import SwiftUI

/// Inspector-header popover for quick-saving the current wallpaper.
///
/// The name draft lives in the presenting header, not here: dismissing the
/// popover by clicking outside must keep an unsaved name (there is no discard
/// path), and this view is destroyed on every dismissal. The draft only resets
/// when the bookmark it was seeded from actually changes.
struct Popover: View {
    let screen: Screen
    /// Inspector tab's content (not necessarily the committed active wallpaper).
    let candidateContent: WallpaperContent?
    @Binding var nameDraft: String
    /// Identity+label of the bookmark the current draft was seeded from.
    @Binding var draftBaseline: String?

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var store = BookmarkStore.shared
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        Group {
            if let candidateContent {
                form(for: candidateContent)
            } else {
                emptyState
            }
        }
        .settingsPopoverChrome(width: 260)
        .confirmDestructive($pendingDestructive)
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(systemImage: "bookmark", title: Text("Bookmark"))
            Text("Configure a wallpaper first to bookmark it.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func form(for content: WallpaperContent) -> some View {
        let existing = store.equivalentBookmark(content: content)
        VStack(alignment: .leading, spacing: 12) {
            header(
                systemImage: existing == nil ? "bookmark" : "bookmark.fill",
                title: existing == nil ? Text("Save Bookmark") : Text("Bookmarked")
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(DesignTokens.Typography.badge)
                    .foregroundStyle(.secondary)
                TextField(defaultLabel(for: content), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.body)
                    .onSubmit { commit(content: content, existing: existing) }
            }

            actionRow(content: content, existing: existing)
        }
        .onAppear { syncDraft(with: existing) }
        .onChange(of: Self.baselineKey(for: existing)) { _, _ in syncDraft(with: existing) }
    }

    private func header(systemImage: String, title: Text) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(.tint)
            title
                .font(DesignTokens.Typography.bodyEmphasized)
            Spacer()
        }
    }

    @ViewBuilder
    private func actionRow(content: WallpaperContent, existing: WallpaperBookmark?) -> some View {
        if let existing {
            HStack(spacing: 6) {
                Button(role: .destructive) {
                    pendingDestructive = PendingDestructive(
                        .deleteBookmark(bookmarkName: existing.label)
                    ) {
                        store.remove(existing.id)
                        dismiss()
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .destructiveControlTint()

                Spacer()

                Button {
                    let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != existing.label else { dismiss(); return }
                    store.rename(existing.id, to: trimmed)
                    dismiss()
                } label: {
                    Text("Update")
                }
                .adaptiveGlassButton(.prominent, size: .small)
                .keyboardShortcut(.defaultAction)
                .disabled(updateDisabled(existing: existing))
            }
        } else {
            HStack {
                Spacer()
                Button {
                    commit(content: content, existing: nil)
                } label: {
                    Label("Save", systemImage: "plus")
                }
                .adaptiveGlassButton(.prominent, size: .small)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Commit / sync

    private func commit(content: WallpaperContent, existing: WallpaperBookmark?) {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            guard !trimmed.isEmpty, trimmed != existing.label else { dismiss(); return }
            store.rename(existing.id, to: trimmed)
        } else {
            store.add(
                label: trimmed,
                content: content,
                sourceDisplayName: sourceDisplayName(for: content)
            )
        }
        dismiss()
    }

    private func syncDraft(with existing: WallpaperBookmark?) {
        let key = Self.baselineKey(for: existing)
        guard draftBaseline != key else { return }
        draftBaseline = key
        nameDraft = existing?.label ?? ""
    }

    private static func baselineKey(for existing: WallpaperBookmark?) -> String {
        guard let existing else { return "" }
        return "\(existing.id)|\(existing.label)"
    }

    private func updateDisabled(existing: WallpaperBookmark) -> Bool {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == existing.label
    }

    // MARK: - Data sources


    private func defaultLabel(for content: WallpaperContent) -> String {
        BookmarkStore.defaultLabel(
            for: content,
            sourceDisplayName: sourceDisplayName(for: content)
        )
    }

    private func sourceDisplayName(for content: WallpaperContent) -> String? {
        switch content {
        case .video(let bookmarkData, _):
            return screenManager.bookmarkDisplayName(for: bookmarkData)
        case .html(let source, _):
            return source.displayName
        case .scene(let descriptor):
            return String(localized: "Scene \(descriptor.workshopID)", bundle: .appLanguage, comment: "Bookmark source label for a Wallpaper Engine scene. The placeholder is the Workshop ID.")
        }
    }
}
