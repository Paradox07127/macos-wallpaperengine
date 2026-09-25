import Foundation
import Testing

@Suite("Localization coverage")
struct LocalizationCoverageTests {
    private static let requiredLocales = ["zh-Hans", "zh-Hant", "ja", "es"]

    static func projectSwiftFiles(_ roots: [String]) throws -> [String] {
        let base = RepositoryRoot.url("")
        var found: [String] = []
        for root in roots {
            let url = base.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(atPath: url.path) else { continue }
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                if relative.contains("Tests") { continue }
                found.append(url.appendingPathComponent(relative).path)
            }
        }
        return found
    }

    /// Full text of each `String(localized:` call, brace-matched so a nested
    /// call's closing paren does not end the outer one.
    static func stringLocalizedCalls(in source: String) -> [String] {
        var calls: [String] = []
        let chars = Array(source)
        var i = 0
        let needle = Array("String(localized:")
        while i < chars.count {
            guard i + needle.count <= chars.count,
                  Array(chars[i..<(i + needle.count)]) == needle else {
                // Allow whitespace/newline between `String(` and `localized:`.
                if chars[i] == "S", let open = Self.matchLooseOpening(chars, at: i) {
                    let end = Self.matchClosingParen(chars, from: open)
                    calls.append(String(chars[i..<end]))
                    i = end
                    continue
                }
                i += 1
                continue
            }
            // From the `(` of `String(`, not from the trailing `:` — starting
            // past the open paren leaves the depth counter at zero and swallows
            // the rest of the file as one call.
            let end = Self.matchClosingParen(chars, from: i + "String".count)
            calls.append(String(chars[i..<end]))
            i = end
        }
        return calls
    }

    private static func matchLooseOpening(_ chars: [Character], at index: Int) -> Int? {
        let prefix = Array("String(")
        guard index + prefix.count <= chars.count,
              Array(chars[index..<(index + prefix.count)]) == prefix else { return nil }
        var j = index + prefix.count
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        guard j + 10 <= chars.count,
              String(chars[j..<(j + 10)]) == "localized:" else { return nil }
        return index + prefix.count - 1
    }

    private static func matchClosingParen(_ chars: [Character], from openParen: Int) -> Int {
        var depth = 0
        var i = openParen
        var inString = false
        while i < chars.count {
            let ch = chars[i]
            if inString {
                if ch == "\\" { i += 2; continue }
                if ch == "\"" { inString = false }
                i += 1
                continue
            }
            if ch == "\"" { inString = true }
            else if ch == "(" { depth += 1 }
            else if ch == ")" {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return chars.count
    }

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

    /// Catalog keys are shared by text, not by feature — a "Weather location status"
    /// comment does not make the key weather-only.
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

    /// The scan above drops any literal containing a backslash, which silently exempts every
    /// interpolated site — exactly the ones whose catalog key differs from the source text
    /// (`%@`/`%lld` in place of each interpolation).
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
            // English too: each of its plural forms has to consume the same arguments.
            for locale in [catalog.sourceLanguage] + Self.requiredLocales {
                let mismatches = catalog.placeholderMismatches(for: locale)

                #expect(
                    mismatches.isEmpty,
                    "\(catalogName) has \(locale) placeholder mismatches: \(mismatches.prefix(20).joined(separator: "; "))"
                )
            }
        }
    }

    @Test("English and Spanish vary by plural together, and an English plural has every form written")
    func pluralKeysVaryInEnglishAndSpanish() throws {
        let catalog = try StringCatalog.load(named: "Localizable.xcstrings")
        let plural = catalog.pluralKeys
        #expect(!plural.isEmpty, "No key varies by plural — the catalog decode stopped seeing variations")

        let english = plural.filter { catalog.strings[$0]?.localizations?[catalog.sourceLanguage]?.isComplete(for: catalog.sourceLanguage) != true }
        let oneForm = catalog.pluralMismatches
        #expect(english.isEmpty, "English plural with a form missing, blank or never used: \(english.prefix(20).joined(separator: ", "))")
        #expect(oneForm.isEmpty, "Only one of English and Spanish varies by plural; the bracketed one reads \"1 fondos\": \(oneForm.prefix(20).joined(separator: ", "))")
    }

    @Test("Plural entries count as written only with every form their language needs")
    func pluralCoverageHasTeeth() throws {
        func plural(_ forms: [String: String]) -> String {
            let variants = forms.map { #""\#($0.key)": {"stringUnit": {"state": "translated", "value": "\#($0.value)"}}"# }
            return #"{"variations": {"plural": {\#(variants.joined(separator: ", "))}}}"#
        }
        func substituted(_ value: String, _ forms: [String: String]) -> String {
            let variations = plural(forms).dropFirst().dropLast()
            return #"{"stringUnit": {"state": "translated", "value": "\#(value)"}, "substitutions": {"n": {"formatSpecifier": "lld", \#(variations)}}}"#
        }
        let english = plural(["one": "%lld item", "other": "%lld items"])
        let elementos = plural(["one": "%lld elemento", "other": "%lld elementos"])
        let fixture = #"""
        {"sourceLanguage": "en", "strings": {
          "%lld complete": {"localizations": {"en": \#(english), "es": \#(elementos)}},
          "%lld drops the count": {"localizations": {"en": \#(english), "es": \#(plural(["one": "un elemento", "other": "%lld elementos"]))}},
          "%lld es blank": {"localizations": {"en": \#(english), "es": \#(plural(["one": "", "other": "%lld elementos"]))}},
          "%lld es lacks one": {"localizations": {"en": \#(english), "es": \#(plural(["other": "%lld elementos"]))}},
          "%lld es only, en absent": {"localizations": {"es": \#(elementos)}},
          "%lld es only, en flat": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%lld items"}}, "es": \#(elementos)}},
          "%lld / %lld substituted": {"localizations": {
            "en": \#(substituted("%1$lld / %2$#@n@", ["one": "%arg item", "other": "%arg items"])),
            "es": \#(substituted("%1$lld / %2$#@n@", ["one": "%arg elemento", "other": "%arg elementos"]))}},
          "%lld / %lld substitution lacks one": {"localizations": {
            "en": \#(substituted("%lld / %#@n@", ["one": "%arg item", "other": "%arg items"])),
            "es": \#(substituted("%lld / %#@n@", ["other": "%arg elementos"]))}},
          "%lld / %lld substitution unused": {"localizations": {
            "en": \#(substituted("%1$lld / %2$#@n@", ["one": "%arg item", "other": "%arg items"])),
            "es": \#(substituted("%1$lld / %2$lld elementos", ["one": "%arg elemento", "other": "%arg elementos"]))}}
        }}
        """#
        let catalog = try JSONDecoder().decode(StringCatalog.self, from: Data(fixture.utf8))

        #expect(catalog.keysMissingLocalization("es") == [
            "%lld / %lld substitution lacks one", "%lld / %lld substitution unused", "%lld es blank", "%lld es lacks one",
        ])
        #expect(catalog.pluralMismatches == ["%lld es only, en absent [en]", "%lld es only, en flat [en]"])
        #expect(catalog.placeholderMismatches(for: "es").map { $0.components(separatedBy: " expected").first } == ["%lld drops the count", "%lld es blank"])
        #expect(catalog.strings["%lld / %lld substituted"]?.localizations?["es"]?.texts == [
            ["one"]: "%1$lld / %2$lld elemento", ["other"]: "%1$lld / %2$lld elementos",
        ])
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

    /// What keeps a translation from being swallowed is the parameter type: a `String`
    /// parameter routes through Text's verbatim overload and never consults the catalog,
    /// while a `LocalizedStringKey` does.
    @Test("Shared package UI takes localizable keys, not resolved strings")
    func sharedPackageUITakesLocalizableKeys() throws {
        let source = try Self.projectFile("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/SettingRow.swift")

        #expect(source.contains("title: LocalizedStringKey"))
        #expect(source.contains("subtitle: LocalizedStringKey?"))
        #expect(source.contains("let info: String.LocalizationValue?"))
        #expect(source.contains("@AppStorage(AppLanguagePreference.storageKey)"))
        #expect(source.contains(".help(localizedText)"))
        #expect(source.contains("Text(verbatim: localizedText)"))
        #expect(!source.contains(".help(text)"))
        #expect(!source.contains("title: String,"))
        #expect(!source.contains("Text(verbatim: title)"))
    }

    // Naming the bundle is the only form that follows the in-app language picker: without it the
    // lookup resolves against `Locale.current` — the *system* language — and ignores both
    // SwiftUI's `\.locale` environment and its own `locale:` argument. Brace-matched rather than
    // grepped: most of these calls span several lines and carry nested calls.
    @Test("Every String(localized:) names the in-app language bundle")
    func stringLocalizedSitesNameTheLanguageBundle() throws {
        // Compiled into the SystemWallpaperProvider appex too, which does not
        // link LiveWallpaperCore and ships no catalog of its own.
        let sharedWithAppExtension = ["LiveWallpaper/Models/SystemWallpaperManifest.swift"]

        var offenders: [String] = []
        var checked = 0
        for path in try Self.projectSwiftFiles(["LiveWallpaper", "Packages"]) {
            if sharedWithAppExtension.contains(where: { path.hasSuffix($0) }) { continue }
            let source = try String(contentsOfFile: path, encoding: .utf8)
            for call in Self.stringLocalizedCalls(in: source) {
                checked += 1
                if !call.contains("bundle:") {
                    let firstLine = call.split(separator: "\n").first.map(String.init) ?? call
                    offenders.append("\(path): \(firstLine.prefix(80))")
                }
            }
        }

        #expect(checked > 300, "Only \(checked) call sites matched — the scan stopped working")
        #expect(
            offenders.isEmpty,
            "String(localized:) without a bundle: \(offenders.prefix(10).joined(separator: "; "))"
        )
    }

    /// The bundle only picks the table; the plural rule comes from the `locale:` argument, which
    /// defaults to the system language (see AppLanguageRuntimeProbeTests). A literal key without
    /// interpolation is a raw format for `String(format:)`, which keeps the table's own rule.
    @Test("String(localized:) of a key that varies by plural passes the app language's locale")
    func pluralSitesPassTheAppLanguageLocale() throws {
        let pluralKeys = try StringCatalog.load(named: "Localizable.xcstrings").pluralKeys
        /// The whole key, not `matchesKey`: that one lets `"\(a): \(b)"` match any key with a colon in it.
        func isPlural(_ site: InterpolatedLiteralScan.Site) -> Bool {
            let placeholder = #"%(?:\d+\$)?(?:lld|llu|ld|lu|d|u|@|f)"#
            let pattern = "^" + site.segments.map(NSRegularExpression.escapedPattern(for:)).joined(separator: placeholder) + "$"
            guard let key = try? NSRegularExpression(pattern: pattern) else { return false }
            return pluralKeys.contains { key.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        var offenders: [String] = []
        var checked = 0
        for path in try Self.projectSwiftFiles(["LiveWallpaper", "Packages"]) {
            let source = try LocalizedLiteralScan.scannableText(in: String(contentsOfFile: path, encoding: .utf8))
            for call in Self.stringLocalizedCalls(in: source) {
                for site in InterpolatedLiteralScan.parse(call, path: path) where isPlural(site) {
                    checked += 1
                    if !call.contains("locale: AppLanguagePreference.current.locale") {
                        offenders.append("\(RepositoryRoot.relativePath(of: URL(fileURLWithPath: path))): \(site.literal.prefix(60))")
                    }
                }
            }
        }

        #expect(checked > 10, "Only \(checked) plural call sites matched — the scan stopped working")
        #expect(
            offenders.isEmpty,
            "String(localized:) of a plural key without the app language's locale: \(offenders.prefix(10).joined(separator: "; "))"
        )
    }

    /// An interpolated `String(localized:)` builds its key with plain `%@`/`%lld`, so a key that spells
    /// `%1$@` is only ever looked up when the source passes that exact text as a literal.
    @Test("Catalog keys with positional placeholders appear in source as literals")
    func positionalKeysAppearAsSourceLiterals() throws {
        func literal(_ key: String) -> String {
            let escaped = key.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        #expect(#"format: String(localized: "Say \"%1$@\" to %2$@", bundle: .appLanguage)"#.contains(literal(#"Say "%1$@" to %2$@"#)))

        let catalog = try StringCatalog.load(named: "Localizable.xcstrings")
        let source = try Self.projectSwiftFiles(["LiveWallpaper", "Packages"])
            .map { try LocalizedLiteralScan.scannableText(in: String(contentsOfFile: $0, encoding: .utf8)) }
            .joined(separator: "\n")
        let unreachable = catalog.strings.keys.sorted().filter { key in
            key.range(of: #"%\d+\$"#, options: .regularExpression) != nil && !source.contains(literal(key))
        }
        #expect(unreachable.isEmpty, "No source literal spells these positional keys, so no lookup ever finds them: \(unreachable.joined(separator: "; "))")
    }

    @Test("Every popover in the app's views opens through the in-app language scope")
    func popoversCarryTheLanguageScope() throws {
        let modifier = "LiveWallpaper/Views/Shared/AppLanguagePopover.swift"
        var offenders: [String] = []
        var scoped = 0
        for file in RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views") {
            let path = RepositoryRoot.relativePath(of: file)
            let source = try String(contentsOf: file, encoding: .utf8)
            scoped += source.components(separatedBy: ".appLanguagePopover(").count - 1
            if path != modifier, source.contains(".popover(") {
                offenders.append(path)
            }
        }

        #expect(scoped > 20, "Only \(scoped) scoped popovers matched — the scan stopped working")
        #expect(offenders.isEmpty, ".popover( without the language scope: \(offenders.joined(separator: "; "))")
        #expect(try Self.projectFile(modifier).contains("AppLanguageScope(defaults: .appScoped())"))
    }

    @Test("Every popover and sheet wraps its content in AppLanguageScope")
    func presentationsWrapContentInTheLanguageScope() throws {
        var offenders: [String] = []
        var presentations = 0
        for file in RepositoryRoot.swiftFiles(under: "LiveWallpaper") {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains(".popover(") || code.contains(".sheet(") else { continue }
                presentations += 1
                let limit = min(index + 8, lines.count)
                let end = lines[(index + 1) ..< limit].firstIndex { next in
                    let nextCode = next.trimmingCharacters(in: .whitespaces)
                    return !nextCode.hasPrefix("//") && (nextCode.contains(".popover(") || nextCode.contains(".sheet("))
                } ?? limit
                if !lines[index ..< end].contains(where: { $0.contains("AppLanguageScope") }) {
                    offenders.append("\(RepositoryRoot.relativePath(of: file)):\(index + 1)")
                }
            }
        }

        #expect(presentations > 25, "Only \(presentations) popovers and sheets matched — the scan stopped working")
        #expect(offenders.isEmpty, "\(offenders.count) without AppLanguageScope: \(offenders.joined(separator: "; "))")
    }

    @Test("Shortcut action copy remains localizable at render time")
    func shortcutActionCopyRemainsLocalizableAtRenderTime() throws {
        let shortcutView = try Self.projectFile("LiveWallpaper/Views/Settings/ShortcutsView.swift")
        let actionModel = try Self.projectFile("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Schema/GlobalShortcutAction.swift")

        #expect(!shortcutView.contains("Text(verbatim: action.displayName)"))
        #expect(shortcutView.contains("Text(action.displayNameKey)"))
        #expect(shortcutView.contains("Text(action.displayDescriptionKey)"))
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

        let copy = try Self.projectFile("LiveWallpaper/Views/EditDesk/Support/WallpaperImportCopy.swift")
        #expect(copy.contains("unsupportedFileTypeMessage(sceneCapable: Bool) -> LocalizedStringResource"))
        #expect(copy.contains("case .videoAndWeb:\n            \"That file type isn't supported. Pick a video or web page.\""))
        #expect(copy.contains("case .videoWebAndScene:\n            \"That file type isn't supported. Pick a video, web page, or scene.\""))
        #expect(
            Self.hasDirectOnboardingSceneCapabilityPolicy(copy),
            "The onboarding scene policy must directly query FeatureCatalog's .scene capability"
        )

        let source = try Self.projectFile("LiveWallpaper/Views/Onboarding/PickerView.swift")
        #expect(
            Self.hasDirectOnboardingSceneCapabilityWiring(source),
            "PickerView.sceneCapable must directly use the tested .scene catalog policy"
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

/// Deliberately blind — under-reporting beats a false alarm. The allowlist stays
/// SwiftUI-only on purpose: `appendingPathComponent("Workshop")` and `contains("error")`
/// also spell a live catalog key, so widening it by name would invent failures.
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

    /// Blanks comments and `#Preview` bodies while keeping one line per line, so reported
    /// line numbers still point at the real call site. A preview is skipped up to its
    /// closing column-zero `}`; truncating would drop every declaration written below it.
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
            // The empty key is an extraction artifact of `Picker("", …)`-style calls and has
            // nothing to translate; Xcode re-adds it on every catalog re-save.
            guard !key.isEmpty else { return false }
            // `shouldTranslate: false` marks deliberately unlocalized entries
            // (brand names like CFBundleDisplayName: the per-SKU Info.plist value
            // must stand, and any catalog override would leak across SKUs).
            guard strings[key]?.shouldTranslate != false else { return false }
            guard let localization = strings[key]?.localizations?[locale] else {
                return true
            }
            return !localization.isComplete(for: locale)
        }
    }

    var pluralKeys: [String] {
        strings.keys.sorted().filter { strings[$0]?.localizations?[sourceLanguage]?.variesByPlural == true }
    }

    /// "key [language]" for each key where only one of English and Spanish varies by plural; the
    /// bracket names the language left with one form. A missing `en` counts as one form: the key.
    var pluralMismatches: [String] {
        strings.keys.sorted().compactMap { key in
            let english = strings[key]?.localizations?[sourceLanguage]?.variesByPlural == true
            let spanish = strings[key]?.localizations?["es"]?.variesByPlural == true
            return english == spanish ? nil : "\(key) [\(english ? "es" : sourceLanguage)]"
        }
    }

    func placeholderMismatches(for locale: String) -> [String] {
        strings.keys.sorted().compactMap { key in
            let sourceValue = strings[key]?.localizations?[sourceLanguage]?.otherText ?? key
            let sourcePlaceholders = Self.placeholders(in: sourceValue)
            let texts = strings[key]?.localizations?[locale]?.texts ?? [:]
            guard let drifted = texts.keys.sorted(by: { $0.joined() < $1.joined() })
                .compactMap({ texts[$0] })
                .first(where: { !Self.placeholdersMatch(sourcePlaceholders, Self.placeholders(in: $0)) }) else {
                return nil
            }

            return "\(key) expected \(sourcePlaceholders) but found \(Self.placeholders(in: drifted))"
        }
    }

    func literalPercentIssues() -> [String] {
        strings.keys.sorted().flatMap { key in
            let localizations = strings[key]?.localizations ?? [:]
            return localizations.keys.sorted().compactMap { locale -> String? in
                guard localizations[locale]?.texts.values.contains(where: { Self.containsLiteralPercent(in: $0) }) == true else {
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

    /// CLDR plural categories a language cannot do without; a missing `many` in es falls back to `other`.
    static let pluralCategories = ["en": ["one", "other"], "es": ["one", "other"]]

    struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: Variations?
        let substitutions: [String: Substitution]?

        var variesByPlural: Bool {
            variations?.plural != nil || !(substitutions ?? [:]).isEmpty
        }

        /// Each finished text by the plural categories chosen: a plural's variants, or the value with
        /// every `%#@name@` filled by each variant of that substitution, `%arg` becoming the argument.
        var texts: [[String]: String] {
            if let plural = variations?.plural {
                return plural.reduce(into: [:]) { texts, variant in
                    if let value = variant.value.stringUnit?.value {
                        texts[[variant.key]] = value
                    }
                }
            }
            guard let value = stringUnit?.value else { return [:] }
            return (substitutions ?? [:]).reduce([[]: value]) { texts, substitution in
                texts.reduce(into: [:]) { filled, text in
                    for (category, variant) in substitution.value.variations?.plural ?? [:] {
                        guard let option = variant.stringUnit?.value else { continue }
                        filled[text.key + [category]] = StringCatalog.fill(
                            text.value, substitution: substitution.key, with: option,
                            specifier: substitution.value.formatSpecifier ?? ""
                        )
                    }
                }
            }
        }

        var otherText: String? {
            texts.first { $0.key.allSatisfy { $0 == "other" } }?.value
        }

        /// Substitutions no `%#@name@` in the value names: their plural forms are never shown.
        var unusedSubstitutions: [String] {
            let value = stringUnit?.value ?? ""
            return (substitutions ?? [:]).keys.sorted().filter { name in
                value.range(of: #"%(\d+\$)?#@"# + NSRegularExpression.escapedPattern(for: name) + "@", options: .regularExpression) == nil
            }
        }

        /// Every text written, each plural carrying every category `locale` needs, and every substitution used.
        func isComplete(for locale: String) -> Bool {
            if variations != nil, variations?.plural == nil {
                return false
            }
            guard variations != nil || stringUnit?.value.isEmpty == false else { return false }
            guard unusedSubstitutions.isEmpty else { return false }
            let required = StringCatalog.pluralCategories[locale] ?? ["other"]
            let plurals = [variations?.plural].compactMap(\.self) + (substitutions ?? [:]).values.map { $0.variations?.plural ?? [:] }
            return plurals.allSatisfy { plural in
                required.allSatisfy { plural[$0] != nil } && plural.values.allSatisfy { $0.stringUnit?.value.isEmpty == false }
            }
        }
    }

    struct Variations: Decodable {
        let plural: [String: Variant]?
    }

    struct Variant: Decodable {
        let stringUnit: StringUnit?
    }

    struct Substitution: Decodable {
        let formatSpecifier: String?
        let variations: Variations?
    }

    struct StringUnit: Decodable {
        let state: String?
        let value: String
    }

    static func fill(_ text: String, substitution name: String, with option: String, specifier: String) -> String {
        let pattern = #"%(\d+\$)?#@"# + NSRegularExpression.escapedPattern(for: name) + "@"
        guard let token = try? NSRegularExpression(pattern: pattern) else { return text }
        var filled = text
        for match in token.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: filled) else { continue }
            let position = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            filled.replaceSubrange(range, with: option.replacingOccurrences(of: "%arg", with: "%" + position + specifier))
        }
        return filled
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

    static func parse(_ source: String, path: String) -> [Site] {
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
