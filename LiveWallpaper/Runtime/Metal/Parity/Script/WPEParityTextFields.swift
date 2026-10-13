#if !LITE_BUILD
import LiveWallpaperProWPE

/// The SceneScript text field boundary: one mapping seeds host getters and applies writes to layout inputs.
/// Frame rendering owns the dirty boundary and atlas lifetime, without repeating field translation.
enum WPEParityTextFields {
    private static let textStrings: [(String, WritableKeyPath<WPEParityTextObject, String> & Sendable)] = [
        ("text", \.text), ("font", \.font),
    ]
    private static let textScalars: [(String, WritableKeyPath<WPEParityTextObject, Float> & Sendable)] = [
        ("pointsize", \.pointSize), ("maxwidth", \.maxWidth),
    ]
    private static let textVectors: [(String, WritableKeyPath<WPEParityTextObject, SIMD2<Float>> & Sendable)] = [
        ("padding", \.padding), ("spacing", \.spacing),
    ]
    private static let textFlags: [(String, WritableKeyPath<WPEParityTextObject, Bool> & Sendable)] = [
        ("limitwidth", \.limitWidth), ("limitrows", \.limitRows), ("limituseellipsis", \.limitUseEllipsis),
    ]

    static func seed(_ text: WPEParityTextObject) -> [String: WPEParitySceneState.ScriptValue] {
        var fields: [String: WPEParitySceneState.ScriptValue] = [:]
        for (name, key) in textStrings {
            fields[name] = .string(text[keyPath: key])
        }
        for (name, key) in textScalars {
            fields[name] = .vector(SIMD4(text[keyPath: key], 0, 0, 0))
        }
        for (name, key) in textVectors {
            fields[name] = .vector(SIMD4(text[keyPath: key].x, text[keyPath: key].y, 0, 0))
        }
        for (name, key) in textFlags {
            fields[name] = .vector(SIMD4(text[keyPath: key] ? 1 : 0, 0, 0, 0))
        }
        fields["maxrows"] = .integer(Int32(clamping: text.maxRows))
        fields["horizontalalign"] = .string(String(describing: text.horizontalAlign))
        fields["verticalalign"] = .string(String(describing: text.verticalAlign))
        return fields
    }

    static func applying(to original: WPEParityTextObject, state: WPEParitySceneState) -> WPEParityTextObject {
        var object = original
        for (name, key) in textStrings {
            if case let .string(value)? = state.scriptField(name, of: object.id) {
                object[keyPath: key] = value
            }
        }
        for (name, key) in textScalars {
            if case let .vector(value)? = state.scriptField(name, of: object.id) {
                object[keyPath: key] = value.x
            }
        }
        for (name, key) in textVectors {
            if case let .vector(value)? = state.scriptField(name, of: object.id) {
                object[keyPath: key] = SIMD2(value.x, value.y)
            }
        }
        for (name, key) in textFlags {
            if case let .vector(value)? = state.scriptField(name, of: object.id) {
                object[keyPath: key] = value.x != 0
            }
        }
        if case let .integer(value)? = state.scriptField("maxrows", of: object.id) {
            object.maxRows = Int(value)
        }
        if case let .string(value)? = state.scriptField("horizontalalign", of: object.id) {
            switch value {
            case "left": object.horizontalAlign = .left
            case "right": object.horizontalAlign = .right
            case "center": object.horizontalAlign = .center
            default: break
            }
        }
        if case let .string(value)? = state.scriptField("verticalalign", of: object.id) {
            switch value {
            case "top": object.verticalAlign = .top
            case "bottom": object.verticalAlign = .bottom
            case "center": object.verticalAlign = .center
            default: break
            }
        }
        return object
    }
}
#endif
