#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Observation
import os
import SwiftUI
import Testing
@preconcurrency import Translation

@Suite("WPE property label translation eligibility")
struct PropertyLabelTranslatorTests {
    private let english = Locale.Language(identifier: "en")
    private let simplifiedChinese = Locale.Language(identifier: "zh-Hans")
    private let japanese = Locale.Language(identifier: "ja")
    private let traditionalChinese = Locale.Language(identifier: "zh-Hant")

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

    @Test("Short Simplified titles are not mistaken for Traditional", arguments: [
        "柠檬味少女/Lemon Giri [4k 60FPS]", "麻匪 夏日影", "麻匪 Elisa", "土星 | Saturn - Sykm",
        "Blue Archive-Plana 普拉娜 祈福", "Summer Rain 夏之雨——夜莺Night", "【4K】雨(Make It Rain)",
    ])
    func shortSimplifiedTitles(title: String) {
        #expect(WPEPropertyLabelTranslator.needsTranslation(title, target: traditionalChinese))
    }

    @Test("Traditional text is told apart by its characters")
    func traditionalTextDetected() {
        #expect(!WPEPropertyLabelTranslator.needsTranslation("顯示觸發區域並啟用音頻響應", target: traditionalChinese))
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
    @Test("Labels skipped for a missing pack queue again once a re-check finds it installed")
    func recheckRequeuesSkippedLabels() async {
        guard #available(macOS 15.0, *) else { return }
        let label = "显示触发区域"
        let installed = OSAllocatedUnfairLock(initialState: false)
        let translator = WPEPropertyLabelTranslator(
            targetLanguage: english, isInstalled: { _, _ in installed.withLock { $0 } }
        )
        translator.enqueue(labels: [label])
        await translator.availabilityCheck?.value
        #expect(translator.configuration == nil)

        installed.withLock { $0 = true }
        translator.recheckLanguagePacks()
        await translator.availabilityCheck?.value
        #expect(translator.configuration?.source == simplifiedChinese)
        #expect(translator.configuration?.target == english)
        #expect(translator.takePending() == [label])
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

    @MainActor
    @Test("A label already in the app language translates once the app switches to another language")
    func retargetTranslatesLabelsSeenInTargetLanguage() async {
        guard #available(macOS 15.0, *) else { return }
        let label = "显示触发区域"
        let translator = WPEPropertyLabelTranslator(targetLanguage: simplifiedChinese, isInstalled: { _, _ in true })
        translator.enqueue(labels: [label])
        #expect(translator.availabilityCheck == nil)

        translator.retarget(to: english)
        await translator.availabilityCheck?.value
        #expect(translator.configuration?.target == english, "a label seen in the old target language was never queued for the new one")
        #expect(translator.takePending() == [label])
    }

    @MainActor
    @Test("A translation arriving keeps the labelled row mounted", .timeLimit(.minutes(1)))
    func authorHelpKeepsRowIdentity() async {
        let mount = AuthorHelpMount()
        let host = NSHostingView(rootView: AuthorHelpProbe(mount: mount))
        let window = ParkedTestWindow(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        func settle() async {
            for _ in 0 ..< 20 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await settle()
        #expect(mount.appearances == 1)

        mount.original = "显示触发区域"
        await settle()
        #expect(mount.disappearances == 0, "the row was torn down when its tooltip arrived, cancelling a slider's pending commit")
        #expect(mount.appearances == 1)
    }

    @Test("Descriptions split into lines, queue only the Chinese ones, and rejoin in order")
    func descriptionLines() {
        typealias Translator = WPEPropertyLabelTranslator
        let description = "夏日海边的黄昏\nA seaside town at dusk.\n\nhttps://example.com/wallpaper\n支持音频响应"
        let lines = Translator.descriptionLines(of: description)
        #expect(lines == ["夏日海边的黄昏", "A seaside town at dusk.", "", "https://example.com/wallpaper", "支持音频响应"])
        #expect(lines.filter { Translator.needsTranslation($0, target: english) } == ["夏日海边的黄昏", "支持音频响应"])

        #expect(Translator.joinLines(of: description, translated: [:]) == description)
        #expect(Translator.joinLines(of: description, translated: ["支持音频响应": "Supports audio response"])
            == "夏日海边的黄昏\nA seaside town at dusk.\n\nhttps://example.com/wallpaper\nSupports audio response")
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

    @MainActor
    @Test("A label queued while a session is draining joins its queue instead of restarting the session", .timeLimit(.minutes(1)))
    func enqueueDuringTranslationKeepsSession() async {
        guard #available(macOS 15.0, *) else { return }
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in true })
        translator.enqueue(labels: ["显示触发区域"])
        await translator.availabilityCheck?.value
        let version = translator.configuration?.version
        #expect(version != nil)
        #expect(translator.takePending() == ["显示触发区域"])

        translator.enqueue(labels: ["音频响应"])
        #expect(translator.configuration?.version == version, "a new card restarted the running session")
        #expect(translator.availabilityCheck == nil)
        #expect(translator.takePending() == ["音频响应"])
    }

    @MainActor
    @Test("Chunks hold at most eight labels and the newest queued come out first", .timeLimit(.minutes(1)))
    func chunksAreNewestFirst() async {
        guard #available(macOS 15.0, *) else { return }
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in true })
        let labels = (1 ... 10).map { "显示区域\($0)" }
        translator.enqueue(labels: labels)
        await translator.availabilityCheck?.value
        #expect(translator.takePending() == Array(labels.reversed().prefix(8)))
        #expect(translator.takePending() == ["显示区域2", "显示区域1"])
        #expect(translator.takePending().isEmpty)
    }

