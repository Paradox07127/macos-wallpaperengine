import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Dependency seam for resolving static transform scripts without coupling the parser to JavaScriptCore.
public protocol WPESceneTransformScriptResolving {
    func resolveVec3(
        script: String,
        properties: [String: WPESceneScriptPropertyValue],
        seed: SIMD3<Double>
    ) -> SIMD3<Double>?

    func resolveBatch(
        _ requests: [WPESceneTransformScriptRequest]
    ) -> [SIMD3<Double>?]
}

public struct WPESceneTransformScriptRequest: Equatable, Sendable {
    public let script: String
    public let properties: [String: WPESceneScriptPropertyValue]
    public let seed: SIMD3<Double>

    public init(
        script: String,
        properties: [String: WPESceneScriptPropertyValue],
        seed: SIMD3<Double>
    ) {
        self.script = script
        self.properties = properties
        self.seed = seed
    }
}

public extension WPESceneTransformScriptResolving {
    func resolveBatch(
        _ requests: [WPESceneTransformScriptRequest]
    ) -> [SIMD3<Double>?] {
        requests.map {
            resolveVec3(script: $0.script, properties: $0.properties, seed: $0.seed)
        }
    }
}

/// Textual classification of WPE transform scripts, shared by the parser
/// (bake static origins at parse time) and the runtime evaluator (execution guard).
public enum WPETransformScriptStaticAnalysis {
    /// Markers for anything a parse-time evaluation cannot know. Matching is
    /// case-sensitive because `Date` would otherwise match `update`.
    public static let dynamicTokens = [
        "getTimeOfDay", "engine.runtime", "frametime", "frameTime", "getTime", "Date",
        // `registerAudioBuffers` is listed separately from "audio": matching is
        // case-sensitive, so the capital A in the method name never hits it, and
        // a script whose only audio use is the buffer object would otherwise be
        // baked once at parse time.
        "Math.random", "getFrequency", "getFrequencies", "audio", "registerAudioBuffers", "elapsed",
        "input.cursorWorldPosition", "shared.", "shared[",
        // Layer/scene handles are runtime graph state, even when the script has
        // no clock, pointer, audio, or shared-state dependency. In particular,
        // `init(value) { parent = thisLayer.getParent(); }` captures a live
        // parent whose origin/scale may be driven by another transform script.
        // Baking that script before a layer graph exists both skips init() and
        // turns a dynamic relationship into a stale authored value.
        "thisLayer", "thisObject", "thisScene",
        // `engine.timeOfDay` is the property form of the day fraction and is
        // refreshed every frame. `getTimeOfDay` above does not match it (the
        // comparison is a case-sensitive substring), so a layout script driving a
        // day/night shift off it was baked once at load and frozen there.
        "timeOfDay"
    ]

    /// Loop and evaluation forms are rejected to keep parse-time JavaScriptCore work bounded.
    public static let staticExecutionBlocklistPatterns = [
        #"\bwhile\s*\("#,
        #"\bfor\s*\("#,
        #"\bdo\s*\{"#,
        #"\beval\s*\("#,
        #"\bFunction\s*\("#
    ]

    public static func isStaticallyResolvable(_ script: String) -> Bool {
        guard !dynamicTokens.contains(where: { script.contains($0) }) else { return false }
        return !staticExecutionBlocklistPatterns.contains {
            script.range(of: $0, options: .regularExpression) != nil
        }
    }
}

/// Parses Wallpaper Engine `scene.json`, accepting object, array, and space-separated vector encodings.
/// Unsupported features are preserved as diagnostics for capability classification.
public enum WPESceneDocumentParser {

    public static func parse(
        data: Data,
        userValues: [String: WallpaperEngineProjectPropertyValue],
        makeTransformScriptResolver: (_ canvasWidth: Double, _ canvasHeight: Double) -> any WPESceneTransformScriptResolving
    ) throws -> WPESceneDocument {
        guard !data.isEmpty else {
            throw WPESceneDocumentError.invalidUTF8
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            throw WPESceneDocumentError.invalidUTF8
        }
        // Record property→target bindings BEFORE resolving envelopes, since
        // resolution replaces `{"user":K}` with the literal value and loses the key.
        let propertyBindings = extractUserPropertyBindings(in: json)
        let resolvedJSON = try resolveUserPropertyEnvelopes(in: json, userValues: userValues)
        guard let root = resolvedJSON as? [String: Any] else {
            throw WPESceneDocumentError.rootNotObject
        }

        var diagnostics: [WPESceneDiagnostic] = []

        guard let cameraDict = root["camera"] as? [String: Any] else {
            throw WPESceneDocumentError.missingCamera
        }
        guard let generalDict = root["general"] as? [String: Any] else {
            throw WPESceneDocumentError.missingGeneral
        }

        let rawGeneralDict = ((json as? [String: Any])?["general"] as? [String: Any]) ?? generalDict
        let authoredCamera = parseCamera(cameraDict, general: generalDict, diagnostics: &diagnostics)
        let general = parseGeneral(generalDict, authored: rawGeneralDict, diagnostics: &diagnostics)

        let rawObjects: [[String: Any]] = (root["objects"] as? [[String: Any]]) ?? []
        let authoredObjects: [[String: Any]] = ((json as? [String: Any])?["objects"] as? [[String: Any]])
            ?? rawObjects
        // WPE's runtime camera is a scene OBJECT carrying a `camera` key ("default");
        // the top-level `camera` block is only the editor viewport bookmark. Ground
        // truth (RenderDoc capture of 3509243656): g_EyePosition == the camera
        // object's origin (0,0,6) with identity orientation, while the top-level
        // eye (−2.06, 0.85, 10.07) sits outside the skybox shell and is never used.
        let camera = runtimeCameraObjectOverride(
            rawObjects,
            base: authoredCamera,
            diagnostics: &diagnostics
        )
        // Script-driven `origin` resolves to the CURRENT user-property values
        // (the baked `value` is stale once the user tweaks the bound sliders).
        // Computed before transform combination so each object's parent offset
        // still applies to the fresh local origin.
        let scriptResolvedOrigins = resolveScriptOrigins(
            rawObjects,
            canvasWidth: general.orthogonalProjection.width,
            canvasHeight: general.orthogonalProjection.height,
            makeResolver: makeTransformScriptResolver
        )
        // One canonical id→object index feeds every downstream pass (transforms,
        // visibility, hierarchy, attachments). Later duplicates win — matching the
        // paint-order map below — so a malformed duplicate-id document resolves
        // every field from a single source object instead of mixing first/last.
        let objectsByID = indexObjectsByID(rawObjects)
        let objectTransforms = resolvedObjectTransforms(
            objectsByID,
            scriptOrigins: scriptResolvedOrigins
        )
        // Effective visibility folds each object's own `visible` with its ancestor
        // groups', so a child of a condition-hidden group is hidden too.
        let objectVisibility = resolvedObjectVisibility(objectsByID)
        let (objectParentByID, ownVisibilityByID) = objectHierarchy(from: objectsByID)
        let inheritedAttachments = inheritedGroupAttachments(from: objectsByID)
        var imageObjects: [WPESceneImageObject] = []
        var scriptHostObjects: [WPESceneScriptHostObject] = []
        var transformHostObjects: [WPESceneTransformHostObject] = []
        var particleObjects: [WPESceneParticleObject] = []
        var textObjects: [WPESceneTextObject] = []
        var soundObjects: [WPESceneSoundObject] = []
        var lightObjects: [WPESceneLightObject] = []
        var objectPaintOrder: [String: Int] = [:]

        for (index, entry) in rawObjects.enumerated() {
            let authoredEntry = authoredObjects.indices.contains(index) ? authoredObjects[index] : entry
            let objectName = entry["name"] as? String ?? "?"
            let resolution = objectKindResolution(for: entry)
            let entryID = objectID(in: entry)
            if let entryID {
                objectPaintOrder[entryID] = index
            }
            let transform = entryID.flatMap { objectTransforms[$0] }
                ?? localTransform(in: entry, scriptOrigins: scriptResolvedOrigins)
            let effectiveVisible = entryID.flatMap { objectVisibility[$0] }
            if resolution.isAmbiguous {
                let declared = resolution.candidates.map(\.rawValue).joined(separator: ", ")
                diagnostics.append(.init(severity: .warning, message: "Ambiguous object \(objectName) declares \(declared)"))
            }

            if resolution.primary == .image,
               let object = parseImageObject(
                   entry,
                   transform: transform,
                   scriptOrigins: scriptResolvedOrigins,
                   effectiveVisible: effectiveVisible,
                   inheritedAttachment: entryID.flatMap { inheritedAttachments[$0] },
                   diagnostics: &diagnostics
            ) {
                imageObjects.append(object)
            } else if entry["image"] == nil,
                      entry["model"] == nil,
                      let object = parseScriptHostObject(entry, diagnostics: &diagnostics) {
                scriptHostObjects.append(object)
            }
            if resolution.primary != .image,
               resolution.primary != .particle,
               resolution.primary != .text,
               resolution.primary != .sound,
               let object = parseTransformHostObject(
                entry,
                transform: transform,
                scriptOrigins: scriptResolvedOrigins
               ) {
                transformHostObjects.append(object)
            }
            if resolution.primary == .particle,
               let object = parseParticleObject(
                   entry,
                   transform: transform,
                   effectiveVisible: effectiveVisible,
                   diagnostics: &diagnostics
               ) {
                particleObjects.append(object)
            }
            if resolution.primary == .text,
               let object = parseTextObject(
                   entry,
                   transform: transform,
                   localOrigin: localTransform(in: entry, scriptOrigins: scriptResolvedOrigins).origin,
                   localScale: localTransform(in: entry, scriptOrigins: scriptResolvedOrigins).scale,
                   parentObjectID: entryID.flatMap { objectParentByID[$0] },
                   effectiveVisible: effectiveVisible,
                   diagnostics: &diagnostics
               ) {
                textObjects.append(object)
            }
            if resolution.primary == .sound,
               let object = parseSoundObject(
                   entry,
                   authored: authoredEntry,
                   effectiveVisible: effectiveVisible,
                   diagnostics: &diagnostics
               ) {
                soundObjects.append(object)
            }
            if resolution.primary == .light,
               let object = parseLightObject(
                   entry,
                   authored: authoredEntry,
                   transform: transform,
                   effectiveVisible: effectiveVisible,
                   diagnostics: &diagnostics
               ) {
                lightObjects.append(object)
            }

            var unsupportedKinds = resolution.candidates.filter {
                $0 != .image && $0 != .unknown && $0 != .particle && $0 != .text
                    && $0 != .sound && $0 != .light
            }
            if resolution.primary != .image
                && resolution.primary != .particle
                && resolution.primary != .text
                && resolution.primary != .sound
                && resolution.primary != .light
                && resolution.primary != .unknown
                && !unsupportedKinds.contains(resolution.primary) {
                unsupportedKinds.append(resolution.primary)
            }
            for kind in unsupportedKinds {
                diagnostics.append(.init(severity: .info, message: "\(kind.displayName) object \(objectName) is unsupported by the current renderer"))
            }
            if resolution.primary == .particle {
                diagnostics.append(.init(severity: .info, message: "Particle object \(objectName) parsed; rendered by the Metal particle simulator"))
            }
            if resolution.primary == .text {
                diagnostics.append(.init(severity: .info, message: "Text object \(objectName) parsed; glyph-mesh text renderer draws it"))
            }
            if resolution.primary == .sound {
                diagnostics.append(.init(severity: .info, message: "Sound object \(objectName) parsed; AVAudioEngine playback runs at scene start"))
            }
            if resolution.primary == .light {
                diagnostics.append(.init(
                    severity: .info,
                    message: "Light object \(objectName) fields and dynamic bindings are preserved; Metal light uniforms and shadows await their L1 gates"
                ))
            }

            if resolution.primary == .unknown {
                let type = resolution.explicitType ?? "missing"
                diagnostics.append(.init(severity: .info, message: "Object type \(type) is unsupported by the current renderer"))
            }
        }

        if (root["effects"] as? [Any])?.isEmpty == false {
            diagnostics.append(.init(
                severity: .info,
                message: String(
                    localized: "Top-level effects are not yet rendered",
                    defaultValue: "Top-level effects are not yet rendered",
                    comment: "Wallpaper Engine scene diagnostic when root-level effects are ignored."
                )
            ))
        }

        for key in generalDict.keys {
            let lowered = key.lowercased()
            // HDR bloom (`bloom` gate + `bloomhdr*` + `bloomtint`) IS rendered
            // (see parseGeneral); only the SDR-only keys (bloomstrength/
            // bloomthreshold/…) still lack a render path.
            let isUnsupportedSDRBloomKey = lowered.hasPrefix("bloom")
                && lowered != "bloom"
                && lowered != "bloomtint"
                && !lowered.hasPrefix("bloomhdr")
            if isUnsupportedSDRBloomKey {
                diagnostics.append(.init(severity: .info, message: "general.\(key) is unsupported by the current renderer"))
            }
        }

        return WPESceneDocument(
            camera: camera,
            general: general,
            imageObjects: imageObjects,
            scriptHostObjects: scriptHostObjects,
            transformHostObjects: transformHostObjects,
            particleObjects: particleObjects,
            textObjects: textObjects,
            soundObjects: soundObjects,
            lightObjects: lightObjects,
            objectPaintOrder: objectPaintOrder,
            propertyBindings: propertyBindings,
            objectParentByID: objectParentByID,
            ownVisibilityByID: ownVisibilityByID,
            diagnostics: diagnostics
        )
    }

