#if DEBUG
import AppKit
import Foundation
import LiveWallpaperCore

@MainActor
extension QAControlPlane {
    /// Screen.activeWallpaperWindow is intentionally non-video for the UI. QA observes every renderer's window.
    static func actualWallpaperWindow(for screen: Screen) -> NSWindow? {
        screen.runtimeSession?.wallpaperWindow ?? screen.runtimeSession?.videoPlayer?.playbackWindow
    }

    func catalogInputs() throws -> SavedLibraryModel.Inputs {
        if let libraryInputs {
            return libraryInputs
        }
        guard let screenManager else { throw QAError.message("ScreenManager unavailable") }
        let inputs = SavedLibraryModel.Inputs.live(screenManager: screenManager)
        libraryInputs = inputs
        return inputs
    }

    func libraryList(_ arguments: [String: Any]) throws -> Any {
        let result = try QALibraryCatalog.list(QALibraryCatalog.entries(inputs: catalogInputs()), arguments: arguments)
        return result.merging(["instanceID": Self.instanceID]) { _, new in new }
    }

    func libraryGet(_ arguments: [String: Any]) async throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["itemID", "expectedItemRevision"])
        let inputs = try catalogInputs()
        let entry = try QALibraryCatalog.resolve(QALibraryCatalog.entries(inputs: inputs), arguments: arguments)
        let available = await inputs.sourceAvailable(entry.item.source)
        let latest = try QALibraryCatalog.resolve(QALibraryCatalog.entries(inputs: inputs), arguments: ["itemID": entry.id, "expectedItemRevision": entry.revision])
        var result = latest.json
        result["availability"] = available ? "available" : "unavailable"
        result["unavailableReason"] = available ? NSNull() : "Source is missing or its grant is unavailable"
        return result
    }

    func libraryRefresh(_ arguments: [String: Any]) async throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: [])
        if AppleAerialsLibrary.shared.isAuthorized {
            await AppleAerialsLibrary.shared.refresh()
        }
        return try libraryList([:])
    }

    func wallpaperApplyLibraryItem(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["screenID", "itemID", "expectedItemRevision", "requestID", "instanceID"])
        if let instance = try QALibraryCatalog.optionalString(arguments["instanceID"], key: "instanceID"), instance != Self.instanceID {
            throw QAError.message("App instance changed; call meta.describe")
        }
        let screen = try resolveScreen(arguments)
        guard let manager = screenManager, !manager.isTerminating else { throw QAError.message("ScreenManager unavailable or terminating") }
        guard let id = try QALibraryCatalog.optionalString(arguments["itemID"], key: "itemID") else { throw QAError.message("Missing itemID") }
        let requestID = try QALibraryCatalog.optionalString(arguments["requestID"], key: "requestID")
        guard requestID == nil || requestID?.isEmpty == false else { throw QAError.message("Empty requestID") }
        let revision = try QALibraryCatalog.optionalString(arguments["expectedItemRevision"], key: "expectedItemRevision")
        // Deduplicate before re-resolving: an import can update its revision as part of a successful apply.
        if let previous = try applyOperations.previous(requestID: requestID, screenID: screen.id, target: id, revision: revision) {
            return previous.json
        }
        let entry = try QALibraryCatalog.resolve(QALibraryCatalog.entries(inputs: catalogInputs()), arguments: arguments)
        guard entry.item.isSupported, let intent = ModalActions.intent(for: entry.item),
              manager.featureCatalog.capabilities.canRender(entry.contentType) else {
            throw QAError.message("This library item's type is unsupported in this edition")
        }
        let apply = libraryApply
        let router = ApplyRouter(manager: manager, bookmarks: .shared, sceneCapable: manager.featureCatalog.isEnabled(.scene))
        let operation = try applyOperations.start(screenID: screen.id, requestID: requestID, target: entry.id, revision: entry.revision) { [weak manager, weak screen] in
            guard let manager, let screen, !manager.isTerminating,
                  manager.screens.contains(where: { $0 === screen }) else {
                return ["confirmed": false, "code": "screen.unavailable"]
            }
            // A library edit between acceptance and dispatch must not apply a stale descriptor.
            do {
                _ = try QALibraryCatalog.resolve(QALibraryCatalog.entries(inputs: self.catalogInputs()), arguments: ["itemID": entry.id, "expectedItemRevision": entry.revision])
            } catch { return ["confirmed": false, "code": "library.changed"] }
            let report = if let apply {
                await apply(intent, screen)
            } else {
                await router.apply(intent, to: screen)
            }
            var result: [String: Any] = ["confirmed": report.outcome == .applied, "exitedSpanMode": report.exitedSpanMode,
                                         "configurationRevision": manager.configurationRevision(for: screen),
                                         "hasActiveWindow": Self.actualWallpaperWindow(for: screen) != nil,
                                         "sessionID": screen.runtimeSession.map { String(describing: ObjectIdentifier($0)) } ?? NSNull()]
            switch report.outcome {
            case .applied: result["code"] = "apply.committed"
            case let .failed(failure):
                result["code"] = Self.dropFailureCode(failure)
                result["reason"] = LogPrivacyRedactor.scrub(failure.toastText)
            case let .prepareFailed(reason, attemptID):
                result["code"] = "apply.prepareFailed"
                result["reason"] = LogPrivacyRedactor.scrub(reason)
                result["attemptID"] = attemptID?.uuidString ?? NSNull()
                if let attemptID, let failure = manager.wallpaperLoads.attempt(for: screen)?.failure, failure.id == attemptID {
                    result["failure"] = ["stage": failure.stage.rawValue, "code": failure.cause.code, "reason": failure.cause.reason]
                }
            default: result["code"] = "apply.unconfirmed"
            }
            return result
        }
        return operation.json
    }

    func playbackSet(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["screenID", "playing"])
        guard let raw = arguments["playing"] else { throw QAError.message("Missing playing") }
        let playing = try QALibraryCatalog.boolean(raw, key: "playing")
        guard let manager = screenManager, !manager.isTerminating else { throw QAError.message("ScreenManager unavailable") }
        let targets = try arguments["screenID"] == nil ? manager.screens : [resolveScreen(arguments)]
        guard !targets.isEmpty, targets.allSatisfy({ $0.playbackController != nil }) else {
            throw QAError.message("Every target must have a playback controller; apply a wallpaper first")
        }
        for screen in targets {
            manager.setPlayback(playing: playing, for: screen)
        }
        return try ["status": "applied", "playing": playing, "runtime": runtimeState(arguments.filter { $0.key == "screenID" })]
    }

    private static func dropFailureCode(_ failure: DropFailure) -> String {
        switch failure {
        case .applyNotConfirmed: "apply.unconfirmed"
        case .unrecognizedDrop: "source.unsupported"
        case .sceneUnsupportedInBuild: "edition.unsupported"
        case .videoBookmarkFailed, .htmlBookmarkFailed: "source.accessDenied"
        case .sourceMissing: "source.missing"
        #if !LITE_BUILD
        case .sceneProjectUnsupported: "source.unsupported"
        case .sceneImportRejected: "import.rejected"
        #endif
        }
    }
}
#endif
