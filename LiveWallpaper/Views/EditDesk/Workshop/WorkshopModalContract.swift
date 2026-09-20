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
    static func make(
        displays: [ModalActions.Display],
        activeOn: Set<CGDirectDisplayID>,
        covers: [CGDirectDisplayID: CGImage]
    ) -> [ModalDisplayTarget] {
        let ordered = displays.sorted { $0.frame.minX < $1.frame.minX }
        let primary = ordered.first { !activeOn.contains($0.id) } ?? ordered.first
        return ordered.enumerated().map { index, display in
            ModalDisplayTarget(
                id: display.id,
                name: display.name,
                shortcutIndex: index + 1,
                aspectRatio: display.frame.width / display.frame.height,
                thumbnail: covers[display.id],
                isPrimary: display.id == primary?.id
            )
        }
    }
}

/// Everything the Workshop modal can trigger; the host fills them. A nil closure hides its control.
struct WorkshopModalActions {
    var selectTarget: @MainActor (CGDirectDisplayID) -> Void
    var primary: @MainActor () -> Void
    var saveOnly: @MainActor () -> Void
    /// Present only while a download of this item is in flight.
    var cancelDownload: (@MainActor () -> Void)?
    var openInSteam: @MainActor () -> Void
    var reveal: @MainActor () -> Void
    var openItem: @MainActor (UInt64) -> Void
    var selectTag: (@MainActor (String) -> Void)?
    var browseCreator: (@MainActor (String, String?) -> Void)?
}
#endif
