#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore

// Seam between `WorkshopModalHost` (which resolves the item, the targets and the download) and
// `WorkshopModal` (which draws them). Values only, so the arithmetic and the wording are testable
// without a window.

/// One Workshop item as the Edit Desk modal shows it.
struct WorkshopModalContent: Equatable {
    let item: WorkshopQueryItem
    /// Present only when this item is already in the wallpaper library.
    var installed: InstalledItemExtras?

    var isInstalled: Bool {
        installed != nil
    }

    /// The one gate for starting a download of an item that is not in the library yet.
    static func canDownload(isBanned: Bool, isDownloadReady: Bool) -> Bool {
        !isBanned && isDownloadReady
    }

    /// A library entry stays installed through a later download of the item, such as an update. Only
    /// this attempt's dependency stage hides it: the root is in the library before its parts are.
    static func isInstalled(hasLibraryEntry: Bool, isDownloading: Bool, isFetchingDependencies: Bool) -> Bool {
        hasLibraryEntry && !(isDownloading && isFetchingDependencies)
    }

    /// Steam's rows for `item`, plus the day the library got it when `importedAt` says it has.
    @MainActor
    static func facts(item: WorkshopQueryItem, importedAt: Date?, now: Date, locale: Locale) -> [WallpaperFact] {
        var facts = WallpaperFacts.steam(item, now: now, locale: locale)
        if let importedAt {
            facts.append(WallpaperFact(
                kind: .imported, value: WallpaperFacts.dateText(importedAt, locale: locale),
                help: WallpaperFacts.relativeText(importedAt, now: now, locale: locale)
            ))
        }
        return facts.sorted { $0.kind < $1.kind }
    }
}

/// What the bottom bar shows for one item, derived from the download coordinator's phase, the live
/// attempt and the deferred-apply ticket.
struct WorkshopDownloadPresentation: Equatable {
    enum Progress: Equatable {
        /// No bar at all.
        case none
        /// A bar with no value: the dependency chain and the import report no fraction.
        case indeterminate
        /// 0…1.
        case fraction(Double)
    }

    var progress: Progress = .none
    /// Localized; empty hides the line.
    var status: String = ""
    /// `264 MB / 412 MB · 12 MB/s` — numbers only, never translated.
    var detail: String = ""
    var isFailure = false

    /// Bytes per second across one pair of samples. nil when the pair cannot produce a speed: no
    /// time passed, or the counter went backwards because the download restarted.
    static func rate(bytes: Int64, elapsed: TimeInterval) -> Double? {
        guard bytes > 0, elapsed > 0 else { return nil }
        return Double(bytes) / elapsed
    }