    private static func parseTransformHostObject(
        _ dict: [String: Any],
        transform: SceneObjectTransform,
        scriptOrigins: [String: SIMD3<Double>] = [:]
    ) -> WPESceneTransformHostObject? {
        guard let id = objectID(in: dict) else { return nil }
        let local = localTransform(in: dict, scriptOrigins: scriptOrigins)
        return WPESceneTransformHostObject(
            id: id,
            name: (dict["name"] as? String) ?? id,
            parentObjectID: parentID(in: dict),
            origin: transform.origin,
            scale: transform.scale,
            angles: transform.angles,
            localOrigin: local.origin,
            localScale: local.scale,
            localAngles: local.angles,
            originAnimation: WPEValueParser.animatedValue(dict["origin"]),
            originScript: dynamicTransformScript(in: dict["origin"], preserveStaticallyResolvable: false),
            scaleScript: dynamicTransformScript(in: dict["scale"], preserveStaticallyResolvable: true),
            anglesScript: dynamicTransformScript(in: dict["angles"], preserveStaticallyResolvable: true),
            parallaxDepth: parseParallaxDepth(dict["parallaxDepth"] ?? dict["parallaxdepth"])
        )
    }

    private static let lightFieldNames = [
        "origin", "scale", "angles", "color", "radius", "intensity", "visible",
        "ledsource", "castshadow", "castvolumetrics", "innercone", "outercone",
        "attenuation", "exponent", "density", "volumetricsexponent",
        "lightsourcesize", "mindistance", "cascadedistance0", "cascadedistance1",
        "cascadedistance2"
    ]

