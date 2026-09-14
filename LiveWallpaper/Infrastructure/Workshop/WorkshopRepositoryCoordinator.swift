#if !LITE_BUILD
import Foundation

extension Notification.Name {
    /// Posted on the main actor before SteamCMD mutates an item; close every in-place read of that item before returning from the callback.
    static let workshopItemWillMutate = Notification.Name("WorkshopItemWillMutate")

    static let workshopItemDidMutate = Notification.Name("WorkshopItemDidMutate")
}

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
