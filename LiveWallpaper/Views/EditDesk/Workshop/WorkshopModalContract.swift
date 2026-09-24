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

    /// Shared by the primary button and the bottom bar's status line.
    static var applyingText: String {
        String(
            localized: "Applying…", bundle: .appLanguage,
            comment: "Workshop modal button and status line while the downloaded wallpaper is being applied."
        )
    }

    /// The bottom bar's primary button. `screenName` is the selected float-layer target.
    static func primaryActionTitle(
        installed: Bool, ticketState: DeferredApplyCoordinator.State?, screenName: String
    ) -> String {
        if ticketState == .applying {
            return applyingText
        }
        if ticketState == .waiting {
            return String(
                localized: "Will apply to \(screenName) when done", bundle: .appLanguage,
                comment: "Workshop modal primary button, disabled while a download is queued to apply to this display. Placeholder is the display name."
            )
        }
        if installed {
            return String(
                localized: "Apply to \(screenName)", bundle: .appLanguage,
                comment: "Apply the wallpaper to one display. Placeholder is the display name."
            )
        }
        return String(
            localized: "Apply to \(screenName) when done", bundle: .appLanguage,
            comment: "Workshop modal primary button: download now, apply to this display once it lands. Placeholder is the display name."
        )
    }

    /// The button beside the primary one; both titles keep the download and drop any queued apply.
    static func secondaryActionTitle(ticketState: DeferredApplyCoordinator.State?) -> String {
        if ticketState == .waiting {
            return String(
                localized: "Cancel Auto-Apply", bundle: .appLanguage,
                comment: "Workshop modal button while a download is queued to apply to a display: drops the apply, keeps the download."
            )
        }
        return String(localized: "Save only", bundle: .appLanguage)
    }

    /// The one gate for both download buttons of an item that is not in the library yet.
    static func canDownload(isBanned: Bool, isDownloadReady: Bool) -> Bool {
        !isBanned && isDownloadReady
    }

    /// A library entry stays installed through a later download of the item, such as an update. Only
    /// this attempt's dependency stage hides it: the root is in the library before its parts are.
    static func isInstalled(hasLibraryEntry: Bool, isDownloading: Bool, isFetchingDependencies: Bool) -> Bool {
        hasLibraryEntry && !(isDownloading && isFetchingDependencies)
    }

    /// Cancelling a queued apply needs no download gate: the download is already under way. A running
    /// apply has nothing left to save, and pressing it would cancel the apply halfway.
    static func isSecondaryEnabled(
        ticketState: DeferredApplyCoordinator.State?, isBanned: Bool, isDownloadReady: Bool
    ) -> Bool {
        switch ticketState {
        case .waiting: true
        case .applying: false
        default: canDownload(isBanned: isBanned, isDownloadReady: isDownloadReady)
        }
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

    /// `wallpapersOn` is the master switch; `unsupportedOrigin` is the installed entry when this Mac can't
    /// run it; `blocker` is the doctor's missing-step sentence, nil when ready.
    @MainActor
    static func make(
        ticketState: DeferredApplyCoordinator.State?,
        settledScreenName: String,
        wallpapersOn: Bool,
        phase: WorkshopDownloadCoordinator.DownloadPhase,
        isFetchingDependencies: Bool,
        fraction: Double?,
        downloadedBytes: UInt64?,
        totalBytes: UInt64?,
        bytesPerSecond: Double?,
        isInstalled: Bool,
        unsupportedOrigin: WPEOrigin?,
        blocker: String?
    ) -> WorkshopDownloadPresentation {
        var presentation = WorkshopDownloadPresentation()
        // A settled ticket is the outcome of record while nothing of the item is in flight. It stays
        // until the next queued apply, so a later transfer of the item reports its own progress.
        let isTransferring = isFetchingDependencies || phase == .downloading || phase == .importing
        switch ticketState {
        case .applying:
            presentation.progress = .indeterminate
            presentation.status = WorkshopModalContent.applyingText
            return presentation
        case let .finished(report) where !isTransferring:
            presentation.status = DeferredApplyToasts.appliedText(
                report, screenName: settledScreenName, wallpapersOn: wallpapersOn
            )
            presentation.isFailure = report.outcome != .applied
            return presentation
        case let .downloadOnly(.failed(reason)) where !isTransferring:
            presentation.status = reason
            presentation.isFailure = true
            return presentation
        case let .downloadOnly(.unsupported(entry)) where !isTransferring:
            presentation.status = cannotRunText(entry.origin)
            presentation.isFailure = true
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
            presentation.status = String(
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
        case .idle, .succeeded, .succeededAsPreset:
            if let unsupportedOrigin {
                presentation.status = cannotRunText(unsupportedOrigin)
                presentation.isFailure = true
            } else if !isInstalled, ticketState != .waiting, let blocker {
                presentation.status = blocker
            }
        }
        return presentation
    }

    @MainActor
    private static func cannotRunText(_ origin: WPEOrigin) -> String {
        let reason = FallbackCard.cannotRunSummary(for: origin)
        return String(
            localized: "Can't run on this Mac: \(reason)", bundle: .appLanguage,
            comment: "Workshop modal status line for an item this Mac cannot run. Placeholder is the reason, such as Windows plugin required."
        )
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

/// The displays the float layer offers, in the order `ModalActions.targets` gives the library
/// modal so ⌘1…⌘9 mean the same panel in both.
enum WorkshopModalTargets {
    @MainActor
    static func make(
        displays: [ModalActions.Display],
        activeOn: Set<CGDirectDisplayID>,
        covers: [CGDirectDisplayID: CGImage]
    ) -> [ModalDisplayTarget] {
        ModalActions.targets(displays: displays, activeOn: activeOn, covers: covers)
    }

    /// `queued` is the target of a waiting or running apply, which outranks this session's choice.
    /// Once that display is unplugged nothing is highlighted: the ticket still points there.
    static func resolvedTarget(
        selected: CGDirectDisplayID?, queued: CGDirectDisplayID?, in targets: [ModalDisplayTarget]
    ) -> CGDirectDisplayID? {
        if let queued {
            return targets.contains { $0.id == queued } ? queued : nil
        }
        if let selected, targets.contains(where: { $0.id == selected }) {
            return selected
        }
        return targets.first(where: \.isPrimary)?.id ?? targets.first?.id
    }

    /// The display the primary button names; an unplugged queued display by its name when queued.
    @MainActor
    static func targetName(
        queued: DeferredApplyCoordinator.Target?, resolved: CGDirectDisplayID?, in targets: [ModalDisplayTarget]
    ) -> String {
        guard let queued else {
            return targets.first { $0.id == resolved }?.name ?? ""
        }
        return targets.first { $0.id == queued.screenID }?.name ?? queued.screenName
    }
}

/// Everything the Workshop modal can trigger; the host fills them. A nil closure hides its control.
struct WorkshopModalActions {
    var selectTarget: @MainActor (CGDirectDisplayID) -> Void
    var primary: @MainActor () -> Void
    var saveOnly: @MainActor () -> Void
    /// Present only while a download of this item is in flight.
    var cancelDownload: (@MainActor () -> Void)?
    /// Present only while a missing setup step keeps this not-yet-installed item from downloading.
    var connectSteam: (@MainActor () -> Void)?
    var openInSteam: @MainActor () -> Void
    var reveal: @MainActor () -> Void
    var openItem: @MainActor (UInt64) -> Void
    var selectTag: (@MainActor (String) -> Void)?
    var browseCreator: (@MainActor (String, String?) -> Void)?
}
#endif
