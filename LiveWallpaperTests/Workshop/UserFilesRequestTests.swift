#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop GetUserFiles request")
struct UserFilesRequestTests {
    @Test("creator-scoped URL states sortmethod and steamid explicitly")
    func userFilesURLCarriesSortMethodAndSteamID() throws {
        let request = WorkshopQueryRequest(
            sort: .lastUpdated,
            page: 2,
            creatorSteamID: "76561198000000001"
        )
        let steamID = try #require(request.creatorSteamID)
        let url = try WorkshopQueryService.buildUserFilesURL(
            for: request,
            steamID: steamID,
            apiKey: "0123456789abcdef0123456789abcdef"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        #expect(url.absoluteString.contains("IPublishedFileService/GetUserFiles"))
        #expect(value("sortmethod") == "lastupdated")
        #expect(value("steamid") == "76561198000000001")
        #expect(value("appid") == String(WorkshopQueryService.wallpaperEngineAppID))
        #expect(value("page") == "2")
        // GetUserFiles has no text-search field; asserting its absence keeps
        // the request honest if someone later routes searchText through here.
        #expect(value("search_text") == nil)
    }
}

@Suite("Installed filter snap-back")
@MainActor
struct InstalledFilterSnapBackTests {
    private static func makeModel() -> InstalledLibraryModel {
        InstalledLibraryModel(dependencies: .init(
            loadEntries: { [] },
            loadRemoteUpdateEpochs: { [:] },
            saveRemoteUpdateEpochs: { _ in },
            loadLastUpdateCheckEpoch: { 0 },
            saveLastUpdateCheckEpoch: { _ in },
            makeMetadataService: { SteamWorkshopMetadataService() },
            now: Date.init
        ))
    }

    @Test("deselecting the last type chip resets the category to all-selected")
    func typeSnapBack() {
        let model = Self.makeModel()
        model.isolateType(.scene)
        #expect(model.selectedTypes == [.scene])
        model.toggleType(.scene)
        #expect(model.selectedTypes == Set(WPELibraryTypeKind.allCases))
        // A non-final deselect still narrows normally.
        model.toggleType(.video)
        #expect(model.selectedTypes == Set(WPELibraryTypeKind.allCases).subtracting([.video]))
    }

    @Test("deselecting the last source chip resets the category to all-selected")
    func sourceSnapBack() {
        let model = Self.makeModel()
        model.isolateSource(.local)
        model.toggleSource(.local)
        #expect(model.selectedSources == Set(InstalledSource.allCases))
    }

    @Test("deselecting the last storage chip resets the category to all-selected")
    func storageSnapBack() {
        let model = Self.makeModel()
        model.isolateStorage(.managed)
        model.toggleStorage(.managed)
        #expect(model.selectedStorage == Set(InstalledStorageKind.allCases))
    }

    @Test("snap-back leaves no phantom active-filter badge")
    func snapBackClearsActiveFilterCount() {
        let model = Self.makeModel()
        model.isolateType(.web)
        #expect(model.activeFilterCount == 1)
        model.toggleType(.web)
        #expect(model.activeFilterCount == 0)
    }
}
#endif
