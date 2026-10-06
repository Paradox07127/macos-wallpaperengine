import SwiftUI
#if !LITE_BUILD
import LiveWallpaperCore
import NaturalLanguage

// `@preconcurrency`: `TranslationSession` is a non-Sendable class whose methods
// are `@concurrent`; without it Swift 6 rejects every `session.translate` call.
@preconcurrency import Translation

/// Translates Chinese wallpaper names and property labels into the app language using
/// the on-device Translation framework. Rows swap to
/// the translation when it lands and keep the author text in a hover tooltip.
/// macOS 14 shows the originals: `TranslationSession` requires macOS 15.
@MainActor
@Observable
final class WPEPropertyLabelTranslator {
    /// One queue for names across library tiles and Workshop cards.
    static let wallpaperNames = WPEPropertyLabelTranslator()
    /// Description lines, kept apart so long text doesn't hold up the names.
    static let descriptions = WPEPropertyLabelTranslator()
    /// Posted when a language pack may have been installed; every live translator re-checks.
    static let languagePacksMayHaveChanged = Notification.Name("WPEPropertyLabelTranslator.languagePacksMayHaveChanged")
    /// `Bool` in `UserDefaults.appScoped()`; a missing value means enabled.
    nonisolated static let enabledPreferenceKey = "loomscreen.translation.wallpaperText.v1"
    /// About one visible row of cards: a chunk lands quickly, yet a store isn't one re-render per label.
    nonisolated static let chunkSize = 8
    /// Author text → translation, filled as responses arrive.
    private(set) var translated: [String: String] = [:]
    /// While `false`, rows show author text and queued labels only join `requested`; `translated` is kept.
    private(set) var isEnabled: Bool
    /// Bumped whenever `displayText` may answer differently; AppKit-drawn text watches it to re-read its labels.
    private(set) var revision = 0
    /// Attempted labels stay requested after a declined download or a language pair that isn't
    /// installed (until a re-check). Internal errors clear their entry so opening the card again can retry.
    /// While disabled it is the set of labels seen, re-queued by `setEnabled(true)`.
    @ObservationIgnored private var requested: Set<String> = []
    /// Oldest first; chunks are taken from the end so the cards on screen now translate first.
    @ObservationIgnored private var pending: [String] = []
    /// Requested labels whose pair had no installed pack; `recheckLanguagePacks` queues them again.
    @ObservationIgnored private var uninstalled: [String] = []
    /// A `.translationTask` is draining `sourceLanguage`; new labels only join `pending`, since
    /// `invalidate()` would cancel it and the restart re-warms the model.
    @ObservationIgnored private var isTranslating = false
    /// When each queued label entered `pending`; removed once it is stored or dropped.
    @ObservationIgnored private var enqueuedAt: [String: ContinuousClock.Instant] = [:]

    /// Boxed `TranslationSession.Configuration` so the type compiles against the
    /// macOS 14.6 deployment target. Observed: assigning it re-evaluates the view
    /// holding `.translationTask`, and `invalidate()` re-runs that task.
    var boxedConfiguration: Any?

    @ObservationIgnored private var targetLanguage: Locale.Language
    /// Detected per language batch — auto-detect fails on 2–4 character
    /// labels, and the session would otherwise show its "choose a language" sheet.
    @ObservationIgnored private var sourceLanguage: Locale.Language?
    /// Whether a source → target pack is installed. A session for a pair that isn't
    /// would show the system download sheet on its first `translate`.
    @ObservationIgnored private let isInstalled: @Sendable (Locale.Language, Locale.Language) async -> Bool
    /// The in-flight installed-pack check; `nil` when none is running.
    @ObservationIgnored private(set) var availabilityCheck: Task<Void, Never>?

    init(
        targetLanguage: Locale.Language = effectiveTargetLanguage(),
        isInstalled: @escaping @Sendable (Locale.Language, Locale.Language) async -> Bool = languagePairIsInstalled,
        isEnabled: Bool = UserDefaults.appScoped().object(forKey: WPEPropertyLabelTranslator.enabledPreferenceKey) as? Bool ?? true
    ) {
        self.targetLanguage = targetLanguage
        self.isInstalled = isInstalled
        self.isEnabled = isEnabled
    }

