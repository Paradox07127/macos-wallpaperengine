import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore

enum FakePlayableVideoLoaderError: Error, Equatable, Sendable {
    case validationFailed
}

actor FakePlayableVideoLoader: PlayableVideoLoading {
    private(set) var validatedURLs: [URL] = []
    private(set) var completedValidationCount = 0
    private let validationError: FakePlayableVideoLoaderError?
    private let suspendsValidation: Bool
    private var validationContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        validationError: FakePlayableVideoLoaderError? = nil,
        suspendsValidation: Bool = false
    ) {
        self.validationError = validationError
        self.suspendsValidation = suspendsValidation
    }

    func validatePlayableVideo(at url: URL) async throws {
        validatedURLs.append(url)
        if suspendsValidation {
            await withCheckedContinuation { continuation in
                validationContinuations.append(continuation)
            }
        }
        try Task.checkCancellation()
        completedValidationCount += 1
        if let validationError {
            throw validationError
        }
    }

    var pendingValidationCount: Int { validationContinuations.count }

    func resumeAllValidations() {
        let pending = validationContinuations
        validationContinuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
