import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Saved library model")
struct SavedLibraryModelTests {
    private func bookmark(_ title: String, used: Double? = nil, created: Double = 0) -> WallpaperBookmark {
        WallpaperBookmark(
            label: title, content: .video(bookmarkData: Data(title.utf8)),
            createdAt: Date(timeIntervalSince1970: created),
            lastUsedAt: used.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func aerial(_ id: String = "sky") -> AerialAsset {
        AerialAsset(
            id: id, url: URL(fileURLWithPath: "/\(id).mov"), displayName: id,
            category: nil, fileSize: nil, bookmarkData: Data(id.utf8)
        )
    }

    private var fourK: LibraryMetadata {
        .video(.init(
            resolution: CGSize(width: 3840, height: 2160), isHDR: false,
            duration: 60, fileSize: 100, probedAt: .distantPast
        ))
    }

    private func inputs(_ bookmarks: [WallpaperBookmark] = []) -> SavedLibraryModel.Inputs {
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { bookmarks }
        inputs.aerials = { .init(assets: [aerial()], isAuthorized: true, lastScanError: nil, isScanning: false) }
        return inputs
    }

    @Test func allExcludesAerials() {
        let saved = bookmark("Saved")
        let model = SavedLibraryModel(inputs: inputs([saved]))
        model.chip = .all
        #expect(model.items.count == 2)
        #expect(model.visibleItems.map(\.id) == ["bookmark:\(saved.id)"])
        #expect(model.visibleItems.first?.thumbnail == .bookmark(saved))
    }

    @Test func recentNarrowsBeforeSortingAndSearching() {
        let saved = (0 ..< 16).map { bookmark(String(format: "%02d", $0), used: Double($0)) }
        let model = SavedLibraryModel(inputs: inputs(saved + [bookmark("Unused")]))
        model.chip = .recent
        #expect(model.visibleItems.map(\.title) == (2 ..< 16).reversed().map { String(format: "%02d", $0) })
        model.sort = .name
        #expect(model.visibleItems.map(\.title) == (2 ..< 16).map { String(format: "%02d", $0) })
        model.query = "00"
        #expect(model.visibleItems.isEmpty)
        model.query = ""
        model.sort = .type
        #expect(model.visibleItems.count == 14)
    }

    @Test func steamRequiresANonemptyNumericOrigin() {
        var steam = bookmark("Steam")
        steam.wpeOrigin = origin("123")
        var local = bookmark("Folder")
        local.wpeOrigin = origin("local-123")
        var empty = bookmark("Empty")
        empty.wpeOrigin = origin("")
        let model = SavedLibraryModel(inputs: inputs([steam, local, empty, bookmark("Plain")]))
        model.chip = .steam
        #expect(model.visibleItems.map(\.title) == ["Steam"])
    }

    @Test func localExcludesSteamAndAerials() {
        var steam = bookmark("Steam")
        steam.wpeOrigin = origin("123")
        let model = SavedLibraryModel(inputs: inputs([steam, bookmark("Local")]))
        model.chip = .local
        #expect(model.visibleItems.map(\.title) == ["Local"])
    }

    @Test func aerialsHaveTheirOwnRows() {
        let model = SavedLibraryModel(inputs: inputs([bookmark("Saved")]))
        model.chip = .aerials
        #expect(model.visibleItems.map(\.id) == ["aerial:sky"])
        #expect(model.visibleItems.first?.kind == .aerial)
        #expect(model.visibleItems.first?.createdAt == .distantPast)
        #expect(model.visibleItems.first?.thumbnail == nil)
    }

    @Test func nowPlayingPreservesDisplayIDs() {
        let playing = bookmark("Playing")
        var source = inputs([playing, bookmark("Idle")])
        let displays: [CGDirectDisplayID: WallpaperContent] = [7: playing.content, 42: playing.content]
        #if !LITE_BUILD
        source.nowPlaying = { content, _ in displays.filter { $0.value == content }.map(\.key).sorted() }
        #else
        source.nowPlaying = { content in displays.filter { $0.value == content }.map(\.key).sorted() }
        #endif
        let model = SavedLibraryModel(inputs: source)
        model.chip = .nowPlaying
        #expect(model.visibleItems.map(\.title) == ["Playing"])
        #expect(model.visibleItems.first?.onDisplays == [7, 42])
    }

    @Test func fourKExcludesUnknownAndNonVideoMetadata() {
        let known = bookmark("Known")
        let unknown = bookmark("4K in the title")
        let other = bookmark("Other")
        let small = bookmark("1080p")
        var source = inputs([known, unknown, other, small])
        source.metadata = {
            if $0.id == known.id {
                return fourK
            }
            if $0.id == other.id {
                return .notApplicable
            }
            if $0.id == small.id {
                return .video(.init(
                    resolution: CGSize(width: 1920, height: 1080), isHDR: false,
                    duration: nil, fileSize: nil, probedAt: .distantPast
                ))
            }
            return nil
        }
        let model = SavedLibraryModel(inputs: source)
        model.chip = .fourK
        #expect(model.visibleItems.map(\.title) == ["Known"])
    }

    @Test func recentlyUsedSortPutsNilLastAndBreaksTiesByCreation() {
        let model = SavedLibraryModel(inputs: inputs([
            bookmark("Old tie", used: 10, created: 1), bookmark("Nil old", created: 1),
            bookmark("Newest", used: 20), bookmark("New tie", used: 10, created: 2),
            bookmark("Nil new", created: 2),
        ]))
        model.sort = .recentlyUsed
        #expect(model.visibleItems.map(\.title) == ["Newest", "New tie", "Old tie", "Nil new", "Nil old"])
    }

    @Test func nameSortIgnoresCase() {
        let model = SavedLibraryModel(inputs: inputs([bookmark("zebra"), bookmark("Beta"), bookmark("alpha")]))
        model.sort = .name
        #expect(model.visibleItems.map(\.title) == ["alpha", "Beta", "zebra"])
    }

    @Test func typeSortUsesKindThenName() {
        var web = bookmark("A web", used: 1)
        web.content = .html(source: .url(URL(fileURLWithPath: "/web")), config: .init())
        var scene = bookmark("A scene", used: 1)
        scene.content = .scene(descriptor())
        var source = inputs([scene, bookmark("Z video", used: 1), web, bookmark("B video", used: 1)])
        #if !LITE_BUILD
        source.nowPlaying = { _, _ in [1] }
        #else
        source.nowPlaying = { _ in [1] }
        #endif
        let model = SavedLibraryModel(inputs: source)
        model.chip = .nowPlaying
        model.sort = .type
        #expect(model.visibleItems.map(\.kind) == [.video, .video, .web, .scene, .aerial])
        #expect(model.visibleItems.prefix(2).map(\.title) == ["B video", "Z video"])
    }

    @Test func queryOnlyMatchesTitleWithoutCaseSensitivity() {
        var hidden = bookmark("Other")
        hidden.sourceDisplayName = "sunset"
        let model = SavedLibraryModel(inputs: inputs([hidden, bookmark("Golden SUNSET")]))
        model.query = "sunSet"
        #expect(model.visibleItems.map(\.title) == ["Golden SUNSET"])
        model.query = ""
        #expect(model.visibleItems.count == 2)
    }

    @Test func aerialsStatusMirrorsInputsOnRefresh() {
        let scanning = SavedLibraryModel.AerialsState(
            assets: [], isAuthorized: false, lastScanError: "scan failed", isScanning: true
        )
        let ready = SavedLibraryModel.AerialsState(assets: [aerial()], isAuthorized: true, lastScanError: nil, isScanning: false)
        let states = StateBox(scanning)
        var source = inputs()
        source.aerials = { states.value }
        let model = SavedLibraryModel(inputs: source)
        #expect(!model.aerialsStatus.isAuthorized)
        #expect(model.aerialsStatus.lastScanError == "scan failed")
        #expect(model.aerialsStatus.isScanning)
        #expect(model.aerialsStatus.isEmpty)
        states.value = ready
        model.refresh()
        #expect(model.aerialsStatus.isAuthorized)
        #expect(model.aerialsStatus.lastScanError == nil)
        #expect(!model.aerialsStatus.isScanning)
        #expect(!model.aerialsStatus.isEmpty)
    }

    @Test func probeMetadataOnlyUpdatesRequestedVideoItems() async {
        let first = bookmark("First")
        let second = bookmark("Second")
        var web = bookmark("Web")
        web.content = .html(source: .url(URL(fileURLWithPath: "/web")), config: .init())
        var probed: [UUID] = []
        var cacheIsReady = false
        var source = inputs([first, second, web])
        source.metadata = { _ in cacheIsReady ? fourK : nil }
        source.probeMetadata = {
            probed.append($0.id)
            cacheIsReady = true
            return fourK
        }
        let model = SavedLibraryModel(inputs: source)
        #expect(probed.isEmpty)
        await model.probeMetadata(for: ["bookmark:\(first.id)", "bookmark:\(first.id)", "bookmark:\(web.id)", "missing"])
        #expect(probed == [first.id])
        #expect(model.items.first { $0.id == "bookmark:\(first.id)" }?.metadata == fourK)
        #expect(model.items.first { $0.id == "bookmark:\(second.id)" }?.metadata == nil)
        #expect(model.items.first { $0.id == "aerial:sky" }?.metadata == nil)
    }

    @MainActor
    private final class StateBox {
        var value: SavedLibraryModel.AerialsState

        init(_ value: SavedLibraryModel.AerialsState) {
            self.value = value
        }
    }

    private func origin(_ id: String, type: WPEType = .scene) -> WPEOrigin {
        WPEOrigin(
            workshopID: id, title: "Installed \(id)", originalType: type,
            sourceFolderBookmark: Data(), cacheRelativePath: nil, previewFileName: nil
        )
    }

    private func descriptor(overrides: [String: WallpaperEngineProjectPropertyValue] = [:]) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: "123", cacheRelativePath: "scene", entryFile: "scene.json", capabilityTier: .imageOnly,
            propertyOverrides: overrides, presetID: "preset", presetSnapshot: ["speed": .number(1)]
        )
    }

