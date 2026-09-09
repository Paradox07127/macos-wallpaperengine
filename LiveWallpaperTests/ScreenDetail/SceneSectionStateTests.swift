import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import SwiftUI
import Testing
@testable import LiveWallpaper

@Suite("SceneSection state machine")
struct WPESceneSectionStateTests {

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

    @Test("Failure class drives the tint, so a reason cannot carry two colours")
    func tintFollowsFailureClass() {
        let danger = DesignTokens.Colors.Status.danger
        let warning = DesignTokens.Colors.Status.warning
        let caution = DesignTokens.Colors.Status.caution
        #expect(danger != warning)
        #expect(warning != caution)

        #expect(FallbackReason.requiresWindowsPlugin.failureClass == .fatal)
        #expect(FallbackReason.requiresWindowsPlugin.tint == danger)
        #expect(FallbackReason.texContainerUnsupported(magic: "X").tint == danger)
        #expect(FallbackReason.sceneParseFailed("boom").failureClass == .blocked)
        #expect(FallbackReason.sceneParseFailed("boom").tint == warning)
        #expect(FallbackReason.texDecodeFailed(detail: "x").tint == warning)
        #expect(FallbackReason.missingDependency(workshopIDs: ["1"]).failureClass == .needsParts)
        #expect(FallbackReason.missingDependency(workshopIDs: ["1"]).tint == caution)
        #expect(FallbackReason.sceneResourceMissing.tint == caution)
        // Skipping a layer is not the same event as failing to load a scene.
        #expect(FallbackReason.texUnsupportedFormat(code: 8).failureClass == .degraded)
    }

    @Test("Recovery actions match what the reason can actually recover from")
    func recoveryMatchesFailureClass() {
        let steamID = "1234"
        #expect(FallbackReason.missingDependency(workshopIDs: ["7"]).recovery(workshopID: steamID)
            .contains(.copyDependencyIDs(["7"])))
        #expect(FallbackReason.sceneResourceMissing.recovery(workshopID: steamID)
            .contains(.configureEngineAssets))
        #expect(FallbackReason.sceneParseFailed("boom").recovery(workshopID: steamID).contains(.retry))
        // Fatal reasons offer no retry on any surface.
        #expect(!FallbackReason.requiresWindowsPlugin.recovery(workshopID: steamID).contains(.retry))
        #expect(!FallbackReason.texContainerUnsupported(magic: "X").recovery(workshopID: steamID).contains(.retry))
        #expect(!FallbackReason.texUnsupportedFormat(code: 8).recovery(workshopID: steamID).contains(.retry))
        // A local project has no Workshop page to open.
        #expect(FallbackReason.requiresWindowsPlugin.recovery(workshopID: "local-folder").isEmpty)
    }

    @Test("error state carries the FallbackReason")
    func errorKeepsFallbackReason() {
        let parse = SceneRenderState.error(.sceneParseFailed("boom"))
        let resource = SceneRenderState.error(.sceneResourceMissing)
        #expect(parse != resource)
        #expect(parse == SceneRenderState.error(.sceneParseFailed("boom")))
    }

    @MainActor
    @Test("The engine-assets banner is driven by setup state, not by a failure")
    func engineAssetsBannerFollowsSetupState() {
        // Measured on 3558034522: with no install linked the scene leaves 144
        // references unresolved, renders four passes short and reports no
        // error at all. Waiting for a failure meant the warning never showed.
        #expect(EngineAssetsBanner.shouldShow(isFeatureEnabled: true, hasEngineAssets: false))
        #expect(!EngineAssetsBanner.shouldShow(isFeatureEnabled: true, hasEngineAssets: true))
        // Lite has no Workshop scenes to warn about.
        #expect(!EngineAssetsBanner.shouldShow(isFeatureEnabled: false, hasEngineAssets: false))
    }
}

@Suite("ColorAdjustmentsView reset")
struct ColorAdjustmentsViewResetTests {
    @MainActor
    @Test("Reset Color & Filters only touches the six promised fields")
    func resetPreservesWeatherAndParticleFields() {
        var config = VideoEffectConfig()
        config.blurRadius = 12
        config.brightness = 0.3
        config.saturation = 1.8
        config.warmth = 3200
        config.vignetteIntensity = 2.5
        config.autoTimeTint = true
        config.weatherReactive = true
        config.weatherWind = true
        config.weatherIntensity = false
        config.particleDensity = 2.5

        let result = ColorAdjustmentsView.resettingColorAdjustments(config)

        #expect(result.blurRadius == VideoEffectConfig.default.blurRadius)
        #expect(result.brightness == VideoEffectConfig.default.brightness)
        #expect(result.saturation == VideoEffectConfig.default.saturation)
        #expect(result.warmth == VideoEffectConfig.default.warmth)
        #expect(result.vignetteIntensity == VideoEffectConfig.default.vignetteIntensity)
        #expect(result.autoTimeTint == VideoEffectConfig.default.autoTimeTint)

        #expect(result.weatherReactive == true)
        #expect(result.weatherWind == true)
        #expect(result.weatherIntensity == false)
        #expect(result.particleDensity == 2.5)
    }
}

@Suite("OverlaysInspectorPanel particle picker")
struct OverlaysInspectorPanelPickerTests {
    @MainActor
    @Test("Picker excludes .none — closing it must go through the toggle")
    func pickerEffectsExcludesNone() {
        let effects = OverlaysInspectorPanel.pickerEffects
        #expect(!effects.contains(.none))
        #expect(effects == ParticleEffect.allCases.filter { $0 != .none })
    }
}