    private static func parseLightObject(
        _ dict: [String: Any],
        authored rawDict: [String: Any],
        transform: SceneObjectTransform,
        effectiveVisible: Bool?,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneLightObject? {
        guard let id = objectID(in: dict) else {
            diagnostics.append(.init(severity: .warning, message: "Light object is missing id"))
            return nil
        }
        let authoredType = nonEmptyString(dict["light"])?.lowercased() ?? "point"
        let type: WPESceneLightType
        switch authoredType {
        case "spot", "lspot": type = .spot
        case "directional", "ldirectional": type = .directional
        default: type = .point
        }
        let local = localTransform(in: dict)
        var fieldBindings: [String: WPESceneLightFieldBinding] = [:]
        for name in lightFieldNames where rawDict[name] != nil {
            let metadata = authoredScriptMetadata(authored: rawDict[name], resolved: dict[name])
            fieldBindings[name] = WPESceneLightFieldBinding(
                seed: WPEValueParser.shaderConstant(rawDict[name]),
                resolvedValue: WPEValueParser.shaderConstant(dict[name]),
                userBindings: authoredUserBindings(in: rawDict[name]),
                script: metadata.script,
                scriptProperties: metadata.properties
            )
        }

        return WPESceneLightObject(
            id: id,
            name: nonEmptyString(dict["name"]) ?? id,
            type: type,
            authoredType: authoredType,
            origin: transform.origin,
            scale: transform.scale,
            angles: transform.angles,
            localOrigin: local.origin,
            localScale: local.scale,
            localAngles: local.angles,
            parentObjectID: parentID(in: dict),
            parallaxDepth: parseParallaxDepth(dict["parallaxDepth"] ?? dict["parallaxdepth"]),
            color: parseVector3(dict["color"]) ?? SIMD3<Double>(repeating: 1),
            radius: parseDouble(dict["radius"]) ?? 1_000,
            intensity: parseDouble(dict["intensity"]) ?? 1,
            visible: effectiveVisible ?? parseBool(dict["visible"]) ?? true,
            shape: nonEmptyString(dict["shape"]),
            ledSource: parseBool(dict["ledsource"]) ?? false,
            castShadow: parseBool(dict["castshadow"]) ?? false,
            castVolumetrics: parseBool(dict["castvolumetrics"]) ?? false,
            innerConeDegrees: parseDouble(dict["innercone"]) ?? 0,
            outerConeDegrees: parseDouble(dict["outercone"]) ?? 0,
            attenuation: parseDouble(dict["attenuation"]) ?? 0,
            exponent: parseDouble(dict["exponent"]) ?? 1,
            density: parseDouble(dict["density"]) ?? 1,
            volumetricsExponent: parseDouble(dict["volumetricsexponent"]) ?? 1,
            lightSourceSize: parseDouble(dict["lightsourcesize"]) ?? 0,
            minimumDistance: parseDouble(dict["mindistance"]) ?? 0,
            cascadeDistances: SIMD3<Double>(
                parseDouble(dict["cascadedistance0"]) ?? 0,
                parseDouble(dict["cascadedistance1"]) ?? 0,
                parseDouble(dict["cascadedistance2"]) ?? 0
            ),
            lockTransforms: parseBool(dict["locktransforms"]) ?? false,
            muteInEditor: parseBool(dict["muteineditor"]) ?? false,
            noInterpolation: parseBool(dict["nointerpolation"]) ?? false,
            disablePropagation: parseBool(dict["disablepropagation"]) ?? false,
            solid: parseBool(dict["solid"]) ?? false,
            dependencies: parseDependencyIDs(dict["dependencies"]),
            fieldBindings: fieldBindings
        )
    }

    private static func parseScriptHostObject(
        _ dict: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneScriptHostObject? {
        guard let visibleDict = dict["visible"] as? [String: Any],
              let script = visibleDict["script"] as? String, !script.isEmpty else {
            return nil
        }
        let id = objectID(in: dict)
            ?? (dict["name"] as? String)
            ?? "script-host-\(abs(script.hashValue))"
        let name = (dict["name"] as? String) ?? id
        diagnostics.append(.init(
            severity: .info,
            message: "Object \(name) has a visible-script but no renderable image; runs as a SceneScript host"
        ))
        return WPESceneScriptHostObject(
            id: id,
            name: name,
            visibleScript: script,
            scriptProperties: scriptPropertyValues(visibleDict["scriptproperties"])
        )
    }

    /// Canonical id→object index. A later duplicate id wins so every downstream
    /// pass resolves the same source object for a given id; well-formed WPE
    /// exports carry unique ids, so this only matters for malformed documents.
    private static func indexObjectsByID(
        _ rawObjects: [[String: Any]]
    ) -> [String: [String: Any]] {
        var objectsByID: [String: [String: Any]] = [:]
        for object in rawObjects {
            guard let id = objectID(in: object) else { continue }
            objectsByID[id] = object
        }
        return objectsByID
    }

    /// Parent id and OWN baked `visible` for every object (groups included). The
    /// renderer walks the parent chain live so a layer script can't show a layer
    /// under a currently-hidden ancestor (group toggle, condition, or live image
    /// toggle alike) — its `getParent()` is a neutral always-visible stub.
    private static func objectHierarchy(
        from objectsByID: [String: [String: Any]]
    ) -> (parents: [String: String], ownVisibility: [String: Bool]) {
        var parents: [String: String] = [:]
        var ownVisibility: [String: Bool] = [:]
        for (id, object) in objectsByID {
            ownVisibility[id] = parseBool(object["visible"]) ?? true
            if let parent = parentID(in: object), parent != id {
                parents[id] = parent
            }
        }
        return (parents, ownVisibility)
    }

    /// WPE allows `attachment` on a pure GROUP object: the whole subtree rides the
    /// named MDAT anchor of the group's parent puppet. Groups are baked away at parse
    /// time, so lower the group's attachment onto each renderable descendant — the
    /// child inherits the anchor name and re-parents to the group's parent (the puppet
    /// layer), the exact shape the static anchor-offset and runtime attachment-follow
    /// paths already handle for directly-attached layers.
    private static func inheritedGroupAttachments(
        from objectsByID: [String: [String: Any]]
    ) -> [String: (name: String, parentID: String)] {
        // Each group node's nearest inherited attachment is a property of its
        // position in the group chain, not of the image that starts the walk, so
        // memoize it once instead of re-walking the whole chain per unattached
        // image (previously O(objects × chain-depth) on deep group hierarchies).
        var memo: [String: (name: String, parentID: String)?] = [:]

        func inherited(groupID: String, stack: Set<String>) -> (name: String, parentID: String)? {
            if let cached = memo[groupID] { return cached }
            guard !stack.contains(groupID),
                  let group = objectsByID[groupID],
                  objectKindResolution(for: group).primary == .unknown else {
                return nil
            }
            let resolved: (name: String, parentID: String)?
            if let attachment = nonEmptyString(group["attachment"]) ?? nonEmptyString(group["anchor"]),
               let groupParentID = parentID(in: group) {
                resolved = (attachment, groupParentID)
            } else if let parent = parentID(in: group) {
                resolved = inherited(groupID: parent, stack: stack.union([groupID]))
            } else {
                resolved = nil
            }
            memo[groupID] = resolved
            return resolved
        }

        var result: [String: (name: String, parentID: String)] = [:]
        for (id, object) in objectsByID {
            guard objectKindResolution(for: object).primary == .image,
                  nonEmptyString(object["attachment"]) == nil,
                  nonEmptyString(object["anchor"]) == nil,
                  let parent = parentID(in: object) else { continue }
            if let attachment = inherited(groupID: parent, stack: []) {
                result[id] = attachment
            }
        }
        return result
    }

    /// Records, per user-property key, the render targets it drives and whether
    /// it can be applied incrementally. Image/text visibility plus sound
    /// visibility/volume have live consumers; everything else is conservatively
    /// `.reload`.
    private static func extractUserPropertyBindings(in json: Any) -> [String: [WPEScenePropertyBinding]] {
        guard let root = json as? [String: Any] else {
            return [:]
        }
        let rawObjects = root["objects"] as? [[String: Any]] ?? []
        var result: [String: [WPEScenePropertyBinding]] = [:]

        func append(
            raw: Any?,
            target: WPEScenePropertyBindingTarget,
            kind: WPEScenePropertyBindingKind,
            action: WPEScenePropertyBindingAction,
            includeNestedScriptProperties: Bool = true
        ) {
            let specs = (try? userPropertyBindingSpecs(
                in: raw,
                includeNestedScriptProperties: includeNestedScriptProperties
            ))?.sorted { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return (lhs.condition ?? "") < (rhs.condition ?? "")
            } ?? []
            for spec in specs {
                result[spec.key, default: []].append(WPEScenePropertyBinding(
                    propertyKey: spec.key,
                    target: target,
                    kind: kind,
                    action: action,
                    condition: spec.condition
                ))
            }
        }

        func appendScriptProperties(
            in raw: Any?,
            objectID: String,
            role: WPESceneScriptPropertyRole,
            subresourceID: String? = nil
        ) {
            guard let envelope = raw as? [String: Any],
                  envelope["script"] is String,
                  let properties = envelope["scriptproperties"] as? [String: Any] else {
                return
            }
            for propertyName in properties.keys.sorted() {
                append(
                    raw: properties[propertyName],
                    target: .scriptProperty(.init(
                        objectID: objectID,
                        role: role,
                        propertyName: propertyName,
                        subresourceID: subresourceID
                    )),
                    kind: .scriptProperty,
                    // The renderer is the final authority: it admits this live
                    // only when the addressed object/role retained an instance;
                    // static or unsupported consumers fail preflight and reload.
                    action: .incremental
                )
            }
        }

        if let general = root["general"] as? [String: Any] {
            let fields = [
                "zoom", "perspectiveoverridefov", "camerashake",
                "camerashakeamplitude", "camerashakespeed", "camerashakeroughness",
                "clearenabled", "windenabled", "winddirection", "windstrength",
                "gravitydirection", "gravitystrength"
            ]
            for field in fields {
                append(
                    raw: general[field],
                    target: .generalField(name: field),
                    kind: .general,
                    action: .reload
                )
            }
        }

        for object in rawObjects {
            guard let objectID = objectID(in: object) else { continue }
            let objectKind = objectKindResolution(for: object).primary
            appendScriptProperties(in: object["origin"], objectID: objectID, role: .origin)
            appendScriptProperties(in: object["scale"], objectID: objectID, role: .scale)
            appendScriptProperties(in: object["angles"], objectID: objectID, role: .angles)
            appendScriptProperties(in: object["color"], objectID: objectID, role: .color)
            switch objectKind {
            case .image:
                append(raw: object["visible"], target: .imageObject(id: objectID), kind: .visible, action: .incremental, includeNestedScriptProperties: false)
                append(raw: object["color"], target: .imageObject(id: objectID), kind: .color, action: .reload, includeNestedScriptProperties: false)
                append(raw: object["alpha"], target: .imageObject(id: objectID), kind: .alpha, action: .reload, includeNestedScriptProperties: false)
                append(raw: object["brightness"], target: .imageObject(id: objectID), kind: .brightness, action: .reload)
                append(raw: object["image"], target: .objectResource(objectID: objectID, field: "image"), kind: .resource, action: .reload)
                append(raw: object["material"], target: .objectResource(objectID: objectID, field: "material"), kind: .resource, action: .reload)
                appendScriptProperties(in: object["visible"], objectID: objectID, role: .layerVisible)
                appendScriptProperties(in: object["alpha"], objectID: objectID, role: .layerAlpha)
                if let effects = object["effects"] as? [[String: Any]] {
                    for (effectIndex, effect) in effects.enumerated() {
                        let effectIdentifier = effectID(in: effect, fallback: "\(effectIndex)")
                        append(raw: effect["visible"], target: .imageEffect(objectID: objectID, effectID: effectIdentifier), kind: .visible, action: .reload, includeNestedScriptProperties: false)
                        appendScriptProperties(
                            in: effect["visible"],
                            objectID: objectID,
                            role: .effectVisible,
                            subresourceID: effectIdentifier
                        )
                        if let passes = effect["passes"] as? [[String: Any]] {
                            for (passIndex, pass) in passes.enumerated() {
                                let passID = parseInt(pass["id"]) ?? passIndex
                                forEachShaderConstant(in: pass["constantshadervalues"]) { name, raw in
                                    append(
                                        raw: raw,
                                        target: .shaderUniform(objectID: objectID, effectID: effectIdentifier, passID: passID, name: name),
                                        kind: .uniform,
                                        action: .reload,
                                        includeNestedScriptProperties: false
                                    )
                                    appendScriptProperties(
                                        in: raw,
                                        objectID: objectID,
                                        role: .effectConstant,
                                        subresourceID: "\(effectIdentifier):\(passID):\(name)"
                                    )
                                }
                                if let combos = pass["combos"] as? [String: Any] {
                                    for (name, raw) in combos {
                                        append(raw: raw, target: .shaderCombo(objectID: objectID, effectID: effectIdentifier, passID: passID, name: name), kind: .combo, action: .reload)
                                    }
                                }
                                if let textures = pass["textures"] as? [Any] {
                                    for (index, raw) in textures.enumerated() {
                                        append(raw: raw, target: .textureSlot(objectID: objectID, effectID: effectIdentifier, passID: passID, index: index), kind: .texture, action: .reload)
                                    }
                                }
                            }
                        }
                    }
                }
            case .text:
                append(raw: object["visible"], target: .textObject(id: objectID), kind: .visible, action: .incremental, includeNestedScriptProperties: false)
                append(raw: object["color"], target: .textObject(id: objectID), kind: .color, action: .reload, includeNestedScriptProperties: false)
                append(raw: object["alpha"], target: .textObject(id: objectID), kind: .alpha, action: .reload, includeNestedScriptProperties: false)
                appendScriptProperties(in: object["text"], objectID: objectID, role: .textContent)
                appendScriptProperties(in: object["visible"], objectID: objectID, role: .textVisible)
                appendScriptProperties(in: object["alpha"], objectID: objectID, role: .textAlpha)
            case .particle:
                append(raw: object["visible"], target: .particleObject(id: objectID), kind: .visible, action: .reload)
                append(raw: object["color"], target: .particleObject(id: objectID), kind: .color, action: .reload)
                append(raw: object["alpha"], target: .particleObject(id: objectID), kind: .alpha, action: .reload)
            case .sound:
                append(raw: object["visible"], target: .soundObject(id: objectID), kind: .visible, action: .incremental)
                append(raw: object["volume"], target: .soundObject(id: objectID), kind: .volume, action: .incremental)
            case .light:
                for field in lightFieldNames {
                    let kind: WPEScenePropertyBindingKind
                    switch field {
                    case "visible": kind = .visible
                    case "color": kind = .color
                    default: kind = .uniform
                    }
                    append(
                        raw: object[field],
                        target: .lightObject(id: objectID),
                        kind: kind,
                        action: .reload
                    )
                }
            default:
                // Pure SceneScript hosts are object-kind `.unknown`: they draw
                // nothing but their visible script still consumes settings.
                appendScriptProperties(in: object["visible"], objectID: objectID, role: .layerVisible)
                break
            }
        }
        return result
    }

    private static func effectID(in dict: [String: Any], fallback: String) -> String {
        if let id = dict["id"] as? String, !id.isEmpty { return id }
        if let id = parseInt(dict["id"]) { return String(id) }
        if let name = dict["name"] as? String, !name.isEmpty { return name }
        return fallback
    }

    /// Describes one user-property dependency discovered in a raw scene field:
    /// the property key plus, for condition-form (style-selector) bindings, the
    /// expected literal the property must match for the field's `value` to take
    /// effect (nil for the simple form).
    private struct UserPropertyBindingSpec: Hashable {
        let key: String
        let condition: String?
    }

    /// Recursively collects every user-property envelope reachable from `raw`
    /// (a field value may be a scalar, a `{user}` envelope, or an array of them
    /// — e.g. color components). Handles both the simple form
    /// `{"user":K,"value":...}` and the condition form
    /// `{"user":{"name":K,"condition":"2"},"value":...}` (style selectors).
    private static func userPropertyBindingSpecs(
        in raw: Any?,
        depth: Int = 0,
        includeNestedScriptProperties: Bool = true
    ) throws -> Set<UserPropertyBindingSpec> {
        guard depth < 100 else {
            throw WPESceneDocumentError.malformedField("scene.json is too deeply nested")
        }
        guard let raw else { return [] }
        if let array = raw as? [Any] {
            return try array.reduce(into: Set<UserPropertyBindingSpec>()) { specs, value in
                specs.formUnion(try userPropertyBindingSpecs(
                    in: value,
                    depth: depth + 1,
                    includeNestedScriptProperties: includeNestedScriptProperties
                ))
            }
        }
        guard let dict = raw as? [String: Any] else { return [] }
        var specs = Set<UserPropertyBindingSpec>()
        if dict.keys.contains("value") {
            if let key = dict["user"] as? String {
                specs.insert(UserPropertyBindingSpec(key: key, condition: nil))
            } else if let user = dict["user"] as? [String: Any],
                      let name = user["name"] as? String, !name.isEmpty {
                specs.insert(UserPropertyBindingSpec(
                    key: name,
                    condition: conditionString(from: user["condition"])
                ))
            }
        }
        for (key, value) in dict {
            if !includeNestedScriptProperties,
               key.caseInsensitiveCompare("scriptproperties") == .orderedSame {
                continue
            }
            specs.formUnion(try userPropertyBindingSpecs(
                in: value,
                depth: depth + 1,
                includeNestedScriptProperties: includeNestedScriptProperties
            ))
        }
        return specs
    }

    /// Normalises a condition literal (`String`/number/`Bool`) to its string
    /// form. Integral numbers render without a trailing `.0` so a combo option
    /// value of `2` matches a condition `"2"`. JSON booleans (which bridge to
    /// `NSNumber`) are kept distinct from numerics.
    private static func conditionString(from raw: Any?) -> String? {
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            // `NSNumber.stringValue` renders integers without a trailing `.0`
            // and never traps — unlike `Int(double)`, which would crash on a
            // finite but out-of-`Int`-range literal from external scene JSON.
            return number.stringValue
        }
        return nil
    }

    private static func resolvedObjectTransforms(
        _ objectsByID: [String: [String: Any]],
        scriptOrigins: [String: SIMD3<Double>] = [:]
    ) -> [String: SceneObjectTransform] {
        var memo: [String: SceneObjectTransform] = [:]

        func resolve(id: String, stack: Set<String>) -> SceneObjectTransform {
            if let cached = memo[id] { return cached }
            guard let object = objectsByID[id] else { return .identity }
            let local = localTransform(in: object, scriptOrigins: scriptOrigins)
            guard let parent = parentID(in: object),
                  parent != id,
                  objectsByID[parent] != nil,
                  !stack.contains(parent) else {
                memo[id] = local
                return local
            }
            guard stack.count < 100 else {
                memo[id] = local
                return local
            }
            let inherited = resolve(id: parent, stack: stack.union([id]))
            let resolved = inherited.combining(child: local)
            memo[id] = resolved
            return resolved
        }

        for id in objectsByID.keys {
            _ = resolve(id: id, stack: [])
        }
        return memo
    }

    private static func objectID(in dict: [String: Any], fallback: String? = nil) -> String? {
        if let id = dict["id"] as? String, !id.isEmpty { return id }
        if let id = parseInt(dict["id"]) { return String(id) }
        if let name = dict["name"] as? String, !name.isEmpty { return name }
        return fallback
    }

    private static func parentID(in dict: [String: Any]) -> String? {
        if let id = dict["parent"] as? String, !id.isEmpty { return id }
        if let id = parseInt(dict["parent"]) { return String(id) }
        return nil
    }

    /// WPE binds a transform component to a user property as
    /// `{"user": "newpropertyN", "value": "0.5 0.5 0.5"}`; the resolved value is
    /// in `value`. Unwrap it in the APP target (not just the package's vector3,
    /// which a stale incremental build may not recompile) so a property-bound
    /// scale/origin resolves instead of defaulting.
    private static func resolveBoundTransformValue(_ raw: Any?) -> Any? {
        if let dict = raw as? [String: Any], let value = dict["value"] {
            return value
        }
        return raw
    }

    private static func localTransform(
        in dict: [String: Any],
        scriptOrigins: [String: SIMD3<Double>] = [:]
    ) -> SceneObjectTransform {
        // A script-resolved origin (computed from current user values) replaces the
        // stale baked `value` at the LOCAL level, so parent combination is unchanged.
        let origin: SIMD3<Double>
        if let id = objectID(in: dict), let scripted = scriptOrigins[id] {
            origin = scripted
        } else {
            origin = parseVector3(resolveBoundTransformValue(dict["origin"])) ?? SIMD3<Double>(0, 0, 0)
        }
        return SceneObjectTransform(
            origin: origin,
            scale: parseScale(dict["scale"]),
            angles: parseVector3(resolveBoundTransformValue(dict["angles"])) ?? SIMD3<Double>(0, 0, 0)
        )
    }

    /// Resolves each object's visibility as its own value combined with every ancestor, including non-renderable groups.
    private static func resolvedObjectVisibility(
        _ objectsByID: [String: [String: Any]]
    ) -> [String: Bool] {
        var memo: [String: Bool] = [:]

        func resolve(id: String, stack: Set<String>) -> Bool {
            if let cached = memo[id] { return cached }
            guard let object = objectsByID[id] else { return true }
            let own = parseBool(object["visible"]) ?? true
            guard own else { memo[id] = false; return false }
            guard let parent = parentID(in: object),
                  parent != id,
                  objectsByID[parent] != nil,
                  !stack.contains(parent) else {
                memo[id] = own
                return own
            }
            guard stack.count < 100 else {
                memo[id] = own
                return own
            }
            let effective = own && resolve(id: parent, stack: stack.union([id]))
            memo[id] = effective
            return effective
        }

        for id in objectsByID.keys {
            _ = resolve(id: id, stack: [])
        }
        return memo
    }

    /// Evaluates static `origin` scripts once per document, returning the resolved
    /// LOCAL origin keyed by object id. Objects without an origin script — or whose
    /// script is dynamic (audio/time/random) — are absent, keeping their baked value.
    private static func resolveScriptOrigins(
        _ rawObjects: [[String: Any]],
        canvasWidth: Double,
        canvasHeight: Double,
        makeResolver: (Double, Double) -> any WPESceneTransformScriptResolving
    ) -> [String: SIMD3<Double>] {
        var pending: [(id: String, script: String, properties: [String: WPESceneScriptPropertyValue], seed: SIMD3<Double>)] = []
        for object in rawObjects {
            guard let id = objectID(in: object),
                  let origin = object["origin"] as? [String: Any],
                  let script = origin["script"] as? String, !script.isEmpty,
                  WPETransformScriptStaticAnalysis.isStaticallyResolvable(script) else { continue }
            let properties = scriptPropertyValues(origin["scriptproperties"])
            let seed = parseVector3(resolveBoundTransformValue(origin["value"])) ?? SIMD3<Double>(0, 0, 0)
            pending.append((id, script, properties, seed))
        }
        guard !pending.isEmpty else { return [:] }

        let evaluator = makeResolver(canvasWidth, canvasHeight)
        var resolved: [String: SIMD3<Double>] = [:]
        resolved.reserveCapacity(pending.count)
        let requests = pending.map {
            WPESceneTransformScriptRequest(
                script: $0.script,
                properties: $0.properties,
                seed: $0.seed
            )
        }
        let outputs = evaluator.resolveBatch(requests)
        for (item, origin) in zip(pending, outputs) {
            if let origin {
                resolved[item.id] = origin
            }
        }
        return resolved
    }

    /// Reads a resolved `scriptproperties` dict into typed values. User-property
    /// envelopes were already collapsed to literals before parsing; the
    /// `{ "value": X }` fallback covers any un-overridden binding. Numbers, bools
    /// (checkboxes), and strings (combos/text) are all preserved so a layout
    /// script can branch on any of them.
    private static func scriptPropertyValues(_ raw: Any?) -> [String: WPESceneScriptPropertyValue] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var properties: [String: WPESceneScriptPropertyValue] = [:]
        for (key, value) in dict {
            if let resolved = scriptPropertyValue(value) {
                properties[key] = resolved
            }
        }
        return properties
    }

