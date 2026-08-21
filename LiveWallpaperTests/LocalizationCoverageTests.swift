import Foundation
import Testing

@Suite("Localization coverage")
struct LocalizationCoverageTests {
    private static let requiredLocales = ["zh-Hans", "zh-Hant", "ja"]

    @Test("String catalogs include supported localizations for every entry")
    func catalogsIncludeSupportedTranslations() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            for locale in Self.requiredLocales {
                let missing = catalog.keysMissingLocalization(locale)

                #expect(
                    missing.isEmpty,
                    "\(catalogName) is missing \(locale) translations for: \(missing.prefix(20).joined(separator: ", "))"
                )
            }
        }
    }

    // The catalog tests above only look at entries the catalog already has, so
    // they are blind to the opposite gap: a key deleted from the catalog while
    // code still asks for it. 2026-08-17: removing a dead
    // `WeatherReactiveService.LocationStatus.authorized` case took the
    // "Authorized" key with it while BoardSettingsView still rendered
    // `Text("Authorized")`, and ja/zh-Hans/zh-Hant VoiceOver read English with
    // all 3020 tests green. Catalog keys are shared by text, not by feature —
    // a "Weather location status" comment does not make the key weather-only.
    @Test("Literal localization keys used in source still exist in the catalog")
    func literalLocalizationKeysExistInCatalog() throws {
        let catalog = try StringCatalog.load(named: "Localizable.xcstrings")
        let scan = try LocalizedLiteralScan.scanRepository(["LiveWallpaper", "Packages"])

        #expect(scan.fileCount > 100, "Source sweep collapsed to \(scan.fileCount) files — the key scan is unenforced")
        #expect(scan.keys.count > 500, "Only \(scan.keys.count) literal keys matched — the scan patterns stopped matching")

        let missing = Set(scan.keys.filter { catalog.strings[$0.key] == nil }.map { "\($0.key) (\($0.location))" }).sorted()
        #expect(
            missing.isEmpty,
            "Localizable.xcstrings is missing keys the app still asks for: \(missing.prefix(20).joined(separator: "; "))"
        )
    }

    // The scan above drops any literal containing a backslash, which silently
    // exempts every interpolated `String(localized:)` — and those are exactly
    // the ones whose catalog key differs from the source text (`%@`/`%lld` in
    // place of each interpolation). 2026-08-20: a new
    // "Some files could not be deleted: \(names)" shipped with no catalog entry
    // at all and all 3153 tests stayed green.
    @Test("Interpolated localized literals resolve to a catalog key")
    func interpolatedLocalizationKeysExistInCatalog() throws {
        let catalog = try StringCatalog.load(named: "Localizable.xcstrings")
        let sites = try InterpolatedLiteralScan.scanRepository(["LiveWallpaper", "Packages"])

        #expect(sites.count > 30, "Only \(sites.count) interpolated sites matched — the scan stopped matching")
        let keys = Array(catalog.strings.keys)
        let missing = sites
            .filter { site in !keys.contains(where: site.matchesKey) }
            .map { "\($0.literal) (\($0.location))" }
        #expect(
            missing.isEmpty,
            "Localizable.xcstrings has no key for: \(missing.prefix(10).joined(separator: "; "))"
        )
    }

    // Every skipped form is followed by a scanned one, so a scanner that bails out
    // early (rather than skipping just that form) fails this test instead of
    // passing it by finding less.
    @Test("The literal-key scan reads live call sites and skips the forms it cannot resolve")
    func literalLocalizationKeyScanHasTeeth() {
        let probe = """
        struct Probe: View {
            var body: some View {
                Text("Scanned literal")
                Text(
                    // A translator note sitting inside the call.
                    "Scanned across lines"
                )
                SettingRow(badge: Badge(accessibilityLabel: Text("Scanned nested")))
                Button("Scanned button", action: run)
                ProgressView("Scanned progress")
                let copy = String(localized: "Scanned labelled")
                Text(verbatim: "Skipped verbatim")
                Text("Skipped \\(interpolated) literal")
                Text(runtimeKey)
                Image("Skipped asset name")
                // Text("Skipped whole-line comment")
                let trailing = 1 // Text("Skipped trailing comment")
                /* Text("Skipped block comment")
                   Text("Skipped block comment second line") */
                let fixture = #"Text("Skipped raw fixture")"#
                Link("https://example.com", destination: url); Text("Scanned after a URL on the same line")
                Text("Scanned after every skipped form")
            }
        }

        #Preview("Probe") {
            Text("Skipped preview")
        }

        struct BelowThePreview: View {
            var body: some View { Text("Scanned below the preview block") }
        }
        """

        let found = Set(LocalizedLiteralScan.keys(in: probe, path: "Probe.swift").map(\.key))

        #expect(LocalizedLiteralScan.patternCount == 2, "A scan pattern failed to compile and was dropped")
        #expect(found == [
            "Scanned literal",
            "Scanned across lines",
            "Scanned nested",
            "Scanned button",
            "Scanned progress",
            "Scanned labelled",
            "Scanned after a URL on the same line",
            "Scanned after every skipped form",
            "Scanned below the preview block",
        ])
    }

    @Test("Supported translations preserve string format placeholders")
    func supportedTranslationsPreservePlaceholders() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            for locale in Self.requiredLocales {
                let mismatches = catalog.placeholderMismatches(for: locale)

                #expect(
                    mismatches.isEmpty,
                    "\(catalogName) has \(locale) placeholder mismatches: \(mismatches.prefix(20).joined(separator: "; "))"
                )
            }
        }
    }

    @Test("String catalogs do not localize literal percent signs")
    func stringCatalogsDoNotLocalizeLiteralPercentSigns() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            let issues = catalog.literalPercentIssues()

            #expect(
                issues.isEmpty,
                "\(catalogName) contains literal percent signs that should be formatted in code: \(issues.prefix(20).joined(separator: "; "))"
            )
        }
    }

    @Test("String catalogs do not keep stale extraction entries")
    func stringCatalogsDoNotKeepStaleEntries() throws {
        for catalogName in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let catalog = try StringCatalog.load(named: catalogName)
            let stale = catalog.staleKeys()

            #expect(
                stale.isEmpty,
                "\(catalogName) contains stale extraction entries: \(stale.prefix(20).joined(separator: ", "))"
            )
        }
    }

    @Test("Shared package UI resolves app-localized Text from the app bundle")
    func sharedPackageUIResolvesTextFromAppBundle() throws {
        let source = try Self.projectFile("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/SettingRow.swift")

        #expect(source.contains("Text(title, bundle: .main)"))
        #expect(source.contains("Text($0, bundle: .main)"))
        #expect(source.contains("let info: String.LocalizationValue?"))
        #expect(source.contains("@AppStorage(AppLanguagePreference.storageKey)"))
        #expect(source.contains(".help(localizedText)"))
        #expect(source.contains("Text(verbatim: localizedText)"))
        #expect(!source.contains(".help(text)"))
        #expect(!source.contains("self.title = Text(title)"))
        #expect(!source.contains("self.subtitle = subtitle.map { Text($0) }"))
        #expect(!source.contains("self.info = info.map { Text($0) }"))
    }

    @Test("Shortcut action copy remains localizable at render time")
    func shortcutActionCopyRemainsLocalizableAtRenderTime() throws {
        let shortcutView = try Self.projectFile("LiveWallpaper/Views/Settings/ShortcutsView.swift")
        let actionModel = try Self.projectFile("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Schema/GlobalShortcutAction.swift")

        #expect(!shortcutView.contains("Text(verbatim: action.displayName)"))
        #expect(shortcutView.contains("Text(action.displayNameKey, bundle: .main)"))
        #expect(shortcutView.contains("Text(action.displayDescriptionKey, bundle: .main)"))
        #expect(actionModel.contains("var displayNameKey: LocalizedStringKey"))
        #expect(actionModel.contains("var displayDescriptionKey: LocalizedStringKey"))
    }

    @Test("Onboarding unsupported-import copy remains statically catalogued for both capabilities")
    func onboardingUnsupportedImportCopyIsCatalogued() throws {
        let catalog = try StringCatalog.load(named: "Localizable.xcstrings")
        let keys = [
            "That file type isn't supported. Pick a video or web page.",
            "That file type isn't supported. Pick a video, web page, or scene.",
        ]
        for key in keys {
            #expect(catalog.strings[key] != nil, "Missing onboarding recovery key: \(key)")
            for locale in [catalog.sourceLanguage] + Self.requiredLocales {
                #expect(
                    catalog.strings[key]?.localizations?[locale]?.stringUnit?.value.isEmpty == false,
                    "Missing \(locale) onboarding recovery copy for: \(key)"
                )
                #expect(
                    catalog.strings[key]?.localizations?[locale]?.stringUnit?.state == "translated",
                    "Onboarding recovery copy is not translated for \(locale): \(key)"
                )
            }
        }

        let source = try Self.projectFile("LiveWallpaper/Views/Onboarding/PickerView.swift")
        #expect(source.contains("unsupportedFileTypeMessage(sceneCapable: Bool) -> LocalizedStringResource"))
        #expect(source.contains("return \"That file type isn't supported. Pick a video or web page.\""))
        #expect(source.contains("return \"That file type isn't supported. Pick a video, web page, or scene.\""))
        #expect(
            Self.hasDirectOnboardingSceneCapabilityWiring(source),
            "PickerView.sceneCapable must directly use the tested .scene catalog policy"
        )
        #expect(
            Self.hasDirectOnboardingSceneCapabilityPolicy(source),
            "The onboarding scene policy must directly query FeatureCatalog's .scene capability"
        )
        #expect(source.contains(
            "return fail(OnboardingImportCopy.unsupportedFileTypeMessage(sceneCapable: sceneCapable))"
        ))

        let invertedWiringProbe = """
        private var sceneCapable: Bool {
            !OnboardingImportCopy.sceneCapable(in: featureCatalog)
        }
        """
        #expect(
            !Self.hasDirectOnboardingSceneCapabilityWiring(invertedWiringProbe),
            "The capability-wiring guard must reject an inverted scene feature"
        )

        let invertedPolicyProbe = """
        static func sceneCapable(in catalog: FeatureCatalog) -> Bool {
            !catalog.isEnabled(.scene)
        }
        """
        #expect(
            !Self.hasDirectOnboardingSceneCapabilityPolicy(invertedPolicyProbe),
            "The capability-policy guard must reject an inverted FeatureCatalog query"
        )
    }

    @Test("Workshop import copy describes linked local projects, not online Workshop connection")
    func workshopImportCopyAvoidsOnlineConnectionLanguage() throws {
        var scanned = RepositoryRoot.swiftFiles(under: "LiveWallpaper")
        scanned.append(RepositoryRoot.url("LiveWallpaper/Resources/Localizable.xcstrings"))
        #expect(scanned.count > 100, "App source sweep collapsed to \(scanned.count) files — the copy scan is unenforced")

        let source = try scanned.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")

        let disallowedPhrases = [
            "Connect Steam Workshop",
            "Search Workshop",
            "Scanning workshop folder",
            "Workshop folder access expired",
            "Workshop folder access denied",
            "Workshop folder is unreachable",
            "Discover Workshop projects under your Steam library",
            "Discover Workshop projects from your Steam Workshop folder",
            "Open a display first, then choose a Workshop wallpaper to apply.",
            "Choose the Wallpaper Engine folder that contains your subscribed project folders.",
            "No Workshop projects found",
            "Recent Workshop Projects",
            "Return to the recent Workshop projects grid",
            "Wallpaper Engine project:",
            "Wallpaper Engine project type is unknown",
            "We couldn't recognize this Wallpaper Engine project type.",
            "Opens a folder chooser to apply a Wallpaper Engine project",
            "Select your Wallpaper Engine projects folder",
            "Auto-enabled for Wallpaper Engine folders.",
            "Browse Wallpaper Engine workshop projects",
            "Wallpaper Engine scenes across every connected display.",
            "Wallpaper Engine scene imports.",
            "Wallpaper Engine Cache",
        ]

        let hits = disallowedPhrases.filter { source.contains($0) }
        #expect(hits.isEmpty, "User-facing import copy still implies online Workshop/WPE coupling: \(hits)")
        #expect(source.contains("Workshop Library"), "The product decision keeps the Workshop Library page label.")
    }

    private static func projectFile(_ relativePath: String) throws -> String {
        try RepositoryRoot.source(relativePath)
    }

    private static func hasDirectOnboardingSceneCapabilityWiring(_ source: String) -> Bool {
        let normalized = source.filter { !$0.isWhitespace }
        let expected = "privatevarsceneCapable:Bool{OnboardingImportCopy.sceneCapable(in:featureCatalog)}"
        return normalized.components(separatedBy: expected).count - 1 == 1
            && normalized.components(separatedBy: "privatevarsceneCapable:Bool{").count - 1 == 1
    }

    private static func hasDirectOnboardingSceneCapabilityPolicy(_ source: String) -> Bool {
        let normalized = source.filter { !$0.isWhitespace }
        let expected = "staticfuncsceneCapable(incatalog:FeatureCatalog)->Bool{catalog.isEnabled(.scene)}"
        return normalized.components(separatedBy: expected).count - 1 == 1
            && normalized.components(separatedBy: "staticfuncsceneCapable(incatalog:FeatureCatalog)->Bool{").count - 1 == 1
    }
}

