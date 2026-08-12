import Foundation
import LiveWallpaperCore

/// project.json properties schema for web/scene inspectors and applyUserProperties.
struct WallpaperEngineProjectPropertySchema: Equatable, Sendable {
    var properties: [Property]

    var hasMeaningfulSettings: Bool {
        properties.contains { $0.type.isEditable }
    }

    var defaultValues: [String: WallpaperEngineProjectPropertyValue] {
        Dictionary(uniqueKeysWithValues: properties.compactMap { property in
            property.defaultValue.map { (property.key, $0) }
        })
    }

    static func read(
        from folder: URL,
        preferredLanguages: [String] = Locale.preferredLanguages,
        includeSchemeColor: Bool = false
    ) throws -> WallpaperEngineProjectPropertySchema {
        try WallpaperEngineProjectPropertySchemaCache.shared.schema(
            from: folder,
            preferredLanguages: preferredLanguages,
            includeSchemeColor: includeSchemeColor
        )
    }

    /// Include schemecolor (scenes need it; HTML usually paints it in CSS).
    static func parse(
        data: Data,
        preferredLanguages: [String] = Locale.preferredLanguages,
        includeSchemeColor: Bool = false
    ) throws -> WallpaperEngineProjectPropertySchema {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = root["general"] as? [String: Any],
              let rawProperties = general["properties"] as? [String: Any] else {
            return WallpaperEngineProjectPropertySchema(properties: [])
        }

        let localization = Localization(
            raw: general["localization"] as? [String: Any],
            preferredLanguages: preferredLanguages
        )

        let properties = rawProperties.compactMap { key, raw -> Property? in
            if !includeSchemeColor && key == "schemecolor" { return nil }
            guard let dict = raw as? [String: Any] else { return nil }
            return Property(key: key, dict: dict, localization: localization)
        }
        .sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if lhs.index != rhs.index { return lhs.index < rhs.index }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }

