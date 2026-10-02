#if DEBUG
import Foundation
import LiveWallpaperCore

@MainActor
extension QAControlPlane {
    func scenePropertiesGet(_ arguments: [String: Any]) async throws -> Any {
        #if LITE_BUILD
        throw QAError.message("Scene wallpapers are not available in this edition")
        #else
        let target = try await resolveScene(arguments)
        let descriptor = target.descriptor
        let layered = descriptor.layeredPropertyValues()
        let properties = target.candidates.map { property -> [String: Any] in
            var entry: [String: Any] = [
                "key": property.key,
                "type": property.type.rawValue,
                "label": property.displayText,
                "default": Self.jsonValue(property.defaultValue),
                "minimum": property.minimum ?? NSNull(),
                "maximum": property.maximum ?? NSNull(),
                "step": property.step ?? NSNull(),
                "current": Self.jsonValue(layered[property.key] ?? property.defaultValue),
                "overridden": descriptor.propertyOverrides[property.key] != nil,
            ]
            if !property.options.isEmpty {
                entry["options"] = property.options.map { option -> [String: Any] in
                    ["label": option.displayLabel, "value": Self.jsonValue(option.value)]
                }
            }
            return entry
        }
        return [
            "screenID": target.screen.id,
            "workshopID": descriptor.workshopID,
            "presetID": descriptor.presetID ?? NSNull(),
            "overrides": descriptor.propertyOverrides.mapValues { Self.jsonValue($0) },
            "properties": properties,
        ]
        #endif
    }

    func scenePropertiesPatch(_ arguments: [String: Any]) async throws -> Any {
        #if LITE_BUILD
        throw QAError.message("Scene wallpapers are not available in this edition")
        #else
        guard let values = arguments["values"] as? [String: Any], !values.isEmpty else {
            throw QAError.message("Missing values: expected {key: value | null}")
        }
        guard let manager = screenManager else { throw QAError.message("ScreenManager unavailable") }
        let target = try await resolveScene(arguments)
        let descriptor = target.descriptor
        let candidates = Dictionary(uniqueKeysWithValues: target.candidates.map { ($0.key, $0) })

        var removals: [String] = []
        var updates: [(SceneProperty, WallpaperEngineProjectPropertyValue)] = []
        for (key, raw) in values {
            guard let property = candidates[key] else {
                throw QAError.message("Rejected \(key): not a scene setting of this wallpaper; call scene.properties.get")
            }
            if raw is NSNull {
                removals.append(key)
            } else {
                try updates.append((property, Self.sceneValue(raw, for: property)))
            }
        }

        var next = descriptor.propertyOverrides
        for key in removals {
            next.removeValue(forKey: key)
        }
        for (property, value) in updates {
            // Same rule as SceneSettingsOwner.setValue: equal to the layer underneath means no override.
            let matchesUnderlyingLayer = if descriptor.presetID != nil,
                                            let presetValue = descriptor.presetSnapshot[property.key] {
                presetValue == value
            } else {
                PropertyValueLogic.matchesDefault(value: value, for: property)
            }
            next[property.key] = matchesUnderlyingLayer ? nil : value
        }

        guard next != descriptor.propertyOverrides else {
            return [
                "status": "unchanged",
                "screenID": target.screen.id,
                "overrides": next.mapValues { Self.jsonValue($0) },
            ]
        }
        await manager.updateSceneDescriptor(descriptor.withPropertyOverrides(next), for: target.screen)
        var stored: Any = NSNull()
        if let configuration = manager.getConfiguration(for: target.screen),
           case let .scene(current) = configuration.activeWallpaper {
            stored = current.propertyOverrides.mapValues { Self.jsonValue($0) }
        }
        return ["status": "applied", "screenID": target.screen.id, "overrides": stored]
        #endif
    }
}

#if !LITE_BUILD
private typealias SceneProperty = WallpaperEngineProjectPropertySchema.Property

private struct SceneTarget {
    let screen: Screen
    let descriptor: SceneDescriptor
    let candidates: [SceneProperty]
}

@MainActor
extension QAControlPlane {
    private func resolveScene(_ arguments: [String: Any]) async throws -> SceneTarget {
        guard let manager = screenManager else { throw QAError.message("ScreenManager unavailable") }
        let screen = try resolveScreen(arguments)
        guard let configuration = manager.getConfiguration(for: screen),
              case let .scene(descriptor) = configuration.activeWallpaper else {
            throw QAError.message("Screen \(screen.id) is not showing a scene wallpaper")
        }
        let outcome = await WPESceneProjectSchemaLoader.load(descriptor: descriptor, wpeOrigin: configuration.wpeOrigin)
        guard let schema = outcome.schema else {
            throw QAError.message("Scene settings schema unavailable: \(outcome.log)")
        }
        // The load suspends; a patch built on a descriptor replaced meanwhile would re-apply the old scene.
        guard let latest = manager.getConfiguration(for: screen), latest.activeWallpaper == .scene(descriptor) else {
            throw QAError.message("Screen \(screen.id) changed wallpaper while its settings were loading; retry")
        }
        return SceneTarget(
            screen: screen,
            descriptor: descriptor,
            candidates: schema.properties.filter(WPESceneCustomSettingsCard.isSceneSettingCandidate)
        )
    }

    private static func sceneValue(_ raw: Any, for property: SceneProperty) throws -> WallpaperEngineProjectPropertyValue {
        let key = property.key
        // NSNumber bridges JSON true/false to 1/0; only the CFBoolean type ID tells them apart.
        let isBoolean = CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID()
        switch property.type {
        case .bool:
            guard isBoolean, let flag = raw as? Bool else {
                throw QAError.message("Rejected \(key): expected a boolean")
            }
            return .bool(flag)
        case .slider:
            guard !isBoolean, let number = (raw as? NSNumber)?.doubleValue, number.isFinite else {
                throw QAError.message("Rejected \(key): expected a number")
            }
            if let minimum = property.minimum, number < minimum {
                throw QAError.message("Rejected \(key): \(number) is below the minimum \(minimum)")
            }
            if let maximum = property.maximum, number > maximum {
                throw QAError.message("Rejected \(key): \(number) is above the maximum \(maximum)")
            }
            return .number(number)
        case .combo:
            let value: WallpaperEngineProjectPropertyValue
            if isBoolean, let flag = raw as? Bool {
                value = .bool(flag)
            } else if let number = raw as? NSNumber {
                value = .number(number.doubleValue)
            } else if let text = raw as? String {
                value = .string(text)
            } else {
                throw QAError.message("Rejected \(key): expected one of the option values")
            }
            guard property.options.contains(where: { $0.value == value }) else {
                let allowed = property.options.map(\.value.stringValue).joined(separator: ", ")
                throw QAError.message("Rejected \(key): \(value.stringValue) is not one of \(allowed)")
            }
            return value
        case .color, .textinput:
            guard let text = raw as? String else {
                throw QAError.message("Rejected \(key): expected a string")
            }
            return .string(text)
        default:
            throw QAError.message("Rejected \(key): \(property.type.rawValue) settings are not writable")
        }
    }

    private static func jsonValue(_ value: WallpaperEngineProjectPropertyValue?) -> Any {
        switch value {
        case let .bool(flag): flag
        case let .number(number): number
        case let .string(text): text
        case nil: NSNull()
        }
    }
}
#endif
#endif