/// Collects the localization keys that source code spells out as a plain string
/// literal, so they can be checked back against the catalog.
///
/// Deliberately blind — under-reporting beats a false alarm, and every form
/// below stays uncovered by this gate:
/// - interpolated or escaped literals (`Text("\(count) items")`, `Text("a\nb")`),
///   because the source text is not the catalog key verbatim;
/// - keys that arrive as a variable, enum property, or `LocalizedStringKey`
///   passed down from a caller, and keys spelled inside a conditional
///   expression (`Text(busy ? "Importing…" : "Idle")`);
/// - project-defined wrappers that take a `LocalizedStringKey` of their own
///   (`WorkshopFilterRow("Maturity")`, `SettingsSearchSectionHeader(…)`). The
///   allowlist stays SwiftUI-only on purpose: `appendingPathComponent("Workshop")`
///   and `contains("error")` also spell a live catalog key, so widening it by
///   name would invent failures rather than find them;
/// - raw (`#"…"#`) and multi-line (`"""`) string literals;
/// - preview bodies (that copy never ships) and comments.
///
/// `Text(verbatim:)` is excluded by construction: it does not localize, and the
/// patterns only match a literal that directly follows the opening paren.
private enum LocalizedLiteralScan {
    struct Hit: Hashable {
        let key: String
        let location: String
    }

