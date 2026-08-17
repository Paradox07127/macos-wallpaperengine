import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import SwiftUI
import Testing
@testable import LiveWallpaper

@Suite("SceneSection state machine")
struct WPESceneSectionStateTests {

    @Test("idle and loading states compare independently of associated values")
    func idleLoadingEquality() {
        #expect(SceneRenderState.idle == SceneRenderState.idle)
        #expect(SceneRenderState.loading == SceneRenderState.loading)
        #expect(SceneRenderState.idle != SceneRenderState.loading)
    }

    @Test("every state equals itself")
    func equalityIsReflexive() {
        // A hand-written `==` that forgot `.notRendering` made it unequal to
        // itself, so `next != state` fired on every refresh.
        let states: [SceneRenderState] = [
            .idle,
            .notRendering,
            .loading(progress: nil),
            .loading(progress: "Decoding 3/12 textures…"),
            .ready,
            .error(.sceneResourceMissing)
        ]
        for state in states {
            #expect(state == state)
        }
        for (index, lhs) in states.enumerated() {
            for rhs in states[(index + 1)...] {
                #expect(lhs != rhs)
            }
        }
    }

    @Test("loading distinguishes nil vs progress text payloads")
    func loadingPayloadDifferentiates() {
        let plain = SceneRenderState.loading(progress: nil)
        let labelled = SceneRenderState.loading(progress: "Decoding 3/12 textures…")
        #expect(plain != labelled)
        #expect(plain == SceneRenderState.loading)
        #expect(plain.isLoading)
        #expect(labelled.isLoading)
    }

    @MainActor
    @Test("Texture decoder error → FallbackReason mapping is precise")
    func textureFallbackMapping() {
        let unsupportedFormat: SceneLoadDiagnostic = .texture(
            layer: "background",
            error: .unsupportedFormat(code: 8)
        )
        let unsupportedContainer: SceneLoadDiagnostic = .texture(
            layer: "fg",
            error: .unsupportedContainer(magic: "TEXV9999")
        )
        let truncated: SceneLoadDiagnostic = .texture(
            layer: "fg",
            error: .truncatedBlock(block: "TEXB", offset: 42)
        )
        #expect(SceneDetailView.fallbackReason(for: unsupportedFormat) == .texUnsupportedFormat(code: 8))
        #expect(SceneDetailView.fallbackReason(for: unsupportedContainer) == .texContainerUnsupported(magic: "TEXV9999"))
        if case .texDecodeFailed = SceneDetailView.fallbackReason(for: truncated) {
        } else {
            Issue.record("Truncated tex should map to .texDecodeFailed")
        }
    }

    @Test("FallbackReason severity tint distinguishes warn vs hard block")
    func severityTintIsHonest() {
        let caution = DesignTokens.Colors.Status.caution
        let warning = DesignTokens.Colors.Status.warning
        #expect(FallbackReason.missingDependency(workshopIDs: ["1"]).severityTint == caution)
        #expect(FallbackReason.sceneResourceMissing.severityTint == caution)
        #expect(FallbackReason.texDecodeFailed(detail: "x").severityTint == caution)
        #expect(FallbackReason.requiresWindowsPlugin.severityTint == warning)
        #expect(FallbackReason.texContainerUnsupported(magic: "X").severityTint == warning)
        #expect(FallbackReason.texUnsupportedFormat(code: 8).severityTint == warning)
        #expect(caution != warning)
    }

    @Test("isActionable matches the Retry button visibility policy")
    func isActionableMatchesRetry() {
        #expect(FallbackReason.missingDependency(workshopIDs: []).isActionable)
        #expect(FallbackReason.texDecodeFailed(detail: "x").isActionable)
        #expect(!FallbackReason.requiresWindowsPlugin.isActionable)
        #expect(!FallbackReason.texContainerUnsupported(magic: "X").isActionable)
        #expect(!FallbackReason.texUnsupportedFormat(code: 8).isActionable)
    }

    @Test("error state carries the FallbackReason")
    func errorKeepsFallbackReason() {
        let parse = SceneRenderState.error(.sceneParseFailed("boom"))
        let resource = SceneRenderState.error(.sceneResourceMissing)
        #expect(parse != resource)
        #expect(parse == SceneRenderState.error(.sceneParseFailed("boom")))
    }

    @MainActor
    @Test("FallbackReason rendering distinguishes parse vs resource failure copy")
    func fallbackReasonCopy() {
        let parse = FallbackCard(
            origin: makeOrigin(),
            reason: .sceneParseFailed("missing camera")
        )
        let missing = FallbackCard(
            origin: makeOrigin(),
            reason: .sceneResourceMissing
        )
        #expect(parse.reason != missing.reason)
        #expect(parse.reason == .sceneParseFailed("missing camera"))
    }

    @MainActor
    @Test("Engine-assets recovery is offered on a ref-less failure whose cause fits")
    func engineAssetsRecoveryCoversRefLessFailures() {
        // The reported gap: a scene that failed before the resolver ran left the
        // user with the error banner and no way to reach the assets setup.
        #expect(SceneDetailView.showsEngineAssetsRecovery(
            isEngineAssetsLinked: false,
            missedRefCount: 0,
            failureMightNeedAssets: true
        ))
        #expect(SceneDetailView.showsEngineAssetsRecovery(
            isEngineAssetsLinked: false,
            missedRefCount: 3,
            failureMightNeedAssets: false
        ))
    }

    @MainActor
    @Test("Engine-assets recovery stays hidden when linked or when nothing is wrong")
    func engineAssetsRecoveryStaysQuiet() {
        // A linked install can't be the cause, however the scene failed.
        #expect(!SceneDetailView.showsEngineAssetsRecovery(
            isEngineAssetsLinked: true,
            missedRefCount: 9,
            failureMightNeedAssets: true
        ))
        // Unlinked is the normal state — most scenes use the built-in equivalents.
        #expect(!SceneDetailView.showsEngineAssetsRecovery(
            isEngineAssetsLinked: false,
            missedRefCount: 0,
            failureMightNeedAssets: false
        ))
    }

    @Test("Only unresolved resources point at an engine-assets install")
    func onlyResourceMissesBlameEngineAssets() {
        #expect(FallbackReason.sceneResourceMissing.mightBeMissingEngineAssets)
        // Downloading gigabytes fixes none of these, so none may advertise it.
        #expect(!FallbackReason.requiresWindowsPlugin.mightBeMissingEngineAssets)
        #expect(!FallbackReason.texContainerUnsupported(magic: "TEXV9999").mightBeMissingEngineAssets)
        #expect(!FallbackReason.texUnsupportedFormat(code: 8).mightBeMissingEngineAssets)
        #expect(!FallbackReason.texDecodeFailed(detail: "truncated").mightBeMissingEngineAssets)
        #expect(!FallbackReason.sceneParseFailed("no camera").mightBeMissingEngineAssets)
        #expect(!FallbackReason.sceneShaderUnsupported.mightBeMissingEngineAssets)
        #expect(!FallbackReason.missingDependency(workshopIDs: ["1"]).mightBeMissingEngineAssets)
        #expect(!FallbackReason.unsupportedType.mightBeMissingEngineAssets)
    }

    private func makeOrigin() -> WPEOrigin {
        WPEOrigin(
            workshopID: "state-machine",
            title: "State Machine",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01]),
            cacheRelativePath: "wpe-cache/state-machine",
            previewFileName: nil,
            entryFile: "scene.json",
            resourceLocation: .cache
        )
    }
}
