import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// On the Edit Desk canvas a library page separates its filter bar from the grid by spacing alone.
@Suite("Edit Desk library pages — filter-bar rule source contract")
struct EditDeskPageSeparatorSourceTests {
    enum Rule: Equatable {
        /// Drawn only off the Edit Desk canvas.
        case gated
        /// Drawn in every window.
        case ungated
        /// No rule under the filter bar at all.
        case missing
    }

    /// How the `Divider()` right under a page's filter bar is drawn.
    static func filterBarRule(in source: String) -> Rule {
        let lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var rule = Rule.missing
        for (index, line) in lines.enumerated() where line == "filterBar" || line.hasPrefix("LibraryFilterBar(") {
            let next = Array(lines[(index + 1)...].prefix(3))
            if next.first == "Divider()" {
                return .ungated
            }
            if next == ["if !windowPaintsCanvas {", "Divider()", "}"] {
                rule = .gated
            }
        }
        return rule
    }

    @Test("Schemes and System Wallpaper draw the filter-bar rule only off the Edit Desk canvas", arguments: [
        "LiveWallpaper/Views/Schemes/SchemeLibraryView.swift",
        "LiveWallpaper/Views/SystemWallpaper/SystemWallpaperLibraryView.swift",
    ])
    func ruleIsGatedOnTheCanvas(path: String) throws {
        let rule = try Self.filterBarRule(in: RepositoryRoot.source(path))
        #expect(rule == .gated, Comment(rawValue: "\(path): the rule under the filter bar is \(rule)"))
    }

    @Test("Control: the checker sees a filter-bar rule drawn in every window")
    func ungatedRuleIsSeen() {
        let rule = Self.filterBarRule(in: "filterBar\nDivider()\ngrid")
        #expect(rule == .ungated, Comment(rawValue: "the checker no longer sees an ungated rule: \(rule)"))
    }
}

#if !LITE_BUILD
/// The Workshop browse pane over the canvas colour, once as the Edit Desk hosts it and once as the old window does.
@Suite("Workshop browse — filter-bar rule on and off the Edit Desk canvas", .serialized)
@MainActor
struct EditDeskBrowseSeparatorRenderTests {
    private static let size = CGSize(width: 1280, height: 320)

    private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable { // stateless: no stored properties
        override static func canInit(with _: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }

        override func stopLoading() {}
    }

    private static let items: [WorkshopQueryItem] = (0 ..< 12).map { index in
        let id = 2_468_489_223 + UInt64(index)
        return WorkshopQueryItem(
            id: id, rawTitle: "Item \(index)", shortDescription: "", creatorID: nil, creatorPersonaName: nil,
            previewImageURL: nil, fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil, rating: nil,
            tags: ["Scene"], visibility: .public, isBanned: false,
            steamCommunityURL: WorkshopCommunityURL.item(itemID: id)
        )
    }

