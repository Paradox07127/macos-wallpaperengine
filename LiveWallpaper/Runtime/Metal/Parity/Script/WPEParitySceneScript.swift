#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import simd

/// One scene's SceneScript engine and the host inputs it reads each frame. Confined to the renderer's
/// actor, like the renderer that drives it.
final class WPEParitySceneScript {
    /// SceneScript storage lives for this scene only and writes no disk state; pass the same instance through a
    /// resize/replan.
    final class Storage {
        private var values = [[String: String](), [String: String]()]

        var provider: WPEParityScriptEngine.Storage {
            WPEParityScriptEngine.Storage(
                get: { [self] key, location in values[Self.index(location)][key] },
                set: { [self] key, text, location in values[Self.index(location)][key] = text },
                delete: { [self] key, location in values[Self.index(location)].removeValue(forKey: key) != nil },
                clear: { [self] location in values[Self.index(location)].removeAll(); return true }
            )
        }

        private static func index(_ location: WPEParityScriptEngine.Storage.Location) -> Int {
            switch location {
            case .global: 0
            case .screen: 1
            }
        }
    }

    /// What the product connects: merged user properties, the usershortcut launcher and the now-playing events.
    struct Host {
        /// project.json `general.properties` with the user's values, `{key: {type, value, …}}`.
        var userPropertiesJSON = "{}"
        var openUserShortcut: (String) -> Bool = { _ in false }
        /// The bindings scripts see as usershortcut `isbound`/`commandtype`/`file`; nil = every key unbound.
        var userShortcuts: WPEUserShortcutScriptBridge?
        var media: WPESceneMediaEventMailbox?
        var storage = Storage()
        var createLayer: ((String, inout WPEParitySceneState) -> WPEParityScriptEngine.CreatedLayer?)?
        var destroyLayer: ((String, inout WPEParitySceneState) -> Bool)?
        var canDestroyLayer: ((String, UInt32?) -> Bool)?
        var sortLayer: ((String, Int, inout WPEParitySceneState) -> Bool)?
        var pauseVideoTexture: ((String) -> Bool)?
        var executeMaterialFunction: ((WPEParitySceneState.EffectKey, String) -> Void)?
        var modelData: WPEParityScriptModelDataProvider?
        /// nil = JS Date reads the wall clock; see `WPEParityScriptEngine.Configuration.dateEpochMillis`.
        var dateEpochMillis: Double?
        /// Explicit deterministic replay; normal product hosts leave JavaScriptCore randomness unchanged.
        var randomSeed: UInt32?
    }

    /// A layer the cursor pass may test, in scene order.
    struct CursorCandidate {
        let id: String
        let solid: Bool
        let disablePropagation: Bool
    }

    let engine: WPEParityScriptEngine
    /// Some binding exports a cursor handler, which turns the cursor pass on (140175880.c:377-379).
    let handlesCursor: Bool
    /// Some binding exports a media handler, which subscribes the engine to media events (140175880.c:373-375).
    let handlesMedia: Bool
    /// Loaded candidate defaults by stable identity; each cursor pass projects State's current common order.
    private var cursorCandidates: [String: CursorCandidate]
    /// Objects with a binding that exports a left-button handler.
    private let buttonIDs: Set<String>
    /// Objects of the camera class, whose fov and zoom the next frame's camera reads.
    let cameraIDs: [String]
    let soundIDs: [String]
    private let userShortcuts: WPEUserShortcutScriptBridge?
    private let hasMediaSource: Bool
    private var userProperties: [String: Any]
    private var mediaProperties: [String: String] = [:]
    private var tracker = WPEParityCursorTracker()
    private var targets: [WPEParityCursorTarget] = []
    private var lastCursor: SIMD2<Float>?

    /// Returns whether a warning line was written for this script log.
    @discardableResult
    static func forwardScriptLog(level: Int, message: String) -> Bool {
        guard level >= 1 else { return false }
        return Logger.repeatedWarning("SceneScript: \(message)", source: .sceneScript, category: .wpeRender)
    }

    /// Some object or the general block carries a property script.
    static func hasScripts(_ document: WPESceneDocument) -> Bool {
        !document.paritySeeds.scripts.isEmpty
    }

