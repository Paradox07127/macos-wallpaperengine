#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

enum WorkshopDownloadOutcome: Equatable, Sendable {
    case succeeded(WPEHistoryEntry)
    case succeededAsPreset(baseWorkshopID: String)
    case failed(reason: String)
    case cancelled
    /// In the library, but this Mac can't run it.
    case unsupported(WPEHistoryEntry)
}

@MainActor
@Observable
final class WorkshopDownloadAttempt: Identifiable {
    let id: UUID
    let itemID: UInt64
    /// Nil while the root import or its dependency chain is still running.
    private(set) var outcome: WorkshopDownloadOutcome?

    @ObservationIgnored private var subscribers: [UUID: AsyncStream<WorkshopDownloadOutcome>.Continuation] = [:]

    init(id: UUID = UUID(), itemID: UInt64) {
        self.id = id
        self.itemID = itemID
    }

    /// Each subscription receives the terminal result, including subscriptions made after completion.
    func outcomes() -> AsyncStream<WorkshopDownloadOutcome> {
        let (stream, continuation) = AsyncStream<WorkshopDownloadOutcome>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if let outcome {
            continuation.yield(outcome)
            continuation.finish()
        } else {
            let token = UUID()
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.subscribers[token] = nil
                }
            }
        }
        return stream
    }

    func finish(_ outcome: WorkshopDownloadOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        for continuation in continuations {
            continuation.yield(outcome)
            continuation.finish()
        }
    }
}
#endif
