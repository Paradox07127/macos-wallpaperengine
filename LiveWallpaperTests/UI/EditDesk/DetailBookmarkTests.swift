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

    @Test("The top bar's bookmark is a toolbar item left of Scheme whose glyph fills once the display's row is marked")
    func topBarCarriesTheBookmark() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DetailTopBar.swift")
        let bookmark = try #require(source.range(of: #"icon(bookmarked ? "bookmark.fill" : "bookmark""#))
        let scheme = try #require(source.range(of: #"icon("square.stack", "Scheme")"#))
        #expect(bookmark.upperBound <= scheme.lowerBound, "the bookmark sits left of Scheme")
        #expect(source.contains("let bookmarked = actions.bookmark?.isBookmarked == true"))
        #expect(source.contains("DetailBookmarkPopover(target: actions.bookmark)"))
        #expect(source.contains(#"Text("Bookmarked — click to rename or remove")"#))
        #expect(source.contains(#"Text("Bookmark this wallpaper")"#))
        #expect(!source.contains("GlassIconButton("), "the top bar's actions are glass toolbar items, not standalone circles")

        let host = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DisplayDetailHost.swift")
        #expect(host.contains("return DetailBookmark.target("), "the host builds the bookmark apart from DetailBookmark")
        #expect(host.contains("itemID: library?.itemID(showing: configuration)"), "the top bar finds the row apart from the library")
        #expect(host.contains("screenManager.captureCover(forBookmark: $0, from: screen)"))
    }

    @Test("The popover's name follows the target, the rename tooltip needs a saved entry, and a refused rename records no undo")
    func draftTooltipAndUndoFollowTheStore() throws {
        let popover = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DetailBookmarkPopover.swift")
        #expect(!popover.contains(".onAppear { nameDraft"), "a draft taken only on appear carries A's name into B's Update")
        #expect(popover.contains(
            ".onChange(of: [target.itemID, target.defaultLabel], initial: true) { nameDraft = renamed?.label ?? \"\" }"
        ))

        let topBar = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DetailTopBar.swift")
        #expect(
            topBar.contains(#"actions.bookmark?.saved == nil ? Text("Bookmarked") : Text("Bookmarked — click to rename or remove")"#),
            "a Workshop or aerial row promises a rename its popover does not offer"
        )

        let update = try #require(popover.range(of: "update: { existing, label in"))
        let record = try #require(popover.range(of: "undo?.recordRename(of: existing)"))
        let guarded = popover[update.upperBound ..< record.lowerBound]
        #expect(
            guarded.contains("store.bookmarks.first(where: { $0.id == existing.id })?.label != existing.label"),
            "a blank name the store refuses still records a rename"
        )
    }

    @Test("A video is saved under its file's name and is then the bookmarked one; another file is not")
    func videoRoundTrip() {
        let configuration = Self.configuration(.video(bookmarkData: Data([1, 2]), packageEntryName: nil))
        let name = DetailBookmark.sourceDisplayName(for: configuration.activeWallpaper) { _ in "clip.mov" }
        #expect(name == "clip.mov")
        #expect(store.equivalentBookmark(content: configuration.activeWallpaper) == nil)

        let saved = DetailBookmark.save(configuration, label: "  ", sourceDisplayName: name, in: store)

        #expect(saved.label == "clip.mov", "an empty name falls back to the file's")
        #expect(saved.content == configuration.activeWallpaper)
        #expect(saved.sourceDisplayName == "clip.mov")
        #expect(saved.wpeOrigin == nil)
        #expect(store.equivalentBookmark(content: configuration.activeWallpaper)?.id == saved.id)
        let other = Self.configuration(.video(bookmarkData: Data([9]), packageEntryName: nil))
        #expect(store.equivalentBookmark(content: other.activeWallpaper) == nil)
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
        #expect(store.equivalentBookmark(content: configuration.activeWallpaper)?.id == saved.id)
    }

    @Test("A scene is saved with its overrides, preset and origin, so a changed look is a second entry")
    func sceneVariant() throws {
        let origin = Self.origin("123", .scene)
        let plain = SceneDescriptor(workshopID: "123", cacheRelativePath: "123", entryFile: "scene.json", capabilityTier: .imageOnly)
        let plainConfiguration = Self.configuration(.scene(plain), origin: origin)
        let original = DetailBookmark.save(plainConfiguration, label: "", sourceDisplayName: nil, in: store)
        let tuned = plain.withPresetLayer(id: "calm", snapshot: ["speed": .number(1)]).withPropertyOverrides(["speed": .number(2)])
        let tunedConfiguration = Self.configuration(.scene(tuned), origin: origin)
        #expect(store.equivalentBookmark(content: tunedConfiguration.activeWallpaper) == nil, "the tuned scene is not the plain one")

        let name = DetailBookmark.sourceDisplayName(for: tunedConfiguration.activeWallpaper) { _ in "never read" }
        let variant = DetailBookmark.save(tunedConfiguration, label: "", sourceDisplayName: name, in: store)

        #expect(variant.label == BookmarkStore.defaultLabel(for: tunedConfiguration.activeWallpaper))
        let descriptor = try #require(variant.content.sceneDescriptor)
        #expect(descriptor.propertyOverrides == ["speed": .number(2)])
        #expect(descriptor.presetID == "calm")
        #expect(variant.wpeOrigin == origin)
        #expect(store.bookmarks.map(\.id) == [original.id, variant.id])
        #expect(store.equivalentBookmark(content: tunedConfiguration.activeWallpaper)?.id == variant.id)
        #expect(store.equivalentBookmark(content: plainConfiguration.activeWallpaper)?.id == original.id)
    }

    @Test("The display's row is its saved entry, else the installed Workshop row it folds into, else the aerial it plays")
    func findsTheDisplaysRow() {
        let video = WallpaperContent.video(bookmarkData: Data([1]), packageEntryName: nil)
        let saved = WallpaperBookmark(label: "Clip", content: video)
        let asset = AerialAsset(
            id: "sky", url: URL(fileURLWithPath: "/Aerials/sky.mov"), displayName: "Sky",
            category: nil, fileSize: nil, bookmarkData: Data([7])
        )
        let origin = Self.origin("123", .scene)
        let plain = SceneDescriptor(workshopID: "123", cacheRelativePath: "123", entryFile: "scene.json", capabilityTier: .imageOnly)
        var inputs = SavedLibraryModel.Inputs()
        inputs.aerials = { .init(assets: [asset], isAuthorized: true, lastScanError: nil, isScanning: false) }
        #if LITE_BUILD
        inputs.bookmarks = { [saved] }
        #else
        let folded = WallpaperBookmark(label: "Folded", content: .scene(plain), wpeOrigin: origin)
        inputs.bookmarks = { [saved, folded] }
        inputs.history = { [WPEHistoryEntry(origin: origin, importedAt: .distantPast)] }
        #endif
        let library = SavedLibraryModel(inputs: inputs)

        #expect(library.itemID(showing: Self.configuration(video)) == "bookmark:\(saved.id)")
        let aerial = Self.configuration(.video(bookmarkData: Data([7]), packageEntryName: nil))
        #expect(library.itemID(showing: aerial) == "aerial:\(asset.url.path)")
        #expect(library.itemID(showing: Self.configuration(.video(bookmarkData: Data([9]), packageEntryName: nil))) == nil)
        #if !LITE_BUILD
        #expect(
            library.itemID(showing: Self.configuration(.scene(plain), origin: origin)) == "workshop:123",
            "a scene saved into the installed project's row resolves to an entry the library does not list"
        )
        let tuned = Self.configuration(.scene(plain.withPropertyOverrides(["speed": .number(2)])), origin: origin)
        #expect(library.itemID(showing: tuned) == nil, "a tuned scene with no saved variant is taken for the project's row")
        #endif
    }

    @Test("Saving marks the row already running the wallpaper and adds no entry; with no row it saves one and marks that")
    func savingMarksTheRunningRow() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "DetailBookmarkTests")
        defer { suite.discard() }
        let marks = LibraryBookmarkStore(defaults: suite.defaults)
        let configuration = Self.configuration(.video(bookmarkData: Data([1]), packageEntryName: nil))
        let existing = store.add(label: "Clip", content: configuration.activeWallpaper)
        var covers: [UUID] = []
        let target = { (itemID: String?) in
            DetailBookmark.target(
                for: configuration, itemID: itemID, sourceDisplayName: nil, store: store, marks: marks, undo: nil
            ) { covers.append($0) }
        }

        let row = target("bookmark:\(existing.id)")
        #expect(!row.isBookmarked)
        #expect(row.saved?.id == existing.id)
        row.save("Other")
        #expect(store.bookmarks.map(\.id) == [existing.id], "saving a row the library already lists adds a second entry")
        #expect(store.bookmarks.first?.label == "Clip")
        #expect(marks.ids == ["bookmark:\(existing.id)"])
        #expect(covers.isEmpty, "marking a row recaptures its cover")
        #expect(target("bookmark:\(existing.id)").isBookmarked)

        let workshop = target("workshop:123")
        #expect(workshop.saved == nil, "an installed project's row offers a rename")
        workshop.save("")
        #expect(store.bookmarks.count == 1)
        #expect(marks.ids == ["bookmark:\(existing.id)", "workshop:123"])

        target(nil).save("New")
        let added = try #require(store.bookmarks.last)
        #expect(store.bookmarks.count == 2)
        #expect(added.label == "New")
        #expect(marks.ids.last == "bookmark:\(added.id)")
        #expect(covers == [added.id])
    }

    @Test("Removing the bookmark unmarks the row and keeps the entry in the library")
    func removingKeepsTheEntry() throws {
        let suite = try TestScratch.defaultsSuite(prefix: "DetailBookmarkTests")
        defer { suite.discard() }
        let marks = LibraryBookmarkStore(defaults: suite.defaults)
        let configuration = Self.configuration(.html(source: .inline("Page"), config: .default))
        let existing = store.add(label: "Page", content: configuration.activeWallpaper)
        marks.add("bookmark:\(existing.id)")
        let target = DetailBookmark.target(
            for: configuration, itemID: "bookmark:\(existing.id)", sourceDisplayName: nil, store: store, marks: marks, undo: nil
        ) { _ in }
        #expect(target.isBookmarked)

        target.remove()

        #expect(marks.ids.isEmpty)
        #expect(store.bookmarks.map(\.id) == [existing.id], "removing the bookmark deleted the library entry")
    }
}

@MainActor
private final class MemoryBookmarks: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}
