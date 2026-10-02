#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperProWPE

func wpeScriptLayerIDKey(_ id: String) -> String {
    "\u{1}id:\(id)"
}

func wpeScriptLayerObjectID(_ key: String) -> String? {
    key.hasPrefix("\u{1}id:") ? String(key.dropFirst(4)) : nil
}

func wpeInitialLayerConfiguration(from authored: WPESceneJSONValue) -> WPESceneJSONValue? {
    guard case var .object(members) = authored else { return nil }
    // WPE's cloneable configuration excludes the layer's runtime identity.
    members.removeValue(forKey: "id")
    return .object(members)
}

func wpeInstallInitialLayerConfiguration(
    on scene: JSValue,
    in context: JSContext,
    lookup: @escaping (JSValue) -> WPESceneJSONValue?
) {
    let get: @convention(block) (JSValue) -> JSValue? = { [weak context] value in
        guard let context else { return nil }
        guard let configuration = lookup(value) else { return JSValue(nullIn: context) }
        return wpeInitialLayerConfigurationValue(configuration, in: context)
    }
    scene.setObject(get, forKeyedSubscript: "getInitialLayerConfig" as NSString)
}

func wpeInitialLayerConfigurationLookup(_ value: JSValue, layers: [WPESceneScriptLayerInfo]) -> WPESceneJSONValue? {
    if value.isString, let name = value.toString() {
        return layers.first(where: { $0.name == name })?.initialConfiguration
    }
    if value.isNumber {
        let index = Int(value.toInt32())
        guard layers.indices.contains(index) else { return nil }
        return layers[index].initialConfiguration
    }
    return nil
}

func wpeCreatedInitialLayerConfiguration(_ specification: JSValue, in context: JSContext) -> WPESceneJSONValue? {
    if specification.isString, let image = specification.toString() {
        return .object(["image": .string(image)])
    }
    // JSON.stringify rejects cyclic input inside JS instead of recursively traversing
    // arbitrary bridged Foundation containers in Swift.
    guard let stringify = context.evaluateScript("""
    (function(value) {
        try { return JSON.stringify(value, function(key, item) {
            return item instanceof Vec2 || item instanceof Vec3 || item instanceof Vec4 ? item.toString() : item;
        }); } catch (_) { return null; }
    })
    """),
        let result = stringify.call(withArguments: [specification]), result.isString,
        let text = result.toString(), let data = text.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let value = WPESceneJSONValue(jsonValue: object) else { return nil }
    return wpeInitialLayerConfiguration(from: value)
}

/// Convert immutable configuration into fresh JS storage on the calling script lane.
/// No JSValue is retained in the shared state or reused across contexts.
func wpeInitialLayerConfigurationValue(_ configuration: WPESceneJSONValue, in context: JSContext) -> JSValue? {
    JSValue(object: initialConfigurationObject(configuration), in: context)
}

private func initialConfigurationObject(_ value: WPESceneJSONValue) -> Any {
    switch value {
    case let .object(members): members.mapValues(initialConfigurationObject)
    case let .array(elements): elements.map(initialConfigurationObject)
    case let .string(value): value
    case let .number(value): value
    case let .bool(value): value
    case .null: NSNull()
    }
}
#endif