    /// `preference` is the stored `AppLanguagePreference` raw value; `.system`, missing and
    /// unknown values follow the bundle's resolved localization.
    nonisolated static func effectiveTargetLanguage(
        preference: String? = UserDefaults.standard.string(forKey: AppLanguagePreference.storageKey),
        preferredLocalization: String? = Bundle.main.preferredLocalizations.first
    ) -> Locale.Language {
        let explicit = preference.flatMap(AppLanguagePreference.init(rawValue:))?.localeIdentifier
        return Locale.Language(identifier: explicit ?? preferredLocalization ?? "en")
    }

    nonisolated static func languagePairIsInstalled(_ source: Locale.Language, _ target: Locale.Language) async -> Bool {
        guard #available(macOS 15.0, *) else { return false }
        return await LanguageAvailability().status(from: source, to: target) == .installed
    }

    /// The label a row should render.
    func displayText(for original: String) -> String {
        isEnabled ? translated[original] ?? original : original
    }

    /// The author label to reveal on hover once a translation replaced it;
    /// `nil` while the row still shows the original.
    func helpText(for original: String) -> String? {
        isEnabled && translated[original] != nil ? original : nil
    }

    /// A description with its translated lines swapped in; every other line stays as authored.
    func displayDescription(for original: String) -> String {
        isEnabled ? Self.joinLines(of: original, translated: translated) : original
    }

    /// Descriptions translate line by line, so English paragraphs and URLs are never sent.
    nonisolated static func descriptionLines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    nonisolated static func joinLines(of text: String, translated: [String: String]) -> String {
        descriptionLines(of: text).map { translated[$0] ?? $0 }.joined(separator: "\n")
    }

    /// Queue every label the schema can render: property texts, combo option
    /// labels, and group headers (which become section titles).
    func enqueue(schema: WallpaperEngineProjectPropertySchema) {
        enqueue(labels: schema.properties.flatMap {
            [$0.displayText] + $0.options.map(\.displayLabel)
        })
    }

    func enqueue(labels: some Sequence<String>) {
        guard #available(macOS 15.0, *) else { return }
        let fresh = labels.filter {
            Self.needsTranslation($0, target: targetLanguage)
                && translated[$0] == nil
                && requested.insert($0).inserted
        }
        guard isEnabled, !fresh.isEmpty else { return }
        let now = ContinuousClock.now
        for label in fresh {
            enqueuedAt[label] = now
        }
        pending.append(contentsOf: fresh)
        configurePendingTranslation()
    }

