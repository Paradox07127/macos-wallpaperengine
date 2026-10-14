import Foundation

/// TEXB selection and the final string observations used by the original property watcher.
/// This reads the caller's existing property snapshot; it does not own another property registry.
public struct WPETexConditionalSelection: Sendable, Equatable {
    public enum Failure: Error, LocalizedError, Sendable, Equatable {
        case invalidConditionEncoding
        case propertyWithoutValue(String)

        public var errorDescription: String? {
            switch self {
            case .invalidConditionEncoding: "Conditional texture JSON is not valid UTF-8"
            case let .propertyWithoutValue(name): "Conditional texture property \(name) has no value member"
            }
        }
    }

    public let flagsByVariantID: [UInt32: UInt32]
    /// Byte keys and values preserve native length/memcmp equality (including Unicode normalization).
    public let observations: [Data: Data]

    public init(variants: [WPETexConditionalVariant], properties: WPESceneJSONValue) throws {
        var selected: [UInt32: UInt32] = [:]
        var observed: [Data: Data] = [:]
        var groups: Set<UInt32> = []
        for variant in variants {
            guard String(data: variant.conditionBytes, encoding: .utf8) != nil else {
                throw Failure.invalidConditionEncoding
            }
            guard let raw = try? JSONSerialization.jsonObject(with: variant.conditionBytes),
                  let json = WPESceneJSONValue(jsonValue: raw), let condition = json["condition"] else { continue }
            let key: Data
            let expected: Data?
            switch condition {
            case let .string(value):
                key = Self.cString(value)
                expected = nil
            case .object:
                guard case let .string(name) = condition["name"],
                      case let .string(value) = condition["condition"] else { continue }
                key = Self.cString(name)
                expected = Self.cString(value)
            default: continue
            }
            let matches = try Self.matches(properties: properties, key: key, expected: expected)
            // The shared observation is written before group de-duplication, even for a later true entry.
            if let expected {
                if matches {
                    observed[key] = expected
                } else if observed[key] == nil {
                    observed[key] = Data("$__default".utf8)
                }
            } else {
                observed[key] = Data((matches ? "1" : "0").utf8)
            }
            if matches, groups.insert(variant.groupKey).inserted {
                selected[variant.variantID] = variant.flags
            }
        }
        flagsByVariantID = selected
        observations = observed
    }

    /// 14015ea10 only compares fresh string/bool values with the stored observation. It neither updates
    /// the observation nor clears a previously latched dirty bit; the owner replaces this metadata on reload.
    public func requiresReload(changedProperties: WPESceneJSONValue) -> Bool {
        guard case let .object(entries) = changedProperties else { return false }
        return entries.contains { name, entry in
            guard let previous = observations[Data(name.utf8)], let value = entry["value"] else { return false }
            let current: Data
            switch value {
            case let .string(text): current = Data(text.utf8)
            case let .bool(flag): current = Data((flag ? "1" : "0").utf8)
            default: return false
            }
            return previous != current
        }
    }

    private static func matches(properties: WPESceneJSONValue, key: Data, expected: Data?) throws -> Bool {
        guard case let .object(entries) = properties,
              let entry = entries.first(where: { Data($0.key.utf8) == key })?.value,
              case .object = entry else { return false }
        guard let value = entry["value"] else {
            // The native expected-string path dereferences this missing member. Reject the malformed
            // envelope explicitly instead of reproducing that fault or calling it native false.
            if expected != nil {
                throw Failure.propertyWithoutValue(String(bytes: key, encoding: .utf8) ?? "<invalid UTF-8>")
            }
            return false
        }
        if let expected {
            guard case let .string(text) = value else { return false }
            return Data(text.utf8) == expected
        }
        guard case let .bool(flag) = value else { return false }
        return flag
    }

    private static func cString(_ value: String) -> Data {
        Data(value.utf8.prefix { $0 != 0 })
    }
}
