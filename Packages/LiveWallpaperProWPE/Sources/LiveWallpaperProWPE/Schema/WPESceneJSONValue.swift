import CoreFoundation
import Foundation

/// Sendable, equatable representation of every authored JSON value in a WPE scene.
///
/// Typed scene fields remain the runtime's fast path. This tree is the lossless
/// compatibility substrate for fields that have not acquired a typed consumer yet,
/// so adding support later never requires changing the package decoder first.
public indirect enum WPESceneJSONValue: Equatable, Sendable {
    case object([String: WPESceneJSONValue])
    case array([WPESceneJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Converts a value produced by `JSONSerialization` without dropping keys.
    public init?(jsonValue value: Any) {
        if let dictionary = value as? [String: Any] {
            var converted: [String: WPESceneJSONValue] = [:]
            converted.reserveCapacity(dictionary.count)
            for (key, child) in dictionary {
                guard let child = WPESceneJSONValue(jsonValue: child) else { return nil }
                converted[key] = child
            }
            self = .object(converted)
            return
        }
        if let array = value as? [Any] {
            var converted: [WPESceneJSONValue] = []
            converted.reserveCapacity(array.count)
            for child in array {
                guard let child = WPESceneJSONValue(jsonValue: child) else { return nil }
                converted.append(child)
            }
            self = .array(converted)
            return
        }
        if value is NSNull {
            self = .null
            return
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
            return
        }
        if let string = value as? String {
            self = .string(string)
            return
        }
        return nil
    }

    public subscript(key: String) -> WPESceneJSONValue? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary[key]
    }

    public subscript(index: Int) -> WPESceneJSONValue? {
        guard case .array(let values) = self, values.indices.contains(index) else { return nil }
        return values[index]
    }
}
