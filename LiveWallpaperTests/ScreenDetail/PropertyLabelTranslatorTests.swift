#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing
@preconcurrency import Translation

@Suite("WPE property label translation eligibility")
struct PropertyLabelTranslatorTests {
    private let english = Locale.Language(identifier: "en")
    private let simplifiedChinese = Locale.Language(identifier: "zh-Hans")
    private let japanese = Locale.Language(identifier: "ja")

    @MainActor
    @Test("Mixed Chinese labels use a Chinese source and an English target", arguments: [
        "音量 Volume", "显示触发区域 Show trigger area", "静音 Mute", "音量 4K HDR",
    ])
    func mixedChineseSource(label: String) async {
        guard #available(macOS 15.0, *) else { return }
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in true })
        translator.enqueue(labels: [label])
        await translator.availabilityCheck?.value
        #expect(translator.configuration?.source?.languageCode?.identifier == "zh")
        #expect(translator.configuration?.target?.languageCode?.identifier == "en")
        #expect(translator.takePending() == [label])
    }

    @Test("Only Chinese author text needs translation", arguments: [
        "Показать область активации", "音楽に反応する", "Enable audio", "★ 4K HDR", "4K", "★ ON/OFF",
    ])
    func otherLanguagesSkip(label: String) {
        #expect(!WPEPropertyLabelTranslator.needsTranslation(label, target: english))
    }

    @Test("CJK labels need translation for English readers")
    func cjkLabelsTranslate() {
        #expect(WPEPropertyLabelTranslator.needsTranslation("显示触发区域", target: english))
        #expect(WPEPropertyLabelTranslator.needsTranslation("显示触发区域 Show trigger area", target: english))
        #expect(WPEPropertyLabelTranslator.needsTranslation("音频响应", target: english))
    }

    @Test("Kanji-only Japanese stays as authored while words shared with Chinese still translate")
    func kanjiOnlyJapaneseSkips() {
        #expect(!WPEPropertyLabelTranslator.needsTranslation("東京駅", target: english))
        #expect(!WPEPropertyLabelTranslator.needsTranslation("天気予報", target: english))
        #expect(WPEPropertyLabelTranslator.needsTranslation("静音", target: english))
        #expect(WPEPropertyLabelTranslator.needsTranslation("原神", target: english))
    }

    @Test("Label already in the target language is left alone")
    func sameLanguageSkips() {
        #expect(!WPEPropertyLabelTranslator.needsTranslation("显示触发区域", target: simplifiedChinese))
        // Traditional label for a Simplified reader still translates.
        #expect(WPEPropertyLabelTranslator.needsTranslation("顯示觸發區域", target: simplifiedChinese))
    }

    @Test("The target follows the app language, then the bundle localization, then English")
    func effectiveTargetLanguage() {
        typealias Translator = WPEPropertyLabelTranslator
        #expect(Translator.effectiveTargetLanguage(preference: AppLanguagePreference.system.rawValue, preferredLocalization: "ja") == japanese)
        #expect(Translator.effectiveTargetLanguage(preference: "zh-Hant", preferredLocalization: "en") == Locale.Language(identifier: "zh-Hant"))
        #expect(Translator.effectiveTargetLanguage(preference: nil, preferredLocalization: nil) == english)
        #expect(Translator.effectiveTargetLanguage(preference: "unknown", preferredLocalization: nil) == english)
    }

    @MainActor
    @Test("A Simplified target skips Simplified labels; a Japanese target configures only after the pack check")
    func targetLanguageGatesQueue() async {
        guard #available(macOS 15.0, *) else { return }
        let label = "显示触发区域"
        let chinese = WPEPropertyLabelTranslator(targetLanguage: simplifiedChinese, isInstalled: { _, _ in true })
        chinese.enqueue(labels: [label])
        #expect(chinese.availabilityCheck == nil)
        #expect(chinese.takePending().isEmpty)

        let pair = (simplifiedChinese, japanese)
        let translator = WPEPropertyLabelTranslator(targetLanguage: japanese, isInstalled: { $0 == pair.0 && $1 == pair.1 })
        translator.enqueue(labels: [label])
        #expect(translator.configuration == nil, "configured a session before the pack check returned")
        await translator.availabilityCheck?.value
        #expect(translator.configuration?.source == simplifiedChinese)
        #expect(translator.configuration?.target == japanese)
        #expect(translator.takePending() == [label])
    }

    @MainActor
    @Test("A pair without an installed pack never configures a session and keeps the author label")
    func uninstalledPairStaysOriginal() async {
        guard #available(macOS 15.0, *) else { return }
        let label = "显示触发区域"
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in false })
        translator.enqueue(labels: [label])
        await translator.availabilityCheck?.value
        #expect(translator.configuration == nil)
        #expect(translator.takePending().isEmpty)
        #expect(translator.displayText(for: label) == label)
        translator.enqueue(labels: [label])
        #expect(translator.availabilityCheck == nil, "re-checked a label already found to have no installed pack")
    }

    @MainActor
    @Test("Changing the app language clears translations and re-queues every seen label for the new target")
    func retargetRequeuesSeenLabels() async {
        guard #available(macOS 15.0, *) else { return }
        let simplified = "显示触发区域"
        let traditional = "顯示觸發區域"
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in true })
        translator.enqueue(labels: [simplified, traditional])
        await translator.availabilityCheck?.value
        #expect(translator.takePending() == [simplified])
        translator.store([(simplified, "Show trigger area")])

        translator.retarget(to: simplifiedChinese)
        #expect(translator.translated.isEmpty)
        #expect(translator.configuration == nil)
        await translator.availabilityCheck?.value
        #expect(translator.configuration?.target == simplifiedChinese)
        #expect(translator.takePending() == [traditional])
    }

    @Test("Response cleanup drops empties and echoes")
    func cleanedTargetText() {
        #expect(WPEPropertyLabelTranslator.cleanedTargetText(for: "音量", targetText: " Volume ") == "Volume")
        #expect(WPEPropertyLabelTranslator.cleanedTargetText(for: "音量 Volume", targetText: "Volume Volume") == "Volume")
        #expect(WPEPropertyLabelTranslator.cleanedTargetText(
            for: "显示触发区域 Show trigger area", targetText: "Show trigger area Show trigger area"
        ) == "Show trigger area")
        #expect(WPEPropertyLabelTranslator.cleanedTargetText(for: "安静安静", targetText: "Quiet Quiet") == "Quiet Quiet")
        #expect(WPEPropertyLabelTranslator.cleanedTargetText(for: "音量", targetText: "音量") == nil)
        #expect(WPEPropertyLabelTranslator.cleanedTargetText(for: "音量", targetText: "  ") == nil)
    }

    @MainActor
    @Test("Chinese variants drain separately and cancelled labels can be retried")
    func mixedLanguageQueuePreservesUnfinishedLabels() async {
        guard #available(macOS 15.0, *) else { return }
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in true })
        let chinese = "显示触发区域并启用音频响应"
        let traditional = "顯示觸發區域並啟用音頻響應"
        translator.enqueue(labels: [chinese, traditional])
        await translator.availabilityCheck?.value
        let first = translator.takePending()
        #expect(first == [chinese])
        translator.restorePending(first[...])
        #expect(translator.takePending() == first)
        translator.restorePending([])
        await translator.availabilityCheck?.value
        #expect(translator.takePending() == [traditional])
    }

    @MainActor
    @Test("Internal failures can retry without immediately restarting the session")
    func internalFailureCanRetry() async {
        guard #available(macOS 15.0, *) else { return }
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in true })
        let label = "音量 Volume"
        translator.enqueue(labels: [label])
        await translator.availabilityCheck?.value
        #expect(translator.takePending() == [label])
        translator.enqueue(labels: [label])
        #expect(translator.takePending().isEmpty)
        translator.recordFailure(for: label, error: TranslationError.internalError)
        #expect(translator.takePending().isEmpty)
        translator.enqueue(labels: [label])
        #expect(translator.takePending() == [label])
        translator.store([(label, "Volume")])
        #expect(translator.displayText(for: label) == "Volume")
        #expect(translator.helpText(for: label) == label)
    }
}
#endif
