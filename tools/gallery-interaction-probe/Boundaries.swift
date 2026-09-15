import AppKit
import LiveWallpaperCore
import Observation
import WebKit

// Harness boundaries: no display application, export, live trust store or user configuration writes.
@MainActor struct Screen: Identifiable { let id: UInt32; let name: String }
@MainActor @Observable final class WallpaperExportService {
    func isPublished(bookmarkID: UUID) -> Bool { false }
    func remove(itemID: String) throws {}
    func publish(bookmark: WallpaperBookmark) async throws {}
}
struct ConfigurationDirectory {
    var root: URL
    init(root: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GALLERY_FIXTURES"]!)) { self.root = root }
}
enum TrustedHostStore {
    @MainActor static let shared = TrustedHostStoreValue()
    struct TrustedHostStoreValue { let originSet: Set<TrustedHTMLOrigin> = [] }
}
enum HTMLWallpaperView {
    @MainActor static func preparedTrackerRuleList() async -> WKContentRuleList? { nil }
    // Local fixture pages never navigate away; navigation policy is covered by app tests.
    enum NavigationDecision { case allow, cancel, openExternally(URL) }
    static func navigationDecision(for: URL?, navigationType: WKNavigationType, currentURL: URL?, allowMouseInteraction: Bool, localReadAccessRoot: URL?, remoteSourceOrigin: URL?) -> NavigationDecision { .allow }
}