    @MainActor
    @Test("A disabled translator shows author text, opens no session, and queues seen labels once enabled", .timeLimit(.minutes(1)))
    func disabledTranslatorShowsOriginals() async {
        guard #available(macOS 15.0, *) else { return }
        let stored = "显示触发区域"
        let seen = "音频响应"
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in true }, isEnabled: false)
        translator.store([(stored, "Show trigger area")])
        #expect(translator.displayText(for: stored) == stored)
        #expect(translator.helpText(for: stored) == nil)
        #expect(translator.displayDescription(for: stored) == stored)

        translator.enqueue(labels: [seen])
        #expect(translator.availabilityCheck == nil)
        #expect(translator.configuration == nil)

        translator.setEnabled(true)
        #expect(translator.displayText(for: stored) == "Show trigger area")
        await translator.availabilityCheck?.value
        #expect(translator.configuration?.source == simplifiedChinese)
        #expect(translator.takePending() == [seen])
    }

    @MainActor
    @Test("Revision advances when translations land, not for an empty store")
    func revisionAdvancesOnStore() {
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in true })
        let start = translator.revision
        translator.store([])
        #expect(translator.revision == start)
        translator.store([("显示触发区域", "Show trigger area")])
        #expect(translator.revision > start)
    }

    @MainActor
    @Test("Revision advances when the switch flips, not when it is set to its current value")
    func revisionAdvancesOnToggle() {
        guard #available(macOS 15.0, *) else { return }
        let translator = WPEPropertyLabelTranslator(targetLanguage: english, isInstalled: { _, _ in true })
        let start = translator.revision
        translator.setEnabled(true)
        #expect(translator.revision == start)
        translator.setEnabled(false)
        let off = translator.revision
        #expect(off > start)
        translator.setEnabled(false)
        #expect(translator.revision == off)
        translator.setEnabled(true)
        #expect(translator.revision > off)
    }

    @MainActor
    private func cachedTranslator(
        _ url: URL, target: Locale.Language? = nil
    ) -> WPEPropertyLabelTranslator {
        WPEPropertyLabelTranslator(
            targetLanguage: target ?? english, isInstalled: { _, _ in true },
            nameCache: WallpaperNameTranslationCache(fileURL: url)
        )
    }

    private func scratchCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PropertyLabelTranslatorTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("names.json", isDirectory: false)
    }

    @MainActor
    @Test("A persisted library name shows its cached translation after a relaunch without queuing again", .timeLimit(.minutes(1)))
    func persistedNameLoadsFromCache() async {
        guard #available(macOS 15.0, *) else { return }
        let url = scratchCacheURL()
        let title = "夕阳下的海边小镇"
        let first = cachedTranslator(url)
        first.enqueue(labels: [title], persist: true)
        await first.availabilityCheck?.value
        #expect(first.takePending() == [title])
        first.store([(title, "Seaside town at sunset")])

        let relaunched = cachedTranslator(url)
        #expect(relaunched.displayText(for: title) == "Seaside town at sunset")
        relaunched.enqueue(labels: [title], persist: true)
        await relaunched.availabilityCheck?.value
        #expect(relaunched.configuration == nil, "a cached name was queued for translation again")
    }

    @MainActor
    @Test("Names queued without persist stay out of the cache")
    func unpersistedNameIsNotCached() {
        guard #available(macOS 15.0, *) else { return }
        let url = scratchCacheURL()
        let library = "夕阳下的海边小镇"
        let workshop = "雨夜的霓虹街道"
        let first = cachedTranslator(url)
        first.enqueue(labels: [library], persist: true)
        first.enqueue(labels: [workshop])
        first.store([(library, "Seaside town at sunset"), (workshop, "Neon street on a rainy night")])

        let relaunched = cachedTranslator(url)
        #expect(relaunched.displayText(for: library) == "Seaside town at sunset")
        #expect(relaunched.displayText(for: workshop) == workshop, "a Workshop name was written to the cache")
    }

    @MainActor
    @Test("Pruning drops cached names that left the library")
    func retainPersistedPrunesCache() {
        guard #available(macOS 15.0, *) else { return }
        let url = scratchCacheURL()
        let kept = "夕阳下的海边小镇"
        let removed = "雨夜的霓虹街道"
        let first = cachedTranslator(url)
        first.enqueue(labels: [kept, removed], persist: true)
        first.store([(kept, "Seaside town at sunset"), (removed, "Neon street on a rainy night")])
        first.retainPersisted([kept])

        let relaunched = cachedTranslator(url)
        #expect(relaunched.displayText(for: kept) == "Seaside town at sunset")
        #expect(relaunched.displayText(for: removed) == removed, "a name no longer in the library stayed cached")
    }

    @MainActor
    @Test("A different target language never reads another language's cached names")
    func cacheIsPerTargetLanguage() {
        guard #available(macOS 15.0, *) else { return }
        let url = scratchCacheURL()
        let title = "夕阳下的海边小镇"
        let translator = cachedTranslator(url)
        translator.enqueue(labels: [title], persist: true)
        translator.store([(title, "Seaside town at sunset")])

        #expect(cachedTranslator(url, target: japanese).displayText(for: title) == title)
        translator.retarget(to: japanese)
        #expect(translator.displayText(for: title) == title, "the English cache answered for a Japanese target")
        translator.retarget(to: english)
        #expect(translator.displayText(for: title) == "Seaside town at sunset")
    }
}

@MainActor @Observable
private final class AuthorHelpMount {
    /// The author label handed to `wpeAuthorLabelHelp`; nil while no translation replaced it.
    var original: String?
    @ObservationIgnored var appearances = 0
    @ObservationIgnored var disappearances = 0
}

private struct AuthorHelpProbe: View {
    let mount: AuthorHelpMount

    var body: some View {
        Color.clear
            .onAppear { mount.appearances += 1 }
            .onDisappear { mount.disappearances += 1 }
            .wpeAuthorLabelHelp(mount.original)
            .frame(width: 120, height: 40)
    }
}
#endif