    init(document: WPESceneDocument, state: WPEParitySceneState, assets: WPEParityProgramAssets,
         canvasSize: SIMD2<Float>, screenResolution: SIMD2<Float>,
         materialConstants: [WPEParityScriptEngine.ConstantKey: WPEParityScriptEngine.MaterialConstant] = [:],
         resolvedEffectRecords: [WPEParitySceneState.EffectKey: [WPEParityEffectPassRecord]] = [:],
         fieldDefaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [:], host: Host) throws {
        let defaults = Self.generalFields(document.paritySeeds).merging(fieldDefaults) { _, value in value }
        var properties = (try? JSONSerialization.jsonObject(with: Data(host.userPropertiesJSON.utf8))) as? [String: Any] ?? [:]
        // Taken before the snapshot: a rebind in between stays marked for the first tick instead of being lost.
        _ = host.userShortcuts?.takeChangedKeys()
        Self.overlayUserShortcuts(&properties, bridge: host.userShortcuts)
        engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: canvasSize, screenResolution: screenResolution,
            userPropertiesJSON: Self.json(properties), materialConstants: materialConstants,
            resolvedEffectRecords: resolvedEffectRecords,
            fieldDefaults: defaults, storage: host.storage.provider, modelData: host.modelData,
            createLayer: host.createLayer, destroyLayer: host.destroyLayer, canDestroyLayer: host.canDestroyLayer,
            sortLayer: host.sortLayer,
            pauseVideoTexture: host.pauseVideoTexture,
            executeMaterialFunction: host.executeMaterialFunction,
            log: { level, message in Self.forwardScriptLog(level: level, message: message) },
            openUserShortcut: host.openUserShortcut, dateEpochMillis: host.dateEpochMillis, randomSeed: host.randomSeed
        ))
        let bits = engine.bindings.reduce(0) { $0 | $1.exportBits }
        handlesCursor = bits & WPEParityScriptEvent.cursorBits != 0
        handlesMedia = bits & WPEParityScriptEvent.mediaBits != 0
        let buttonBits = [WPEParityScriptEvent.cursorClick, .cursorDown, .cursorUp].reduce(0) { $0 | $1.exportBit }
        buttonIDs = Set(engine.bindings.lazy.filter { $0.exportBits & buttonBits != 0 && !$0.objectID.isEmpty }
            .map(\.objectID))
        userShortcuts = host.userShortcuts
        hasMediaSource = host.media != nil
        userProperties = properties
        var candidates: [CursorCandidate] = []
        var cameras: [String] = []
        for object in document.paritySeeds.objects {
            guard let id = object.id else { continue }
            if object.isCamera {
                cameras.append(id)
            }
            candidates.append(CursorCandidate(id: id, solid: object.solid, disablePropagation: object.disablePropagation))
        }
        cursorCandidates = Dictionary(candidates.map { ($0.id, $0) }) { first, _ in first }
        cameraIDs = cameras
        soundIDs = document.soundObjects.map(\.id)
        targets.reserveCapacity(candidates.count)
    }

    /// Event 0 once every object loaded, then enable media handlers (140172830.c:82-288).
    /// The renderer delivers current media state with its atomic texture/event input.
    func start(state: inout WPEParitySceneState) throws {
        try engine.start(state: &state)
        guard handlesMedia, hasMediaSource else { return }
        engine.dispatch(.mediaStatusChanged, payloadJSON: #"{"enabled":true}"#, state: &state)
    }

    /// The layers the cursor pass tests this frame. `quad` gives a layer's corners in client pixels, nil for an object
    /// the frame does not draw as a quad.
    func updateCursorTargets(state: WPEParitySceneState,
                             quad: (String) throws -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?) rethrows {
        guard handlesCursor else { return }
        targets.removeAll(keepingCapacity: true)
        func flag(_ name: String, _ candidate: CursorCandidate, fallback: Bool) -> Bool {
            guard case let .vector(value)? = state.scriptField(name, of: candidate.id) else { return fallback }
            return value.x != 0
        }
        // 140189e10.c:115-122: topmost first, after the common sort/removal consumed by the draw projection.
        for id in state.commonOrder.reversed() {
            guard let candidate = cursorCandidates[id], state.isAlive(candidate.id) else { continue }
            // 140189e10.c:115-123 reads the live bit13 before each hit test.
            guard flag("solid", candidate, fallback: candidate.solid), let corners = try quad(candidate.id) else { continue }
            targets.append(WPEParityCursorTarget(
                id: candidate.id, quad: corners, visible: state.isVisible(candidate.id),
                disablePropagation: flag("disablepropagation", candidate, fallback: candidate.disablePropagation)
            ))
        }
    }

    /// Client-pixel corners of this frame's visible, not fully transparent targets that take the left button.
    func buttonQuads(state: WPEParitySceneState) -> [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] {
        targets.filter { target in
            buttonIDs.contains(target.id) && target.visible && (state.value(.alpha, of: target.id)?.x ?? 1) > 0.001
        }.map(\.quad)
    }

    /// The cursor pass over the targets of `updateCursorTargets` (14017fa70.c:473-474).
    func cursor(at cursor: SIMD2<Float>, world: SIMD3<Float>, leftDown: Bool, timeOfDay: Float,
                state: inout WPEParitySceneState) {
        guard handlesCursor else { return }
        let moved = lastCursor.map { $0 != cursor } ?? true
        lastCursor = cursor
        let dispatches = tracker.update(targets: targets, cursor: cursor, leftDown: leftDown, moved: moved)
        engine.cursor(dispatches, input: input(cursor: cursor, world: world, leftDown: leftDown, timeOfDay: timeOfDay),
                      state: &state)
    }

    /// Native thumbnail inputs reapply their system properties before dispatching the matching media events.
    func applyMedia(properties: [String: String], events: [WPESceneMediaEvent], state: inout WPEParitySceneState) {
        if !properties.isEmpty {
            mediaProperties.merge(properties) { $1 }
            var changed: [String: Any] = [:]
            for (name, value) in properties {
                var property = userProperties[name] as? [String: Any] ?? [:]
                property["value"] = value
                userProperties[name] = property
                // Native 171440 authors a fresh value-only change, even when merged metadata has a type.
                changed[name] = ["value": value]
            }
            Self.overlayUserShortcuts(&userProperties, bridge: userShortcuts)
            engine.applyUserProperties(changedJSON: Self.json(changed), mergedJSON: Self.json(userProperties), state: &state)
        }
        guard handlesMedia else { return }
        for event in events {
            let (id, payload) = Self.payload(event)
            engine.dispatch(id, payloadJSON: payload, state: &state)
        }
    }

    /// Product property changes keep the system properties installed by the last accepted media input.
    func applyUserProperties(changedJSON: String, mergedJSON: String, state: inout WPEParitySceneState) {
        userProperties = (try? JSONSerialization.jsonObject(with: Data(mergedJSON.utf8))) as? [String: Any] ?? [:]
        for (name, value) in mediaProperties {
            var property = userProperties[name] as? [String: Any] ?? [:]
            property["value"] = value
            userProperties[name] = property
        }
        Self.overlayUserShortcuts(&userProperties, bridge: userShortcuts)
        engine.applyUserProperties(changedJSON: changedJSON, mergedJSON: Self.json(userProperties), state: &state)
    }

    /// 1401731d0.c:539-698: a usershortcut entry carries `isbound`, and when bound its `commandtype` and `file`.
    private static func overlayUserShortcuts(_ properties: inout [String: Any], bridge: WPEUserShortcutScriptBridge?) {
        let bound = bridge?.snapshot().bound ?? [:]
        for (key, value) in properties {
            guard var entry = value as? [String: Any], entry["type"] as? String == "usershortcut" else { continue }
            entry["isbound"] = bound[key] != nil
            entry["commandtype"] = bound[key].map { ["web": "website", "cmd": "command"][$0.commandType] ?? $0.commandType }
            entry["file"] = bound[key]?.target
            properties[key] = entry
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    func tick(dt: Float, cursor: SIMD2<Float>, world: SIMD3<Float>, leftDown: Bool, timeOfDay: Float,
              state: inout WPEParitySceneState) {
        if let userShortcuts, case let keys = userShortcuts.takeChangedKeys(), !keys.isEmpty {
            Self.overlayUserShortcuts(&userProperties, bridge: userShortcuts)
            engine.applyUserProperties(changedJSON: Self.json(userProperties.filter { keys.contains($0.key) }),
                                       mergedJSON: Self.json(userProperties), state: &state)
        }
        engine.tick(dt: dt, input: input(cursor: cursor, world: world, leftDown: leftDown, timeOfDay: timeOfDay),
                    state: &state)
    }

    func prepareFrame(frame: UInt64, dt: Float, runtime: Float, cursor: SIMD2<Float>, world: SIMD3<Float>,
                      leftDown: Bool, timeOfDay: Float) {
        engine.prepareFrame(frame: frame, dt: dt, runtime: runtime,
                            input: input(cursor: cursor, world: world, leftDown: leftDown, timeOfDay: timeOfDay))
    }

    func resize(canvasSize: SIMD2<Float>, screenResolution: SIMD2<Float>, state: inout WPEParitySceneState) {
        engine.resize(canvasSize: canvasSize, screenResolution: screenResolution, state: &state)
    }

    /// The document's native seeds, not the parser's defaults, which differ from WPE's.
    private static func generalFields(_ seeds: WPESceneParitySeeds)
        -> [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] {
        let values: [(String, SIMD4<Float>)] = [
            ("bloomstrength", seeds.bloomStrength), ("bloomthreshold", seeds.bloomThreshold),
            ("ambientcolor", seeds.ambientColor), ("skylightcolor", seeds.skylightColor),
            ("bloom", SIMD4(seeds.bloom ? 1 : 0, 0, 0, 0)),
        ]
        return Dictionary(uniqueKeysWithValues: values.map { name, value in
            (WPEParitySceneState.ScriptFieldKey(objectID: "", name: name), WPEParitySceneState.ScriptValue.vector(value))
        })
    }

    /// Refreshes the registerAudioBuffers bins from the frame's 128 spectrum bins (left 64, then right 64).
    func updateAudio(_ bins: [Float]) {
        engine.updateAudio(bins)
    }

    private func input(cursor: SIMD2<Float>, world: SIMD3<Float>, leftDown: Bool,
                       timeOfDay: Float) -> WPEParityScriptEngine.Input {
        WPEParityScriptEngine.Input(cursorScreen: cursor, cursorWorld: world, leftDown: leftDown, timeOfDay: timeOfDay)
    }

    /// WPE's media event ids with the payload fields `lib.sceneScript.d.ts` declares.
    static func payload(_ event: WPESceneMediaEvent) -> (WPEParityScriptEvent, String) {
        switch event {
        case let .playbackChanged(state):
            return (.mediaPlaybackChanged, #"{"state":\#(state.rawValue)}"#)
        case let .propertiesChanged(properties):
            guard let properties else { return (.mediaPropertiesChanged, "{}") }
            let fields = ["title": properties.title, "artist": properties.artist, "subTitle": properties.subTitle,
                          "albumTitle": properties.albumTitle, "albumArtist": properties.albumArtist,
                          "genres": properties.genres, "contentType": properties.contentType]
            return (.mediaPropertiesChanged, json(fields))
        case let .thumbnailChanged(thumbnail):
            func color(_ value: SIMD3<Double>) -> [Double] {
                [value.x, value.y, value.z]
            }
            return (.mediaThumbnailChanged, json([
                "hasThumbnail": thumbnail.hasThumbnail, "primaryColor": color(thumbnail.primaryColor),
                "secondaryColor": color(thumbnail.secondaryColor), "tertiaryColor": color(thumbnail.tertiaryColor),
                "textColor": color(thumbnail.textColor), "highContrastColor": color(thumbnail.highContrastColor),
            ]))
        case let .timelineChanged(timeline):
            return (.mediaTimelineChanged, json(["position": timeline.position, "duration": timeline.duration]))
        }
    }

    /// project.json's `general.properties` with each entry's `value` replaced by the user's, as engine.userProperties
    /// takes it; "{}" without a readable project.json.
    static func userPropertiesJSON(projectRoot: URL, values: [String: WallpaperEngineProjectPropertyValue]) -> String {
        guard let data = try? Data(contentsOf: projectRoot.appending(path: "project.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = (root["general"] as? [String: Any])?["properties"] as? [String: Any] else { return "{}" }
        return mergedUserProperties(properties, values: values)
    }

    /// `base` (a userPropertiesJSON) with `values` written over the entries' `value`.
    static func userPropertiesJSON(_ base: String, values: [String: WallpaperEngineProjectPropertyValue]) -> String {
        let properties = (try? JSONSerialization.jsonObject(with: Data(base.utf8))) as? [String: Any] ?? [:]
        return mergedUserProperties(properties, values: values)
    }

    /// Only the entries of `values`, for applyUserProperties' changed set.
    static func changedUserPropertiesJSON(_ merged: String, keys: Set<String>) -> String {
        let properties = (try? JSONSerialization.jsonObject(with: Data(merged.utf8))) as? [String: Any] ?? [:]
        return json(properties.filter { keys.contains($0.key) })
    }

    private static func mergedUserProperties(_ properties: [String: Any],
                                             values: [String: WallpaperEngineProjectPropertyValue]) -> String {
        var merged = properties
        for (key, value) in values {
            var entry = merged[key] as? [String: Any] ?? [:]
            entry["value"] = switch value {
            case let .bool(flag): flag
            case let .number(number): number
            case let .string(text): text
            }
            merged[key] = entry
        }
        return json(merged)
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}
#endif