    /// Off ends the running session and drops the queue but keeps `translated`;
    /// on queues every label seen but not yet translated.
    @available(macOS 15.0, *)
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        revision += 1
        if enabled {
            let seen = requested
            requested = []
            enqueue(labels: seen)
        } else {
            pending = []
            uninstalled = []
            enqueuedAt = [:]
            availabilityCheck?.cancel()
            availabilityCheck = nil
            isTranslating = false
            sourceLanguage = nil
            configuration = nil
        }
    }

    /// Re-translates every label seen so far into `language`.
    @available(macOS 15.0, *)
    func retarget(to language: Locale.Language) {
        guard language != targetLanguage else { return }
        let seen = requested.union(translated.keys)
        targetLanguage = language
        translated = [:]
        revision += 1
        pending = []
        requested = []
        uninstalled = []
        enqueuedAt = [:]
        availabilityCheck?.cancel()
        availabilityCheck = nil
        isTranslating = false
        sourceLanguage = nil
        // Ends the running `.translationTask`; its results for the old target are dropped in `storeChunk`.
        configuration = nil
        enqueue(labels: seen)
    }

    /// Queues the labels skipped for a missing pack again, so a pack installed since can translate them.
    @available(macOS 15.0, *)
    func recheckLanguagePacks() {
        guard !uninstalled.isEmpty else { return }
        let labels = uninstalled
        uninstalled = []
        requested.subtract(labels)
        enqueue(labels: labels)
    }

    @available(macOS 15.0, *)
    private func configurePendingTranslation() {
        guard !isTranslating, !pending.isEmpty, availabilityCheck == nil else { return }
        let detected = Self.language(of: pending[0])
        if configuration != nil, detected == sourceLanguage {
            configuration?.invalidate()
            return
        }
        guard let detected else { return }
        let target = targetLanguage
        availabilityCheck = Task { [isInstalled] in
            let installed = await isInstalled(detected, target)
            // A retarget cancels this check and has already started its own.
            guard !Task.isCancelled else { return }
            self.availabilityCheck = nil
            if installed {
                self.sourceLanguage = detected
                self.configuration = TranslationSession.Configuration(source: detected, target: target)
            } else {
                let skipped = self.pending.filter { Self.language(of: $0) == detected }
                self.uninstalled += skipped
                self.pending.removeAll { Self.language(of: $0) == detected }
                for label in skipped {
                    self.enqueuedAt[label] = nil
                }
                self.configurePendingTranslation()
            }
        }
    }

    @available(macOS 15.0, *)
    var configuration: TranslationSession.Configuration? {
        get { boxedConfiguration as? TranslationSession.Configuration }
        set { boxedConfiguration = newValue }
    }

    private nonisolated static func language(of text: String) -> Locale.Language? {
        // Ignore the Latin half of bilingual labels: "音量 Volume" is otherwise
        // detected as English. Kana marks Japanese text, which is outside this feature.
        guard !text.unicodeScalars.contains(where: {
            (0x3040 ... 0x30FF).contains($0.value) || (0xFF66 ... 0xFF9F).contains($0.value)
        }) else { return nil }
        let han = String(String.UnicodeScalarView(text.unicodeScalars.filter(\.properties.isIdeographic)))
        guard !han.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese, .japanese]
        recognizer.processString(text)
        // Kanji-only Japanese: Japanese-only forms (駅, 気, 桜) score ~1.0, while words
        // shared with Chinese ("静音", "原神") stay near an even split.
        if (recognizer.languageHypotheses(withMaximum: 1)[.japanese] ?? 0) > 0.9 {
            return nil
        }
        // The recognizer calls short Simplified titles Traditional; ICU's Traditional → Simplified
        // mapping only changes text that has Traditional-only characters.
        let traditional = han.applyingTransform(StringTransform("Hant-Hans"), reverse: false).map { $0 != han } ?? false
        return Locale.Language(identifier: traditional ? "zh-Hant" : "zh-Hans")
    }

    /// Takes the next chunk of `sourceLanguage` labels, newest first, and marks a drain in progress.
    func takePending() -> [String] {
        isTranslating = true
        var chunk: [String] = []
        for index in pending.indices.reversed() where chunk.count < Self.chunkSize {
            if Self.language(of: pending[index]) == sourceLanguage {
                chunk.append(pending.remove(at: index))
            }
        }
        return chunk
    }

    /// `nil` once `sourceLanguage` has nothing left; the drain then ends and other languages get a session.
    @available(macOS 15.0, *)
    private func nextChunk(source: Locale.Language?, target: Locale.Language?) -> (labels: [String], target: Locale.Language)? {
        // A session whose configuration a retarget already replaced must not drain the new pair's labels,
        // nor clear `isTranslating` for the session that replaced it.
        guard source == sourceLanguage, target == targetLanguage else { return nil }
        let labels = takePending()
        guard !labels.isEmpty else {
            isTranslating = false
            configurePendingTranslation()
            return nil
        }
        return (labels, targetLanguage)
    }

    /// Ends a cancelled drain, putting its untranslated labels back in the queue.
    @available(macOS 15.0, *)
    func restorePending(_ labels: ArraySlice<String>) {
        isTranslating = false
        pending.append(contentsOf: labels)
        configurePendingTranslation()
    }

    /// `.translationTask` action. `nonisolated` so the session — which is not
    /// `Sendable` — lives here rather than in a MainActor closure. Drains
    /// `sourceLanguage` chunk by chunk; unfinished labels survive task cancellation.
    @available(macOS 15.0, *)
    nonisolated func translateLabels(using session: TranslationSession) async {
        while case let (labels, target)? = await nextChunk(source: session.sourceLanguage, target: session.targetLanguage) {
            var pairs: [(String, String)] = []
            do {
                try Task.checkCancellation()
                let sources = Dictionary(uniqueKeysWithValues: labels.enumerated().map { (String($0), $1) })
                let requests = labels.enumerated().map {
                    TranslationSession.Request(sourceText: $1, clientIdentifier: String($0))
                }
                // Responses may arrive in any order; `clientIdentifier` maps each back to its label.
                for response in try await session.translations(from: requests) {
                    guard let source = response.clientIdentifier.flatMap({ sources[$0] }),
                          let text = Self.cleanedTargetText(for: source, targetText: response.targetText) else { continue }
                    pairs.append((source, text))
                }
            } catch where !Self.isCancellation(error) {
                // One bad label fails the whole batch call; retry singly so the rest still land.
                for (index, source) in labels.enumerated() {
                    do {
                        try Task.checkCancellation()
                        let response = try await session.translate(source)
                        if let text = Self.cleanedTargetText(for: source, targetText: response.targetText) {
                            pairs.append((source, text))
                        }
                    } catch {
                        if Self.isCancellation(error) {
                            await finish(pairs, chunk: labels[..<index], unfinished: labels[index...], target: target)
                            return
                        }
                        await recordFailure(for: source, error: error)
                    }
                }
            } catch {
                await finish([], chunk: [], unfinished: labels[...], target: target)
                return
            }
            guard await storeChunk(pairs, chunk: labels[...], target: target) else { return }
        }
    }

    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError
    }

    @available(macOS 15.0, *)
    private func finish(
        _ pairs: [(String, String)], chunk: ArraySlice<String>, unfinished: ArraySlice<String>, target: Locale.Language
    ) {
        guard storeChunk(pairs, chunk: chunk, target: target) else { return }
        restorePending(unfinished)
    }

    /// Stores one chunk's results; `false` when a retarget or switch-off has replaced this session,
    /// whose labels are then already re-queued or dropped.
    @available(macOS 15.0, *)
    private func storeChunk(_ pairs: [(String, String)], chunk: ArraySlice<String>, target: Locale.Language) -> Bool {
        guard isEnabled, target == targetLanguage else { return false }
        guard !chunk.isEmpty else { return true }
        let oldest = chunk.compactMap { enqueuedAt.removeValue(forKey: $0) }.min()
        if !pairs.isEmpty {
            store(pairs)
        }
        let waited = oldest.map { Int((ContinuousClock.now - $0) / .milliseconds(1)) } ?? 0
        Logger.debug(
            "Translated \(pairs.count)/\(chunk.count) labels \(sourceLanguage?.minimalIdentifier ?? "?")→\(target.minimalIdentifier); oldest waited \(waited) ms",
            category: .ui
        )
        return true
    }

    /// Stores finished translations in one mutation, so observers rebuild once per batch.
    func store(_ pairs: [(String, String)]) {
        guard !pairs.isEmpty else { return }
        translated.merge(pairs) { _, new in new }
        revision += 1
    }

    @available(macOS 15.0, *)
    func recordFailure(for source: String, error: any Error) {
        // An internal failure can retry when the card next queues its schema.
        // Leave declined downloads requested so opening a card doesn't prompt again.
        if case TranslationError.internalError = error {
            requested.remove(source)
        }
    }

    /// Trims a response and drops no-ops so untranslatable labels don't linger
    /// in `pending` forever.
    nonisolated static func cleanedTargetText(for source: String, targetText: String) -> String? {
        let text = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != source else { return nil }
        // Bilingual author labels can translate to "Volume Volume". Collapse
        // identical halves only when the original already contains Latin letters.
        if source.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.value <= 0x024F }) {
            let words = text.split(whereSeparator: \.isWhitespace)
            let midpoint = words.count / 2
            if midpoint > 0, words.count.isMultiple(of: 2),
               words.prefix(midpoint).map({ $0.lowercased() }) == words.suffix(midpoint).map({ $0.lowercased() }) {
                return words.prefix(midpoint).joined(separator: " ")
            }
        }
        return text
    }

    /// Only Chinese author text qualifies; other wallpaper languages stay as authored.
    nonisolated static func needsTranslation(_ text: String, target: Locale.Language) -> Bool {
        guard let source = language(of: text) else { return false }
        return source.languageCode != target.languageCode || source.script != target.script
    }
}

