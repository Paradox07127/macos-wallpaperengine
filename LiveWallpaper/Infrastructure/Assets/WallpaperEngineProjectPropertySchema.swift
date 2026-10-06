import Foundation
import LiveWallpaperCore

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

    /// Keep only editable declared keys: a preset map has an entry for every row (including decorative `text`/`group` empty strings) and `effectiveValues` would let those win over schema defaults.
    func declaredEditableValues(
        _ values: [String: WallpaperEngineProjectPropertyValue]
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        guard !properties.isEmpty else { return values }
        let editable = Set(properties.lazy.filter { $0.type.isEditable }.map(\.key))
        return values.filter { editable.contains($0.key) }
    }

    /// Reads `layeredPropertyValues()`, never `propertyOverrides`: the increment alone is half the look, so a descriptor carrying a preset would render as bare scene defaults.
    static func effectiveSceneValues(
        descriptor: SceneDescriptor,
        cacheRootURL: URL
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        let layered = descriptor.layeredPropertyValues()
        do {
            let schema = try read(from: cacheRootURL, includeSchemeColor: true)
            return schema.effectiveValues(
                overrides: schema.declaredEditableValues(layered)
            )
        } catch {
            return layered
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

        private static let promoKeyTokens = [
            "href", "http", "www", "imgsrc", "kofi", "ko-fi", "patreon", "paypal",
            "donate", "sponsor", "discord", "afdian", "aifadian", "爱发电", "赞助", "赞赏", "打赏"
        ]
        private static let promoTextMarkers = [
            "<a ", "<a>", "href=", "<img", "src=", "http://", "https://", "www.",
            "ko-fi", "kofi", "patreon", "paypal", "donate", "sponsor", "discord.gg",
            "爱发电", "赞助", "赞赏", "打赏"
        ]

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

        /// `NSNumber as? Bool` succeeds for 0 and 1; only CoreFoundation booleans are booleans. The declared type is the disambiguator.
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
            let value: Double? = if let number = raw as? NSNumber {
                number.doubleValue
            } else if let string = raw as? String {
                Double(string)
            } else {
                nil
            }
            return value.flatMap { $0.isFinite ? $0 : nil }
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
        case sceneTexture = "scenetexture"
        case userShortcut = "usershortcut"
        case group
        case unsupported

        /// Rows whose "user has not chosen yet" state is an empty string. Omitting the key instead
        /// leaves a page on its own initializer, and the common `var custom = {}` is truthy in JS.
        var deliversEmptyStringWhenUnset: Bool {
            switch self {
            case .textinput, .file, .directory: true
            default: false
            }
        }

        var isEditable: Bool {
            switch self {
            case .bool, .slider, .combo, .color, .textinput, .file, .directory:
                return true
            case .text, .sceneTexture, .userShortcut, .group, .unsupported:
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
        var maps: [String: [String: String]] = [:]
        // Canonical lowercase spelling wins; remaining collisions use stable lexical order.
        for key in raw?.keys.sorted() ?? [] {
            guard let map = raw?[key] as? [String: String] else { continue }
            let normalized = key.lowercased()
            if maps[normalized] == nil || key == normalized {
                maps[normalized] = map
            }
        }
        selected = Self.selectMap(from: maps, preferredLanguages: preferredLanguages) ?? [:]
        fallback = maps["en-us"] ?? maps["en"] ?? [:]
    }

    func displayText(for raw: String) -> String {
        let cleaned = Self.clean(raw)
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
        for language in preferredLanguages.map({ $0.lowercased() }) {
            let candidates = localeCandidates(for: language)
            for candidate in candidates {
                if let map = maps[candidate] {
                    return map
                }
            }
        }
        return nil
    }

    private static func localeCandidates(for language: String) -> [String] {
        var candidates = [language]
        if language.hasPrefix("zh") {
            let components = language.split(separator: "-").map(String.init)
            let traditional = components.contains("hant") || components.contains("cht") ||
                (!components.contains("hans") && !components.contains("chs") &&
                    components.contains(where: { ["tw", "hk", "mo"].contains($0) }))
            candidates.append(contentsOf: traditional
                ? ["zh-cht", "zh-hant", "zh-tw", "zh-hk", "zh-mo"]
                : ["zh-chs", "zh-hans", "zh-cn", "zh-sg"])
        }
        if let prefix = language.split(separator: "-").first {
            candidates.append(String(prefix))
        }
        if language.hasPrefix("en") {
            candidates.append("en-us")
        }
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

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
        WPEPropertyLabelText.clean(raw)
    }
}

extension WallpaperEngineProjectPropertySchema {
    static func sceneConditionMatches(
        value: WallpaperEngineProjectPropertyValue?,
        condition: String
    ) -> Bool {
        ConditionEvaluator.matchesLiteral(value: value, condition: condition)
    }
}

private enum ConditionEvaluator {
    private static let maximumBytes = 16 * 1024
    private static let maximumParts = 512

    static func isVisible(
        condition: String?,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool {
        guard let condition, !condition.isEmpty else { return true }
        guard condition.utf8.prefix(maximumBytes + 1).count <= maximumBytes else { return false }
        var clauses = maximumParts
        return evaluateBoolean(condition, values: values, depth: 0, clauses: &clauses) ?? false
    }

    static func matchesLiteral(
        value: WallpaperEngineProjectPropertyValue?,
        condition: String
    ) -> Bool {
        value.matches(.conditionLiteral(condition))
    }

    private static let maximumNesting = 64

    private static func evaluateBoolean(
        _ raw: String,
        values: [String: WallpaperEngineProjectPropertyValue],
        depth: Int,
        clauses: inout Int
    ) -> Bool? {
        guard depth <= maximumNesting else { return nil }
        let expression = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty,
              let groups = split(expression, separator: "||", topLevel: true) else { return nil }
        if groups.count > 1 {
            let results = groups.map { evaluateBoolean($0, values: values, depth: depth, clauses: &clauses) }
            guard results.allSatisfy({ $0 != nil }) else { return nil }
            return results.contains(true)
        }
        guard let terms = split(expression, separator: "&&", topLevel: true) else { return nil }
        if terms.count > 1 {
            let results = terms.map { evaluateBoolean($0, values: values, depth: depth, clauses: &clauses) }
            guard results.allSatisfy({ $0 != nil }) else { return nil }
            return results.allSatisfy { $0 == true }
        }
        // Strip a complete group only; an includes(...) call remains an atomic clause.
        var body = expression
        var negations = 0
        while body.hasPrefix("!") {
            body = String(body.unicodeScalars.dropFirst())
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            negations += 1
        }
        guard !body.isEmpty else { return nil }
        if isWholeGroup(body) {
            guard let result = evaluateBoolean(String(body.unicodeScalars.dropFirst().dropLast()), values: values,
                                               depth: depth + 1, clauses: &clauses) else { return nil }
            return negations.isMultiple(of: 2) ? result : !result
        }
        guard clauses > 0 else { return nil }
        clauses -= 1
        return evaluateClause(expression, values: values)
    }

    /// True when the leading `(` closes at the final `)`, so `(a) && (b)` is not one group.
    private static func isWholeGroup(_ raw: String) -> Bool {
        guard raw.utf8.first == 40, raw.utf8.last == 41 else { return false }
        // "(" never matches as a top-level delimiter, so this only checks that the inside is balanced.
        return split(String(raw.unicodeScalars.dropFirst().dropLast()), separator: "(", topLevel: true) != nil
    }

    /// Quoted author literals are data. `topLevel` also requires balanced ()/[] and
    /// splits only outside them, so groups and includes calls stay atomic.
    private static func split(_ raw: String, separator: String, topLevel: Bool) -> [String]? {
        let bytes = Array(raw.utf8)
        let delimiter = Array(separator.utf8)
        var stack: [UInt8] = []
        var quote: UInt8?
        var escaped = false
        var parts: [String] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == activeQuote {
                    quote = nil
                }
            } else if byte == 34 || byte == 39 {
                quote = byte
            } else if topLevel, byte == 40 || byte == 91 {
                guard stack.count < maximumNesting else { return nil }
                stack.append(byte)
            } else if topLevel, byte == 41 || byte == 93 {
                guard stack.last == (byte == 41 ? 40 : 91) else { return nil }
                stack.removeLast()
            } else if stack.isEmpty, bytes[index...].starts(with: delimiter) {
                guard let part = String(bytes: bytes[start ..< index], encoding: .utf8) else { return nil }
                parts.append(part)
                guard parts.count < maximumParts else { return nil }
                index += delimiter.count
                start = index
                continue
            }
            index += 1
        }
        guard stack.isEmpty, quote == nil, !escaped,
              let part = String(bytes: bytes[start...], encoding: .utf8) else { return nil }
        parts.append(part)
        return parts
    }

    private static func evaluateClause(
        _ rawClause: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool? {
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
        } else if let comparison = evaluatePrimitiveComparison(clause, values: values) {
            switch comparison {
            case let .value(matched): result = matched
            case .invalid: return nil
            }
        } else if let includeMatch = evaluateIncludes(clause, values: values) {
            result = includeMatch
        } else if let operands = split(clause, separator: "==", topLevel: false), operands.count == 2 {
            guard let matched = looseEquality(operands[0], operands[1], values: values) else { return nil }
            result = matched
        } else if let operands = split(clause, separator: "!=", topLevel: false), operands.count == 2 {
            guard let matched = looseEquality(operands[0], operands[1], values: values) else { return nil }
            result = !matched
        } else {
            let key = propertyKey(from: clause)
            result = values[key].isTruthy
        }

        return negated ? !result : result
    }

    /// Strict ===/!== and numeric ordering; operators are tried longest-first so `>=` is not read as `>`.
    private enum PrimitiveComparison { case value(Bool), invalid }

    private static func evaluatePrimitiveComparison(
        _ clause: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> PrimitiveComparison? {
        for operation in ["===", "!==", "<=", ">=", "<", ">"] {
            guard let operands = split(clause, separator: operation, topLevel: false) else { return .invalid }
            guard operands.count > 1 else { continue }
            guard operands.count == 2,
                  let lhs = primitiveOperand(operands[0], values: values),
                  let rhs = primitiveOperand(operands[1], values: values) else { return .invalid }
            if operation == "===" || operation == "!==" {
                let equal: Bool = switch (lhs, rhs) {
                case let (.bool(a), .bool(b)): a == b
                case let (.number(a), .number(b)): a == b
                case let (.string(a), .string(b)): a.utf16.elementsEqual(b.utf16)
                default: false
                }
                return .value(operation == "===" ? equal : !equal)
            }
            guard let a = numericValue(lhs), let b = numericValue(rhs) else { return .value(false) }
            switch operation {
            case "<": return .value(a < b)
            case ">": return .value(a > b)
            case "<=": return .value(a <= b)
            default: return .value(a >= b)
            }
        }
        return nil
    }

    private static func unwrappedOperand(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while isWholeGroup(value) {
            value = String(value.unicodeScalars.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    /// One side of a loose `==`/`!=`: a resolved literal/identifier, `nil` for
    /// JS `undefined`, or `.invalid` for a malformed operand.
    private enum EqualityOperand {
        case value(WallpaperEngineProjectPropertyValue?)
        case invalid
    }

    /// WPE conditions run as JavaScript, so both `==` operands are expressions:
    /// quoted text, `true`/`false` and numbers are literals, and any other bare
    /// token is an identifier resolved against the property values — a miss is
    /// JS `undefined`, and `undefined == undefined` is true. That is why typo'd
    /// conditions like `value==ture` still show their property in WPE.
    /// Returns nil for malformed operands and unsupported expressions, not a miss.
    private static func looseEquality(
        _ rawLHS: String,
        _ rawRHS: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool? {
        guard case let .value(lhs) = equalityOperand(rawLHS, values: values),
              case let .value(rhs) = equalityOperand(rawRHS, values: values) else { return nil }
        switch (lhs, rhs) {
        case let (.number(number)?, .string(text)?), let (.string(text)?, .number(number)?):
            // JS `==` converts the string to a number, so 2 == '2.0'.
            guard let coerced = numericValue(.string(text)) else { return false }
            return WallpaperEngineProjectPropertyValue.number(number).looselyMatches(.number(coerced))
        case let (lhs?, rhs?): return lhs.looselyMatches(rhs)
        case (nil, nil): return true
        default: return false
        }
    }

    private static func equalityOperand(
        _ raw: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> EqualityOperand {
        let operand = unwrappedOperand(raw)
        guard !operand.isEmpty else { return .invalid }
        if let quote = operand.utf8.first, quote == 34 || quote == 39 {
            guard operand.utf8.count >= 2, operand.utf8.last == quote else { return .invalid }
            return .value(.string(String(operand.unicodeScalars.dropFirst().dropLast())))
        }
        if operand.caseInsensitiveCompare("true") == .orderedSame {
            return .value(.bool(true))
        }
        if operand.caseInsensitiveCompare("false") == .orderedSame {
            return .value(.bool(false))
        }
        if let number = Double(operand) {
            return .value(.number(number))
        }
        if let value = values[propertyKey(from: operand)] {
            return .value(value)
        }
        // Only a dotted identifier path can be JS `undefined`; `a + 1` or `f()` is an unsupported expression.
        let isIdentifierPath = operand.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard let first = part.first, !first.isNumber else { return false }
            return part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        }
        return isIdentifierPath ? .value(nil) : .invalid
    }

    private static func primitiveOperand(
        _ raw: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> WallpaperEngineProjectPropertyValue? {
        let value = unwrappedOperand(raw)
        if value.hasSuffix(".value") {
            return values[propertyKey(from: value)]
        }
        if value == "true" {
            return .bool(true)
        }
        if value == "false" {
            return .bool(false)
        }
        if let quote = value.utf8.first, quote == 34 || quote == 39 {
            guard value.utf8.last == quote, value.utf8.count >= 2 else { return nil }
            // Like conditionLiteral, quotes are stripped without escape decoding.
            return .string(String(value.unicodeScalars.dropFirst().dropLast()))
        }
        return Double(value).map(WallpaperEngineProjectPropertyValue.number)
    }

    private static func numericValue(_ value: WallpaperEngineProjectPropertyValue) -> Double? {
        switch value {
        case let .number(number): number
        case let .bool(flag): flag ? 1 : 0
        case let .string(string): Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func evaluateIncludes(
        _ clause: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> Bool? {
        guard let operands = split(clause, separator: ".includes(", topLevel: false), operands.count == 2,
              clause.hasSuffix(")") else {
            return nil
        }

        let rawList = operands[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawList.hasPrefix("["),
              rawList.hasSuffix("]") else {
            return nil
        }

        let key = propertyKey(from: String(operands[1].dropLast()))
        guard let items = split(String(rawList.dropFirst().dropLast()), separator: ",", topLevel: false) else {
            return false
        }
        let candidates = items
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(WallpaperEngineProjectPropertyValue.conditionLiteral)

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
