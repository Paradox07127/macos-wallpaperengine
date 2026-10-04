#if DEBUG
import Foundation
import LiveWallpaperCore

@MainActor
struct QAScreenCheckpoint {
    let screenID: UInt32
    let fingerprint: String
    let configuration: ScreenConfiguration?
    let overlay: MonitorOverlayConfiguration
    let playing: Bool?
}

@MainActor
extension QAControlPlane {
    func screenCheckpoint(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["screenID"])
        let screen = try resolveScreen(arguments)
        guard let manager = screenManager, !manager.isTerminating else { throw QAError.message("ScreenManager unavailable") }
        guard screenCheckpoints.count < 16 else { throw QAError.message("Release an old checkpoint first (limit 16)") }
        let configuration = manager.getConfiguration(for: screen)
        // A one-screen Scheme deliberately drops span membership; pretending to restore a group would lose state.
        guard configuration?.videoDisplayMode != .spanAllDisplays, configuration?.sceneSpanGroupID == nil else {
            throw QAError.message("Single-screen checkpoints do not support span groups")
        }
        let id = UUID().uuidString
        screenCheckpoints[id] = QAScreenCheckpoint(screenID: screen.id, fingerprint: screen.displayFingerprint,
                                                   configuration: configuration, overlay: manager.monitorOverlay(for: screen),
                                                   playing: screen.playbackController?.userIntendsToPlay)
        return ["checkpointID": id, "screenID": screen.id, "configurationRevision": manager.configurationRevision(for: screen),
                "scope": "single-screen content, configuration, overlay and playback intent; memory-only"]
    }

    func screenRestoreCheckpoint(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["checkpointID", "expectedConfigurationRevision"])
        let (id, checkpoint) = try checkpoint(arguments)
        guard let manager = screenManager, !manager.isTerminating,
              let screen = manager.screens.first(where: { $0.id == checkpoint.screenID && $0.displayFingerprint == checkpoint.fingerprint }) else {
            throw QAError.message("Checkpoint display is unavailable or its identity changed")
        }
        guard let raw = arguments["expectedConfigurationRevision"] else { throw QAError.message("Missing expectedConfigurationRevision; read state.dump") }
        let revision = try QALibraryCatalog.integer(raw, key: "expectedConfigurationRevision", range: 0 ... Int.max)
        let current = manager.getConfiguration(for: screen)
        guard manager.configurationRevision(for: screen) == UInt64(revision) else { throw QAError.message("Display configuration changed; restore refused") }
        guard current?.videoDisplayMode != .spanAllDisplays, current?.sceneSpanGroupID == nil else {
            throw QAError.message("Leave the span group before restoring a single-screen checkpoint")
        }
        let router = ApplyRouter(manager: manager, bookmarks: .shared, sceneCapable: manager.featureCatalog.isEnabled(.scene))
        let operation = try applyOperations.start(screenID: screen.id, requestID: nil, target: "checkpoint:\(id)", revision: String(revision)) { [weak manager, weak screen] in
            guard let manager, let screen, !manager.isTerminating,
                  manager.screens.contains(where: { $0 === screen }), manager.configurationRevision(for: screen) == UInt64(revision) else {
                return ["confirmed": false, "code": "checkpoint.conflict"]
            }
            if let configuration = checkpoint.configuration {
                let scheme = ScreenScheme(name: "QA checkpoint", configuration: configuration, overlay: checkpoint.overlay)
                let report = await router.apply(.scheme(scheme), to: screen)
                guard report.outcome == .applied else { return ["confirmed": false, "code": "checkpoint.unconfirmed"] }
                if let playing = checkpoint.playing {
                    manager.setPlayback(playing: playing, for: screen)
                }
            } else {
                manager.clearWallpaperForScreen(screen)
                manager.setMonitorOverlay(checkpoint.overlay, for: screen)
            }
            return ["confirmed": true, "code": "checkpoint.restored", "configurationRevision": manager.configurationRevision(for: screen)]
        }
        return operation.json
    }

    func screenReleaseCheckpoint(_ arguments: [String: Any]) throws -> Any {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["checkpointID"])
        let (id, _) = try checkpoint(arguments)
        screenCheckpoints.removeValue(forKey: id)
        return ["status": "released", "checkpointID": id]
    }

    private func checkpoint(_ arguments: [String: Any]) throws -> (String, QAScreenCheckpoint) {
        guard let id = try QALibraryCatalog.optionalString(arguments["checkpointID"], key: "checkpointID"),
              let checkpoint = screenCheckpoints[id] else { throw QAError.message("Unknown or expired checkpointID") }
        return (id, checkpoint)
    }

    static var checkpointToolDescriptions: [[String: Any]] {
        let checkpointID: [String: Any] = ["type": "string", "maxLength": 1024]
        return [
            ["name": "screen.checkpoint", "description": "Save one non-span display's configuration, content, overlay and playback intent in app memory (limit 16). Does not change the display or save a Scheme. Tokens expire on app restart; global settings, files and system state are outside this scope.",
             "inputSchema": ["type": "object", "properties": ["screenID": ["type": "integer", "minimum": 0, "maximum": UInt32.max]], "required": ["screenID"], "additionalProperties": false]],
            ["name": "screen.restoreCheckpoint", "description": "Restore a captured non-span display through product Scheme/clear paths. Requires the current configurationRevision from state.dump, rejects conflicts and returns an operation. Wait for it and inspect runtime state. It does not rewind queue timers or restore global settings/files. Checkpoints remain until release.",
             "inputSchema": ["type": "object", "properties": ["checkpointID": checkpointID, "expectedConfigurationRevision": ["type": "integer", "minimum": 0]], "required": ["checkpointID", "expectedConfigurationRevision"], "additionalProperties": false]],
            ["name": "screen.releaseCheckpoint", "description": "Discard a retained checkpoint without changing product configuration.",
             "inputSchema": ["type": "object", "properties": ["checkpointID": checkpointID], "required": ["checkpointID"], "additionalProperties": false]],
        ]
    }
}
#endif
