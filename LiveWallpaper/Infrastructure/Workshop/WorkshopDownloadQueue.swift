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
    /// `phaseAtEnqueue` tells a success another entry point produced while the item waited from one it already had.
    @ObservationIgnored private var requests: [UInt64: (request: Request, phaseAtEnqueue: WorkshopDownloadCoordinator.DownloadPhase)] = [:]
    @ObservationIgnored private var walk: Task<Void, Never>?

    init(downloads: WorkshopDownloadCoordinator = .shared) {
        self.downloads = downloads
    }

    func enqueue(_ newRequests: [Request]) {
        for request in newRequests {
            let itemID = request.itemID
            guard itemID != current, requests[itemID] == nil, !downloads.isBusy(itemID) else { continue }
            requests[itemID] = (request, downloads.phase(for: itemID))
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
        remove(itemID)
        if itemID == current || downloads.isBusy(itemID) {
            downloads.cancel(itemID)
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let itemID = pending.removeFirst()
            guard case let (request, phaseAtEnqueue)? = requests.removeValue(forKey: itemID) else { continue }
            if !downloads.isBusy(itemID), Self.isSuccess(downloads.phase(for: itemID)), !Self.isSuccess(phaseAtEnqueue) {
                continue
            }
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

    private static func isSuccess(_ phase: WorkshopDownloadCoordinator.DownloadPhase) -> Bool {
        switch phase {
        case .succeeded, .succeededAsPreset: true
        default: false
        }
    }
}
#endif
