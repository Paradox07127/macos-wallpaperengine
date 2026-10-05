import SwiftUI
#if !LITE_BUILD
import NaturalLanguage

// `@preconcurrency`: `TranslationSession` is a non-Sendable class whose methods
// are `@concurrent`; without it Swift 6 rejects every `session.translate` call.
@preconcurrency import Translation

/// Translates Chinese wallpaper names and property labels into English using
/// the on-device Translation framework. Rows swap to
/// the translation when it lands and keep the author text in a hover tooltip.
/// macOS 14 shows the originals: `TranslationSession` requires macOS 15.
@MainActor
@Observable
final class WPEPropertyLabelTranslator {
    /// One queue for names across library tiles and Workshop cards.
    static let wallpaperNames = WPEPropertyLabelTranslator()
    /// Author text → translation, filled as responses arrive.
    private(set) var translated: [String: String] = [:]
    /// Attempted labels stay requested after a declined download. Internal
    /// errors clear their entry so opening the card again can retry.
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var pending: [String] = []

    /// Boxed `TranslationSession.Configuration` so the type compiles against the
    /// macOS 14.6 deployment target. Observed: assigning it re-evaluates the view
    /// holding `.translationTask`, and `invalidate()` re-runs that task.
    var boxedConfiguration: Any?

    @ObservationIgnored private let targetLanguage: Locale.Language
    /// Detected per language batch — auto-detect fails on 2–4 character
    /// labels, and the session would otherwise show its "choose a language" sheet.
    @ObservationIgnored private var sourceLanguage: Locale.Language?

    init(targetLanguage: Locale.Language = Locale.Language(identifier: "en")) {
        self.targetLanguage = targetLanguage
    }

    /// The label a row should render.
    func displayText(for original: String) -> String {
        translated[original] ?? original
    }

    /// The author label to reveal on hover once a translation replaced it;
    /// `nil` while the row still shows the original.
    func helpText(for original: String) -> String? {
        translated[original] != nil ? original : nil
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
        guard !fresh.isEmpty else { return }
        pending.append(contentsOf: fresh)
        configurePendingTranslation()
    }

    @available(macOS 15.0, *)
    private func configurePendingTranslation() {
        guard !pending.isEmpty else { return }
        let detected = Self.language(of: pending[0])
        if configuration == nil || detected != sourceLanguage {
            sourceLanguage = detected
            boxedConfiguration = TranslationSession.Configuration(source: detected, target: targetLanguage)
        } else {
            configuration?.invalidate()
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
        let traditional = NLLanguageRecognizer.dominantLanguage(for: han) == .traditionalChinese
        return Locale.Language(identifier: traditional ? "zh-Hant" : "zh-Hans")
    }

    /// Drains one source language. Called from `.translationTask`'s closure; the session
    /// itself stays in that closure because it is not `Sendable`.
    func takePending() -> [String] {
        let batch = pending.filter { Self.language(of: $0) == sourceLanguage || Self.language(of: $0) == nil }
        let labels = Set(batch)
        pending.removeAll { labels.contains($0) }
        return batch
    }

    @available(macOS 15.0, *)
    func restorePending(_ labels: ArraySlice<String>) {
        pending.insert(contentsOf: labels, at: 0)
        configurePendingTranslation()
    }

    /// `.translationTask` action. `nonisolated` so the session — which is not
    /// `Sendable` — lives here rather than in a MainActor closure. Per-string
    /// calls: the batch API takes non-Sendable `Request`s. Each session handles
    /// one source language; unfinished labels survive task cancellation.
    @available(macOS 15.0, *)
    nonisolated func translateLabels(using session: TranslationSession) async {
        let batch = await takePending()
        for (index, source) in batch.enumerated() {
            do {
                try Task.checkCancellation()
                let response = try await session.translate(source)
                if let text = Self.cleanedTargetText(for: source, targetText: response.targetText) {
                    await store([(source, text)])
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    await restorePending(batch[index...])
                    return
                }
                await recordFailure(for: source, error: error)
            }
        }
        await configurePendingTranslation()
    }

    /// Stores finished translations; rows re-render on the next pass.
    func store(_ pairs: [(String, String)]) {
        for (source, text) in pairs {
            translated[source] = text
        }
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

    /// Attach once at the card level. Below macOS 15 there is no Translation
    /// framework, so the rows simply render their author labels. `session` is
    /// not `Sendable` — all of its use stays inside the task's closure.
    @ViewBuilder
    func wpePropertyLabelTranslation(_ translator: WPEPropertyLabelTranslator) -> some View {
        if #available(macOS 15.0, *) {
            // A closure literal here inherits MainActor from `View`, which
            // isolates the non-Sendable session and makes its nonisolated
            // methods uncallable — a nonisolated method reference keeps the
            // session in its own region.
            translationTask(translator.configuration, action: translator.translateLabels)
        } else {
            self
        }
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
}

extension View {
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
}