    static var patternCount: Int { patterns.count }

    static func scanRepository(_ relativePaths: [String]) throws -> (keys: [Hit], fileCount: Int) {
        var collected: [Hit] = []
        var fileCount = 0
        for relativePath in relativePaths {
            // Package test fixtures are free to spell any string they like; only
            // shipping sources owe the catalog a key.
            for url in RepositoryRoot.swiftFiles(under: relativePath) where !url.path.contains("/Tests/") {
                fileCount += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                let display = RepositoryRoot.relativePath(of: url)
                collected.append(contentsOf: keys(in: source, path: display))
            }
        }
        return (collected, fileCount)
    }

    static func keys(in source: String, path: String) -> [Hit] {
        let scannable = scannableText(in: source)
        let range = NSRange(scannable.startIndex..<scannable.endIndex, in: scannable)
        return patterns.flatMap { pattern in
            pattern.matches(in: scannable, range: range).compactMap { match -> Hit? in
                guard let keyRange = Range(match.range(at: 1), in: scannable) else { return nil }
                let key = String(scannable[keyRange])
                guard !key.isEmpty, !key.contains("\\") else { return nil }
                let line = scannable[scannable.startIndex..<keyRange.lowerBound].filter { $0 == "\n" }.count + 1
                return Hit(key: key, location: "\(path):\(line)")
            }
        }
    }