/// Below macOS 15 there is no Translation framework, so the rows simply render
/// their author labels. `session` is not `Sendable` — all of its use stays inside the task's closure.
private struct WPEPropertyLabelTranslation: ViewModifier {
    let translator: WPEPropertyLabelTranslator
    @AppStorage(AppLanguagePreference.storageKey) private var languagePreference = AppLanguagePreference.system.rawValue
    @AppStorage(WPEPropertyLabelTranslator.enabledPreferenceKey, store: .appScoped()) private var translationEnabled = true

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            // A closure literal here inherits MainActor from `View`, which
            // isolates the non-Sendable session and makes its nonisolated
            // methods uncallable — a nonisolated method reference keeps the
            // session in its own region.
            content
                .translationTask(translator.configuration, action: translator.translateLabels)
                .onChange(of: languagePreference) { _, preference in
                    translator.retarget(to: WPEPropertyLabelTranslator.effectiveTargetLanguage(preference: preference))
                }
                // `initial`: the shared translators may have been created before the setting last changed.
                .onChange(of: translationEnabled, initial: true) { _, enabled in
                    translator.setEnabled(enabled)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    translator.recheckLanguagePacks()
                }
                .onReceive(NotificationCenter.default.publisher(for: WPEPropertyLabelTranslator.languagePacksMayHaveChanged)) { _ in
                    translator.recheckLanguagePacks()
                }
        } else {
            content
        }
    }
}

