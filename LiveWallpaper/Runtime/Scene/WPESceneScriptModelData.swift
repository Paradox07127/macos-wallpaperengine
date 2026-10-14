#if !LITE_BUILD
import Foundation
import JavaScriptCore

/// IModelData vertex components; raw values are the script-visible `IModelData.POSITION`… strings.
enum WPESceneScriptVertexAttribute: String, Sendable, Equatable, CaseIterable {
    case position
    case normal
    case tangentSigned
    case uv
    case color

    var floatCount: Int {
        switch self {
        case .position, .normal: 3
        case .tangentSigned, .color: 4
        case .uv: 2
        }
    }

    fileprivate var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

struct WPESceneScriptModelShapeSnapshot: Sendable, Equatable {
    /// Ordered subset of position/normal/tangentSigned/uv/color, never reordered.
    var vertexFormat: [WPESceneScriptVertexAttribute]
    var floatsPerVertex: Int
    /// Interleaved in `vertexFormat` order; positions are scene pixels.
    var vertices: [Float]
    /// Empty = non-indexed triangle list.
    var indices: [UInt32]
    /// Registered material asset; nil when the shape names none or the bridge did not admit it.
    var materialPath: String?
}

/// Geometry of one script-created model layer, as the renderer reads it.
struct WPESceneScriptModelSnapshot: Sendable, Equatable {
    var modelID: Int
    var shapes: [WPESceneScriptModelShapeSnapshot]
    var perspective: Bool
}

/// One bridge's model data and created-layer bindings, journaled as a single value.
struct WPESceneScriptModelLayerState: Sendable {
    private(set) var models: [Int: [WPESceneScriptModelShapeSnapshot]] = [:]
    /// destroyModelData on a model a live layer still uses; dropped with its last layer.
    private var destroyedModels: Set<Int> = []
    /// Created-layer key → model id.
    private var layerModels: [String: Int] = [:]
    /// Created-layer key → parent object id.
    var layerParents: [String: String] = [:]
    /// Survives rollback so a handle minted in a failed entry never aliases a later model.
    private var nextModelID = 0

    func isLive(_ id: Int) -> Bool {
        models[id] != nil && !destroyedModels.contains(id)
    }

    mutating func addModel(_ shapes: [WPESceneScriptModelShapeSnapshot]) -> Int {
        let id = nextModelID
        nextModelID += 1
        models[id] = shapes
        return id
    }

    mutating func setShapes(_ shapes: [WPESceneScriptModelShapeSnapshot], for id: Int) {
        models[id] = shapes
    }

    mutating func bind(layer key: String, to id: Int) {
        layerModels[key] = id
    }

    mutating func destroyModel(_ id: Int) {
        guard models[id] != nil else { return }
        if layerModels.values.contains(id) {
            destroyedModels.insert(id)
        } else {
            models[id] = nil
        }
    }

    mutating func removeLayers(_ keys: Set<String>) {
        for key in keys {
            layerParents[key] = nil
            guard let id = layerModels.removeValue(forKey: key),
                  destroyedModels.contains(id), !layerModels.values.contains(id) else { continue }
            models[id] = nil
            destroyedModels.remove(id)
        }
    }

    mutating func rollBack(to previous: Self) {
        let next = nextModelID
        self = previous
        nextModelID = next
    }

    func snapshot(forLayer key: String, perspective: Bool) -> WPESceneScriptModelSnapshot? {
        guard let id = layerModels[key], let shapes = models[id] else { return nil }
        return WPESceneScriptModelSnapshot(modelID: id, shapes: shapes, perspective: perspective)
    }
}

extension WPELayerScriptBridge {
    private static let assetPathKey = "__assetPath"
    private static let modelDataIDKey = "__modelDataID"

