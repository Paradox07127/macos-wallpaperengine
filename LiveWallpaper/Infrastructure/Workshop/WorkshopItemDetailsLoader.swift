#if !LITE_BUILD
import Foundation

@MainActor
final class WorkshopItemDetailsLoader {
    struct Outcome: Equatable {
        /// In request order. Steam's drop rules apply (`SteamWorkshopMetadataService.decode`):
        /// private, banned, not-found and foreign-app ids are failures.
        let items: [WorkshopQueryItem]
        let failedIDs: [UInt64]
        /// Whole-batch failure that says nothing about the ids: items and failedIDs are empty, and a retry may succeed.
        var transientFailure = false
    }

    private let metadata: SteamWorkshopMetadataService
    private let retryPolicy: WorkshopRetryPolicy

    init(
        metadata: SteamWorkshopMetadataService = SteamWorkshopMetadataService(),
        retryPolicy: WorkshopRetryPolicy = WorkshopRetryPolicy()
    ) {
        self.metadata = metadata
        self.retryPolicy = retryPolicy
    }

    func load(ids: [UInt64]) async -> Outcome {
        var seen = Set<UInt64>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return Outcome(items: [], failedIDs: []) }
        let response: WorkshopRetryPolicy.Response
        do {
            response = try await retryPolicy.run(host: SteamWorkshopMetadataService.endpoint.host() ?? "") { [metadata] in
                try await metadata.post(publishedFileIDs: unique)
            }
        } catch {
            return Outcome(items: [], failedIDs: [], transientFailure: true)
        }
        let status = response.http.statusCode
        if status == 429 || (500 ... 599).contains(status) {
            return Outcome(items: [], failedIDs: [], transientFailure: true)
        }
        let results = SteamWorkshopMetadataService.results(from: response, requestedIDs: unique)
        var items: [WorkshopQueryItem] = []
        var failed: [UInt64] = []
        var unknownFailures = 0
        for id in unique {
            switch results[id] {
            case let .success(entry)?:
                items.append(WorkshopPublicSearchSource.queryItem(from: entry))
            case .failure(.unknown)?:
                unknownFailures += 1
                failed.append(id)
            default:
                failed.append(id)
            }
        }
        if unknownFailures == unique.count {
            return Outcome(items: [], failedIDs: [], transientFailure: true)
        }
        return Outcome(items: items, failedIDs: failed)
    }
}
#endif
