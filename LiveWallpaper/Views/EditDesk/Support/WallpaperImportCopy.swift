import LiveWallpaperCore
import SwiftUI

enum OnboardingImportCopy {
    enum UnsupportedFileTypeVariant: Equatable {
        case videoAndWeb
        case videoWebAndScene
    }

    static func unsupportedFileTypeVariant(sceneCapable: Bool) -> UnsupportedFileTypeVariant {
        sceneCapable ? .videoWebAndScene : .videoAndWeb
    }

    static func sceneCapable(in catalog: FeatureCatalog) -> Bool {
        catalog.isEnabled(.scene)
    }

    static func unsupportedFileTypeMessage(sceneCapable: Bool) -> LocalizedStringResource {
        switch unsupportedFileTypeVariant(sceneCapable: sceneCapable) {
        case .videoAndWeb:
            "That file type isn't supported. Pick a video or web page."
        case .videoWebAndScene:
            "That file type isn't supported. Pick a video, web page, or scene."
        }
    }
}
