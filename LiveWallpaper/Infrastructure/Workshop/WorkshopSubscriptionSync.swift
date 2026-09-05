#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

/// Downloads the Workshop items the signed-in Steam account is subscribed to
/// but this Mac does not have yet.
///
/// Additive only, deliberately: an item present locally but absent from the
/// subscription list is left alone. Nothing here deletes, unsubscribes, or
/// reconciles removals — a "sync" that could take wallpapers away would be a
/// different feature with a different confirmation.
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

    @ObservationIgnored private let metadataService: SteamWorkshopMetadataService
    @ObservationIgnored private let downloads: WorkshopDownloadCoordinator
    /// The sequential download walk, so a second press replaces it.
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let metadataFetchBatchSize = 50

    init(
        metadataService: SteamWorkshopMetadataService = SteamWorkshopMetadataService(),
        downloads: WorkshopDownloadCoordinator = .shared
    ) {
        self.metadataService = metadataService
        self.downloads = downloads
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

        guard let installed = installedWorkshopIDs(using: doctor) else {
            fail(String(
                localized: "Authorize your Steam library folder before checking your subscriptions.",
                bundle: .appLanguage, comment: "Subscription sync error when the Steam library folder is not authorized."
            ))
            return
        }
        guard let result = await SteamConnectorClient.listSubscribedWorkshopItems(accountName: account) else {
            fail(String(
                localized: "Loomscreen's Steam connector did not respond.",
                bundle: .appLanguage, comment: "Subscription sync error when the XPC connector could not be reached."
            ))
            return
        }

        switch result.outcome {
        case .listed:
            let missing = result.workshopIDs.compactMap(UInt64.init).filter { !installed.contains($0) }
            phase = .ready(missing: missing)
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
                localized: "SteamCMD could not be launched. Re-select it in the setup list.",
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

    /// Queues every missing item through the ordinary download path, so their
    /// progress, cancellation and import are the ones the rest of the app
    /// already shows.
    /// One at a time. The connector runs SteamCMD on a serial queue and drops a
    /// request that waited too long for it, so enqueueing a whole subscription
    /// list at once makes everything after the first item time out in the queue
    /// rather than download.
    func downloadMissing(using doctor: SteamCMDDoctorService) {
        guard case let .ready(missing) = phase else { return }
        task?.cancel()
        task = Task { [weak self] in
            for itemID in missing {
                guard let self, !Task.isCancelled else { return }
                downloads.download(itemID: itemID, title: title(for: itemID), using: doctor)
                while downloads.isBusy(itemID) {
                    if Task.isCancelled {
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    func title(for itemID: UInt64) -> String {
        titles[itemID] ?? String(itemID)
    }

    // MARK: - Helpers

    private func fail(_ reason: String, requiresSignIn: Bool = false) {
        self.requiresSignIn = requiresSignIn
        phase = .failed(reason)
    }

    /// What is already on disk, from the same content root the Doctor's
    /// Workshop probe reads. nil means the library grant could not be
    /// resolved — reporting every subscription as missing would be worse than
    /// saying so.
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

    /// Titles come from the keyless batch endpoint the paste queue already
    /// uses, in the same ≤50 chunks. Failures are silent: an id is a usable
    /// label, and a second network path for names is not worth one.
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
