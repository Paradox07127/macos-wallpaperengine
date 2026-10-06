#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Translation pack offer follows the current app language")
struct TranslationPackOfferTests {
    private let english = Locale.Language(identifier: "en")
    private let japanese = Locale.Language(identifier: "ja")

    @available(macOS 15.0, *)
    @Test(.timeLimit(.minutes(1)))
    func olderCheckFinishingLastKeepsCurrentLanguageResult() async {
        let gate = AvailabilityGate()
        let english = english
        let offer = TranslationPackOffer { _, target in
            target == english ? await gate.wait() : true
        }
        let stale = Task { await offer.refresh(target: english) }
        await gate.waitUntilParked()
        await offer.refresh(target: japanese)
        #expect(offer.offersDownload)
        await gate.release(false)
        await stale.value
        #expect(offer.offersDownload, "The previous language's check finished last and replaced the current language's offer")
    }

    @available(macOS 15.0, *)
    @Test(.timeLimit(.minutes(1)))
    func finishedDownloadRechecksCurrentLanguage() async {
        let asked = AskedTargets()
        let offer = TranslationPackOffer { _, target in
            await asked.append(target)
            return true
        }
        offer.requestDownload(target: english)
        await offer.refresh(target: japanese)
        await offer.finishDownload()
        #expect(await asked.targets.last == japanese, "A finished download re-checked the language it was started for, not the app language")
    }
}

private actor AvailabilityGate {
    private var pending: CheckedContinuation<Bool, Never>?
    private var parked: CheckedContinuation<Void, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            pending = continuation
            parked?.resume()
            parked = nil
        }
    }

    func waitUntilParked() async {
        guard pending == nil else { return }
        await withCheckedContinuation { parked = $0 }
    }

    func release(_ result: Bool) {
        pending?.resume(returning: result)
        pending = nil
    }
}

private actor AskedTargets {
    private(set) var targets: [Locale.Language] = []

    func append(_ target: Locale.Language) {
        targets.append(target)
    }
}
#endif
