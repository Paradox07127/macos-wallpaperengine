#if !LITE_BUILD
import Foundation

extension Notification.Name {
    /// Posted synchronously on the main actor before SteamCMD is allowed to
    /// mutate one Workshop item. Runtime owners must close every in-place read
    /// of that item before returning from the notification callback.
    static let workshopItemWillMutate = Notification.Name("WorkshopItemWillMutate")

    /// Posted after SteamCMD and the import/validation boundary have completed.
    /// Runtime owners may rebuild sessions from the newly validated generation.
    static let workshopItemDidMutate = Notification.Name("WorkshopItemDidMutate")
}

/// App-local consistency boundary for the shared Steam Workshop repository. Steam does not participate in `NSFileCoordinator`, so Loomscreen coordinates its own readers around every mutation it starts.
/// The existing SteamCMD operation/process gates still serialize writers across the repository; this coordinator adds the narrower per-item lifecycle required by renderers that read `scene.pkg` and loose assets in place.
@MainActor
final class WorkshopRepositoryCoordinator {
    enum MutationError: Error, Equatable {
        case itemAlreadyMutating(String)
    }

    static let shared = WorkshopRepositoryCoordinator()

    private var mutationTokens: [String: UUID] = [:]

    #if DEBUG
    // Test-only introspection; no production reader.
    func isMutating(workshopID: String) -> Bool {
        mutationTokens[workshopID] != nil
    }
    #endif

    func withExclusiveMutation<Result: Sendable>(
        workshopID: String,
        operation: @MainActor @Sendable () async throws -> Result
    ) async throws -> Result {
        guard !workshopID.isEmpty, mutationTokens[workshopID] == nil else {
            throw MutationError.itemAlreadyMutating(workshopID)
        }

        let token = UUID()
        mutationTokens[workshopID] = token
        NotificationCenter.default.post(
            name: .workshopItemWillMutate,
            object: self,
            userInfo: ["workshopID": workshopID]
        )
        defer {
            if mutationTokens[workshopID] == token {
                mutationTokens[workshopID] = nil
                NotificationCenter.default.post(
                    name: .workshopItemDidMutate,
                    object: self,
                    userInfo: ["workshopID": workshopID]
                )
            }
        }
        return try await operation()
    }
}
#endif