    /// engine.registerAsset plus thisScene.createModelData/destroyModelData.
    func installModelDataAPI(on scene: JSValue, in context: JSContext) {
        let registerAsset: @convention(block) (JSValue) -> JSValue? = { [weak context] path in
            guard let context else { return nil }
            guard path.isString, let text = path.toString(), let handle = JSValue(newObjectIn: context) else {
                wpeRaiseModelDataError("registerAsset requires an asset path")
                return nil
            }
            handle.setObject(text, forKeyedSubscript: Self.assetPathKey as NSString)
            return handle
        }
        if let engine = context.objectForKeyedSubscript("engine"), engine.isObject {
            engine.setObject(registerAsset, forKeyedSubscript: "registerAsset" as NSString)
        }
        let createModelData: @convention(block) (JSValue) -> JSValue? = { [weak self, weak context] configuration in
            guard let self, let context else { return nil }
            do throws(WPESceneScriptModelDataError) {
                guard configuration.isObject, let configs = Self.elements(configuration.objectForKeyedSubscript("shapes")),
                      !configs.isEmpty else {
                    throw WPESceneScriptModelDataError("createModelData requires a non-empty shapes array")
                }
                var shapes: [WPESceneScriptModelShapeSnapshot] = []
                for config in configs {
                    guard let config else { throw WPESceneScriptModelDataError("createModelData shape must be an object") }
                    try shapes.append(parsedShape(config, base: nil))
                }
                return makeModelDataHandle(id: modelLayers.addModel(shapes), in: context)
            } catch {
                wpeRaiseModelDataError(error.message)
                return nil
            }
        }
        scene.setObject(createModelData, forKeyedSubscript: "createModelData" as NSString)
        let destroyModelData: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let id = modelDataID(value) else { return }
            modelLayers.destroyModel(id)
        }
        scene.setObject(destroyModelData, forKeyedSubscript: "destroyModelData" as NSString)
    }

    /// Live model id for a bare IModelData or `{model: IModelData}` createLayer argument.
    func createdLayerModelID(_ spec: JSValue) -> Int? {
        guard spec.isObject else { return nil }
        return modelDataID(spec) ?? spec.objectForKeyedSubscript("model").flatMap(modelDataID)
    }

    /// Asset path of a bare IAssetHandle or `{model: IAssetHandle}` createLayer argument.
    func createdLayerAssetPath(_ spec: JSValue) -> String? {
        guard spec.isObject else { return nil }
        return Self.assetPath(spec) ?? spec.objectForKeyedSubscript("model").flatMap(Self.assetPath)
    }

    /// With a load-time bridge, every shape's material must be in its registered subset.
    func admitsModelLayer(_ id: Int) -> Bool {
        guard createdLayerBridge != nil else { return true }
        return modelLayers.models[id]?.allSatisfy { $0.materialPath != nil } == true
    }

    func installParentSetter(on handle: JSValue, key: String, isCreated: Bool) {
        let setParent: @convention(block) (JSValue, JSValue) -> Void = { [weak self] parent, adjustTransforms in
            guard let self else { return }
            guard isCreated else {
                reportUnsupportedLayerOperation("setParent supports script-created layers only")
                return
            }
            guard !adjustTransforms.toBool() else {
                reportUnsupportedLayerOperation("setParent with adjustTransforms is not supported")
                return
            }
            if parent.isUndefined || parent.isNull {
                modelLayers.layerParents[key] = nil
                return
            }
            guard let parentKey = layerKey(parent), let info = layerInfo(forKey: parentKey) else {
                reportUnsupportedLayerOperation("setParent requires an authored scene layer as parent")
                return
            }
            modelLayers.layerParents[key] = info.id
        }
        handle.setObject(setParent, forKeyedSubscript: "setParent" as NSString)
    }

    private func makeModelDataHandle(id: Int, in context: JSContext) -> JSValue? {
        guard let handle = JSValue(newObjectIn: context) else { return nil }
        handle.setObject(id, forKeyedSubscript: Self.modelDataIDKey as NSString)
        let applyData: @convention(block) (JSValue) -> Void = { [weak self] shapes in
            self?.updateModelData(id: id, shapes, replacing: false)
        }
        let replaceData: @convention(block) (JSValue) -> Void = { [weak self] shapes in
            self?.updateModelData(id: id, shapes, replacing: true)
        }
        handle.setObject(applyData, forKeyedSubscript: "applyData" as NSString)
        handle.setObject(replaceData, forKeyedSubscript: "replaceData" as NSString)
        return handle
    }

    private func modelDataID(_ value: JSValue) -> Int? {
        guard value.isObject, let raw = value.objectForKeyedSubscript(Self.modelDataIDKey), raw.isNumber else { return nil }
        let id = Int(raw.toInt32())
        return modelLayers.isLive(id) ? id : nil
    }

    private static func assetPath(_ value: JSValue) -> String? {
        guard value.isObject, let path = value.objectForKeyedSubscript(assetPathKey), path.isString else { return nil }
        return path.toString()
    }

