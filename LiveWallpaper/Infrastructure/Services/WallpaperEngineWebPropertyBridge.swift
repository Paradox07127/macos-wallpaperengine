import Foundation
import LiveWallpaperCore

enum WallpaperEngineWebPropertyBridge {
    static func bootstrapScript(
        schema: WallpaperEngineProjectPropertySchema,
        overrides: [String: WallpaperEngineProjectPropertyValue] = [:]
    ) -> String? {
        guard let json = propertiesJSON(schema: schema, overrides: overrides) else {
            return nil
        }

        // The hook is installed at once, but delivery waits for `load`: Wallpaper Engine delivers
        // once the wallpaper is ready, and a page that builds its GL state in a load handler throws
        // if the listener runs at documentEnd — the throw then eats every property after it.
        return """
        (function () {
            var properties = \(json);
            var delivered = false;
            var attempted = false;
            var ready = false;
            function deliver(listener) {
                if (!ready || delivered) return;
                if (!listener || typeof listener.applyUserProperties !== 'function') return;
                attempted = true;
                try {
                    listener.applyUserProperties(properties);
                    delivered = true;
                } catch (error) {
                    // A throw before `load` is the timeout beating a page that builds its GL state in
                    // its load handler; `load` delivers again. After `load` the page had its chance.
                    delivered = document.readyState === 'complete';
                    console.error('Loomscreen failed to apply Wallpaper Engine properties', error);
                }
            }
            // Installed before `load` on purpose: a page that assigns its listener later must still
            // be captured, including when `load` has already been missed.
            try {
                var current = window.wallpaperPropertyListener;
                Object.defineProperty(window, 'wallpaperPropertyListener', {
                    configurable: true,
                    get: function () { return current; },
                    set: function (value) {
                        current = value;
                        deliver(value);
                    }
                });
            } catch (e) {}
            function becomeReady() {
                var firstCall = !ready;
                ready = true;
                deliver(window.wallpaperPropertyListener);
                if (!firstCall) return;
                // Short polling fallback for pages that mutate an already-defined property
                // instead of assigning to the window.
                var attempts = 0;
                function pollFallback() {
                    if (delivered || attempted) return;
                    deliver(window.wallpaperPropertyListener);
                    if (delivered || attempted) return;
                    if (attempts++ < 60) {
                        window.requestAnimationFrame(pollFallback);
                    }
                }
                pollFallback();
            }
            if (document.readyState === 'complete') {
                becomeReady();
            } else {
                window.addEventListener('load', becomeReady);
                // One hanging subresource can hold `load` forever. Before this bridge waited,
                // properties always arrived at documentEnd, so the wait has to be bounded.
                window.setTimeout(becomeReady, \(Self.readinessFallbackMilliseconds));
            }
        })();
        """
    }

    /// Long enough that a normally-loading page always wins the race.
    static let readinessFallbackMilliseconds = 10000

