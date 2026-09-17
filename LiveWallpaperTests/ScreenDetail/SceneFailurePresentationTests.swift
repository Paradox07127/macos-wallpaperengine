import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Scene failure presentation")
struct SceneFailurePresentationTests {
    /// Every case, so a newly added reason cannot ship without a mapping.
    private static let allReasons: [FallbackReason] = [
        .unsupportedType,
        .sceneParseFailed("boom"),
        .sceneShaderUnsupported,
        .sceneResourceMissing,
        .missingDependency(workshopIDs: ["111", "222"]),
        .requiresWindowsPlugin,
        .texContainerUnsupported(magic: "TEXV0009"),
        .texUnsupportedFormat(code: 8),
        .texDecodeFailed(detail: "mip 3"),
    ]

    @Test("Every reason has a distinct, non-empty error code")
    func codesAreDistinct() {
        let codes = Self.allReasons.map(\.code)
        #expect(codes.allSatisfy { !$0.isEmpty })
        #expect(Set(codes).count == Self.allReasons.count)
        #expect(codes.allSatisfy { $0.hasPrefix("WPE_") })
    }

    @Test("Every reason has a symbol, and colour is never the only difference")
    func symbolsAccompanyEveryTint() {
        for reason in Self.allReasons {
            #expect(!reason.symbol.isEmpty)
            #expect(!reason.localizedTitle(originalType: .scene).isEmpty)
        }
    }

    @Test("Tint is a pure function of failure class")
    func tintIsDerivedFromClass() {
        for reason in Self.allReasons {
            let expected: Color = switch reason.failureClass {
            case .fatal: DesignTokens.Colors.Status.danger
            case .blocked: DesignTokens.Colors.Status.warning
            case .needsParts, .degraded: DesignTokens.Colors.Status.caution
            }
            #expect(reason.tint == expected)
        }
    }

    @Test("A fatal reason never offers a retry, a recoverable one always does")
    func retryTracksRecoverability() {
        for reason in Self.allReasons {
            let actions = reason.recovery(workshopID: "1234")
            switch reason.failureClass {
            case .fatal, .degraded:
                #expect(!actions.contains(.retry))
            case .blocked, .needsParts:
                #expect(actions.contains(.retry))
            }
        }
    }

    /// 0.6.7's card always linked a Steam item to its Workshop page; the missing-resource
    /// row must keep that, and must not lead with a setup step the user already finished.
    @Test("Missing resources keep the Workshop link and drop asset setup once assets are linked")
    func missingResourcesRecovery() {
        let reason = FallbackReason.sceneResourceMissing
        #expect(reason.recovery(workshopID: "1234") == [.configureEngineAssets, .retry, .openWorkshop("1234")])
        #expect(reason.recovery(workshopID: "1234", engineAssetsAuthorized: true) == [.retry, .openWorkshop("1234")])
        #expect(reason.recovery(workshopID: "local") == [.configureEngineAssets, .retry])
    }

    @Test("Both surfaces read the same presentation for the same reason")
    func presentationIsSurfaceIndependent() {
        let origin = WPEOrigin(
            workshopID: "1234",
            title: "Night Sky",
            originalType: .scene,
            sourceFolderBookmark: Data([1]),
            cacheRelativePath: "1234",
            previewFileName: nil,
            entryFile: "scene.json"
        )
        for reason in Self.allReasons {
            let a = reason.presentation(origin: origin, engineAssetsAuthorized: true)
            let b = reason.presentation(origin: origin, engineAssetsAuthorized: true)
            #expect(a.tint == b.tint)
            #expect(a.symbol == b.symbol)
            #expect(a.code == b.code)
            #expect(a.recovery == b.recovery)
            #expect(a.failureClass == b.failureClass)
        }
    }

    @Test("Shared-asset wording changes with whether assets are linked")
    func resourceMessageTracksAssetState() {
        let linked = FallbackReason.sceneResourceMissing
            .localizedMessage(originalType: .scene, engineAssetsAuthorized: true)
        let unlinked = FallbackReason.sceneResourceMissing
            .localizedMessage(originalType: .scene, engineAssetsAuthorized: false)
        #expect(linked != unlinked)
        #expect(!linked.isEmpty)
        #expect(!unlinked.isEmpty)
    }
}
