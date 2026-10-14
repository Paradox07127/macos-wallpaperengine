#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import simd

/// One scene's SceneScript engine and the host inputs it reads each frame (R25 §1, §4). Confined to the renderer's
/// actor, like the renderer that drives it.
final class WPEParitySceneScript {
    /// Product policy keeps SceneScript storage within this scene lifetime (10-01 user decision).
    /// Pass the same instance through a resize/replan; it deliberately writes no disk state.
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
        var media: WPESceneMediaEventMailbox?
        /// The existing product load generation; parity inputs are consumed atomically by the renderer.
        var mediaGeneration: Int?
        var storage = Storage()
        var createLayer: ((String, inout WPEParitySceneState) -> WPEParityScriptEngine.CreatedLayer?)?
        var destroyLayer: ((String, inout WPEParitySceneState) -> Bool)?
        var canDestroyLayer: ((String, UInt32?) -> Bool)?
        var sortLayer: ((String, Int, inout WPEParitySceneState) -> Bool)?
        var pauseVideoTexture: ((String) -> Bool)?
        var executeMaterialFunction: ((WPEParitySceneState.EffectKey, String) -> Void)?
        var modelData: WPEParityScriptModelDataProvider?
    }

    /// A layer the cursor pass may test, in scene order.
    struct CursorCandidate {
        let id: String
        let solid: Bool
        let disablePropagation: Bool
    }

    let engine: WPEParityScriptEngine
    let storage: Storage
    /// Some binding exports a cursor handler, which turns the cursor pass on (140175880.c:377-379).
    let handlesCursor: Bool
    /// Some binding exports a media handler, which subscribes the engine to media events (140175880.c:373-375).
    let handlesMedia: Bool
    /// Loaded candidate defaults by stable identity; each cursor pass projects State's current common order.
    private var cursorCandidates: [String: CursorCandidate]
    /// Objects of the camera class, whose fov and zoom the next frame's camera reads.
    let cameraIDs: [String]
    let soundIDs: [String]
    private let media: WPESceneMediaEventMailbox?
    private let hasMediaSource: Bool
    private var userProperties: [String: Any]
    private var mediaProperties: [String: String] = [:]
    private var tracker = WPEParityCursorTracker()
    private var targets: [WPEParityCursorTarget] = []
    private var lastCursor: SIMD2<Float>?
    private var destroyedSeen = 0

    /// Some object or the general block carries a property script.
    static func hasScripts(_ document: WPESceneDocument) -> Bool {
        ([document.resolvedGeneralJSON] + document.resolvedObjectsJSON).contains(where: hasScript)
    }

    private static func hasScript(_ value: WPESceneJSONValue) -> Bool {
        switch value {
        case let .object(members): members["script"] != nil || members.values.contains(where: hasScript)
        case let .array(elements): elements.contains(where: hasScript)
        default: false
        }
    }

    init(document: WPESceneDocument, state: WPEParitySceneState, assets: WPEParityProgramAssets,
         canvasSize: SIMD2<Float>, screenResolution: SIMD2<Float>,
         materialConstants: [WPEParityScriptEngine.ConstantKey: WPEParityScriptEngine.MaterialConstant] = [:],
         resolvedEffectRecords: [WPEParitySceneState.EffectKey: [WPEParityEffectPassRecord]] = [:],
         fieldDefaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [:], host: Host) throws {
        storage = host.storage
        let defaults = Self.generalFields(document.resolvedGeneralJSON).merging(fieldDefaults) { _, value in value }
        engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: canvasSize, screenResolution: screenResolution,
            userPropertiesJSON: host.userPropertiesJSON, materialConstants: materialConstants,
            resolvedEffectRecords: resolvedEffectRecords,
            fieldDefaults: defaults, storage: host.storage.provider, modelData: host.modelData,
            createLayer: host.createLayer, destroyLayer: host.destroyLayer, canDestroyLayer: host.canDestroyLayer,
            sortLayer: host.sortLayer,
            pauseVideoTexture: host.pauseVideoTexture,
            executeMaterialFunction: host.executeMaterialFunction,
            log: { level, message in
                if level >= 1 {
                    Logger.warning("SceneScript: \(message)", category: .wpeRender)
                }
            },
            openUserShortcut: host.openUserShortcut
        ))
        let bits = engine.bindings.reduce(0) { $0 | $1.exportBits }
        handlesCursor = bits & WPEParityScriptEvent.cursorBits != 0
        handlesMedia = bits & WPEParityScriptEvent.mediaBits != 0
        media = host.mediaGeneration == nil ? host.media : nil
        hasMediaSource = host.media != nil
        userProperties = (try? JSONSerialization.jsonObject(with: Data(host.userPropertiesJSON.utf8))) as? [String: Any] ?? [:]
        var candidates: [CursorCandidate] = []
        var cameras: [String] = []
        for object in document.resolvedObjectsJSON {
            guard let id = Self.id(object) else { continue }
            if case .string? = object["camera"] {
                cameras.append(id)
            }
            // The editor writes `solid` on every layer; an object without it counts as solid.
            candidates.append(CursorCandidate(id: id, solid: Self.flag(object["solid"]) ?? true,
                                              disablePropagation: Self.flag(object["disablepropagation"]) ?? false))
        }
        cursorCandidates = Dictionary(candidates.map { ($0.id, $0) }) { first, _ in first }
        cameraIDs = cameras
        soundIDs = document.soundObjects.map(\.id)
        targets.reserveCapacity(candidates.count)
    }

    /// Event 0 once every object loaded, then the current media state to the media handlers (140172830.c:82-288).
    func start(state: inout WPEParitySceneState) throws {
        if let failure = engine.start(state: &state) {
            throw failure
        }
        guard handlesMedia, hasMediaSource else { return }
        engine.dispatch(.mediaStatusChanged, payloadJSON: #"{"enabled":true}"#, state: &state)
        dispatchMedia(state: &state)
    }

    /// The layers the cursor pass tests this frame. `quad` gives a layer's corners in client pixels, nil for an object
    /// the frame does not draw as a quad.
    func updateCursorTargets(state: WPEParitySceneState,
                             quad: (String) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?) {
        guard handlesCursor else { return }
        targets.removeAll(keepingCapacity: true)
        func flag(_ name: String, _ candidate: CursorCandidate, fallback: Bool) -> Bool {
            guard case let .vector(value)? = state.scriptField(name, of: candidate.id) else { return fallback }
            return value.x != 0
        }
        // 140189e10.c:115-122: topmost first, after the common sort/removal consumed by the draw projection.
        for id in state.commonOrder.reversed() {
            guard let candidate = cursorCandidates[id] else { continue }
            guard state.isAlive(candidate.id) else { continue }
            // 140189e10.c:115-123 reads the live bit13 before each hit test.
            guard flag("solid", candidate, fallback: candidate.solid) else { continue }
            guard let corners = quad(candidate.id) else { continue }
            targets.append(WPEParityCursorTarget(
                id: candidate.id, quad: corners, visible: state.isVisible(candidate.id),
                disablePropagation: flag("disablepropagation", candidate, fallback: candidate.disablePropagation)
            ))
        }
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

    /// Queued now-playing events, first in the manager tick (140171440.c:148-535).
    func dispatchMedia(state: inout WPEParitySceneState) {
        guard handlesMedia, let media else { return }
        for event in media.drain() {
            let (id, payload) = Self.payload(event)
            engine.dispatch(id, payloadJSON: payload, state: &state)
        }
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
        engine.applyUserProperties(changedJSON: changedJSON, mergedJSON: Self.json(userProperties), state: &state)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    func tick(dt: Float, cursor: SIMD2<Float>, world: SIMD3<Float>, leftDown: Bool, timeOfDay: Float,
              state: inout WPEParitySceneState) {
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

    /// Read native seeds from the authored/resolved JSON. Parser defaults currently differ from Windows H05.
    private static func generalFields(_ general: WPESceneJSONValue)
        -> [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] {
        func components(_ value: WPESceneJSONValue?) -> [Float]? {
            switch value {
            case let .object(entries)?: return components(entries["value"])
            case let .number(number)?: return [Float(number)]
            case let .string(text)?:
                let tokens = text.split { $0.isWhitespace || $0 == "," }
                let parsed = tokens.compactMap { Float($0) }
                return parsed.count == tokens.count ? parsed : nil
            case let .array(values)?:
                var result: [Float] = []
                for value in values {
                    guard case let .number(number) = value else { return nil }
                    result.append(Float(number))
                }
                return result
            default: return nil
            }
        }
        let native: [(String, SIMD4<Float>)] = [
            ("bloomstrength", SIMD4(2, 0, 0, 0)), ("bloomthreshold", SIMD4(0.65, 0, 0, 0)),
            ("ambientcolor", .zero), ("skylightcolor", .zero),
        ]
        return Dictionary(uniqueKeysWithValues: native.map { name, fallback in
            var value = fallback
            if let parsed = components(general[name]), !parsed.isEmpty {
                value = .zero
                for (lane, number) in parsed.prefix(4).enumerated() {
                    value[lane] = number
                }
            }
            return (WPEParitySceneState.ScriptFieldKey(objectID: "", name: name),
                    WPEParitySceneState.ScriptValue.vector(value))
        })
    }

    /// Refreshes the registerAudioBuffers bins from the frame's spectrum: 64 as published, 32 and 16 max-pooled
    /// like the g_AudioSpectrum uniforms; `average` is the mean of both channels.
    func updateAudio(_ bins: [Float]) {
        guard bins.count == 128, let full = engine.audioBuffer(resolution: 64),
              let half = engine.audioBuffer(resolution: 32), let quarter = engine.audioBuffer(resolution: 16) else { return }
        for index in 0 ..< 64 {
            (full[index], full[64 + index]) = (bins[index], bins[64 + index])
            full[128 + index] = (bins[index] + bins[64 + index]) * 0.5
        }
        func pool(_ source: UnsafeMutableBufferPointer<Float>, into target: UnsafeMutableBufferPointer<Float>,
                  count: Int) {
            for channel in 0 ..< 2 {
                for index in 0 ..< count {
                    let base = channel * count * 2 + index * 2
                    target[channel * count + index] = max(source[base], source[base + 1])
                }
            }
            for index in 0 ..< count {
                target[2 * count + index] = (target[index] + target[count + index]) * 0.5
            }
        }
        pool(full, into: half, count: 32)
        pool(half, into: quarter, count: 16)
    }

    /// Objects destroyLayer removed since the last call (14017fa70.c:477).
    func takeDestroyed() -> ArraySlice<String> {
        let ids = engine.destroyedObjectIDs
        defer { destroyedSeen = ids.count }
        return ids[destroyedSeen...]
    }

    private func input(cursor: SIMD2<Float>, world: SIMD3<Float>, leftDown: Bool,
                       timeOfDay: Float) -> WPEParityScriptEngine.Input {
        WPEParityScriptEngine.Input(cursorScreen: cursor, cursorWorld: world, leftDown: leftDown, timeOfDay: timeOfDay)
    }

    /// The engine's object id: `id` as a string or number, else `name`.
    private static func id(_ object: WPESceneJSONValue) -> String? {
        switch object["id"] {
        case let .string(id)? where !id.isEmpty: id
        case let .number(number)?: String(Int(number))
        default: if case let .string(name)? = object["name"] {
                name
            } else {
                nil
            }
        }
    }

    private static func flag(_ value: WPESceneJSONValue?) -> Bool? {
        switch value {
        case let .bool(flag)?: flag
        case let .number(number)?: number != 0
        case let .object(entries)?: flag(entries["value"])
        default: nil
        }
    }

    /// WPE's media event ids (R25 §4) with the payload fields `lib.sceneScript.d.ts` declares.
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