    /// Blanks comments and `#Preview` bodies while keeping one line per line, so
    /// reported line numbers still point at the real call site. A preview is
    /// skipped up to its closing column-zero `}` rather than to end of file —
    /// truncating would silently drop every declaration written below it.
    static func scannableText(in source: String) -> String {
        var lines: [String] = []
        var blockCommentDepth = 0
        var insidePreview = false
        for line in source.components(separatedBy: "\n") {
            let (stripped, depth) = strippingComments(line, blockCommentDepth: blockCommentDepth)
            blockCommentDepth = depth
            if insidePreview {
                lines.append("")
                if stripped.hasPrefix("}") { insidePreview = false }
                continue
            }
            if stripped.trimmingCharacters(in: .whitespaces).hasPrefix("#Preview") {
                insidePreview = true
                lines.append("")
                continue
            }
            lines.append(stripped)
        }
        return lines.joined(separator: "\n")
    }

    /// Quote-aware enough that `//` inside a string literal (a URL) is kept and a
    /// trailing `// Text("…")` note is dropped. String state does not carry across
    /// lines, so a `"""` body degrades to over-stripping, never to a false hit.
    private static func strippingComments(_ line: String, blockCommentDepth: Int) -> (String, Int) {
        var depth = blockCommentDepth
        var output = ""
        var insideString = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            let pair = next < line.endIndex ? String([character, line[next]]) : ""
            if depth > 0 {
                if pair == "*/" { depth -= 1; index = line.index(after: next); continue }
                if pair == "/*" { depth += 1; index = line.index(after: next); continue }
                output.append(" ")
                index = next
                continue
            }
            if insideString {
                if character == "\\", next < line.endIndex {
                    output.append(character)
                    output.append(line[next])
                    index = line.index(after: next)
                    continue
                }
                if character == "\"" { insideString = false }
                output.append(character)
                index = next
                continue
            }
            if character == "\"" { insideString = true; output.append(character); index = next; continue }
            if pair == "//" { break }
            if pair == "/*" { depth += 1; index = line.index(after: next); continue }
            output.append(character)
            index = next
        }
        return (output, depth)
    }

    private static let patterns: [NSRegularExpression] = {
        let literal = #""((?:[^"\\\n]|\\.)*)""#
        let initializers = "Text|Button|Label|Toggle|TextField|SecureField|Picker|Section|Menu|Stepper|ProgressView|LocalizedStringKey|LocalizedStringResource"
        let modifiers = "help|alert|confirmationDialog|navigationTitle|accessibilityLabel|accessibilityHint"
        // The `"` in the lookbehind keeps a raw-string source fixture (`#"Text("…")"#`)
        // from reading as a call site.
        return [
            #"(?<![A-Za-z0-9_"])(?:\#(initializers))\(\s*"# + literal,
            #"(?:String\(localized:|\.(?:\#(modifiers))\()\s*"# + literal,
        ].compactMap { try? NSRegularExpression(pattern: $0) }
    }()
}

