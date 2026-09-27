import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Edit Desk detail bookmark", .serialized)
struct DetailBookmarkTests {
    private let store = BookmarkStore(persistence: MemoryBookmarks())

    private static func configuration(_ content: WallpaperContent, origin: WPEOrigin? = nil) -> ScreenConfiguration {
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: content)
        configuration.wpeOrigin = origin
        return configuration
    }

    private static func origin(_ id: String, _ type: WPEType) -> WPEOrigin {
        WPEOrigin(
            workshopID: id, title: "Workshop \(id)", originalType: type, sourceFolderBookmark: Data([4]),
            cacheRelativePath: nil, previewFileName: nil
        )
    }

    @Test("The top bar's bookmark is a toolbar item left of Scheme whose glyph fills once this wallpaper is saved")
    func topBarCarriesTheBookmark() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DetailTopBar.swift")
        let bookmark = try #require(source.range(of: #"icon(bookmarked ? "bookmark.fill" : "bookmark""#))
        let scheme = try #require(source.range(of: #"icon("square.stack", "Scheme")"#))
        #expect(bookmark.upperBound <= scheme.lowerBound, "the bookmark sits left of Scheme")
        #expect(source.contains("let bookmarked = actions.bookmark?.existing != nil"))
        #expect(source.contains("DetailBookmarkPopover(target: actions.bookmark)"))
        #expect(source.contains(#"Text("Bookmarked — click to rename or remove")"#))
        #expect(source.contains(#"Text("Bookmark this wallpaper")"#))
        #expect(!source.contains("GlassIconButton("), "the top bar's actions are glass toolbar items, not standalone circles")

        let host = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DisplayDetailHost.swift")
        #expect(host.contains("DetailBookmark.remove(existing.id, from: store, undo: undo)"))
        #expect(host.contains("captureCover(forBookmark: saved.id, from: screen)"))
        #expect(host.contains("captureCover(forBookmark: existing.id, from: screen)"))
    }

    @Test("A video is saved under its file's name and is then the bookmarked one; another file is not")
    func videoRoundTrip() {
        let configuration = Self.configuration(.video(bookmarkData: Data([1, 2]), packageEntryName: nil))
        let name = DetailBookmark.sourceDisplayName(for: configuration.activeWallpaper) { _ in "clip.mov" }
        #expect(name == "clip.mov")
        #expect(DetailBookmark.existing(for: configuration, in: store) == nil)

        let saved = DetailBookmark.save(configuration, label: "  ", sourceDisplayName: name, in: store)

        #expect(saved.label == "clip.mov", "an empty name falls back to the file's")
        #expect(saved.content == configuration.activeWallpaper)
        #expect(saved.sourceDisplayName == "clip.mov")
        #expect(saved.wpeOrigin == nil)
        #expect(DetailBookmark.existing(for: configuration, in: store)?.id == saved.id)
        let other = Self.configuration(.video(bookmarkData: Data([9]), packageEntryName: nil))
        #expect(DetailBookmark.existing(for: other, in: store) == nil)
        #expect(DetailBookmark.existing(for: nil, in: store) == nil)
    }

    @Test("A Workshop web page keeps its origin and the typed name")
    func webRoundTrip() {
        let origin = Self.origin("200", .web)
        let configuration = Self.configuration(.html(source: .inline("Page"), config: .default), origin: origin)
        let name = DetailBookmark.sourceDisplayName(for: configuration.activeWallpaper) { _ in "never read" }
        #expect(name == BookmarkStore.nonResolvingSourceDisplayName(for: configuration.activeWallpaper))

        let saved = DetailBookmark.save(configuration, label: " My Page ", sourceDisplayName: name, in: store)

        #expect(saved.label == "My Page")
        #expect(saved.content == configuration.activeWallpaper)
        #expect(saved.wpeOrigin == origin)
        #expect(DetailBookmark.existing(for: configuration, in: store)?.id == saved.id)
    }

    @Test("A scene is saved with its overrides, preset and origin, so a changed look is a second entry")
    func sceneVariant() throws {
        let origin = Self.origin("123", .scene)
        let plain = SceneDescriptor(workshopID: "123", cacheRelativePath: "123", entryFile: "scene.json", capabilityTier: .imageOnly)
        let plainConfiguration = Self.configuration(.scene(plain), origin: origin)
        let original = DetailBookmark.save(plainConfiguration, label: "", sourceDisplayName: nil, in: store)
        let tuned = plain.withPresetLayer(id: "calm", snapshot: ["speed": .number(1)]).withPropertyOverrides(["speed": .number(2)])
        let tunedConfiguration = Self.configuration(.scene(tuned), origin: origin)
        #expect(DetailBookmark.existing(for: tunedConfiguration, in: store) == nil, "the tuned scene is not the plain one")

        let name = DetailBookmark.sourceDisplayName(for: tunedConfiguration.activeWallpaper) { _ in "never read" }
        let variant = DetailBookmark.save(tunedConfiguration, label: "", sourceDisplayName: name, in: store)

        #expect(variant.label == BookmarkStore.defaultLabel(for: tunedConfiguration.activeWallpaper))
        let descriptor = try #require(variant.content.sceneDescriptor)
        #expect(descriptor.propertyOverrides == ["speed": .number(2)])
        #expect(descriptor.presetID == "calm")
        #expect(variant.wpeOrigin == origin)
        #expect(store.bookmarks.map(\.id) == [original.id, variant.id])
        #expect(DetailBookmark.existing(for: tunedConfiguration, in: store)?.id == variant.id)
        #expect(DetailBookmark.existing(for: plainConfiguration, in: store)?.id == original.id)
    }

    @Test("Removing the bookmark is one undo step that puts it back where it was", .timeLimit(.minutes(1)))
    func removalUndoes() async throws {
        let manager = UndoTestManager()
        let stack = EditDeskUndoStack(
            manager: manager,
            router: ApplyRouter(manager: manager, bookmarks: store, sceneCapable: true, confirmationTimeout: .seconds(5)),
            bookmarks: store
        )
        let first = store.add(label: "First", content: .html(source: .inline("1"), config: .default))
        let middle = store.add(label: "Middle", content: .html(source: .inline("2"), config: .default))
        let last = store.add(label: "Last", content: .html(source: .inline("3"), config: .default))

        DetailBookmark.remove(middle.id, from: store, undo: stack)

        #expect(store.bookmarks.map(\.id) == [first.id, last.id])
        #expect(stack.undoSteps.map(\.action) == [.removeFromSaved])
        let undone = try #require(await stack.undo())
        #expect(undone.restored == ["Middle"])
        #expect(store.bookmarks.map(\.id) == [first.id, middle.id, last.id])
    }
}

@MainActor
private final class MemoryBookmarks: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}
