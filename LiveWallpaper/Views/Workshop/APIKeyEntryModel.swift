#if !LITE_BUILD
import LiveWallpaperCore
import Observation
import SwiftUI

/// The state machine behind entering a Steam Web API key.
///
/// Two surfaces enter the same key — the onboarding/browse sheet and the
/// inline Workshop settings section — and they differ only in how the fields
/// are laid out. Keeping the debounce, the shape check, the Valve round-trip
/// and the error vocabulary here is what stops the two from drifting into
/// disagreeing about when a key is valid.
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

    var apiKey: String = ""
    var hasReadTOU: Bool = false
    var isShowingKey: Bool = false

    private(set) var validation: Validation = .empty
    private(set) var savingError: String?

    @ObservationIgnored private let services: WorkshopServices
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var validatedAPIKey: String?

    init(services: WorkshopServices) {
        self.services = services
    }

    var canSave: Bool {
        // The consent checkbox gates the field, but validation outlives it: tick
        // it, let the key validate, untick it, and Save was still lit.
        validation == .valid && hasReadTOU
    }

    func reset() {
        validationTask?.cancel()
        validationTask = nil
        validatedAPIKey = nil
        apiKey = ""
        hasReadTOU = false
        isShowingKey = false
        validation = .empty
        savingError = nil
    }

    func keyChanged() {
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
        let service = services.queryService
        validationTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                let ok = try await service.validateAPIKey(trimmed)
                if Task.isCancelled { return }
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
                        comment: "Steam Web API key validation error with the underlying failure."
                    )
                )
            }
        }
    }

    /// Returns `true` once the key is stored and `hasWebAPIKey` reflects it.
    @discardableResult
    func save() async -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasReadTOU, validation == .valid, validatedAPIKey == trimmed else {
            keyChanged()
            return false
        }
        do {
            try await services.keychain.setWebAPIKey(trimmed)
            await services.refreshAPIKeyStatus()
            return true
        } catch {
            savingError = String(
                localized: "Couldn't save: \(error.localizedDescription)",
                comment: "Steam Web API key save failure."
            )
            return false
        }
    }

    func forget() async {
        do {
            try await services.keychain.deleteWebAPIKey()
        } catch {
            // Swallowing this left `hasWebAPIKey` true with the UI claiming the
            // key was forgotten — the one state where the user stops looking.
            savingError = String(
                localized: "Couldn't remove the key: \(error.localizedDescription)",
                comment: "Steam Web API key deletion failure."
            )
            await services.refreshAPIKeyStatus()
            return
        }
        await services.refreshAPIKeyStatus()
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
            return String(localized: "Steam rejected the key.", comment: "Steam Web API key validation error.")
        case .keyDisabled:
            return String(
                localized: "Your Steam API key was disabled by Valve.",
                comment: "Steam Web API key validation error."
            )
        case .rateLimited:
            return String(
                localized: "Steam is rate-limiting right now. Retry in a moment.",
                comment: "Steam Web API key validation error."
            )
        case .networkUnreachable:
            return String(
                localized: "Couldn't reach Steam. Check your connection.",
                comment: "Steam Web API key validation error."
            )
        case .timeout:
            return String(localized: "Steam took too long to respond.", comment: "Steam Web API key validation error.")
        default:
            return String(localized: "Validation failed.", comment: "Steam Web API key validation error.")
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
