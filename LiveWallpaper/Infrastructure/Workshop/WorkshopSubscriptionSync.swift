#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

@MainActor
@Observable
final class WorkshopSubscriptionSync {
    enum Phase: Equatable {
        case idle
        case checking
        case ready(missing: [UInt64])
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Workshop titles for the missing ids, where the keyless metadata lookup
    /// answered. Absent means the sheet shows the id.
    private(set) var titles: [UInt64: String] = [:]
    /// The failure is "sign in first", which the sheet can offer to fix rather
    /// than only describe.
    private(set) var requiresSignIn = false
    var selection: Set<UInt64> = []
    /// Ids this sync sent to download, kept so their rows and cancel survive a check that no longer lists them.
    private var submitted: [UInt64] = []

    @ObservationIgnored private let metadataService: SteamWorkshopMetadataService
    @ObservationIgnored private let downloads: WorkshopDownloadCoordinator
    @ObservationIgnored private let queue: WorkshopDownloadQueue
    @ObservationIgnored private let listSubscriptions: @MainActor (String) async -> SteamSubscribedItemsResult?

    private static let metadataFetchBatchSize = 50

    init(
        metadataService: SteamWorkshopMetadataService = SteamWorkshopMetadataService(),
        downloads: WorkshopDownloadCoordinator = .shared,
        queue: WorkshopDownloadQueue = .shared,
        listSubscriptions: @escaping @MainActor (String) async -> SteamSubscribedItemsResult? = {
            await SteamConnectorClient.listSubscribedWorkshopItems(accountName: $0)
        }
    ) {
        self.metadataService = metadataService
        self.downloads = downloads
        self.queue = queue
        self.listSubscriptions = listSubscriptions
    }

    func refresh(using doctor: SteamCMDDoctorService) async {
        guard let account = doctor.username else {
            fail(String(
                localized: "Choose a Steam account before checking your subscriptions.",
                bundle: .appLanguage, comment: "Subscription sync error when no Steam account is selected."
            ), requiresSignIn: true)
            return
        }
        phase = .checking
        titles = [:]
        requiresSignIn = false
        submitted.removeAll { !isActive($0) }

        guard let installed = installedWorkshopIDs(using: doctor) else {
            fail(String(
                localized: "Authorize your Steam library folder before checking your subscriptions.",
                bundle: .appLanguage, comment: "Subscription sync error when the Steam library folder is not authorized."
            ))
            return
        }
        guard let result = await listSubscriptions(account) else {
            fail(String(
                localized: "Loomscreen's Steam connector did not respond.",
                bundle: .appLanguage, comment: "Subscription sync error when the XPC connector could not be reached."
            ))
            return
        }

        switch result.outcome {
        case .listed:
            let missing = result.workshopIDs.compactMap(UInt64.init).filter { !installed.contains($0) }
            for itemID in missing where !isActive(itemID) {
                downloads.forgetSettledPhase(itemID)
            }
            phase = .ready(missing: missing)
            selection = Set(missing)
            await loadTitles(for: missing)
        case .loginRequired:
            fail(String(
                localized: "Sign in to Steam to read your subscriptions.",
                bundle: .appLanguage, comment: "Subscription sync error when SteamCMD has no cached credentials."
            ), requiresSignIn: true)
        case .steamUnreachable:
            fail(String(
                localized: "Steam could not be reached. Check your connection and try again.",
                bundle: .appLanguage, comment: "Subscription sync error when SteamCMD could not connect to Steam."
            ))
        case .steamCMDUnavailable:
            fail(String(
                localized: "SteamCMD could not be launched. Open Settings › Workshop › Steam connection to install it or locate an existing copy.",
                bundle: .appLanguage, comment: "Steam sign-in diagnostic when the bound SteamCMD binary could not run."
            ))
        case .timedOut:
            fail(String(
                localized: "Reading your subscriptions took too long and was stopped.",
                bundle: .appLanguage, comment: "Subscription sync error when the SteamCMD run timed out."
            ))
        case .unrecognized:
            fail(result.diagnosticTail)
        }
    }

    /// Selected missing items that a press of Download would still send.
    func downloadableSelection() -> [UInt64] {
        missing.filter { selection.contains($0) && !isActive($0) }
    }

    /// The latest check's missing items, then submitted ones still downloading that it did not list.
    var rows: [UInt64] {
        let missing = self.missing
        return missing + submitted.filter { !missing.contains($0) && isActive($0) }
    }

    var hasActiveDownloads: Bool {
        rows.contains(where: isActive)
    }

    func downloadSelected(using doctor: any WorkshopItemDownloading) {
        let itemIDs = downloadableSelection()
        submitted += itemIDs.filter { !submitted.contains($0) }
        // download() approves only a local copy, so a Steam holder passed as `replacing:` still refuses.
        queue.enqueue(itemIDs.map {
            WorkshopDownloadQueue.Request(itemID: $0, title: title(for: $0), replacesLocalCopy: true, doctor: doctor)
        })
    }

    func cancelDownloads() {
        for itemID in rows {
            queue.cancel(itemID)
        }
    }

    func title(for itemID: UInt64) -> String {
        titles[itemID] ?? String(itemID)
    }

    // MARK: - Helpers

    private var missing: [UInt64] {
        if case let .ready(missing) = phase {
            missing
        } else {
            []
        }
    }

    private func isActive(_ itemID: UInt64) -> Bool {
        queue.isQueued(itemID) || downloads.isBusy(itemID)
    }

    private func fail(_ reason: String, requiresSignIn: Bool = false) {
        self.requiresSignIn = requiresSignIn
        phase = .failed(reason)
    }

    /// nil means the library grant could not be resolved — do not report every subscription as missing.
    private func installedWorkshopIDs(using doctor: SteamCMDDoctorService) -> Set<UInt64>? {
        guard let workdir = try? doctor.resolveWorkdirURL() else { return nil }
        let scope = workdir.startAccessingSecurityScopedResource()
        defer {
            if scope {
                workdir.stopAccessingSecurityScopedResource()
            }
        }
        let content = SteamLibraryPaths.workshopContentRoot(steamRoot: workdir)
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: content.path(percentEncoded: false)
        )) ?? []
        return Set(entries.compactMap(UInt64.init))
    }

    /// Titles from the keyless batch endpoint in ≤50 chunks. Failures are silent: an id is a usable label.
    private func loadTitles(for ids: [UInt64]) async {
        var start = 0
        while start < ids.count, !Task.isCancelled {
            let end = min(start + Self.metadataFetchBatchSize, ids.count)
            let chunk = Array(ids[start ..< end])
            start = end
            for (id, result) in await metadataService.fetch(publishedFileIDs: chunk) {
                guard case let .success(metadata) = result, !metadata.title.isEmpty else { continue }
                titles[id] = metadata.title
            }
        }
    }
}
#endif
