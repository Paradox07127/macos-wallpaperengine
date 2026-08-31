#if !LITE_BUILD
import LiveWallpaperCore
import Observation
import SwiftUI

/// The state machine behind entering a Steam Web API key.
/// Two surfaces enter the same key — the onboarding/browse sheet and the inline Workshop
/// settings section — differing only in field layout. Keeping the debounce, shape check, Valve
/// round-trip and error vocabulary here stops the two from disagreeing about when a key is valid.
@MainActor
@Observable
final class SteamWebAPIKeyEntryModel {
    enum Validation: Equatable {
        case empty
        case wrongShape
        case validating
        case valid
        case error(String)
    }

    struct Dependencies: Sendable {
        var validationDelayNanoseconds: UInt64 = 250_000_000
        var validateAPIKey: @Sendable (String) async throws -> Bool
        var saveAPIKey: @Sendable (String) async throws -> Void
        var deleteAPIKey: @Sendable () async throws -> Void
        var refreshAPIKeyStatus: @MainActor @Sendable () async -> Void
    }

    var apiKey: String = ""
    var isShowingKey: Bool = false

    private(set) var validation: Validation = .empty
    private(set) var savingError: String?
    private(set) var isSaving = false

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var validatedAPIKey: String?
    @ObservationIgnored private var editRevision: UInt = 0

    init(services: WorkshopServices) {
        let queryService = services.queryService
        let keychain = services.keychain
        dependencies = Dependencies(
            validateAPIKey: { try await queryService.validateAPIKey($0) },
            saveAPIKey: { try await keychain.setWebAPIKey($0) },
            deleteAPIKey: { try await keychain.deleteWebAPIKey() },
            refreshAPIKeyStatus: { await services.refreshAPIKeyStatus() }
        )
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var canSave: Bool {
        validation == .valid && !isSaving
    }

    func reset() {
        editRevision &+= 1
        validationTask?.cancel()
        validationTask = nil
        validatedAPIKey = nil
        apiKey = ""
        isShowingKey = false
        validation = .empty
        savingError = nil
    }

    func keyChanged() {
        editRevision &+= 1
        savingError = nil
        validatedAPIKey = nil
        validationTask?.cancel()
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validation = .empty
            return
        }
        guard isHex32(trimmed) else {
            validation = .wrongShape
            return
        }
        validation = .validating
        let validateAPIKey = dependencies.validateAPIKey
        let validationDelayNanoseconds = dependencies.validationDelayNanoseconds
        validationTask = Task {
            do {
                try await Task.sleep(nanoseconds: validationDelayNanoseconds)
                if Task.isCancelled {
                    return
                }
                let ok = try await validateAPIKey(trimmed)
                if Task.isCancelled {
                    return
                }
                guard stillEditing(trimmed) else { return }
                if ok {
                    validation = .valid
                    validatedAPIKey = trimmed
                } else {
                    validation = .error(Self.message(for: .unauthorized))
                }
            } catch is CancellationError {
                return
            } catch let error as WorkshopQueryError {
                if Task.isCancelled { return }
                guard stillEditing(trimmed) else { return }
                validation = .error(Self.message(for: error))
            } catch {
                if Task.isCancelled { return }
                guard stillEditing(trimmed) else { return }
                validation = .error(
                    String(
                        localized: "Validation failed: \(error.localizedDescription)",
                        bundle: .appLanguage, comment: "Steam Web API key validation error with the underlying failure."
                    )
                )
            }
        }
    }

    /// Returns `true` once the key is stored and `hasWebAPIKey` reflects it.
    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validation == .valid, validatedAPIKey == trimmed else {
            keyChanged()
            return false
        }
        let revision = editRevision
        isSaving = true
        defer { isSaving = false }
        do {
            try await dependencies.saveAPIKey(trimmed)
            await dependencies.refreshAPIKeyStatus()
            guard editRevision == revision, stillEditing(trimmed) else { return false }
            return true
        } catch {
            guard editRevision == revision, stillEditing(trimmed) else { return false }
            savingError = String(
                localized: "Couldn't save: \(error.localizedDescription)",
                bundle: .appLanguage, comment: "Steam Web API key save failure."
            )
            return false
        }
    }

    func forget() async {
        do {
            try await dependencies.deleteAPIKey()
        } catch {
            // Swallowing this left `hasWebAPIKey` true with the UI claiming the
            // key was forgotten — the one state where the user stops looking.
            savingError = String(
                localized: "Couldn't remove the key: \(error.localizedDescription)",
                bundle: .appLanguage, comment: "Steam Web API key deletion failure."
            )
            await dependencies.refreshAPIKeyStatus()
            return
        }
        await dependencies.refreshAPIKeyStatus()
        reset()
    }

    private func stillEditing(_ candidate: String) -> Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == candidate
    }

    private func isHex32(_ key: String) -> Bool {
        key.count == 32 && key.allSatisfy(\.isHexDigit)
    }

    static func message(for error: WorkshopQueryError) -> String {
        switch error {
        case .unauthorized:
            return String(localized: "Steam rejected the key.", bundle: .appLanguage, comment: "Steam Web API key validation error.")
        case .keyDisabled:
            return String(
                localized: "Your Steam API key was disabled by Valve.",
                bundle: .appLanguage, comment: "Steam Web API key validation error."
            )
        case .rateLimited:
            return String(
                localized: "Steam is rate-limiting right now. Retry in a moment.",
                bundle: .appLanguage, comment: "Steam Web API key validation error."
            )
        case .networkUnreachable:
            return String(
                localized: "Couldn't reach Steam. Check your connection.",
                bundle: .appLanguage, comment: "Steam Web API key validation error."
            )
        case .timeout:
            return String(localized: "Steam took too long to respond.", bundle: .appLanguage, comment: "Steam Web API key validation error.")
        default:
            return String(localized: "Validation failed.", bundle: .appLanguage, comment: "Steam Web API key validation error.")
        }
    }
}

/// The links every key-entry surface points at.
enum SteamWebAPIKeyLinks {
    static let apiKey = URL(string: "https://steamcommunity.com/dev/apikey")!
    static let terms = URL(string: "https://steamcommunity.com/dev/apiterms")!
    static let limitedAccounts = URL(string: "https://help.steampowered.com/en/faqs/view/71D3-35C2-AD96-AA3A")!
}
#endif