extension View {
    /// Attach once at the card level.
    func wpePropertyLabelTranslation(_ translator: WPEPropertyLabelTranslator) -> some View {
        modifier(WPEPropertyLabelTranslation(translator: translator))
    }
}
#endif

extension String {
    @MainActor
    var translatedWallpaperName: String {
        #if !LITE_BUILD
        WPEPropertyLabelTranslator.wallpaperNames.displayText(for: self)
        #else
        self
        #endif
    }

    /// The original name for a hover tooltip; `nil` while the row still shows it.
    @MainActor
    var wallpaperNameHelp: String? {
        #if !LITE_BUILD
        WPEPropertyLabelTranslator.wallpaperNames.helpText(for: self)
        #else
        nil
        #endif
    }

    @MainActor
    var translatedWallpaperDescription: String {
        #if !LITE_BUILD
        WPEPropertyLabelTranslator.descriptions.displayDescription(for: self)
        #else
        self
        #endif
    }

    /// The original description for a hover tooltip; `nil` while no line is translated.
    @MainActor
    var wallpaperDescriptionHelp: String? {
        translatedWallpaperDescription == self ? nil : self
    }
}

extension View {
    /// `help` takes a non-optional `Text`; this skips the modifier entirely
    /// while a row still shows its author label.
    @ViewBuilder
    func wpeAuthorLabelHelp(_ original: String?) -> some View {
        if let original {
            help(Text(verbatim: original))
        } else {
            self
        }
    }

    /// Queue a displayed name without changing the stored title or wallpaper identity.
    @ViewBuilder
    func wpeTranslateWallpaperName(_ original: String) -> some View {
        #if !LITE_BUILD
        onChange(of: original, initial: true) { _, name in
            WPEPropertyLabelTranslator.wallpaperNames.enqueue(labels: [name])
        }
        #else
        self
        #endif
    }

    /// Queue a displayed description's Chinese lines.
    @ViewBuilder
    func wpeTranslateWallpaperDescription(_ original: String) -> some View {
        #if !LITE_BUILD
        onChange(of: original, initial: true) { _, text in
            WPEPropertyLabelTranslator.descriptions.enqueue(labels: WPEPropertyLabelTranslator.descriptionLines(of: text))
        }
        #else
        self
        #endif
    }
}