    private static func scriptPropertyValue(_ raw: Any?) -> WPESceneScriptPropertyValue? {
        if let dict = raw as? [String: Any], let inner = dict["value"] {
            return scriptPropertyValue(inner)
        }
        if let number = raw as? NSNumber {
            // CFBoolean is an NSNumber subtype; JSON true/false must stay a bool
            // rather than collapse to 1/0 so checkbox-driven branches still work.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let string = raw as? String {
            // Prefer a numeric reading of a "0.5"-style string; else keep the text.
            if let number = parseDouble(string) { return .number(number) }
            return .string(string)
        }
        return nil
    }

    /// WPE may store scale as a vector ("0.5 0.5 0.5"), a {user,value} property
    /// binding, OR a single uniform scalar (0.5 → applied to all axes — this is
    /// what a resolved "Scale Size" slider writes). `parseVector3` returns nil for
    /// a lone scalar, which silently defaulted scale to 1.0 and doubled the layer
    /// (scene 3460973721's audio-bar composelayer). Coerce the scalar to uniform.
    private static func parseScale(_ raw: Any?) -> SIMD3<Double> {
        let resolved = resolveBoundTransformValue(raw)
        if let vector = parseVector3(resolved) { return vector }
        if let scalar = parseDouble(resolved) { return SIMD3<Double>(scalar, scalar, scalar) }
        return SIMD3<Double>(1, 1, 1)
    }

