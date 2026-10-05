#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing
@preconcurrency import Translation

@Suite("WPE property label translation eligibility")
struct PropertyLabelTranslatorTests {
    private let english = Locale.Language(identifier: "en")
    private let simplifiedChinese = Locale.Language(identifier: "zh-Hans")

    @MainActor
    @Test("Mixed Chinese labels use a Chinese source and an English target", arguments: [
        "音量 Volume", "显示触发区域 Show trigger area", "静音 Mute", "音量 4K HDR",
    ])
    func mixedChineseSource(label: String) {
        guard #available(macOS 15.0, *) else { return }
        let translator = WPEPropertyLabelTranslator(targetLanguage: english)
        translator.enqueue(labels: [label])
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

    @Test("Label already in the target language is left alone")
    func sameLanguageSkips() {
        #expect(!WPEPropertyLabelTranslator.needsTranslation("显示触发区域", target: simplifiedChinese))
        // Traditional label for a Simplified reader still translates.
        #expect(WPEPropertyLabelTranslator.needsTranslation("顯示觸發區域", target: simplifiedChinese))
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
    func mixedLanguageQueuePreservesUnfinishedLabels() {
        guard #available(macOS 15.0, *) else { return }
        let translator = WPEPropertyLabelTranslator(targetLanguage: english)
        let chinese = "显示触发区域并启用音频响应"
        let traditional = "顯示觸發區域並啟用音頻響應"
        translator.enqueue(labels: [chinese, traditional])
        let first = translator.takePending()
        #expect(first == [chinese])
        translator.restorePending(first[...])
        #expect(translator.takePending() == first)
        translator.restorePending([])
        #expect(translator.takePending() == [traditional])
    }

    @MainActor
    @Test("Internal failures can retry without immediately restarting the session")
    func internalFailureCanRetry() {
        guard #available(macOS 15.0, *) else { return }
        let translator = WPEPropertyLabelTranslator()
        let label = "音量 Volume"
        translator.enqueue(labels: [label])
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