    #if !LITE_BUILD
    @Test func workshopFoldKeepsLatestUsageAndInstalledIdentity() {
        let entry = WPEHistoryEntry(origin: origin("123"), importedAt: .distantPast, lastUsedAt: Date(timeIntervalSince1970: 2))
        var saved = bookmark("Saved", used: 3)
        saved.wpeOrigin = entry.origin
        saved.content = .scene(descriptor())
        var source = inputs([saved])
        source.history = { [entry] }
        source.nowPlaying = { _, history in history?.id == "123" ? [9] : [] }
        let model = SavedLibraryModel(inputs: source)
        #expect(model.visibleItems.count == 1)
        #expect(model.visibleItems.first?.id == "workshop:123")
        #expect(model.visibleItems.first?.source == .workshop(entry))
        #expect(model.visibleItems.first?.lastUsedAt == saved.lastUsedAt)
        #expect(model.visibleItems.first?.onDisplays == [9])
        #expect(model.visibleItems.first?.isVariant == false)
        saved.lastUsedAt = Date(timeIntervalSince1970: 1)
        source.bookmarks = { [saved] }
        #expect(SavedLibraryModel(inputs: source).visibleItems.first?.lastUsedAt == entry.lastUsedAt)
    }

    @Test func sceneOverridesKeepAVariantRow() {
        let entry = WPEHistoryEntry(origin: origin("123"), importedAt: .distantPast)
        var saved = bookmark("Variant")
        saved.wpeOrigin = entry.origin
        saved.content = .scene(descriptor(overrides: ["speed": .number(2)]))
        var source = inputs([saved])
        source.history = { [entry] }
        let model = SavedLibraryModel(inputs: source)
        let variant = model.items.first { $0.id == "bookmark:\(saved.id)" }
        #expect(model.visibleItems.count == 2)
        #expect(variant?.isVariant == true)
        #expect(variant?.parentID == "workshop:123")
        #expect(variant?.source == .bookmark(saved))
    }