private struct StringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]

    static func load(named name: String) throws -> StringCatalog {
        let data = try RepositoryRoot.data("LiveWallpaper/Resources/\(name)")
        return try JSONDecoder().decode(StringCatalog.self, from: data)
    }

    func keysMissingLocalization(_ locale: String) -> [String] {
        strings.keys.sorted().filter { key in
            // The empty key is an extraction artifact of `Picker("", …)`-style
            // calls (65 sites) and has nothing to translate; Xcode re-adds it
            // on every catalog re-save. The value check below already exempted
            // it — an absent unit is the same case, not a missing translation.
            guard !key.isEmpty else { return false }
            // `shouldTranslate: false` marks deliberately unlocalized entries
            // (brand names like CFBundleDisplayName: the per-SKU Info.plist value
            // must stand, and any catalog override would leak across SKUs).
            guard strings[key]?.shouldTranslate != false else { return false }
            guard let unit = strings[key]?.localizations?[locale]?.stringUnit else {
                return true
            }
            return unit.value.isEmpty
        }
    }

    func placeholderMismatches(for locale: String) -> [String] {
        strings.keys.sorted().compactMap { key in
            let sourceValue = strings[key]?.localizations?[sourceLanguage]?.stringUnit?.value ?? key
            guard let localizedValue = strings[key]?.localizations?[locale]?.stringUnit?.value else {
                return nil
            }

            let sourcePlaceholders = Self.placeholders(in: sourceValue)
            let localizedPlaceholders = Self.placeholders(in: localizedValue)
            guard !Self.placeholdersMatch(sourcePlaceholders, localizedPlaceholders) else {
                return nil
            }

            return "\(key) expected \(sourcePlaceholders) but found \(localizedPlaceholders)"
        }
    }

    func literalPercentIssues() -> [String] {
        strings.keys.sorted().flatMap { key in
            let localizations = strings[key]?.localizations ?? [:]
            return localizations.keys.sorted().compactMap { locale -> String? in
                guard let value = localizations[locale]?.stringUnit?.value,
                      Self.containsLiteralPercent(in: value) else {
                    return nil
                }
                return "\(key) [\(locale)]"
            }
        }
    }

    func staleKeys() -> [String] {
        strings.keys.sorted().filter { key in
            strings[key]?.extractionState == "stale"
        }
    }

    private static func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?[+\- #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjtq])?[diuoxXfFeEgGaAcCsSp@]"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression?.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        } ?? []
    }

    private static func placeholdersMatch(_ source: [String], _ localized: [String]) -> Bool {
        let usesExplicitPositions = source.allSatisfy {
            $0.range(of: #"%\d+\$"#, options: .regularExpression) != nil
        }
        return usesExplicitPositions ? source.sorted() == localized.sorted() : source == localized
    }

    private static func containsLiteralPercent(in value: String) -> Bool {
        let placeholderPattern = #"%(?:(\d+)\$)?[+\- #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjtq])?[diuoxXfFeEgGaAcCsSp@]"#
        guard let expression = try? NSRegularExpression(pattern: placeholderPattern) else {
            return value.contains("%")
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let stripped = expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        return stripped.contains("%")
    }

    struct Entry: Decodable {
        let extractionState: String?
        let localizations: [String: Localization]?
        let shouldTranslate: Bool?
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    struct StringUnit: Decodable {
        let state: String?
        let value: String
    }
}

/// Interpolated `String(localized:)` call sites, matched against catalog keys by
/// their static text: the key writes `%@`/`%lld` where the source writes an
/// interpolation, so only the text between them can be compared.
private enum InterpolatedLiteralScan {
    struct Site {
        let literal: String
        let location: String
        /// The static segments, in order. Two adjacent segments are separated
        /// by exactly one placeholder in the catalog key.
        let segments: [String]

        func matchesKey(_ key: String) -> Bool {
            var remainder = Substring(key)
            for (index, segment) in segments.enumerated() {
                if index == 0 {
                    guard remainder.hasPrefix(segment) else { return false }
                    remainder = remainder.dropFirst(segment.count)
                    continue
                }
                if segment.isEmpty {
                    // Trailing interpolation: whatever is left is the placeholder.
                    guard index == segments.count - 1 else { continue }
                    return !remainder.isEmpty
                }
                guard let found = remainder.range(of: segment) else { return false }
                // A placeholder stands between the segments, so it cannot be empty.
                guard found.lowerBound > remainder.startIndex else { return false }
                remainder = remainder[found.upperBound...]
            }
            return segments.last?.isEmpty == true || remainder.isEmpty
        }
    }

    static func scanRepository(_ relativePaths: [String]) throws -> [Site] {
        var sites: [Site] = []
        for relativePath in relativePaths {
            for url in RepositoryRoot.swiftFiles(under: relativePath) where !url.path.contains("/Tests/") {
                let source = LocalizedLiteralScan.scannableText(in: try String(contentsOf: url, encoding: .utf8))
                sites.append(contentsOf: parse(source, path: RepositoryRoot.relativePath(of: url)))
            }
        }
        return sites
    }

    private static let pattern = try? NSRegularExpression(
        // `String(` and `localized:` are routinely split across lines.
        pattern: #"String\(\s*localized:\s*"((?:[^"\\\n]|\\.)*)""#
    )

    private static func parse(_ source: String, path: String) -> [Site] {
        guard let pattern else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return pattern.matches(in: source, range: range).compactMap { match -> Site? in
            guard let literalRange = Range(match.range(at: 1), in: source) else { return nil }
            let literal = String(source[literalRange])
            guard literal.contains("\\(") else { return nil }
            let line = source[source.startIndex..<literalRange.lowerBound].filter { $0 == "\n" }.count + 1
            return Site(
                literal: literal,
                location: "\(path):\(line)",
                segments: staticSegments(of: literal)
            )
        }
    }

    /// Splits on `\(…)`, counting parentheses so a call inside the
    /// interpolation does not end it early, and unescaping the text between.
    private static func staticSegments(of literal: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var index = literal.startIndex
        while index < literal.endIndex {
            if literal[index] == "\\", literal.index(after: index) < literal.endIndex {
                let next = literal[literal.index(after: index)]
                if next == "(" {
                    var depth = 0
                    var cursor = literal.index(after: index)
                    while cursor < literal.endIndex {
                        if literal[cursor] == "(" { depth += 1 }
                        if literal[cursor] == ")" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        cursor = literal.index(after: cursor)
                    }
                    segments.append(current)
                    current = ""
                    index = cursor < literal.endIndex ? literal.index(after: cursor) : literal.endIndex
                    continue
                }
                current.append(next == "n" ? "\n" : next)
                index = literal.index(index, offsetBy: 2)
                continue
            }
            current.append(literal[index])
            index = literal.index(after: index)
        }
        segments.append(current)
        return segments
    }
}
