#if !LITE_BUILD
import Foundation
import Observation

/// Hands downloads to the coordinator one at a time: the connector runs SteamCMD on a serial queue and drops a request that waited too long, so a batch sent at once times out everything after the first item.
@MainActor
@Observable
final class WorkshopDownloadQueue {
    struct Request {
        let itemID: UInt64
        let title: String
        /// true: resolve `downloads.libraryCopyBlockingDownload(of:)` when the item's turn comes and pass it as `replacing:`.
        let replacesLocalCopy: Bool
        let doctor: any WorkshopItemDownloading
    }

    static let shared = WorkshopDownloadQueue()

    /// Waiting items in order; excludes `current`.
    private(set) var pending: [UInt64] = []
    private(set) var current: UInt64?

    @ObservationIgnored private let downloads: WorkshopDownloadCoordinator
    @ObservationIgnored private var requests: [UInt64: Request] = [:]
    @ObservationIgnored private var walk: Task<Void, Never>?

    init(downloads: WorkshopDownloadCoordinator = .shared) {
        self.downloads = downloads
    }

    func enqueue(_ newRequests: [Request]) {
        for request in newRequests {
            let itemID = request.itemID
            guard itemID != current, requests[itemID] == nil, !downloads.isBusy(itemID) else { continue }
            requests[itemID] = request
            pending.append(itemID)
        }
        guard walk == nil, !pending.isEmpty else { return }
        walk = Task { [weak self] in await self?.drain() }
    }

    func isQueued(_ itemID: UInt64) -> Bool {
        pending.contains(itemID)
    }

    func remove(_ itemID: UInt64) {
        pending.removeAll { $0 == itemID }
        requests[itemID] = nil
    }

    /// Also stops a download another entry point started, so a row's cancel works whoever sent it.
    func cancel(_ itemID: UInt64) {
        if isQueued(itemID) {
            remove(itemID)
        } else if itemID == current || downloads.isBusy(itemID) {
            downloads.cancel(itemID)
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let itemID = pending.removeFirst()
            guard let request = requests.removeValue(forKey: itemID) else { continue }
            current = itemID
            let replacing = request.replacesLocalCopy ? downloads.libraryCopyBlockingDownload(of: itemID) : nil
            if let attempt = downloads.download(
                itemID: itemID, title: request.title, using: request.doctor, replacing: replacing
            ) {
                for await _ in attempt.outcomes() {}
            }
            current = nil
        }
        walk = nil
    }
}
#endif