    @Test func unsupportedInstalledTypesRemainInTheLibrary() {
        let types: [WPEType] = [.video, .web, .scene, .application, .unknown]
        var source = inputs()
        source.history = { types.map { WPEHistoryEntry(origin: origin($0.rawValue, type: $0), importedAt: .distantPast) } }
        let model = SavedLibraryModel(inputs: source)
        #expect(model.visibleItems.count == 5)
        for item in model.visibleItems {
            let unsupported = item.id == "workshop:application" || item.id == "workshop:unknown"
            #expect(item.isSupported == !unsupported)
            if unsupported {
                #expect(item.kind == .scene)
            }
        }
    }

    @Test func installedVideoMetadataUsesResolvedContentWithoutASavedBookmark() async {
        let entry = WPEHistoryEntry(origin: origin("123", type: .video), importedAt: .distantPast)
        let content = WallpaperContent.video(bookmarkData: Data([1]))
        var source = inputs()
        source.history = { [entry] }
        source.workshopContent = { $0.id == entry.id ? content : nil }
        var probed: [WallpaperContent] = []
        source.probeMetadata = { probed.append($0.content); return fourK }
        let model = SavedLibraryModel(inputs: source)
        #expect(probed.isEmpty)
        await model.probeMetadata(for: ["workshop:123"])
        #expect(probed == [content])
        #expect(model.visibleItems.first?.metadata == fourK)
        #expect(model.items.first { $0.kind == .aerial }?.metadata == nil)
    }
    #endif

    @Test("Tracking the shared stores does not keep the model alive")
    func observationDoesNotRetainTheModel() {
        weak var leaked: SavedLibraryModel?
        do {
            let model = SavedLibraryModel(inputs: inputs([bookmark("Saved")]))
            model.observeStores()
            leaked = model
        }
        // The observation registrar of an app-wide singleton outlives every window, so a strong
        // capture here keeps the whole library — thumbnails included — alive after teardown.
        #expect(leaked == nil)
    }
}
