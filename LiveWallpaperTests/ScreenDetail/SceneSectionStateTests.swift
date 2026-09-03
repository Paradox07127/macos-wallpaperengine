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