    static func applyScript(
        schema: WallpaperEngineProjectPropertySchema,
        previousOverrides: [String: WallpaperEngineProjectPropertyValue],
        overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> String? {
        let previousValues = schema.effectiveValues(overrides: previousOverrides)
        let currentValues = schema.effectiveValues(overrides: overrides)
        let changedKeys = Set(schema.properties.compactMap { property -> String? in
            previousValues[property.key] == currentValues[property.key] ? nil : property.key
        })
        guard !changedKeys.isEmpty,
              let json = propertiesJSON(
                  schema: schema,
                  overrides: overrides,
                  includingKeys: changedKeys
              ) else {
            return nil
        }

        return """
        (function () {
            var listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyUserProperties === 'function') {
                listener.applyUserProperties(\(json));
            }
        })();
        """
    }

    static func audioBootstrapOverrides(
        schema: WallpaperEngineProjectPropertySchema,
        projectOverrides: [String: WallpaperEngineProjectPropertyValue],
        volume: Double,
        muted: Bool
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        let level = normalizedAudioLevel(volume: volume, muted: muted)
        guard muted || level < 0.999 else { return [:] }
        return audioPropertyOverrides(
            schema: schema,
            projectOverrides: projectOverrides,
            volume: volume,
            muted: muted,
            restoreProjectValueAtFullVolume: false
        )
    }

    static func audioControlScript(
        schema: WallpaperEngineProjectPropertySchema,
        projectOverrides: [String: WallpaperEngineProjectPropertyValue],
        volume: Double,
        muted: Bool
    ) -> String? {
        let audioOverrides = audioPropertyOverrides(
            schema: schema,
            projectOverrides: projectOverrides,
            volume: volume,
            muted: muted,
            restoreProjectValueAtFullVolume: true
        )
        guard !audioOverrides.isEmpty else { return nil }

        let runtimeOverrides = projectOverrides.merging(audioOverrides) { _, runtime in runtime }
        guard let json = propertiesJSON(
            schema: schema,
            overrides: runtimeOverrides,
            includingKeys: Set(audioOverrides.keys)
        ) else {
            return nil
        }

        return """
        (function () {
            var listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyUserProperties === 'function') {
                listener.applyUserProperties(\(json));
            }
        })();
        """
    }

    static func parseSchema(forFolder folderURL: URL) -> WallpaperEngineProjectPropertySchema? {
        let manifestURL = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let schema = try? WallpaperEngineProjectPropertySchema.parse(data: data),
              !schema.properties.isEmpty else {
            return nil
        }
        return schema
    }

    private static func propertiesJSON(
        schema: WallpaperEngineProjectPropertySchema,
        overrides: [String: WallpaperEngineProjectPropertyValue],
        includingKeys allowedKeys: Set<String>? = nil
    ) -> String? {
        guard !schema.properties.isEmpty else { return nil }

        let values = schema.effectiveValues(overrides: overrides)
        var payload: [String: Any] = [:]
        for property in schema.properties {
            if let allowedKeys, !allowedKeys.contains(property.key) {
                continue
            }
            let value: Any
            if let resolved = values[property.key]?.jsonObject {
                value = resolved
            } else if property.type.deliversEmptyStringWhenUnset {
                value = ""
            } else {
                continue
            }
            let wrapped: [String: Any] = ["value": value]
            guard JSONSerialization.isValidJSONObject(wrapped) else { continue }
            payload[property.key] = wrapped
        }

        guard !payload.isEmpty,
              JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        return json
    }

    private static func audioPropertyOverrides(
        schema: WallpaperEngineProjectPropertySchema,
        projectOverrides: [String: WallpaperEngineProjectPropertyValue],
        volume: Double,
        muted: Bool,
        restoreProjectValueAtFullVolume: Bool
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        let candidates = audioVolumeProperties(in: schema)
        guard !candidates.isEmpty else { return [:] }

        let level = normalizedAudioLevel(volume: volume, muted: muted)
        let masterIsActive = muted || level < 0.999
        let effectiveValues = schema.effectiveValues(overrides: projectOverrides)

        var overrides: [String: WallpaperEngineProjectPropertyValue] = [:]
        for property in candidates {
            if masterIsActive {
                overrides[property.key] = .number(scaledAudioLevel(
                    level,
                    for: property,
                    baseValue: effectiveValues[property.key] ?? property.defaultValue
                ))
            } else if restoreProjectValueAtFullVolume {
                overrides[property.key] = effectiveValues[property.key]
                    ?? property.defaultValue
                    ?? .number(scaledAudioLevel(1, for: property, baseValue: nil))
            }
        }
        return overrides
    }

    private static func audioVolumeProperties(
        in schema: WallpaperEngineProjectPropertySchema
    ) -> [WallpaperEngineProjectPropertySchema.Property] {
        schema.properties.filter { property in
            guard property.type == .slider else { return false }
            let haystack = "\(property.key) \(property.displayText)".lowercased()
            return [
                "volume",
                "bgm",
                "audio",
                "sound",
                "music",
                "voice",
                "音量",
                "音频",
                "声音",
                "音乐",
                "音效"
            ].contains { haystack.contains($0) }
        }
    }

    private static func normalizedAudioLevel(volume: Double, muted: Bool) -> Double {
        guard !muted, volume.isFinite else { return 0 }
        return min(max(volume, 0), 1)
    }

    private static func scaledAudioLevel(
        _ level: Double,
        for property: WallpaperEngineProjectPropertySchema.Property,
        baseValue: WallpaperEngineProjectPropertyValue?
    ) -> Double {
        let lower = property.minimum ?? 0
        let fallbackUpper: Double = {
            if property.fraction { return 1 }
            if let defaultNumber = property.defaultValue?.numberValue,
               defaultNumber <= 1,
               lower <= 1 {
                return 1
            }
            return 100
        }()
        let upper = property.maximum ?? fallbackUpper
        let minValue = min(lower, upper)
        let maxValue = max(lower, upper)
        let base = min(max(baseValue?.numberValue ?? maxValue, minValue), maxValue)
        let raw = minValue + ((base - minValue) * min(max(level, 0), 1))

        guard let step = property.step, step > 0 else {
            return raw
        }
        let stepped = ((raw - minValue) / step).rounded() * step + minValue
        return min(max(stepped, minValue), maxValue)
    }
}

private extension WallpaperEngineProjectPropertyValue {
    var jsonObject: Any? {
        switch self {
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        }
    }
}
