#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

/// Bounds submitted downloads so queued items do not consume connector deadlines.
@MainActor
@Observable
final class WorkshopDownloadQueue {
    struct Request {
        let itemID: UInt64
        let title: String
        /// true: resolve `downloads.libraryCopyBlockingDownload(of:)` when the item's turn comes and pass it as `replacing:`.
        let replacesLocalCopy: Bool
        let doctor: any WorkshopItemDownloading
        /// A manual retry keeps the exact copy originally approved for replacement.
        var approvedReplacement: WPEHistoryEntry?
    }

    static let shared = WorkshopDownloadQueue()

    /// Waiting items in order; excludes active downloads.
    private(set) var pending: [UInt64] = []
    private(set) var active: Set<UInt64> = []
    var current: UInt64? {
        active.first
    }

    @ObservationIgnored private let downloads: WorkshopDownloadCoordinator
    /// `phaseAtEnqueue` tells a success another entry point produced while the item waited from one it already had.
    @ObservationIgnored private var requests: [UInt64: (request: Request, phaseAtEnqueue: WorkshopDownloadCoordinator.DownloadPhase)] = [:]
    @ObservationIgnored private let maximumConcurrentDownloads: Int

    init(downloads: WorkshopDownloadCoordinator = .shared, maximumConcurrentDownloads: Int = SteamCMDDownloadLimits.maximumConcurrent) {
        self.downloads = downloads
        self.maximumConcurrentDownloads = min(SteamCMDDownloadLimits.maximumConcurrent, max(1, maximumConcurrentDownloads))
    }

    func enqueue(_ newRequests: [Request]) {
        for request in newRequests {
            let itemID = request.itemID
            guard !active.contains(itemID), requests[itemID] == nil, !downloads.isBusy(itemID) else { continue }
            downloads.retainRequest(request)
            requests[itemID] = (request, downloads.phase(for: itemID))
            pending.append(itemID)
        }
        drain()
    }

    func isQueued(_ itemID: UInt64) -> Bool {
        pending.contains(itemID)
    }

    func remove(_ itemID: UInt64) {
        guard isQueued(itemID) else { return }
        pending.removeAll { $0 == itemID }
        requests[itemID] = nil
        downloads.markCancelled(itemID)
    }

    /// Also stops a download another entry point started, so a row's cancel works whoever sent it.
    func cancel(_ itemID: UInt64) {
        remove(itemID)
        if active.contains(itemID) || downloads.isBusy(itemID) {
            downloads.cancel(itemID)
        }
    }

    func retry(_ itemID: UInt64, using doctor: any WorkshopItemDownloading) {
        guard let request = downloads.retryRequest(for: itemID, using: doctor) else { return }
        enqueue([request])
    }

    private func drain() {
        while active.count < maximumConcurrentDownloads, !pending.isEmpty {
            let itemID = pending.removeFirst()
            guard case let (request, phaseAtEnqueue)? = requests.removeValue(forKey: itemID) else { continue }
            if !downloads.isBusy(itemID), Self.isSuccess(downloads.phase(for: itemID)), !Self.isSuccess(phaseAtEnqueue) {
                continue
            }
            active.insert(itemID)
            let replacing = request.approvedReplacement
                ?? (request.replacesLocalCopy ? downloads.libraryCopyBlockingDownload(of: itemID) : nil)
            if let attempt = downloads.download(
                itemID: itemID, title: request.title, using: request.doctor, replacing: replacing
            ) {
                Task { [self] in
                    for await _ in attempt.outcomes() {}
                    active.remove(itemID)
                    drain()
                }
            } else {
                active.remove(itemID)
            }
        }
    }

    private static func isSuccess(_ phase: WorkshopDownloadCoordinator.DownloadPhase) -> Bool {
        switch phase {
        case .succeeded, .succeededAsPreset: true
        default: false
        }
    }
}
#endif