    private static func makeManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
    }

    private static func luminance(_ image: ProbeImage, _ x: Int, _ y: Int) -> Double {
        let colour = image.rgb(px: x, y)
        return 0.299 * Double(colour.r) + 0.587 * Double(colour.g) + 0.114 * Double(colour.b)
    }

    /// y (points) of each row in the top `depth` points that stands out from the rows 1.5pt above and below across
    /// ≥95% of the width. A 1pt `Divider()` does across all of it; a card edge stays under 90% because of the grid's gaps.
    private static func fullWidthRules(in image: ProbeImage, depth: CGFloat) -> [CGFloat] {
        let gap = max(1, Int((1.5 * image.scale).rounded()))
        let x0 = Int(40 * image.scale), x1 = Int((size.width - 40) * image.scale)
        var rows: [Int] = []
        for y in gap ..< min(image.height - gap, Int(depth * image.scale)) {
            var hits = 0, samples = 0
            for x in stride(from: x0, to: x1, by: 2) {
                let here = luminance(image, x, y)
                let above = luminance(image, x, y - gap), below = luminance(image, x, y + gap)
                samples += 1
                if (here - above > 4 && here - below > 4) || (above - here > 4 && below - here > 4) {
                    hits += 1
                }
            }
            if Double(hits) >= 0.95 * Double(samples) {
                rows.append(y)
            }
        }
        var rules: [CGFloat] = []
        var previous: Int?
        for y in rows {
            if previous.map({ y - $0 > 1 }) ?? true {
                rules.append(CGFloat(y) / image.scale)
            }
            previous = y
        }
        return rules
    }

    /// Whether the top `depth` points hold anything but the canvas: a blank render would pass the missing-rule check.
    private static func hasInk(_ image: ProbeImage, depth: CGFloat) -> Bool {
        var lowest = Double.infinity, highest = -Double.infinity
        for y in stride(from: 0, to: Int(depth * image.scale), by: 2) {
            for x in stride(from: 0, to: image.width, by: 4) {
                let value = luminance(image, x, y)
                lowest = min(lowest, value)
                highest = max(highest, value)
            }
        }
        return highest - lowest > 40
    }

    /// The pane with one cached page, so the grid fills without a fetch; any request that misses the cache fails offline.
    private func render(onCanvas: Bool, dark: Bool) async throws -> ProbeImage {
        let suite = try TestScratch.defaultsSuite("EditDeskBrowseSeparatorRenderTests.render")
        defer { suite.discard() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browse-separator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        let offline = URLSession(configuration: configuration)
        let keychain = WorkshopKeychainStore(directory: directory, slot: WorkshopKeychainSlotSpy().slot())
        let cache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache"))
        let services = WorkshopServices(
            keychain: keychain, cache: cache,
            queryService: WorkshopQueryService(keychain: keychain, cache: cache, session: offline, countIssuedRequest: {})
        )
        let publicCache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("public-cache"))
        let browse = BrowseViewModel(
            services: services, defaults: suite.defaults,
            publicSource: WorkshopPublicSearchSource(
                metadata: SteamWorkshopMetadataService(session: offline), session: offline, cache: publicCache
            )
        )
        let page = WorkshopQueryPage(
            items: Self.items, nextCursor: nil, totalAvailable: Self.items.count,
            sourceItemCount: Self.items.count, totalPages: 1
        )
        await publicCache.write(page, forKey: WorkshopQueryCacheKey.canonical(browse.currentRequest))
        let manager = Self.makeManager()
        defer { manager.tearDownForTermination() }
        let doctor = SteamCMDDoctorService(defaults: suite.defaults)
        return await ProbeRenderer.render(nil, size: Self.size, appearance: dark ? .darkAqua : .aqua, settle: 1.5) {
            ZStack {
                DesignTokens.EditDesk.Colors.background
                BrowsePane(viewModel: browse, doctor: doctor, onRequestKeyEntry: {}, presentation: .editDesk)
            }
            .environment(\.windowPaintsCanvas, onCanvas)
            .environment(services)
            .environment(manager)
        }
    }

    @Test("The Edit Desk draws no rule under the Workshop filter bar; the old window keeps it", arguments: [false, true])
    func ruleFollowsTheCanvas(dark: Bool) async throws {
        let oldWindow = try await Self.fullWidthRules(in: render(onCanvas: false, dark: dark), depth: 120)
        #expect(oldWindow.count == 1, Comment(rawValue: "old window shows full-width rules at \(oldWindow); the scan misses the rule it guards"))
        let editDesk = try await render(onCanvas: true, dark: dark)
        #expect(Self.hasInk(editDesk, depth: 60), "the Edit Desk render is blank, so a missing rule proves nothing")
        let rules = Self.fullWidthRules(in: editDesk, depth: 120)
        #expect(rules.isEmpty, Comment(rawValue: "the Edit Desk still draws a full-width rule at \(rules)"))
    }
}
#endif