    private func updateModelData(id: Int, _ argument: JSValue, replacing: Bool) {
        do throws(WPESceneScriptModelDataError) {
            if replacing, isInsideUpdate {
                throw WPESceneScriptModelDataError("replaceData must not be called from update(); use applyData")
            }
            guard modelLayers.isLive(id), let existing = modelLayers.models[id] else {
                throw WPESceneScriptModelDataError("IModelData was destroyed")
            }
            let configs: [JSValue?]
            if let shapes = Self.elements(argument) {
                configs = shapes
            } else if argument.isObject, let shapes = Self.elements(argument.objectForKeyedSubscript("shapes")) {
                configs = shapes
            } else if argument.isObject {
                configs = [argument]
            } else {
                throw WPESceneScriptModelDataError("model data must be a shape object or an array of shapes")
            }
            let shapes = try replacing ? replacedShapes(existing, with: configs) : appliedShapes(existing, with: configs)
            modelLayers.setShapes(shapes, for: id)
        } catch {
            wpeRaiseModelDataError(error.message)
        }
    }

    /// Same lengths and formats only; options the caller omits stay as they are.
    private func appliedShapes(
        _ existing: [WPESceneScriptModelShapeSnapshot],
        with configs: [JSValue?]
    ) throws(WPESceneScriptModelDataError) -> [WPESceneScriptModelShapeSnapshot] {
        var shapes = existing
        for (index, config) in configs.enumerated() {
            guard let config, !config.isUndefined else { continue }
            guard config.isObject, shapes.indices.contains(index) else {
                throw WPESceneScriptModelDataError("applyData takes shape objects for existing shapes only")
            }
            if let value = Self.defined(config, "vertexBuffer") {
                guard let vertices = Self.floats(value), vertices.count == shapes[index].vertices.count else {
                    throw WPESceneScriptModelDataError("applyData vertexBuffer must be a Float32Array of the same length")
                }
                shapes[index].vertices = vertices
            }
            if let value = Self.defined(config, "indexBuffer") {
                guard let indices = Self.indices(value), indices.count == shapes[index].indices.count else {
                    throw WPESceneScriptModelDataError("applyData indexBuffer must keep its length")
                }
                shapes[index].indices = indices
                try Self.validate(shapes[index])
            }
        }
        return shapes
    }

    /// A null shape deletes it; shapes past the end are added from a full configuration.
    private func replacedShapes(
        _ existing: [WPESceneScriptModelShapeSnapshot],
        with configs: [JSValue?]
    ) throws(WPESceneScriptModelDataError) -> [WPESceneScriptModelShapeSnapshot] {
        var shapes: [WPESceneScriptModelShapeSnapshot?] = existing
        for (index, config) in configs.enumerated() {
            if let config, config.isUndefined {
                continue
            }
            while shapes.count <= index {
                shapes.append(nil)
            }
            guard let config, !config.isNull else {
                shapes[index] = nil
                continue
            }
            shapes[index] = try parsedShape(config, base: existing.indices.contains(index) ? existing[index] : nil)
        }
        return shapes.compactMap(\.self)
    }

    private func parsedShape(
        _ config: JSValue,
        base: WPESceneScriptModelShapeSnapshot?
    ) throws(WPESceneScriptModelDataError) -> WPESceneScriptModelShapeSnapshot {
        guard config.isObject else { throw WPESceneScriptModelDataError("model shape must be an object") }
        let format: [WPESceneScriptVertexAttribute]
        if let value = Self.defined(config, "vertexFormat") {
            format = try Self.vertexFormat(value)
        } else if let base {
            format = base.vertexFormat
        } else {
            throw WPESceneScriptModelDataError("model shape requires a vertexFormat")
        }
        let vertices: [Float]
        if let value = Self.defined(config, "vertexBuffer") {
            guard let floats = Self.floats(value) else {
                throw WPESceneScriptModelDataError("vertexBuffer must be a Float32Array")
            }
            vertices = floats
        } else if let base {
            vertices = base.vertices
        } else {
            throw WPESceneScriptModelDataError("model shape requires a vertexBuffer")
        }
        var indices = base?.indices ?? []
        if let value = config.objectForKeyedSubscript("indexBuffer"), !value.isUndefined {
            guard value.isNull || Self.indices(value) != nil else {
                throw WPESceneScriptModelDataError("indexBuffer must be a Uint16Array or Uint32Array")
            }
            indices = Self.indices(value) ?? []
        }
        var materialPath = base?.materialPath
        if let value = Self.defined(config, "material") {
            materialPath = resolvedMaterialPath(value)
        }
        let shape = WPESceneScriptModelShapeSnapshot(
            vertexFormat: format,
            floatsPerVertex: format.reduce(0) { $0 + $1.floatCount },
            vertices: vertices,
            indices: indices,
            materialPath: materialPath
        )
        try Self.validate(shape)
        return shape
    }