    private static func parseSoundObject(
        _ dict: [String: Any],
        authored rawDict: [String: Any],
        effectiveVisible: Bool? = nil,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneSoundObject? {
        var paths: [String] = []
        if let single = dict["sound"] as? String, !single.isEmpty {
            paths.append(single)
        } else if let array = dict["sound"] as? [Any] {
            for value in array {
                if let s = value as? String, !s.isEmpty {
                    paths.append(s)
                }
            }
        }
        guard !paths.isEmpty else {
            let objectName = dict["name"] as? String ?? "?"
            diagnostics.append(.init(
                severity: .warning,
                message: String(
                    localized: "Sound object \(objectName) has no sound files",
                    comment: "Wallpaper Engine scene diagnostic. The placeholder is the sound object name."
                )
            ))
            return nil
        }
        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? paths[0]
        let name = (dict["name"] as? String) ?? id
        let volumeField = preservedDoubleField(
            authored: rawDict["volume"],
            resolved: dict["volume"],
            defaultValue: 1
        )
        let visibleField = preservedBoolField(
            authored: rawDict["visible"],
            resolved: dict["visible"],
            defaultValue: true
        )
        let mode = (dict["playbackmode"] as? String) ?? "loop"
        let startSilent = (dict["startsilent"] as? Bool) ?? false
        return WPESceneSoundObject(
            id: id,
            name: name,
            soundRelativePaths: paths,
            volume: max(0, min(volumeField.resolvedValue, 1)),
            playbackMode: mode.lowercased(),
            startSilent: startSilent,
            visible: effectiveVisible ?? visibleField.resolvedValue,
            volumeField: volumeField,
            visibleField: visibleField
        )
    }

    private static func parseTextObject(
        _ dict: [String: Any],
        transform: SceneObjectTransform,
        localOrigin: SIMD3<Double>? = nil,
        localScale: SIMD3<Double>? = nil,
        parentObjectID: String? = nil,
        effectiveVisible: Bool? = nil,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneTextObject? {
        let raw = dict["text"]
        let authoredText: String?
        var textScript: String?
        var textScriptProperties: [String: WPESceneScriptPropertyValue] = [:]
        switch raw {
        case let value as String:
            authoredText = value
        case let nested as [String: Any]:
            authoredText = (nested["value"] as? String) ?? (nested["text"] as? String)
            if let script = nested["script"] as? String, !script.isEmpty {
                textScript = script
                // The scene's per-object scriptProperty overrides (already
                // envelope-resolved to literals) so the script renders with the
                // scene's settings, not just its own declared defaults.
                textScriptProperties = scriptPropertyValues(nested["scriptproperties"])
            }
        default:
            authoredText = nil
        }
        // A script-driven text object may author an EMPTY placeholder — its
        // update() computes the real string (3509243656's `time` display authors
        // "" and is the scene's only `shared.xntime` producer; dropping it froze
        // every consumer text). WPE runs the script regardless of the authored
        // value, so only SCRIPTLESS objects with no resolvable text are dropped.
        guard authoredText?.isEmpty == false || textScript != nil else {
            let objectName = dict["name"] as? String ?? "?"
            diagnostics.append(.init(
                severity: .warning,
                message: String(
                    localized: "Text object \(objectName) has no resolvable text",
                    comment: "Wallpaper Engine scene diagnostic. The placeholder is the text object name."
                )
            ))
            return nil
        }
        let text = authoredText ?? ""
        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? text
        let name = (dict["name"] as? String) ?? id
        let font = unwrapString(dict["font"])
        let pointSize = unwrapDouble(dict["pointsize"]) ?? unwrapDouble(dict["fontsize"]) ?? 32
        let color = unwrapVector3(dict["color"]) ?? SIMD3<Double>(1, 1, 1)
        // Generic object `brightness` — the same field image objects consume;
        // WPE modulates text with it too (3460973721's Clock/Date/Day author
        // 2.39/1.98/1.4), so dropping it discarded authored intensity.
        let brightness = unwrapDouble(dict["brightness"]) ?? 1.0
        let alphaValue = parseAnimatedScalar(dict["alpha"], fallback: 1)
        // Script-driven alpha/visible (3509243656's login-intro texts) — the
        // renderer ticks these; the baked value above is only the seed.
        var alphaScript: String?
        var alphaScriptProperties: [String: WPESceneScriptPropertyValue] = [:]
        if let alphaDict = dict["alpha"] as? [String: Any],
           let script = alphaDict["script"] as? String, !script.isEmpty {
            alphaScript = script
            alphaScriptProperties = scriptPropertyValues(alphaDict["scriptproperties"])
        }
        var visibleScript: String?
        var visibleScriptProperties: [String: WPESceneScriptPropertyValue] = [:]
        if let visibleDict = dict["visible"] as? [String: Any],
           let script = visibleDict["script"] as? String, !script.isEmpty {
            visibleScript = script
            visibleScriptProperties = scriptPropertyValues(visibleDict["scriptproperties"])
        }
        let origin = transform.origin
        let scale = transform.scale
        // Text objects carry static `angles` like image layers (2986828130's
        // Clock/Date tilt 30° standalone) — dropping it froze them unrotated.
        let angles = transform.angles
        let visible = effectiveVisible ?? (parseBool(dict["visible"]) ?? true)
        let horiz = unwrapString(dict["horizontalalign"]) ?? "center"
        let vert = unwrapString(dict["verticalalign"]) ?? "middle"
        // `maxwidth` only constrains the text when WPE's "Limit Width" toggle
        // (`limitwidth`) is on. With it off (the default), the text is unbounded;
        // applying `maxwidth` unconditionally made large clock/date text wrap at
        // every glyph (each digit is wider than the authored 500pt maxwidth).
        let limitWidth = parseBool(dict["limitwidth"]) ?? false
        let maxWidth = limitWidth ? unwrapDouble(dict["maxwidth"]) : nil
        // Same gating for rows: WPE writes `maxrows` on every text object (525 of
        // 527 corpus objects say 1) but only honours it when `limitrows` is on —
        // 34 objects, 26 of which also ask for the ellipsis.
        let limitRows = parseBool(dict["limitrows"]) ?? false
        let maxRows = limitRows ? parseInt(dict["maxrows"]).map { Swift.max(1, $0) } : nil
        let limitUseEllipsis = parseBool(dict["limituseellipsis"]) ?? false
        let parallaxDepth = parseParallaxDepth(dict["parallaxDepth"] ?? dict["parallaxdepth"])
        // The authored "size" box is an editor bounding-box snapshot — WPE's
        // runtime never lays text out against it (glyphs render at
        // pointsize×300/72 anchored to `origin`; oracle-verified). Parsed only
        // because SceneScript's `layer.size` reports it.
        let boxSize = parseVector3(dict["size"]).map { SIMD2<Double>($0.x, $0.y) }
        let padding = parseDouble(dict["padding"]) ?? 0
        let copyBackground = parseBool(dict["copybackground"]) ?? false
        let opaqueBackground = parseBool(dict["opaquebackground"]) ?? false
        let backgroundColor = unwrapVector3(dict["backgroundcolor"]) ?? SIMD3<Double>(0, 0, 0)
        let backgroundBrightness = unwrapDouble(dict["backgroundbrightness"]) ?? 1
        // 202 of the corpus's 572 text objects carry an effect chain; WPE runs
        // it over the rendered glyphs exactly as it does for an image layer.
        let effects = parseImageEffects(dict["effects"], imageName: name, diagnostics: &diagnostics)
        let letterSpacing = unwrapDouble(dict["letterspacing"]) ?? unwrapDouble(dict["spacing"]) ?? 0

        return WPESceneTextObject(
            id: id,
            name: name,
            text: text,
            textScript: textScript,
            scriptProperties: textScriptProperties,
            fontRelativePath: font,
            pointSize: max(1, pointSize),
            color: color,
            brightness: max(0, brightness),
            alpha: max(0, min(alphaValue.value, 1)),
            alphaAnimation: alphaValue.animation,
            origin: origin,
            scale: scale,
            angles: angles,
            visible: visible,
            horizontalAlignment: horiz.lowercased(),
            verticalAlignment: vert.lowercased(),
            maxWidth: maxWidth.map { max(1, $0) },
            maxRows: maxRows,
            limitUseEllipsis: limitUseEllipsis,
            parallaxDepth: parallaxDepth,
            boxSize: (boxSize.map { $0.x > 0 && $0.y > 0 } ?? false) ? boxSize : nil,
            padding: max(0, padding),
            copyBackground: copyBackground,
            opaqueBackground: opaqueBackground,
            backgroundColor: backgroundColor,
            backgroundBrightness: max(0, backgroundBrightness),
            effects: effects,
            letterSpacing: letterSpacing,
            parentObjectID: parentObjectID,
            localOrigin: localOrigin,
            localScale: localScale,
            alphaScript: alphaScript,
            alphaScriptProperties: alphaScriptProperties,
            visibleScript: visibleScript,
            visibleScriptProperties: visibleScriptProperties,
            originScript: dynamicTransformScript(in: dict["origin"], preserveStaticallyResolvable: false),
            colorScript: dynamicTransformScript(in: dict["color"], preserveStaticallyResolvable: true),
            scaleScript: dynamicTransformScript(in: dict["scale"], preserveStaticallyResolvable: true),
            anglesScript: dynamicTransformScript(in: dict["angles"], preserveStaticallyResolvable: true)
        )
    }

    /// Recursively replace every WPE user-property envelope
    /// `{ "user": K, "value": V }` with `userValues[K] ?? V` BEFORE field
    /// parsing, so scene custom settings (e.g. toggling an object's `visible`
    /// via its bound property) actually drive the parsed document.
    private static func resolveUserPropertyEnvelopes(
        in raw: Any,
        userValues: [String: WallpaperEngineProjectPropertyValue],
        depth: Int = 0
    ) throws -> Any {
        guard depth < 100 else {
            throw WPESceneDocumentError.malformedField("scene.json is too deeply nested")
        }
        if let array = raw as? [Any] {
            return try array.map {
                try resolveUserPropertyEnvelopes(in: $0, userValues: userValues, depth: depth + 1)
            }
        }

        guard let dict = raw as? [String: Any] else {
            return raw
        }

        // A field carrying a `script` is script-driven (a SceneScript computes it
        // per frame); its `user`/`value` is the script's own enable binding, not a
        // plain user-property envelope. Collapsing it to `value` would discard the
        // script (e.g. an intro video layer whose `visible` is `{script, user, value}`),
        // so preserve the dict — recursing so nested `scriptproperties` envelopes
        // still resolve to the user's values.
        if let script = dict["script"] as? String, !script.isEmpty {
            var resolved: [String: Any] = [:]
            resolved.reserveCapacity(dict.count)
            for (key, value) in dict {
                resolved[key] = try resolveUserPropertyEnvelopes(in: value, userValues: userValues, depth: depth + 1)
            }
            return resolved
        }

        if let key = dict["user"] as? String,
           dict.keys.contains("value") {
            let fallback = try resolveUserPropertyEnvelopes(
                in: dict["value"] ?? NSNull(),
                userValues: userValues,
                depth: depth + 1
            )
            guard let override = userValues[key] else {
                return fallback
            }
            return jsonValue(for: override)
        }

        // Condition form (WPE style selector):
        // `{"user":{"name":K,"condition":"2"},"value":false}`. The field is
        // visible only while `userValues[K]` matches the condition literal.
        if let user = dict["user"] as? [String: Any],
           let name = user["name"] as? String, !name.isEmpty,
           dict.keys.contains("value") {
            let fallback = try resolveUserPropertyEnvelopes(
                in: dict["value"] ?? NSNull(),
                userValues: userValues,
                depth: depth + 1
            )
            guard let override = userValues[name] else {
                return fallback
            }
            guard let condition = conditionString(from: user["condition"]) else {
                // Nested user with a name but no condition → the property drives
                // the value directly, like the simple form.
                return jsonValue(for: override)
            }
            // Gate to a Bool only when the baked fallback is a genuine JSON
            // boolean (a `visible` field). `strictBool` rejects numeric
            // NSNumbers, so a condition-form envelope wrapping a scalar field
            // (alpha/brightness/scale) — or a vector/color — is returned
            // untouched instead of being coerced into a Bool.
            guard WPEValueParser.strictBool(fallback) != nil else {
                return fallback
            }
            return override.looselyMatches(.conditionLiteral(condition))
        }

        var resolved: [String: Any] = [:]
        resolved.reserveCapacity(dict.count)
        for (key, value) in dict {
            resolved[key] = try resolveUserPropertyEnvelopes(
                in: value,
                userValues: userValues,
                depth: depth + 1
            )
        }
        return resolved
    }

    private static func jsonValue(for value: WallpaperEngineProjectPropertyValue) -> Any {
        switch value {
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        }
    }

    /// Accept legacy `{ "value": <X> }` wrappers. User-property envelopes are
    /// resolved before field parsing so these helpers only see effective values.
    private static func unwrapDouble(_ raw: Any?) -> Double? {
        if let value = WPEValueParser.double(raw) { return value }
        if let dict = raw as? [String: Any] {
            return unwrapDouble(dict["value"])
        }
        return nil
    }

    private static func unwrapVector3(_ raw: Any?) -> SIMD3<Double>? {
        if let value = WPEValueParser.vector3(raw) { return value }
        if let dict = raw as? [String: Any] {
            return unwrapVector3(dict["value"])
        }
        return nil
    }

    private static func unwrapString(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        if let dict = raw as? [String: Any] {
            return unwrapString(dict["value"])
        }
        return nil
    }

    private static func parseAnimatedScalar(
        _ raw: Any?,
        fallback: Double
    ) -> (value: Double, animation: WPESceneAnimatedValue?) {
        guard let constant = WPEValueParser.shaderConstant(raw) else {
            return (parseDouble(raw) ?? fallback, nil)
        }
        switch constant {
        case .number(let value):
            return (value, nil)
        case .vector(let vector):
            return (vector.first ?? fallback, nil)
        case .bool(let value):
            return (value ? 1 : 0, nil)
        case .string(let value):
            return (Double(value) ?? fallback, nil)
        case .animated(let value):
            return (value.scalarFallback ?? value.scalar(at: 0) ?? fallback, value)
        }
    }

    private static func parseParticleObject(
        _ dict: [String: Any],
        transform: SceneObjectTransform,
        effectiveVisible: Bool? = nil,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneParticleObject? {
        guard let path = dict["particle"] as? String, !path.isEmpty else {
            let objectName = dict["name"] as? String ?? "?"
            diagnostics.append(.init(
                severity: .warning,
                message: String(
                    localized: "Particle object \(objectName) has no particle file",
                    comment: "Wallpaper Engine scene diagnostic. The placeholder is the particle object name."
                )
            ))
            return nil
        }
        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? path
        let name = (dict["name"] as? String) ?? id
        let origin = transform.origin
        let scale = transform.scale
        let angles = transform.angles
        let visible = effectiveVisible ?? (parseBool(dict["visible"]) ?? true)
        let alphaValue = parseAnimatedScalar(dict["alpha"], fallback: 1)
        let color = parseVector3(dict["color"]) ?? SIMD3<Double>(1, 1, 1)
        // Generic object `brightness` — the same field image objects consume;
        // WPE applies it to particles too, so dropping it discarded authored
        // intensity.
        let brightness = parseDouble(dict["brightness"]) ?? 1.0
        let parallaxDepth = parseParallaxDepth(dict["parallaxDepth"] ?? dict["parallaxdepth"])
        let instanceOverride = parseParticleInstanceOverride(
            dict["instanceoverride"] ?? dict["instanceOverride"]
        )
        return WPESceneParticleObject(
            id: id,
            name: name,
            parentObjectID: parentID(in: dict),
            particleRelativePath: path,
            origin: origin,
            scale: scale,
            angles: angles,
            visible: visible,
            alpha: alphaValue.value,
            alphaAnimation: alphaValue.animation,
            color: color,
            brightness: brightness,
            parallaxDepth: parallaxDepth,
            instanceOverride: instanceOverride
        )
    }

    private static func parseParticleInstanceOverride(_ raw: Any?) -> WPESceneParticleInstanceOverride? {
        guard let dict = raw as? [String: Any] else { return nil }
        // WPE stores an override either as a bare value (`"lifetime": 0.66`)
        // or, when bound to a user-editable property, as a wrapper
        // `{ "user": "<prop>", "value": X }`. Unwrap `.value` first or the
        // user-bound overrides get silently dropped — that dropped debris
        // `rate` (→ over-dense) and wildfire `alpha` (→ over-bright) in
        // scene 3460973721.
        func unwrap(_ key: String) -> Any? {
            let v = dict[key]
            if let inner = (v as? [String: Any])?["value"] { return inner }
            return v
        }
        let value = WPESceneParticleInstanceOverride(
            count: parseDouble(unwrap("count")),
            rate: parseDouble(unwrap("rate")),
            lifetime: parseDouble(unwrap("lifetime")),
            size: parseDouble(unwrap("size")),
            speed: parseDouble(unwrap("speed")),
            alpha: parseDouble(unwrap("alpha")),
            brightness: parseDouble(unwrap("brightness")),
            color: parseNormalizedParticleColor(unwrap("colorn")) ?? parseVector3(unwrap("color")),
            alphaAnimation: WPEValueParser.animatedValue(dict["alpha"]),
            controlPointOffsets: parseInstanceControlPoints(dict)
        )
        return value.count == nil
            && value.rate == nil
            && value.lifetime == nil
            && value.size == nil
            && value.speed == nil
            && value.alpha == nil
            && value.brightness == nil
            && value.color == nil
            && value.alphaAnimation == nil
            && value.controlPointOffsets.isEmpty
            ? nil
            : value
    }

    /// `controlpoint1` … `controlpoint7` on a particle object's `instanceoverride`.
    /// WPE also writes `controlpointangleN`; those are orientations, not offsets,
    /// and nothing consumes an angle yet, so they stay unread on purpose.
    private static func parseInstanceControlPoints(_ dict: [String: Any]) -> [Int: SIMD3<Double>] {
        var offsets: [Int: SIMD3<Double>] = [:]
        for (key, raw) in dict {
            let lowered = key.lowercased()
            guard lowered.hasPrefix("controlpoint"),
                  !lowered.hasPrefix("controlpointangle"),
                  let index = Int(lowered.dropFirst("controlpoint".count)),
                  let offset = unwrapVector3(raw) else { continue }
            offsets[index] = offset
        }
        return offsets
    }

    private static func parseNormalizedParticleColor(_ raw: Any?) -> SIMD3<Double>? {
        guard let color = parseVector3(raw) else { return nil }
        return SIMD3<Double>(
            color.x * 255,
            color.y * 255,
            color.z * 255
        )
    }

    private static func objectKindResolution(for entry: [String: Any]) -> WPESceneObjectKindResolution {
        let candidates = shapeCandidates(in: entry)
        if let explicit = (entry["type"] as? String)?.lowercased(), !explicit.isEmpty {
            return WPESceneObjectKindResolution(
                primary: objectKind(explicitType: explicit),
                candidates: candidates,
                explicitType: explicit
            )
        }
        if candidates.contains(.image) {
            return WPESceneObjectKindResolution(primary: .image, candidates: candidates, explicitType: nil)
        }
        return WPESceneObjectKindResolution(primary: candidates.first ?? .unknown, candidates: candidates, explicitType: nil)
    }

    private static func objectKind(explicitType: String) -> WPESceneObjectKind {
        switch explicitType {
        case "image", "model": return .image
        case "sound": return .sound
        case "particle": return .particle
        case "text": return .text
        case "light": return .light
        default: return .unknown
        }
    }

    /// A JSON `null` bridges to `NSNull`, which is non-nil — so a bare
    /// `entry[key] != nil` classifies `{"image": null}` as image-kind. The
    /// object then parses to nothing AND skips the transform-host branch
    /// (gated on `primary != .image`), silently dropping any origin/scale/
    /// angles script or keyframe track it carried onto its descendants.
    private static func hasValue(_ entry: [String: Any], _ key: String) -> Bool {
        guard let value = entry[key] else { return false }
        return !(value is NSNull)
    }

    private static func shapeCandidates(in entry: [String: Any]) -> [WPESceneObjectKind] {
        var kinds: [WPESceneObjectKind] = []
        if hasValue(entry, "image") || hasValue(entry, "model") { kinds.append(.image) }
        // A `shape: "quad"` layer carries no image — it is a bare geometry surface
        // for a DIRECTDRAW effect (e.g. lightshafts light beams). Treat it as an
        // image-kind layer; `parseImageObject` synthesizes a transparent solid
        // base so the effect chain still renders.
        if isShapeQuadLayer(entry) { kinds.append(.image) }
        if hasValue(entry, "sound") { kinds.append(.sound) }
        if hasValue(entry, "particle") { kinds.append(.particle) }
        if hasValue(entry, "text") { kinds.append(.text) }
        if hasValue(entry, "light") { kinds.append(.light) }
        return kinds
    }

    /// True for a `shape: "quad"` object with no image/model of its own. WPE
    /// draws these as a 4-corner perspective quad fed by an effect's
    /// `EffectPerspectiveUV` points.
    private static func isShapeQuadLayer(_ entry: [String: Any]) -> Bool {
        guard entry["image"] == nil, entry["model"] == nil else { return false }
        return (entry["shape"] as? String)?.lowercased() == "quad"
    }

    // MARK: - Camera

    private static func parseCamera(
        _ dict: [String: Any],
        general: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneCamera {
        let center = parseVector3(dict["center"]) ?? WPESceneCamera.defaultCamera.center
        let eye = parseVector3(dict["eye"]) ?? WPESceneCamera.defaultCamera.eye
        let up = parseVector3(dict["up"]) ?? WPESceneCamera.defaultCamera.up
        let nearZ = parseDouble(dict["nearz"])
            ?? parseDouble(general["nearz"])
            ?? WPESceneCamera.defaultCamera.nearZ
        let farZ = parseDouble(dict["farz"])
            ?? parseDouble(general["farz"])
            ?? WPESceneCamera.defaultCamera.farZ
        let fov = parseDouble(dict["fov"])
            ?? parseDouble(general["fov"])
            ?? WPESceneCamera.defaultCamera.fov
        return WPESceneCamera(center: center, eye: eye, up: up, nearZ: nearZ, farZ: farZ, fov: fov)
    }

    private static func runtimeCameraObjectOverride(
        _ rawObjects: [[String: Any]],
        base: WPESceneCamera,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneCamera {
        guard let entry = rawObjects.first(where: { $0["camera"] is String }) else { return base }
        let origin = parseVector3(entry["origin"]) ?? .zero
        var fov = base.fov
        if let raw = entry["fov"] {
            if let dict = raw as? [String: Any], let value = parseDouble(dict["value"]) {
                fov = value
            } else if let value = parseDouble(raw) {
                fov = value
            }
        }
        if parseVector3(entry["angles"]) != nil {
            diagnostics.append(.init(
                severity: .warning,
                message: "Camera object declares angles — not applied (identity orientation assumed)"
            ))
        }
        return WPESceneCamera(
            center: origin + SIMD3<Double>(0, 0, -1),
            eye: origin,
            up: SIMD3<Double>(0, 1, 0),
            nearZ: base.nearZ,
            farZ: base.farZ,
            fov: fov
        )
    }

    // MARK: - General

    private static func authoredUserBindings(in raw: Any?) -> [WPESceneAuthoredUserBinding] {
        let specs = (try? userPropertyBindingSpecs(in: raw)) ?? []
        return specs.sorted { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return (lhs.condition ?? "") < (rhs.condition ?? "")
        }.map {
            WPESceneAuthoredUserBinding(propertyKey: $0.key, condition: $0.condition)
        }
    }

    private static func authoredScriptMetadata(
        authored raw: Any?,
        resolved: Any?
    ) -> (script: String?, properties: [String: WPESceneScriptPropertyValue]) {
        let rawEnvelope = raw as? [String: Any]
        let resolvedEnvelope = resolved as? [String: Any]
        return (
            script: nonEmptyString(rawEnvelope?["script"]),
            properties: scriptPropertyValues(
                resolvedEnvelope?["scriptproperties"] ?? rawEnvelope?["scriptproperties"]
            )
        )
    }

    private static func preservedDoubleField(
        authored raw: Any?,
        resolved: Any?,
        defaultValue: Double
    ) -> WPESceneAuthoredField<Double> {
        let metadata = authoredScriptMetadata(authored: raw, resolved: resolved)
        let seed = unwrapDouble(raw) ?? defaultValue
        return WPESceneAuthoredField(
            seed: seed,
            resolvedValue: unwrapDouble(resolved) ?? seed,
            isAuthored: raw != nil,
            userBindings: authoredUserBindings(in: raw),
            script: metadata.script,
            scriptProperties: metadata.properties
        )
    }

    private static func preservedBoolField(
        authored raw: Any?,
        resolved: Any?,
        defaultValue: Bool
    ) -> WPESceneAuthoredField<Bool> {
        let metadata = authoredScriptMetadata(authored: raw, resolved: resolved)
        let seed = parseBool(raw) ?? defaultValue
        return WPESceneAuthoredField(
            seed: seed,
            resolvedValue: parseBool(resolved) ?? seed,
            isAuthored: raw != nil,
            userBindings: authoredUserBindings(in: raw),
            script: metadata.script,
            scriptProperties: metadata.properties
        )
    }

    private static func preservedVector3Field(
        authored raw: Any?,
        resolved: Any?,
        defaultValue: SIMD3<Double>
    ) -> WPESceneAuthoredField<SIMD3<Double>> {
        let metadata = authoredScriptMetadata(authored: raw, resolved: resolved)
        let seed = unwrapVector3(raw) ?? defaultValue
        return WPESceneAuthoredField(
            seed: seed,
            resolvedValue: unwrapVector3(resolved) ?? seed,
            isAuthored: raw != nil,
            userBindings: authoredUserBindings(in: raw),
            script: metadata.script,
            scriptProperties: metadata.properties
        )
    }

    private static func parseGeneral(
        _ dict: [String: Any],
        authored rawDict: [String: Any],
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneGeneral {
        let clearColor = parseVector3(dict["clearcolor"]) ?? WPESceneGeneral.defaultGeneral.clearColor
        let projection: WPESceneOrthogonalProjection
        let usesPerspectiveProjection: Bool
        if let nested = dict["orthogonalprojection"] as? [String: Any] {
            let width = parseDouble(nested["width"]) ?? WPESceneGeneral.defaultGeneral.orthogonalProjection.width
            let height = parseDouble(nested["height"]) ?? WPESceneGeneral.defaultGeneral.orthogonalProjection.height
            let auto = (nested["auto"] as? Bool) ?? WPESceneGeneral.defaultGeneral.orthogonalProjection.auto
            projection = WPESceneOrthogonalProjection(width: width, height: height, auto: auto)
            usesPerspectiveProjection = false
        } else if dict.keys.contains("orthogonalprojection"),
                  dict["orthogonalprojection"] is NSNull {
            diagnostics.append(.init(
                severity: .info,
                message: String(
                    localized: "general.orthogonalprojection is null — using perspective camera with 1920×1080 render size",
                    defaultValue: "general.orthogonalprojection is null — using perspective camera with 1920×1080 render size",
                    comment: "Wallpaper Engine scene diagnostic when perspective projection is used."
                )
            ))
            projection = WPESceneGeneral.defaultGeneral.orthogonalProjection
            usesPerspectiveProjection = true
        } else {
            diagnostics.append(.init(
                severity: .info,
                message: String(
                    localized: "general.orthogonalprojection missing — using 1920×1080",
                    defaultValue: "general.orthogonalprojection missing — using 1920×1080",
                    comment: "Wallpaper Engine scene diagnostic when default projection dimensions are used."
                )
            ))
            projection = WPESceneGeneral.defaultGeneral.orthogonalProjection
            usesPerspectiveProjection = false
        }
        let parallaxDefaults = WPESceneCameraParallaxSettings.disabled
        let zoomField = preservedDoubleField(
            authored: rawDict["zoom"],
            resolved: dict["zoom"],
            defaultValue: WPESceneGeneral.defaultGeneral.zoom
        )
        let zoom = zoomField.resolvedValue
        if zoomField.isAuthored {
            diagnostics.append(.init(
                severity: .info,
                message: "general.zoom and its authored bindings are preserved as metadata; camera consumption awaits L1 validation"
            ))
        }
        let perspectiveOverrideFOV = preservedDoubleField(
            authored: rawDict["perspectiveoverridefov"],
            resolved: dict["perspectiveoverridefov"],
            defaultValue: 0
        )
        let cameraShake = WPESceneCameraShakeSettings(
            enabled: preservedBoolField(authored: rawDict["camerashake"], resolved: dict["camerashake"], defaultValue: false),
            amplitude: preservedDoubleField(authored: rawDict["camerashakeamplitude"], resolved: dict["camerashakeamplitude"], defaultValue: 0),
            speed: preservedDoubleField(authored: rawDict["camerashakespeed"], resolved: dict["camerashakespeed"], defaultValue: 0),
            roughness: preservedDoubleField(authored: rawDict["camerashakeroughness"], resolved: dict["camerashakeroughness"], defaultValue: 0)
        )
        let clearEnabled = preservedBoolField(
            authored: rawDict["clearenabled"],
            resolved: dict["clearenabled"],
            defaultValue: true
        )
        let wind = WPESceneWindSettings(
            enabled: preservedBoolField(authored: rawDict["windenabled"], resolved: dict["windenabled"], defaultValue: false),
            direction: preservedVector3Field(authored: rawDict["winddirection"], resolved: dict["winddirection"], defaultValue: SIMD3<Double>(0, 0, 1)),
            strength: preservedDoubleField(authored: rawDict["windstrength"], resolved: dict["windstrength"], defaultValue: 0)
        )
        let gravity = WPESceneGravitySettings(
            direction: preservedVector3Field(authored: rawDict["gravitydirection"], resolved: dict["gravitydirection"], defaultValue: SIMD3<Double>(0, -1, 0)),
            strength: preservedDoubleField(authored: rawDict["gravitystrength"], resolved: dict["gravitystrength"], defaultValue: 0)
        )
        let lightConfiguration = parseLightConfiguration(dict["lightconfig"])
        if perspectiveOverrideFOV.isAuthored {
            diagnostics.append(.init(
                severity: .info,
                message: "general.perspectiveoverridefov and its authored bindings are preserved; camera-domain consumption awaits L1 validation"
            ))
        }
        if [cameraShake.enabled.isAuthored, cameraShake.amplitude.isAuthored,
            cameraShake.speed.isAuthored, cameraShake.roughness.isAuthored].contains(true) {
            diagnostics.append(.init(
                severity: .info,
                message: "general.camerashake fields and authored bindings are preserved; camera jitter is not consumed without a continuous-frame L1 oracle"
            ))
        }
        if clearEnabled.isAuthored {
            diagnostics.append(.init(
                severity: .info,
                message: "general.clearenabled is preserved as metadata; render-pass clear consumption awaits L1 validation"
            ))
        }
        if [wind.enabled.isAuthored, wind.direction.isAuthored, wind.strength.isAuthored,
            gravity.direction.isAuthored, gravity.strength.isAuthored].contains(true) {
            diagnostics.append(.init(
                severity: .info,
                message: "general wind/gravity fields and authored bindings are preserved; particle/render consumption awaits L1 validation"
            ))
        }
        if rawDict["lightconfig"] != nil {
            diagnostics.append(.init(
                severity: .info,
                message: "general.lightconfig capacity counts are preserved; Metal light-array allocation and shadow passes await their L1 gates"
            ))
        }
        let cameraParallax = WPESceneCameraParallaxSettings(
            enabled: parseBool(dict["cameraparallax"]) ?? parallaxDefaults.enabled,
            amount: parseDouble(dict["cameraparallaxamount"]) ?? parallaxDefaults.amount,
            delay: parseDouble(dict["cameraparallaxdelay"]) ?? parallaxDefaults.delay,
            mouseInfluence: parseDouble(dict["cameraparallaxmouseinfluence"]) ?? parallaxDefaults.mouseInfluence
        )
        let supportsAudioProcessing = parseBool(dict["supportsaudioprocessing"]) ?? false
        let hdr = parseBool(dict["hdr"]) ?? false
        // v1 scope: HDR bloom only (the RenderDoc-verified pipeline). The SDR
        // bloom path (bloomstrength/bloomthreshold, quarter-res blur) differs
        // and stays unimplemented rather than approximated.
        var bloom: WPESceneBloomSettings?
        if hdr, parseBool(dict["bloom"]) == true {
            bloom = WPESceneBloomSettings(
                strength: unwrapDouble(dict["bloomhdrstrength"]) ?? 1,
                threshold: unwrapDouble(dict["bloomhdrthreshold"]) ?? 0.5,
                feather: unwrapDouble(dict["bloomhdrfeather"]) ?? 0.5,
                scatter: unwrapDouble(dict["bloomhdrscatter"]) ?? 1,
                iterations: parseInt(dict["bloomhdriterations"]) ?? 6,
                tint: parseVector3(dict["bloomtint"]) ?? SIMD3<Double>(1, 1, 1)
            )
        }
        return WPESceneGeneral(
            clearColor: clearColor,
            orthogonalProjection: projection,
            usesPerspectiveProjection: usesPerspectiveProjection,
            zoom: zoom,
            zoomField: zoomField,
            perspectiveOverrideFOV: perspectiveOverrideFOV,
            cameraShake: cameraShake,
            clearEnabled: clearEnabled,
            wind: wind,
            gravity: gravity,
            cameraParallax: cameraParallax,
            supportsAudioProcessing: supportsAudioProcessing,
            lightAmbientColor: parseVector3(dict["ambientcolor"])
                ?? WPESceneGeneral.defaultGeneral.lightAmbientColor,
            lightSkylightColor: parseVector3(dict["skylightcolor"])
                ?? WPESceneGeneral.defaultGeneral.lightSkylightColor,
            lightConfiguration: lightConfiguration,
            hdr: hdr,
            bloom: bloom
        )
    }

    private static func parseLightConfiguration(_ raw: Any?) -> WPESceneLightConfiguration {
        guard let dict = raw as? [String: Any] else { return .empty }
        return WPESceneLightConfiguration(
            directional: parseInt(dict["directional"]) ?? 0,
            directionalShadow: parseInt(dict["directionalshadow"]) ?? 0,
            point: parseInt(dict["point"]) ?? 0,
            pointShadow: parseInt(dict["pointshadow"]) ?? 0,
            spot: parseInt(dict["spot"]) ?? 0,
            spotShadow: parseInt(dict["spotshadow"]) ?? 0
        )
    }

    // MARK: - Image objects

    private static func parseImageObject(
        _ dict: [String: Any],
        transform: SceneObjectTransform,
        scriptOrigins: [String: SIMD3<Double>] = [:],
        effectiveVisible: Bool? = nil,
        inheritedAttachment: (name: String, parentID: String)? = nil,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> WPESceneImageObject? {
        // A `shape: "quad"` layer has no image; it renders a DIRECTDRAW effect on a
        // synthesized transparent solid base (the same builtin used for other
        // effect-only surfaces), so its effect chain still composites.
        let isShapeQuad = isShapeQuadLayer(dict)
        guard let imagePath = nonEmptyString(dict["image"]) ?? nonEmptyString(dict["model"])
            ?? (isShapeQuad ? "models/util/solidlayer.json" : nil) else {
            let objectName = dict["name"] as? String ?? "?"
            diagnostics.append(.init(
                severity: .warning,
                message: "Image/model object \(objectName) has no renderable resource path"
            ))
            return nil
        }

        let id = (dict["id"] as? String)
            ?? (dict["id"] as? Int).map(String.init)
            ?? (dict["name"] as? String)
            ?? imagePath
        let name = (dict["name"] as? String) ?? id
        let origin = transform.origin
        let scale = transform.scale
        let angles = transform.angles
        let local = localTransform(in: dict, scriptOrigins: scriptOrigins)
        let ownAttachment = nonEmptyString(dict["attachment"]) ?? nonEmptyString(dict["anchor"])
        let attachment = ownAttachment ?? inheritedAttachment?.name
        let parentObjectID = (ownAttachment == nil && inheritedAttachment != nil)
            ? inheritedAttachment?.parentID
            : parentID(in: dict)
        let visible = effectiveVisible ?? (parseBool(dict["visible"]) ?? true)
        let effects = parseImageEffects(dict["effects"], imageName: name, diagnostics: &diagnostics)
        let alphaFallback = imageAlphaFallback(
            imagePath: imagePath,
            rawAlpha: dict["alpha"],
            effects: effects,
            syntheticShapeBase: isShapeQuad
        )
        let alphaValue = parseAnimatedScalar(dict["alpha"], fallback: alphaFallback)
        let colorValue = parseAnimatedVector3(dict["color"], fallback: SIMD3<Double>(1, 1, 1))
        let brightness = parseDouble(dict["brightness"]) ?? 1.0
        // The perspective-quad corners a DIRECTDRAW effect draws through (lightshafts
        // `point0..3`). Also picks the additive scene composite WPE uses for these
        // beams (RenderDoc pass 65/66: SRC_ALPHA/ONE).
        let shapePoints = isShapeQuad ? shapeQuadPoints(in: effects) : nil
        let isShapeQuadBeam = isShapeQuad && shapePoints != nil
        let blend = isShapeQuadBeam
            ? WPESceneBlendMode.additive
            : parseImageBlendMode(dict)
        let colorBlendMode = isShapeQuadBeam ? 9 : parseColorBlendMode(dict)
        let alignment = WPESceneAlignment(rawWPEValue: dict["alignment"] as? String)
        let size: CGSize?
        if let vec = parseVector3(dict["size"]) {
            size = CGSize(width: vec.x, height: vec.y)
        } else {
            size = nil
        }

        let materialRelativePath = dict["material"] as? String
        let materialInstance = parseMaterialInstance(dict["instance"])
        let config = parseImageConfig(dict["config"])
        let disablePropagation = parseBool(dict["disablepropagation"]) ?? false
        let solid = parseBool(dict["solid"]) ?? false
        let copyBackground = parseBool(dict["copybackground"]) ?? true
        let dependencies = parseDependencyIDs(dict["dependencies"])
        let animationLayers = parseAnimationLayers(dict["animationlayers"], imageName: name, diagnostics: &diagnostics)
        let originScript = dynamicTransformScript(in: dict["origin"], preserveStaticallyResolvable: false)
        let scaleScript = dynamicTransformScript(in: dict["scale"], preserveStaticallyResolvable: true)
        let anglesScript = dynamicTransformScript(in: dict["angles"], preserveStaticallyResolvable: true)
        // Kept even when statically resolvable, for the same reason as scale and
        // angles: there is no parse-time bake path for color, so dropping a
        // "static" script would leave the layer on its authored value forever.
        let colorScript = dynamicTransformScript(in: dict["color"], preserveStaticallyResolvable: true)

        if !effects.isEmpty {
            let names = effects.map(\.name).joined(separator: ", ")
            diagnostics.append(.init(severity: .info, message: "Image \(name) declares effects (\(names)) — shader pipeline partially supported"))
        }
        if materialRelativePath != nil {
            diagnostics.append(.init(severity: .info, message: "Image \(name) declares material — rendered via the material shader pass"))
        }
        if materialInstance?.userTextures.isEmpty == false {
            diagnostics.append(.init(
                severity: .info,
                message: "Image \(name) declares dynamic instance user textures — preserved but awaiting a native provider"
            ))
        }
        if config.passthrough {
            diagnostics.append(.init(
                severity: .info,
                message: "Image \(name) declares config.passthrough — preserved as metadata; render-graph consumption awaits L1 validation"
            ))
        }
        if disablePropagation {
            diagnostics.append(.init(
                severity: .info,
                message: "Image \(name) declares disablepropagation — preserved as metadata; parallax-hierarchy consumption awaits L1 validation"
            ))
        }
        if !animationLayers.isEmpty {
            diagnostics.append(.init(severity: .info, message: "Image \(name) declares animationlayers — rendered by the puppet warp system"))
        }
        if imagePath.lowercased().hasSuffix(".tex") {
            diagnostics.append(.init(severity: .warning, message: "Image \(name) uses .tex texture — falls back to first-frame stub if available"))
        }

        let parallaxDepth = parseParallaxDepth(dict["parallaxDepth"] ?? dict["parallaxdepth"])

        // A `visible` field that is a script-dict carries a WPE SceneScript that
        // drives the layer's visibility/alpha (and any video texture) per frame —
        // e.g. an intro video that plays once then hides. Capture it; the layer
        // stays renderable (visible defaults true above) until init()/update() run.
        var visibleScript: String?
        var visibleScriptProperties: [String: WPESceneScriptPropertyValue] = [:]
        if let visibleDict = dict["visible"] as? [String: Any],
           let script = visibleDict["script"] as? String, !script.isEmpty {
            visibleScript = script
            visibleScriptProperties = scriptPropertyValues(visibleDict["scriptproperties"])
            diagnostics.append(.init(severity: .info, message: "Image \(name) has a visible-script; runs as a layer SceneScript"))
        }
        var alphaScript: String?
        var alphaScriptProperties: [String: WPESceneScriptPropertyValue] = [:]
        if let alphaDict = dict["alpha"] as? [String: Any],
           let script = alphaDict["script"] as? String, !script.isEmpty {
            alphaScript = script
            alphaScriptProperties = scriptPropertyValues(alphaDict["scriptproperties"])
            diagnostics.append(.init(severity: .info, message: "Image \(name) has an alpha-script; runs as a layer SceneScript"))
        }

        return WPESceneImageObject(
            id: id,
            name: name,
            imageRelativePath: imagePath,
            materialRelativePath: materialRelativePath,
            materialInstance: materialInstance,
            config: config,
            disablePropagation: disablePropagation,
            solid: solid,
            copyBackground: copyBackground,
            parentObjectID: parentObjectID,
            attachment: attachment,
            origin: origin,
            scale: scale,
            angles: angles,
            localOrigin: local.origin,
            localScale: local.scale,
            localAngles: local.angles,
            visible: visible,
            alpha: alphaValue.value,
            alphaAnimation: alphaValue.animation,
            color: colorValue.value,
            colorAnimation: colorValue.animation,
            brightness: brightness,
            blendMode: blend,
            colorBlendMode: colorBlendMode,
            alignment: alignment,
            size: size,
            dependencies: dependencies,
            effects: effects,
            animationLayers: animationLayers,
            parallaxDepth: parallaxDepth,
            visibleScript: visibleScript,
            alphaScript: alphaScript,
            alphaScriptProperties: alphaScriptProperties,
            originScript: originScript,
            scaleScript: scaleScript,
            anglesScript: anglesScript,
            colorScript: colorScript,
            scriptProperties: visibleScriptProperties,
            shapePoints: shapePoints
        )
    }

    /// Extracts the four `point0..3` perspective corners from the first effect
    /// pass that declares a complete set (the `EffectPerspectiveUV` gizmo WPE uses
    /// for lightshafts / directdraw quads). Returns `nil` when no effect supplies them.
    private static func shapeQuadPoints(in effects: [WPESceneImageEffect]) -> [SIMD2<Double>]? {
        for effect in effects where effect.visible {
            for override in effect.passOverrides {
                var points: [SIMD2<Double>] = []
                for index in 0..<4 {
                    guard let vector = override.constants["point\(index)"]?.vectorValue,
                          vector.count >= 2 else {
                        points = []
                        break
                    }
                    points.append(SIMD2<Double>(vector[0], vector[1]))
                }
                if points.count == 4 { return points }
            }
        }
        return nil
    }

    private static func imageAlphaFallback(
        imagePath: String,
        rawAlpha: Any?,
        effects: [WPESceneImageEffect],
        syntheticShapeBase: Bool = false
    ) -> Double {
        // A synthesized `shape:"quad"` base has no image of its own — it only
        // exists to carry a DIRECTDRAW effect. Keep it transparent even when the
        // effect is missing/invisible or its points didn't parse, so a bare or
        // broken shape quad draws nothing instead of an opaque solid rectangle.
        if syntheticShapeBase, rawAlpha == nil {
            return 0
        }
        guard rawAlpha == nil,
              effects.contains(where: \.visible) else {
            return 1
        }

        switch imagePath.lowercased() {
        case "models/util/solidlayer.json", "models/util/solidlayer_depthtest.json":
            // Solid layers are commonly used as transparent effect surfaces. If
            // the scene did not author an alpha, keep the base transparent so the
            // effect draws its own alpha instead of filling the target rectangle.
            return 0
        default:
            return 1
        }
    }

    /// Raw `common_blending.h` BLENDMODE index (0 = normal). A `blendmode`
    /// string, when present, wins and is re-expressed as its numeric equivalent
    /// so the render graph only ever reasons about one representation.
    static func parseColorBlendMode(_ dict: [String: Any]) -> Int {
        if let rawBlend = dict["blendmode"] as? String {
            switch WPESceneBlendMode(rawWPEValue: rawBlend) {
            case .multiply: return 2
            case .screen:   return 7
            case .additive: return 9
            // `translucent` has no BLENDMODE peer — it is a plain alpha-over
            // that the fixed-function path already covers.
            case .normal, .translucent: return 0
            }
        }
        return parseInt(dict["colorBlendMode"] ?? dict["colorblendmode"]) ?? 0
    }

    /// The fixed-function approximation used for the layer's own draw. Modes
    /// that need the destination resolve to `.normal` here and are routed
    /// through the programmable composite by the render-graph builder, which
    /// reads `colorBlendMode` — never assume this alone reproduces the blend.
    private static func parseImageBlendMode(_ dict: [String: Any]) -> WPESceneBlendMode {
        if let rawBlend = dict["blendmode"] as? String {
            return WPESceneBlendMode(rawWPEValue: rawBlend)
        }
        return WPESceneBlendMode.fixedFunction(forWPEBlendMode: parseColorBlendMode(dict)) ?? .normal
    }

    private static func parseAnimatedVector3(
        _ raw: Any?,
        fallback: SIMD3<Double>
    ) -> (value: SIMD3<Double>, animation: WPESceneAnimatedValue?) {
        guard case .animated(let animated)? = WPEValueParser.shaderConstant(raw) else {
            return (parseVector3(raw) ?? fallback, nil)
        }
        // Seed from the authored static `value` (WPE's own preview value) so a
        // frame rendered before the timeline ticks matches the editor.
        let seed = animated.vectorFallback ?? animated.vector(at: 0)
        guard let seed, seed.count >= 3 else {
            return (fallback, animated)
        }
        return (SIMD3<Double>(seed[0], seed[1], seed[2]), animated)
    }

    private static func dynamicTransformScript(
        in raw: Any?,
        preserveStaticallyResolvable: Bool
    ) -> WPESceneTransformScript? {
        guard let transform = raw as? [String: Any],
              let script = transform["script"] as? String, !script.isEmpty,
              preserveStaticallyResolvable || !WPETransformScriptStaticAnalysis.isStaticallyResolvable(script) else {
            return nil
        }
        let seed = parseVector3(resolveBoundTransformValue(transform["value"])) ?? SIMD3<Double>(0, 0, 0)
        return WPESceneTransformScript(
            script: script,
            scriptProperties: scriptPropertyValues(transform["scriptproperties"]),
            seed: seed
        )
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDependencyIDs(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for value in array {
            let id: String?
            if let string = value as? String, !string.isEmpty {
                id = string
            } else if let int = parseInt(value) {
                id = String(int)
            } else {
                id = nil
            }
            guard let id, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    private static func parseImageEffects(
        _ raw: Any?,
        imageName: String,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> [WPESceneImageEffect] {
        guard let array = raw as? [Any] else { return [] }
        var effects: [WPESceneImageEffect] = []
        for (index, entry) in array.enumerated() {
            guard let dict = entry as? [String: Any] else {
                diagnostics.append(.init(severity: .warning, message: "Image \(imageName) effect \(index) is malformed"))
                continue
            }
            guard let file = dict["file"] as? String, !file.isEmpty else {
                diagnostics.append(.init(severity: .warning, message: "Image \(imageName) effect \(index) has no file"))
                continue
            }
            let id = (dict["id"] as? String)
                ?? parseInt(dict["id"]).map(String.init)
                ?? "\(index)"
            let name = (dict["name"] as? String) ?? effectName(from: file)
            // `visible` may be a bare Bool or a `{value, script}` envelope. Reading
            // it with a plain `parseBool` returned nil for the envelope form and
            // silently defaulted to shown — so an effect authored hidden with a
            // script bound to it rendered anyway.
            let visibleEnvelope = dict["visible"] as? [String: Any]
            let visibleSeed = parseBool(dict["visible"])
                ?? visibleEnvelope.flatMap { parseBool($0["value"]) }
                ?? true
            var visibleScript: WPESceneTransformScript?
            if let visibleEnvelope,
               let script = visibleEnvelope["script"] as? String, !script.isEmpty {
                visibleScript = WPESceneTransformScript(
                    script: script,
                    scriptProperties: scriptPropertyValues(visibleEnvelope["scriptproperties"]),
                    seed: SIMD3<Double>(visibleSeed ? 1 : 0, 0, 0)
                )
            }
            effects.append(WPESceneImageEffect(
                id: id,
                name: name,
                fileRelativePath: file,
                visible: visibleSeed,
                passOverrides: parseEffectPassOverrides(dict["passes"]),
                visibleScript: visibleScript
            ))
        }
        return effects
    }

    private static func parseEffectPassOverrides(_ raw: Any?) -> [WPESceneEffectPassOverride] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            return WPESceneEffectPassOverride(
                id: parseInt(dict["id"]),
                combos: parseComboMap(dict["combos"]),
                constants: parseShaderConstants(dict["constantshadervalues"]),
                textures: parseTextureSlots(dict["textures"]),
                userTextures: parseUserTextureBindings(dict["usertextures"]),
                constantScripts: parseConstantScripts(dict["constantshadervalues"])
            )
        }
    }

    /// WPE applies `objects[].instance` after loading the base image material.
    /// Null/blank texture slots are sparse no-ops, while combo values overwrite
    /// the matching compiled-shader switch. Preserve dynamic user-texture
    /// bindings even though their provider is a separate runtime concern.
    private static func parseMaterialInstance(_ raw: Any?) -> WPESceneMaterialInstance? {
        guard let dict = raw as? [String: Any] else { return nil }
        let userTextures = parseUserTextureBindings(dict["usertextures"])
        return WPESceneMaterialInstance(
            id: parseInt(dict["id"]),
            combos: parseComboMap(dict["combos"]),
            textures: parseTextureSlots(dict["textures"]),
            userTextures: userTextures
        )
    }

    private static func parseUserTextureBindings(_ raw: Any?) -> [WPESceneUserTextureBinding] {
        (raw as? [Any] ?? []).compactMap { raw in
            if let name = nonEmptyString(raw) {
                return WPESceneUserTextureBinding(name: name)
            }
            guard let entry = raw as? [String: Any],
                  let name = nonEmptyString(entry["name"]) else { return nil }
            return WPESceneUserTextureBinding(
                name: name,
                type: nonEmptyString(entry["type"])
            )
        }
    }

    /// Preserve image config independently of render-graph behavior. In
    /// particular, `passthrough` must not change pass topology until an L1
    /// mutation capture establishes its exact composition semantics.
    private static func parseImageConfig(_ raw: Any?) -> WPESceneImageConfig {
        guard let dict = raw as? [String: Any] else { return WPESceneImageConfig() }
        return WPESceneImageConfig(
            passthrough: parseBool(dict["passthrough"]) ?? false
        )
    }

    /// SceneScripts bound to individual shader constants. Kept even when the body
    /// looks statically resolvable: there is no parse-time bake path for a shader
    /// uniform, so dropping one would freeze the pass at its authored seed.
    /// The seed itself comes from the sibling `value`, widened to a Vec3 so the
    /// runtime can drive scalars, Vec2s and Vec3s through one engine.
    private static func parseConstantScripts(
        _ raw: Any?
    ) -> [String: WPESceneTransformScript] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var scripts: [String: WPESceneTransformScript] = [:]
        for (name, entry) in dict {
            guard let entry = entry as? [String: Any],
                  let script = entry["script"] as? String, !script.isEmpty else { continue }
            let seed = parseVector3(entry["value"])
                ?? (parseDouble(entry["value"]).map { SIMD3<Double>($0, $0, $0) })
                ?? SIMD3<Double>(0, 0, 0)
            scripts[name] = WPESceneTransformScript(
                script: script,
                scriptProperties: scriptPropertyValues(entry["scriptproperties"]),
                seed: seed
            )
        }
        return scripts
    }

    private static func parseAnimationLayers(
        _ raw: Any?,
        imageName: String,
        diagnostics: inout [WPESceneDiagnostic]
    ) -> [WPESceneAnimationLayer] {
        guard let array = raw as? [Any] else { return [] }
        var layers: [WPESceneAnimationLayer] = []
        for (index, entry) in array.enumerated() {
            guard let dict = entry as? [String: Any],
                  let id = parseInt(dict["id"]),
                  let animation = parseInt(dict["animation"]) else {
                diagnostics.append(.init(severity: .warning, message: "Image \(imageName) animation layer \(index) is malformed"))
                continue
            }
            layers.append(WPESceneAnimationLayer(
                id: id,
                rate: parseDouble(dict["rate"]) ?? 0,
                visible: parseBool(dict["visible"]) ?? true,
                blend: parseDouble(dict["blend"]) ?? 1,
                animation: animation,
                additive: parseBool(dict["additive"]) ?? false
            ))
        }
        return layers
    }

    private static func parseComboMap(_ raw: Any?) -> [String: Int] {
        WPEValueParser.comboMap(raw)
    }

    private static func parseShaderConstants(_ raw: Any?) -> [String: WPESceneShaderConstantValue] {
        WPEValueParser.shaderConstants(raw)
    }

    private static func parseTextureSlots(_ raw: Any?) -> [Int: String] {
        guard let array = raw as? [Any] else { return [:] }
        var result: [Int: String] = [:]
        for (index, value) in array.enumerated() {
            if let string = parseTextureSlotPath(value) {
                result[index] = string
            }
        }
        return result
    }

    /// Effect texture arrays mix plain path strings with structured entries
    /// (`{"name": "masks/pulse__mask_…"}` — how per-instance opacity masks are
    /// declared). Resolve both; `NSNull` / empty slots return nil.
    private static func parseTextureSlotPath(_ raw: Any?) -> String? {
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let dict = raw as? [String: Any] else { return nil }
        for key in ["value", "name", "texture", "path", "file"] {
            if let parsed = parseTextureSlotPath(dict[key]) {
                return parsed
            }
        }
        return nil
    }

    /// Iterates `constantshadervalues` in either of WPE's two forms (plain
    /// dict, or structured array of `{name:…, value:…|default:…}` entries).
    private static func forEachShaderConstant(
        in raw: Any?,
        _ body: (String, Any) -> Void
    ) {
        if let dict = raw as? [String: Any] {
            for (name, value) in dict {
                body(name, value)
            }
            return
        }
        guard let array = raw as? [Any] else { return }
        for entry in array {
            guard let dict = entry as? [String: Any],
                  let name = WPEValueParser.shaderConstantEntryName(in: dict) else { continue }
            if dict.keys.contains("value") {
                body(name, dict["value"] ?? NSNull())
            } else if dict.keys.contains("default") {
                body(name, dict["default"] ?? NSNull())
            }
        }
    }

    private static func effectName(from file: String) -> String {
        let pieces = file.split(separator: "/")
        if pieces.count >= 2 {
            return String(pieces[pieces.count - 2])
        }
        return file
    }

    // MARK: - Primitive parsing

    /// Accepts JSON arrays of numbers, JSON dictionaries with x/y/z keys, or WPE's space-separated strings ("0.5 0 0").
    public static func parseVector3(_ raw: Any?) -> SIMD3<Double>? {
        WPEValueParser.vector3(raw)
    }

    static func parseDouble(_ raw: Any?) -> Double? {
        WPEValueParser.double(raw)
    }

    /// WPE stores object `parallaxDepth` as a PER-AXIS vector string ("x y"),
    /// not a scalar — e.g. "1.000 1.000". A plain `parseDouble` returns nil for
    /// that (Swift's `Double(_:)` rejects the embedded space), so every object's
    /// depth silently fell back to 0 and the camera-parallax pipeline received
    /// all-zero depths → no layer ever shifted with the cursor. WPE supports
    /// per-axis depth ("1 0" = horizontal-only, "0 1" = vertical-only), so keep
    /// both axes rather than collapsing to one. A bare scalar maps to both axes;
    /// a `{ "user", "value" }` wrapper is unwrapped; absent → `.zero` (pinned).
    static func parseParallaxDepth(_ raw: Any?) -> SIMD2<Double> {
        if let dict = raw as? [String: Any], let value = dict["value"] {
            return parseParallaxDepth(value)
        }
        if let vector = parseVector3(raw) { return SIMD2<Double>(vector.x, vector.y) }
        if let scalar = parseDouble(raw) { return SIMD2<Double>(scalar, scalar) }
        return SIMD2<Double>(0, 0)
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        WPEValueParser.int(raw)
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        // Property-bound visibility stores the resolved boolean in the envelope's `value` field.
        if let dict = raw as? [String: Any], let value = dict["value"] {
            return parseBool(value)
        }
        return WPEValueParser.bool(raw)
    }
}

private struct SceneObjectTransform {
    let origin: SIMD3<Double>
    let scale: SIMD3<Double>
    let angles: SIMD3<Double>

    static let identity = SceneObjectTransform(
        origin: SIMD3<Double>(0, 0, 0),
        scale: SIMD3<Double>(1, 1, 1),
        angles: SIMD3<Double>(0, 0, 0)
    )

    func combining(child: SceneObjectTransform) -> SceneObjectTransform {
        let scaled = SIMD3<Double>(
            child.origin.x * scale.x,
            child.origin.y * scale.y,
            child.origin.z * scale.z
        )
        let rotated = Self.rotate(scaled, by: angles)

        return SceneObjectTransform(
            origin: SIMD3<Double>(
                origin.x + rotated.x,
                origin.y + rotated.y,
                origin.z + rotated.z
            ),
            scale: SIMD3<Double>(
                scale.x * child.scale.x,
                scale.y * child.scale.y,
                scale.z * child.scale.z
            ),
            angles: angles + child.angles
        )
    }

    private static func rotate(_ value: SIMD3<Double>, by angles: SIMD3<Double>) -> SIMD3<Double> {
        var result = value

        if angles.x != 0 {
            let c = cos(angles.x)
            let s = sin(angles.x)
            result = SIMD3<Double>(
                result.x,
                result.y * c - result.z * s,
                result.y * s + result.z * c
            )
        }
        if angles.y != 0 {
            let c = cos(angles.y)
            let s = sin(angles.y)
            result = SIMD3<Double>(
                result.x * c + result.z * s,
                result.y,
                -result.x * s + result.z * c
            )
        }
        if angles.z != 0 {
            let c = cos(angles.z)
            let s = sin(angles.z)
            result = SIMD3<Double>(
                result.x * c - result.y * s,
                result.x * s + result.y * c,
                result.z
            )
        }

        return result
    }
}