    /// `264 MB / 412 MB · 12 MB/s`; each half is dropped when its numbers are unknown.
    @MainActor
    static func detailText(
        downloaded: UInt64?, total: UInt64?, bytesPerSecond: Double?, fraction: Double?
    ) -> String {
        var parts: [String] = []
        if let fraction {
            parts.append("\(Int((fraction * 100).rounded()))%")
        }
        if let total, total > 0 {
            let downloadedBytes = downloaded ?? UInt64((Double(total) * (fraction ?? 0)).rounded())
            parts.append(
                "\(WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Int64(clamping: downloadedBytes)))"
                    + " / \(WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Int64(clamping: total)))"
            )
        }
        if let bytesPerSecond, bytesPerSecond > 0 {
            let amount = WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Int64(clamping: UInt64(bytesPerSecond)))
            parts.append(String(
                localized: "\(amount)/s", bundle: .appLanguage,
                comment: "Download speed. Placeholder is a formatted byte amount such as 12 MB."
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// `screenName` is the ticket's display; `wallpapersOn` is the master switch; `blocker` is the
    /// doctor's missing-step sentence, nil when ready.
    /// `reportsSave` puts the library line on a finished download; false where the entry was in the library already.
    @MainActor
    static func make(
        ticketState: DeferredApplyCoordinator.State?,
        screenName: String,
        wallpapersOn: Bool,
        phase: WorkshopDownloadCoordinator.DownloadPhase,
        isFetchingDependencies: Bool,
        fraction: Double?,
        downloadedBytes: UInt64?,
        totalBytes: UInt64?,
        bytesPerSecond: Double?,
        isInstalled: Bool,
        reportsSave: Bool,
        blocker: String?
    ) -> WorkshopDownloadPresentation {
        var presentation = WorkshopDownloadPresentation()
        // A settled ticket is the outcome of record while nothing of the item is in flight. It stays
        // until the next queued apply, so a later transfer of the item reports its own progress.
        let isTransferring = isFetchingDependencies || phase == .downloading || phase == .importing
        switch ticketState {
        case .applying:
            presentation.progress = .indeterminate
            presentation.status = String(
                localized: "Applying…", bundle: .appLanguage,
                comment: "Workshop modal status line while the downloaded wallpaper is being applied."
            )
            return presentation
        case let .finished(report) where !isTransferring:
            presentation.status = DeferredApplyToasts.appliedText(
                report, screenName: screenName, wallpapersOn: wallpapersOn
            )
            presentation.isFailure = report.outcome != .applied
            return presentation
        case let .downloadOnly(.failed(reason)) where !isTransferring:
            presentation.status = reason
            presentation.isFailure = true
            return presentation
        case .downloadOnly(.unsupported) where !isTransferring:
            // The right column's notice says why this Mac can't run it.
            return presentation
        case .invalidated(.newerSelection) where !isTransferring:
            presentation.status = DeferredApplyToasts.newerSelectionText(screenName: screenName)
            return presentation
        case .invalidated(.screenUnavailable) where !isTransferring:
            presentation.status = DeferredApplyToasts.screenUnavailableText(screenName: screenName)
            return presentation
        case .finished, .downloadOnly, .invalidated, .waiting, nil:
            break
        }
        if isFetchingDependencies {
            presentation.progress = .indeterminate
            presentation.status = String(
                localized: "Downloading required items…", bundle: .appLanguage,
                comment: "Workshop modal status while the other Workshop items a wallpaper needs are downloading."
            )
            return presentation
        }
        switch phase {
        case .downloading:
            presentation.progress = fraction.map { .fraction($0) } ?? .indeterminate
            presentation.status = ticketState == .waiting
                ? String(
                    localized: "Will apply to \(screenName) when done", bundle: .appLanguage,
                    comment: "Workshop modal status while a download is queued to apply to a display. Placeholder is the display name."
                )
                : String(
                    localized: "Downloading…", bundle: .appLanguage,
                    comment: "Workshop download in progress."
                )
            presentation.detail = detailText(
                downloaded: downloadedBytes, total: totalBytes, bytesPerSecond: bytesPerSecond, fraction: fraction
            )
        case .importing:
            presentation.progress = .indeterminate
            presentation.status = String(
                localized: "Importing…", bundle: .appLanguage,
                comment: "Workshop item is being imported after download."
            )
        case let .failed(message):
            presentation.status = message
            presentation.isFailure = true
        case .succeeded where reportsSave && isInstalled && ticketState != .waiting:
            // Saved with no apply queued, or with the queued one cancelled; a waiting apply reports next.
            presentation.status = String(
                localized: "Added to your library.", bundle: .appLanguage, comment: "Workshop download success toast subtitle."
            )
        case .idle, .succeeded, .succeededAsPreset:
            if !isInstalled, ticketState != .waiting, let blocker {
                presentation.status = blocker
            }
        }
        return presentation
    }
}

/// Turns the coordinator's running byte totals into a speed. Resetting on a new attempt is the
/// point: a retry starts its counter from zero and the previous sample would read as a rewind.
struct WorkshopDownloadRateMeter {
    private(set) var bytesPerSecond: Double?
    private var attemptID: UUID?
    private var sampledBytes: UInt64?
    private var sampledAt: Date?

    mutating func record(attemptID: UUID?, downloadedBytes: UInt64?, at now: Date) {
        guard let attemptID, let downloadedBytes else {
            self = WorkshopDownloadRateMeter()
            return
        }
        guard attemptID == self.attemptID, let previousBytes = sampledBytes, let previousAt = sampledAt else {
            self = WorkshopDownloadRateMeter()
            self.attemptID = attemptID
            sampledBytes = downloadedBytes
            sampledAt = now
            return
        }
        let delta = Int64(clamping: downloadedBytes) - Int64(clamping: previousBytes)
        if let rate = WorkshopDownloadPresentation.rate(bytes: delta, elapsed: now.timeIntervalSince(previousAt)) {
            bytesPerSecond = rate
            sampledBytes = downloadedBytes
            sampledAt = now
        } else if delta < 0 {
            // The counter restarted inside one attempt (SteamCMD retries a chunk): drop the pair
            // rather than publishing a negative speed.
            bytesPerSecond = nil
            sampledBytes = downloadedBytes
            sampledAt = now
        }
    }
}

/// The display buttons, in the order `ModalActions.targets` gives the library modal so ⌘1…⌘9 mean
/// the same display in both.
enum WorkshopModalTargets {
    @MainActor
    static func make(displays: [ModalActions.Display], activeOn: Set<CGDirectDisplayID>) -> [ModalDisplayTarget] {
        ModalActions.targets(displays: displays, activeOn: activeOn, covers: [:])
    }
}

/// The bottom row for one item: the display buttons with the queued one marked, and the buttons after them.
struct WorkshopModalButtonRow: Equatable {
    enum ExtraKind: Equatable {
        case saveOnly, cancelAutoApply, cancelDownload, connectSteam

        var title: String {
            switch self {
            case .saveOnly: String(localized: "Save only", bundle: .appLanguage)
            case .cancelAutoApply:
                String(
                    localized: "Cancel Auto-Apply", bundle: .appLanguage,
                    comment: "Workshop modal button while a download is queued to apply to a display: drops the apply, keeps the download."
                )
            case .cancelDownload: String(localized: "Cancel download", bundle: .appLanguage)
            case .connectSteam: String(localized: "Connect Steam", bundle: .appLanguage)
            }
        }
    }

    struct Extra: Equatable {
        let kind: ExtraKind
        var isEnabled = true
    }

    var targets: [ModalDisplayTarget]
    /// False greys every display button.
    var canPress: Bool
    var mode: ModalDisplayButtons.Mode
    var extras: [Extra]

    /// `queuedScreenID` is the display a waiting or running apply goes to; `isBusy` means a download of
    /// the item is in flight. While an apply is queued no display leads, so no button moves under the pointer.
    static func make(
        targets: [ModalDisplayTarget], isInstalled: Bool, canRun: Bool, ticketState: DeferredApplyCoordinator.State?,
        queuedScreenID: CGDirectDisplayID?, isBanned: Bool, isDownloadReady: Bool, isBusy: Bool
    ) -> WorkshopModalButtonRow {
        let isQueued = ticketState == .waiting || ticketState == .applying
        var targets = targets
        if isQueued {
            for index in targets.indices {
                targets[index].isPrimary = false
                targets[index].isPreparing = targets[index].id == queuedScreenID
            }
        }
        var row = WorkshopModalButtonRow(targets: targets, canPress: false, mode: isInstalled ? .apply : .download, extras: [])
        if ticketState == .applying {
            return row
        }
        let canDownload = WorkshopModalContent.canDownload(isBanned: isBanned, isDownloadReady: isDownloadReady)
        if isInstalled {
            row.canPress = canRun
        } else if ticketState == .waiting {
            row.canPress = true
            row.extras = [Extra(kind: .cancelAutoApply)]
        } else {
            // A download already running needs no gate of its own to take an apply.
            row.canPress = isBusy || canDownload
            if !isBusy {
                row.extras = [Extra(kind: .saveOnly, isEnabled: canDownload)]
            }
        }
        if isBusy {
            row.extras.append(Extra(kind: .cancelDownload))
        }
        if !isInstalled, !isDownloadReady {
            row.extras.append(Extra(kind: .connectSteam))
        }
        return row
    }
}

/// What pressing a display button does.
enum WorkshopModalPress {
    enum Action: Equatable {
        case applyNow, retarget, applyWhenDownloaded
        /// The apply is already running; pressing again would leave the first display half-changed.
        case ignore
    }

    static func action(isInstalled: Bool, ticketState: DeferredApplyCoordinator.State?) -> Action {
        if ticketState == .applying {
            return .ignore
        }
        if isInstalled {
            return .applyNow
        }
        return ticketState == .waiting ? .retarget : .applyWhenDownloaded
    }
}

/// ← → over the browse page as loaded: an item opened from elsewhere, such as a required item, is not on it.
enum WorkshopModalPaging {
    static func neighbours(of id: UInt64, in page: [UInt64]) -> (previous: UInt64?, next: UInt64?) {
        guard let index = page.firstIndex(of: id) else { return (nil, nil) }
        return (
            index > page.startIndex ? page[index - 1] : nil,
            index + 1 < page.endIndex ? page[index + 1] : nil
        )
    }
}

/// Everything the Workshop modal can trigger; the host fills them. A nil closure leaves its control inert.
struct WorkshopModalActions {
    /// A display button or ⌘n; `WorkshopModalPress` decides what it does.
    var press: @MainActor (CGDirectDisplayID) -> Void
    /// Save only and Cancel Auto-Apply alike: keeps the download, drops any queued apply.
    var saveOnly: @MainActor () -> Void
    var cancelDownload: @MainActor () -> Void
    var connectSteam: @MainActor () -> Void
    var openInSteam: @MainActor () -> Void
    var reveal: @MainActor () -> Void
    var openItem: @MainActor (UInt64) -> Void
    var selectTag: (@MainActor (String) -> Void)?
    var browseCreator: (@MainActor (String, String?) -> Void)?
}
#endif