    private func resolvedMaterialPath(_ value: JSValue) -> String? {
        guard let path = Self.assetPath(value) ?? (value.isString ? value.toString() : nil) else { return nil }
        guard let createdLayerBridge else { return path }
        return createdLayerBridge.resolvedMaterialPath(path, workshopID: scriptWorkshopID)
    }

    private static func validate(_ shape: WPESceneScriptModelShapeSnapshot) throws(WPESceneScriptModelDataError) {
        guard shape.vertices.count.isMultiple(of: shape.floatsPerVertex) else {
            throw WPESceneScriptModelDataError("vertexBuffer length is not a whole number of vertices")
        }
        let vertexCount = shape.vertices.count / shape.floatsPerVertex
        if shape.indices.isEmpty {
            guard vertexCount.isMultiple(of: 3) else {
                throw WPESceneScriptModelDataError("non-indexed vertexBuffer must hold whole triangles")
            }
        } else {
            guard shape.indices.count.isMultiple(of: 3), shape.indices.allSatisfy({ Int($0) < vertexCount }) else {
                throw WPESceneScriptModelDataError("indexBuffer must hold whole triangles within the vertexBuffer")
            }
        }
    }

    private static func vertexFormat(_ value: JSValue) throws(WPESceneScriptModelDataError) -> [WPESceneScriptVertexAttribute] {
        guard let items = elements(value), !items.isEmpty else {
            throw WPESceneScriptModelDataError("vertexFormat must be a non-empty array")
        }
        var format: [WPESceneScriptVertexAttribute] = []
        for item in items {
            guard let item, item.isString,
                  let attribute = item.toString().flatMap(WPESceneScriptVertexAttribute.init(rawValue:)) else {
                throw WPESceneScriptModelDataError("vertexFormat entries must be IModelData constants")
            }
            guard (format.last?.order ?? -1) < attribute.order else {
                throw WPESceneScriptModelDataError("vertexFormat must follow POSITION, NORMAL, TANGENT_SIGNED, UV, COLOR order")
            }
            format.append(attribute)
        }
        return format
    }

    private static func defined(_ object: JSValue, _ key: String) -> JSValue? {
        guard let value = object.objectForKeyedSubscript(key), !value.isUndefined else { return nil }
        return value
    }

    /// Array elements, with null/undefined entries as nil; nil when `value` is not an array.
    private static func elements(_ value: JSValue?) -> [JSValue?]? {
        guard let value, value.isArray, let length = value.objectForKeyedSubscript("length")?.toInt32() else { return nil }
        return (0 ..< Int(max(0, length))).map { index in
            value.atIndex(index).flatMap { $0.isNull ? nil : $0 }
        }
    }

    private static func floats(_ value: JSValue) -> [Float]? {
        typedArrayElements(value, type: kJSTypedArrayTypeFloat32Array, as: Float.self)
    }

    private static func indices(_ value: JSValue) -> [UInt32]? {
        typedArrayElements(value, type: kJSTypedArrayTypeUint32Array, as: UInt32.self)
            ?? typedArrayElements(value, type: kJSTypedArrayTypeUint16Array, as: UInt16.self)?.map(UInt32.init)
    }

    private static func typedArrayElements<Element>(
        _ value: JSValue,
        type: JSTypedArrayType,
        as _: Element.Type
    ) -> [Element]? {
        guard let context = value.context else { return nil }
        let ref = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard JSValueGetTypedArrayType(ref, value.jsValueRef, &exception) == type, exception == nil,
              let object = JSValueToObject(ref, value.jsValueRef, &exception), exception == nil else { return nil }
        let count = JSObjectGetTypedArrayLength(ref, object, &exception)
        let offset = JSObjectGetTypedArrayByteOffset(ref, object, &exception)
        guard exception == nil else { return nil }
        guard count > 0 else { return [] }
        // The buffer base excludes the view's byte offset; the pointer is valid only until the next JSC call.
        guard let buffer = JSObjectGetTypedArrayBuffer(ref, object, &exception), exception == nil,
              let base = JSObjectGetArrayBufferBytesPtr(ref, buffer, &exception), exception == nil else { return nil }
        let start = (base + offset).bindMemory(to: Element.self, capacity: count)
        return Array(UnsafeBufferPointer(start: start, count: count))
    }
}

struct WPESceneScriptModelDataError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private func wpeRaiseModelDataError(_ message: String) {
    guard let context = JSContext.current() else { return }
    context.exception = JSValue(newErrorFromMessage: message, in: context)
}
#endif
