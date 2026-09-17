import Foundation
import Testing

/// Guards for the 0.7.0 cross-review fixes whose code lives in views, closures or a
/// target the test host cannot link. Each names the defect it keeps out.
@Suite("0.7.0 review fixes stay in place")
struct ReviewFixSourceGuardsTests {
    @Test("A saved bookmark only inherits the playing wallpaper's Workshop origin when it is that wallpaper")
    func bookmarkProvenanceIsNotBorrowedFromAnotherWallpaper() throws {
        let popover = try RepositoryRoot.source("LiveWallpaper/Views/Bookmarks/Popover.swift")
        #expect(
            !popover.contains("wpeOrigin: screenManager.getConfiguration(for: screen)?.wpeOrigin"),
            "the playing scene's origin was attached to whatever content the inspector held, so deleting that scene also deleted unrelated bookmarks"
        )
    }

    @Test("Perspective sprites keep the CPU depth scale whenever the GPU path has no matrix")
    func perspectiveSpritesFallBackToTheCPUScale() throws {
        let system = try RepositoryRoot.source("LiveWallpaper/Runtime/Scene/WPEParticleSystem.swift")
        #expect(
            system.contains("if definition.isPerspective, usesRibbonGeometry || cpuPerspectiveFallback {"),
            "3D scenes leave particlePerspectiveViewProjectionMatrix nil, so non-ribbon sprites lost every perspective treatment"
        )
        let frame = try RepositoryRoot.source("LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift")
        #expect(frame.contains("system.cpuPerspectiveFallback ="))
    }

    @Test("A low target frame rate is simulated in full, not truncated to a tenth of a second")
    func particleCatchUpBoundCoversTheLowestFrameRate() throws {
        let system = try RepositoryRoot.source("LiveWallpaper/Runtime/Scene/WPEParticleSystem.swift")
        #expect(
            !system.contains("min(now - (lastTickTime ?? now), 0.1)"),
            "at 5 FPS only 0.1 s of every 0.2 s frame was simulated, so particles ran at half speed"
        )
    }

    @Test("A finished navigation keeps the failure the same generation already classified")
    func finishedNavigationDoesNotEraseAClassifiedFailure() throws {
        let view = try RepositoryRoot.source("LiveWallpaper/Playback/Web/HTMLWallpaperView.swift")
        let finish = try #require(view.range(of: "func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {"))
        let body = view[finish.upperBound...].prefix(900)
        #expect(
            body.contains("if failedPreparationGeneration != preparationGeneration {"),
            "an HTTP error page finishes loading like any document, and the unconditional nil wiped its web.http_status classification"
        )
    }

    @Test("A changed preset value is announced, not only tinted")
    func presetDivergenceReachesVoiceOver() throws {
        let bar = try RepositoryRoot.source("LiveWallpaper/Views/ScreenDetail/ScenePresetBar.swift")
        #expect(bar.contains(".accessibilityValue(changedHelp)"), "the only remaining changed indicator was an accessibility-hidden dot")
        let card = try RepositoryRoot.source("LiveWallpaper/Views/ScreenDetail/SceneSettingsCard.swift")
        #expect(card.contains("Changed from preset"), "a diverging row was tint-only, which VoiceOver cannot read")
    }

    @Test("A finished scheme-task worker only reaps its own map entry")
    func schemeTaskWorkerDoesNotReapItsSuccessor() throws {
        let handler = try RepositoryRoot.source("LiveWallpaper/Playback/Web/FolderURLSchemeHandler.swift")
        #expect(
            handler.contains("activeTasks[taskID]?.delivery === delivery"),
            "a worker that outlived a stop() removed the replacement registered under the same task identifier"
        )
    }
}
