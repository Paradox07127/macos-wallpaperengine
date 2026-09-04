#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

private actor APIKeySaveProbe {
    private(set) var callCount = 0

    func save(_: String) async throws {
        callCount += 1
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

@Suite("SteamWebAPIKeyEntryModel")
struct SteamWebAPIKeyEntryModelTests {
    private static let sampleKey = String(repeating: "a1b2c3d4", count: 4)

    @Test("Save is single-flight and disables every save surface")
    @MainActor
    func saveIsSingleFlight() async {
        let probe = APIKeySaveProbe()
        let model = SteamWebAPIKeyEntryModel(
            dependencies: .init(
                validationDelayNanoseconds: 0,
                validateAPIKey: { _ in true },
                saveAPIKey: { try await probe.save($0) },
                deleteAPIKey: {},
                refreshAPIKeyStatus: {}
            )
        )
        model.apiKey = Self.sampleKey
        model.keyChanged()
        await waitForValidation(of: model)
        #expect(model.canSave)

        async let firstSave = model.save()
        while !model.isSaving {
            await Task.yield()
        }
        #expect(model.canSave == false)

        #expect(await model.save() == false)
        #expect(await firstSave)
        #expect(await probe.callCount == 1)
        #expect(model.isSaving == false)
    }

    @Test("A late save failure cannot overwrite a newly edited key")
    @MainActor
    func lateFailureDoesNotOverwriteNewEdit() async {
        struct ExpectedFailure: Error {}
        let model = SteamWebAPIKeyEntryModel(
            dependencies: .init(
                validationDelayNanoseconds: 0,
                validateAPIKey: { _ in true },
                saveAPIKey: { _ in
                    try await Task.sleep(nanoseconds: 50_000_000)
                    throw ExpectedFailure()
                },
                deleteAPIKey: {},
                refreshAPIKeyStatus: {}
            )
        )
        model.apiKey = Self.sampleKey
        model.keyChanged()
        await waitForValidation(of: model)

        async let saveResult = model.save()
        while !model.isSaving {
            await Task.yield()
        }
        model.apiKey = String(repeating: "f9e8d7c6", count: 4)
        model.keyChanged()

        #expect(await saveResult == false)
        #expect(model.savingError == nil)
        #expect(model.isSaving == false)
    }

    @MainActor
    private func waitForValidation(of model: SteamWebAPIKeyEntryModel) async {
        while model.validation == .validating {
            await Task.yield()
        }
    }
}
#endif