        return WallpaperEngineProjectPropertySchema(properties: properties)
    }

    func effectiveValues(
        overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        defaultValues.merging(overrides) { _, override in override }
    }

    /// Schema defaults + descriptor overrides (overrides-only if no project.json).
    static func effectiveSceneValues(
        descriptor: SceneDescriptor,
        cacheRootURL: URL
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        do {
            return try read(
                from: cacheRootURL,
                includeSchemeColor: true
            ).effectiveValues(overrides: descriptor.propertyOverrides)
        } catch {
            return descriptor.propertyOverrides
        }
    }

    func visibleProperties(
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> [Property] {
        properties.filter { property in
            Self.visiblePropertyConditionMatches(
                condition: property.condition,
                values: values
            )
        }
    }

    static func visiblePropertyConditionMatches(
        condition: String?,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool {
        ConditionEvaluator.isVisible(condition: condition, values: values)
    }
}

final class WallpaperEngineProjectPropertySchemaCache: @unchecked Sendable {
    static let shared = WallpaperEngineProjectPropertySchemaCache()

    private struct Key: Hashable {
        let projectPath: String
        let fileSize: Int
        let modificationTime: TimeInterval
        let preferredLanguages: [String]
        let includeSchemeColor: Bool
    }

    private let lock = NSLock()
    private let limit: Int
    private var entries: [Key: WallpaperEngineProjectPropertySchema] = [:]
    private var recency: [Key] = []

    init(limit: Int = 128) {
        self.limit = max(1, limit)
    }

    func schema(
        from folder: URL,
        preferredLanguages: [String] = Locale.preferredLanguages,
        includeSchemeColor: Bool = false
    ) throws -> WallpaperEngineProjectPropertySchema {
        let manifestURL = folder.appendingPathComponent("project.json", isDirectory: false)
        let key = try cacheKey(
            manifestURL: manifestURL,
            preferredLanguages: preferredLanguages,
            includeSchemeColor: includeSchemeColor
        )
        if let cached = cachedValue(for: key) {
            return cached
        }

        let data = try Data(contentsOf: manifestURL)
        let parsed = try WallpaperEngineProjectPropertySchema.parse(
            data: data,
            preferredLanguages: preferredLanguages,
            includeSchemeColor: includeSchemeColor
        )
        store(parsed, for: key)
        return parsed
    }

    private func cacheKey(
        manifestURL: URL,
        preferredLanguages: [String],
        includeSchemeColor: Bool
    ) throws -> Key {
        let values = try manifestURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        return Key(
            projectPath: manifestURL.standardizedFileURL.resolvingSymlinksInPath().path,
            fileSize: values.fileSize ?? -1,
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            preferredLanguages: preferredLanguages,
            includeSchemeColor: includeSchemeColor
        )
    }

    private func cachedValue(for key: Key) -> WallpaperEngineProjectPropertySchema? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = entries[key] else { return nil }
        markRecentlyUsed(key)
        return value
    }

    private func store(_ schema: WallpaperEngineProjectPropertySchema, for key: Key) {
        lock.lock()
        entries[key] = schema
        markRecentlyUsed(key)
        while entries.count > limit, let oldest = recency.first {
            recency.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    private func markRecentlyUsed(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

extension WallpaperEngineProjectPropertySchema {
    struct Property: Identifiable, Equatable, Sendable {
        var id: String { key }

        let key: String
        let type: PropertyType
        let displayText: String
        let defaultValue: WallpaperEngineProjectPropertyValue?
        let minimum: Double?
        let maximum: Double?
        let step: Double?
        let precision: Int?
        let fraction: Bool
        let order: Double
        let index: Int
        let condition: String?
        let options: [Option]
        let fileType: String?
        /// True for promotional or external-link markup that does not bind to the render graph.
        let isPromotionalLink: Bool

        fileprivate init?(key: String, dict: [String: Any], localization: Localization) {
            self.key = key
            type = PropertyType(rawValue: (dict["type"] as? String)?.lowercased() ?? "") ?? .unsupported
            let rawText = dict["text"] as? String
            displayText = localization.displayText(for: rawText ?? key)
            defaultValue = Self.value(from: dict["value"], type: type)
            minimum = Self.double(from: dict["min"])
            maximum = Self.double(from: dict["max"])
            step = Self.double(from: dict["step"])
            precision = Self.int(from: dict["precision"])
            fraction = (dict["fraction"] as? Bool) ?? false
            order = Self.double(from: dict["order"]) ?? Double.greatestFiniteMagnitude
            index = Self.int(from: dict["index"]) ?? Int.max
            condition = (dict["condition"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let rawOptions = dict["options"] as? [[String: Any]]
            if let rawOptions {
                options = rawOptions.compactMap { Option(dict: $0, localization: localization) }
            } else {
                options = []
            }
            fileType = (dict["fileType"] as? String) ?? (dict["filetype"] as? String)
            isPromotionalLink = Self.detectPromotionalLink(
                key: key,
                rawText: rawText ?? "",
                rawOptions: rawOptions,
                localization: localization
            )
        }

        /// Tokens used to identify promotional links in generated keys and visible labels.
        private static let promoKeyTokens = [
            "href", "http", "www", "imgsrc", "kofi", "ko-fi", "patreon", "paypal",
            "donate", "sponsor", "discord", "afdian", "aifadian", "爱发电", "赞助", "赞赏", "打赏"
        ]
        private static let promoTextMarkers = [
            "<a ", "<a>", "href=", "<img", "src=", "http://", "https://", "www.",
            "ko-fi", "kofi", "patreon", "paypal", "donate", "sponsor", "discord.gg",
            "爱发电", "赞助", "赞赏", "打赏"
        ]

        /// Detects embedded promotional markup while preserving ordinary styled labels.
        fileprivate static func detectPromotionalLink(
            key: String,
            rawText: String,
            rawOptions: [[String: Any]]?,
            localization: Localization
        ) -> Bool {
            let loweredKey = key.lowercased()
            if ["ahref", "imgsrc", "http"].contains(where: loweredKey.hasPrefix) {
                return true
            }
            if key.count > 40, promoKeyTokens.contains(where: loweredKey.contains) {
                return true
            }

            var candidates = localization.detectionCandidates(for: rawText)
            if let rawOptions {
                for option in rawOptions {
                    if let label = option["label"] as? String {
                        candidates.append(contentsOf: localization.detectionCandidates(for: label))
                    }
                }
            }
            let haystack = candidates.joined(separator: " ").lowercased()
            return promoTextMarkers.contains(where: haystack.contains)
        }

        /// `JSONSerialization` returns every JSON number as `NSNumber`, and `NSNumber as? Bool`
        /// succeeds for 0 and 1 — so a `{"type":"slider","value":0}` used to collapse to
        /// `.bool(false)`. The envelope `{"user":K,"value":V}` then resolved to `false`, the bound
        /// uniform silently fell back to its shader default, and scene 3413921910's water blur ran
        /// at full strength (author default 0) and smeared the finished reflection into a flat
        /// band. The DECLARED type is the disambiguator; only CoreFoundation booleans are booleans.
        fileprivate static func value(
            from raw: Any?,
            type: PropertyType
        ) -> WallpaperEngineProjectPropertyValue? {
            if let number = raw as? NSNumber {
                if type == .bool, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return .bool(number.boolValue)
                }
                return .number(number.doubleValue)
            }
            if let value = raw as? Bool { return .bool(value) }
            if let value = raw as? String { return .string(value) }
            return nil
        }

        private static func double(from raw: Any?) -> Double? {
            if let value = raw as? Double { return value }
            if let value = raw as? Int { return Double(value) }
            if let value = raw as? NSNumber { return value.doubleValue }
            if let value = raw as? String { return Double(value) }
            return nil
        }

        private static func int(from raw: Any?) -> Int? {
            if let value = raw as? Int { return value }
            if let value = raw as? NSNumber { return value.intValue }
            if let value = raw as? String { return Int(value) }
            return nil
        }
    }

    struct Option: Identifiable, Equatable, Sendable {
        var id: String { value.stringValue + displayLabel }

        let displayLabel: String
        let value: WallpaperEngineProjectPropertyValue

        fileprivate init?(dict: [String: Any], localization: Localization) {
            guard let value = Property.value(from: dict["value"], type: .combo) else { return nil }
            self.value = value
            displayLabel = localization.displayText(for: dict["label"] as? String ?? value.stringValue)
        }
    }

    enum PropertyType: String, Equatable {
        case bool
        case slider
        case combo
        case color
        case textinput
        case text
        case file
        case directory
        case group
        case unsupported

        var isEditable: Bool {
            switch self {
            case .bool, .slider, .combo, .color, .textinput, .file, .directory:
                return true
            case .text, .group, .unsupported:
                return false
            }
        }
    }
}

private enum KnownWallpaperEngineKeys {
    private static let displayNames: [String: String] = [
        "bgmvolume": "BGM Volume",
        "mouseactions": "Mouse Actions",
        "schemecolor": "Scheme Color",
        "ui_browse_properties_alignment": "Alignment",
        "ui_browse_properties_background_image": "Background Image",
        "ui_browse_properties_blur": "Blur",
        "ui_browse_properties_brightness": "Brightness",
        "ui_browse_properties_color": "Color",
        "ui_browse_properties_contrast": "Contrast",
        "ui_browse_properties_opacity": "Opacity",
        "ui_browse_properties_playback_rate": "Playback Rate",
        "ui_browse_properties_rotation": "Rotation",
        "ui_browse_properties_scale": "Scale",
        "ui_browse_properties_scheme_color": "Scheme Color",
        "ui_browse_properties_schemecolor": "Scheme Color",
        "ui_browse_properties_size": "Size",
        "ui_browse_properties_speed": "Speed",
        "ui_browse_properties_volume": "Volume"
    ]

    static func displayText(for raw: String) -> String? {
        displayNames[raw.lowercased()]
    }
}

private struct Localization: Equatable {
    private let selected: [String: String]
    private let fallback: [String: String]

    init(raw: [String: Any]?, preferredLanguages: [String]) {
        let maps = raw?.compactMapValues { $0 as? [String: String] } ?? [:]
        selected = Self.selectMap(from: maps, preferredLanguages: preferredLanguages) ?? [:]
        fallback = maps["en-us"] ?? maps["en"] ?? [:]
    }

    func displayText(for raw: String) -> String {
        let cleaned = Self.clean(raw)
        // Localized author string wins; else prettify known WPE keys.
        if let localized = selected[cleaned] ?? fallback[cleaned] {
            return Self.clean(localized)
        }
        return Self.resolveDisplayText(cleaned)
    }

    /// Raw + localized strings for promo-link detection (keep markup uncleaned).
    func detectionCandidates(for raw: String) -> [String] {
        var candidates = [raw]
        let cleaned = Self.clean(raw)
        guard !cleaned.isEmpty else { return candidates }
        if let localized = selected[cleaned] { candidates.append(localized) }
        if let localized = fallback[cleaned], localized != selected[cleaned] {
            candidates.append(localized)
        }
        return candidates
    }

    private static func selectMap(
        from maps: [String: [String: String]],
        preferredLanguages: [String]
    ) -> [String: String]? {
        let normalizedMaps = Dictionary(uniqueKeysWithValues: maps.map { ($0.key.lowercased(), $0.value) })
        for language in preferredLanguages.map({ $0.lowercased() }) {
            let candidates = localeCandidates(for: language)
            for candidate in candidates {
                if let map = normalizedMaps[candidate] { return map }
            }
        }
        return nil
    }

    private static func localeCandidates(for language: String) -> [String] {
        var candidates = [language]
        if let prefix = language.split(separator: "-").first {
            candidates.append(String(prefix))
        }
        if language.hasPrefix("zh") {
            candidates.append(contentsOf: ["zh-chs", "zh-cn", "zh-hans"])
        }
        if language.hasPrefix("en") {
            candidates.append("en-us")
        }
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    /// Fallback label: known-key map, then identifier prettify; free text untouched.
    private static func resolveDisplayText(_ cleaned: String) -> String {
        if let known = KnownWallpaperEngineKeys.displayText(for: cleaned) {
            return known
        }
        if let suffix = browsePropertySuffix(for: cleaned) {
            return prettifyIdentifier(suffix)
        }
        if isIdentifierLike(cleaned) {
            return prettifyIdentifier(cleaned)
        }
        return cleaned
    }

    private static func browsePropertySuffix(for text: String) -> String? {
        let prefix = "ui_browse_properties_"
        let lowered = text.lowercased()
        guard lowered.hasPrefix(prefix), text.count > prefix.count else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    /// Prettify snake_case only (never mangle 4K / camelCase author labels).
    private static func isIdentifierLike(_ text: String) -> Bool {
        guard !text.isEmpty,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return text.contains("_")
    }

    private static func prettifyIdentifier(_ raw: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spaced.split(separator: " ").map(titleCasedIdentifierWord).joined(separator: " ")
    }

    private static func titleCasedIdentifierWord(_ word: Substring) -> String {
        let lower = word.lowercased()
        if ["bgm", "css", "fps", "hdr", "html", "rgb", "rgba", "ui", "url", "wpe"].contains(lower) {
            return lower.uppercased()
        }
        guard let first = lower.first else { return "" }
        return String(first).uppercased() + lower.dropFirst()
    }

    private static func clean(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"</?(h[1-6]|p|big|small|b|center|hr)[^>]*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension WallpaperEngineProjectPropertySchema {
    /// Evaluate visible.user.condition against a live property (loose number/string).
    static func sceneConditionMatches(
        value: WallpaperEngineProjectPropertyValue?,
        condition: String
    ) -> Bool {
        ConditionEvaluator.matchesLiteral(value: value, condition: condition)
    }
}

private enum ConditionEvaluator {
    static func isVisible(
        condition: String?,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool {
        guard let condition, !condition.isEmpty else { return true }
        return condition
            .components(separatedBy: "||")
            .map { evaluateAndGroup($0, values: values) }
            .contains(true)
    }

    /// Loose property-vs-condition-literal equality.
    static func matchesLiteral(
        value: WallpaperEngineProjectPropertyValue?,
        condition: String
    ) -> Bool {
        value.matches(.conditionLiteral(condition))
    }

    private static func evaluateAndGroup(
        _ rawGroup: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool {
        rawGroup
            .components(separatedBy: "&&")
            .map { evaluateClause($0, values: values) }
            .allSatisfy { $0 }
    }

    private static func evaluateClause(
        _ rawClause: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool {
        var clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip all leading `!` so `!!flag` does not look up key "!flag".
        var negationCount = 0
        while clause.hasPrefix("!") {
            clause.removeFirst()
            clause = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            negationCount += 1
        }
        let negated = negationCount.isMultiple(of: 2) == false

        let result: Bool
        if clause.caseInsensitiveCompare("true") == .orderedSame {
            result = true
        } else if clause.caseInsensitiveCompare("false") == .orderedSame {
            result = false
        } else if let includeMatch = evaluateIncludes(clause, values: values) {
            result = includeMatch
        } else if let range = clause.range(of: "==") {
            let key = propertyKey(from: String(clause[..<range.lowerBound]))
            let expected = WallpaperEngineProjectPropertyValue.conditionLiteral(String(clause[range.upperBound...]))
            result = values[key].matches(expected)
        } else if let range = clause.range(of: "!=") {
            let key = propertyKey(from: String(clause[..<range.lowerBound]))
            let expected = WallpaperEngineProjectPropertyValue.conditionLiteral(String(clause[range.upperBound...]))
            result = !values[key].matches(expected)
        } else {
            let key = propertyKey(from: clause)
            result = values[key].isTruthy
        }

        return negated ? !result : result
    }

    private static func evaluateIncludes(
        _ clause: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool? {
        guard let includeRange = clause.range(of: ".includes("),
              clause.hasSuffix(")") else {
            return nil
        }

        let rawList = String(clause[..<includeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawList.hasPrefix("["),
              rawList.hasSuffix("]") else {
            return nil
        }

        let argumentStart = includeRange.upperBound
        let argumentEnd = clause.index(before: clause.endIndex)
        let key = propertyKey(from: String(clause[argumentStart..<argumentEnd]))
        let candidates = rawList
            .dropFirst()
            .dropLast()
            .split(separator: ",")
            .map { WallpaperEngineProjectPropertyValue.conditionLiteral(String($0)) }

        return candidates.contains { values[key].matches($0) }
    }

    private static func propertyKey(from raw: String) -> String {
        // Strip trailing `.value` only (keep keys like slider.value.max).
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".value") {
            return String(trimmed.dropLast(".value".count))
        }
        return trimmed
    }

}

private extension Optional where Wrapped == WallpaperEngineProjectPropertyValue {
    var isTruthy: Bool {
        guard let value = self else { return false }
        switch value {
        case .bool(let bool):
            return bool
        case .number(let number):
            return abs(number) > 0.000_001
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && trimmed.caseInsensitiveCompare("false") != .orderedSame
                && trimmed != "0"
        }
    }

    func matches(_ expected: WallpaperEngineProjectPropertyValue) -> Bool {
        self?.looselyMatches(expected) ?? false
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
