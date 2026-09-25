import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// Pins GAP_ANALYSIS.md §8.2's layout B: 16:9 hero on the left, 372 inspector on the right.
@Suite("Display detail shell")
struct DisplayDetailTests {
    private func near(_ actual: CGFloat, _ expected: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(actual - expected) <= tolerance
    }

    private func tag(_ index: Int, current: Bool = false) -> DetailDisplayTag {
        DetailDisplayTag(id: CGDirectDisplayID(index), name: "Display \(index)", thumbnail: nil, isCurrent: current)
    }

    // MARK: Stage area

    @Test("The stage area is everything left of the 372 inspector and below the 56 top bar")
    func stageAreaExcludesTheInspectorAndTopBar() {
        #expect(
            DetailGeometry.stageRect(in: CGSize(width: 1280, height: 820))
                == CGRect(x: 0, y: 56, width: 908, height: 764)
        )
        #expect(
            DetailGeometry.stageRect(in: CGSize(width: 1040, height: 700))
                == CGRect(x: 0, y: 56, width: 668, height: 644)
        )
        #expect(DetailGeometry.inspectorWidth == 372)
    }

    // MARK: Hero box

    @Test("The design window gives an 860×483.75 hero at x 24, centred in the stage area")
    func heroAtDesignSize() {
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1280, height: 820))
        #expect(near(hero.minX, 24) && near(hero.width, 860), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 483.75), Comment(rawValue: "\(hero)"))
        // Preview alone is centred; no explanatory footer consumes canvas space.
        #expect(near(hero.minY, 56 + (764 - 483.75) / 2), Comment(rawValue: "\(hero)"))
    }

    @Test("The smallest window gives a 620×348.75 hero, still at x 24")
    func heroAtMinimumWindow() {
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1040, height: 700))
        #expect(near(hero.minX, 24) && near(hero.width, 620), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 348.75), Comment(rawValue: "\(hero)"))
        #expect(near(hero.minY, 56 + (644 - 348.75) / 2), Comment(rawValue: "\(hero)"))
    }

    @Test("A wider window grows the hero at 16:9 and keeps the inspector at 372")
    func heroGrowsWithTheWindow() {
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1600, height: 1000))
        // 1600 − 372 − 48 = 1180 wide; the 944-tall stage area has height to spare.
        #expect(near(hero.minX, 24) && near(hero.width, 1180), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 663.75), Comment(rawValue: "\(hero)"))
        #expect(near(hero.width / hero.height, 16.0 / 9), Comment(rawValue: "\(hero)"))
    }

    @Test("A short window lets the height cap the hero instead of the width")
    func heroHeightCaps() {
        // 1600 − 372 − 48 = 1180 across, but only 644 − 48 = 596 of vertical budget.
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1600, height: 700))
        #expect(near(hero.width, 596 * 16 / 9), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 596), Comment(rawValue: "\(hero)"))
        #expect(hero.maxX <= DetailGeometry.stageRect(in: CGSize(width: 1600, height: 700)).maxX)
    }

    @Test("Fingers moving right step back, moving left step forward; vertical and diagonal scrolling stay in place")
    func swipeStepsByFingerDirection() {
        var right = DetailSwipeGesture()
        #expect(right.update(dx: 50, dy: 3) == nil)
        #expect(right.update(dx: 50, dy: 1) == .previous, "fingers moving right past 96pt step back")
        var left = DetailSwipeGesture()
        #expect(left.update(dx: -150, dy: 0) == .next)
        var vertical = DetailSwipeGesture()
        #expect(vertical.update(dx: 5, dy: 30) == nil)
        #expect(vertical.update(dx: 120, dy: 0) == nil, "a gesture that started vertical never steps")
        var diagonal = DetailSwipeGesture()
        #expect(diagonal.update(dx: 110, dy: 90) == nil)
    }

    /// `events` scroll events 10ms apart from `start`; the first one carries `.began` when `began` is set.
    private func swipe(
        _ tracker: inout DetailSwipeTracker, dx: CGFloat, dy: CGFloat = 0, events: Int, from start: TimeInterval,
        began: Bool = true, hasPhase: Bool = true, startsInside: Bool = true
    ) -> [DetailSwipeStep] {
        (0 ..< events).compactMap { index in
            tracker.handle(
                hasPhase: hasPhase, began: began && index == 0, ended: false, timestamp: start + Double(index) * 0.01,
                startsInside: startsInside, dx: dx, dy: dy
            )
        }
    }

    @Test("One gesture takes one step, however far it travels; the next gesture takes the next")
    func swipeStepsOncePerGesture() {
        var tracker = DetailSwipeTracker()
        #expect(swipe(&tracker, dx: 20, events: 13, from: 1) == [.previous], "260pt of travel is still one step")
        _ = tracker.handle(hasPhase: true, began: false, ended: true, timestamp: 1.2, startsInside: true, dx: 0, dy: 0)
        #expect(swipe(&tracker, dx: -20, events: 6, from: 2) == [.next])
    }

    @Test("A gesture that starts outside the canvas never steps")
    func swipeStartingOutsideIsIgnored() {
        var tracker = DetailSwipeTracker()
        #expect(swipe(&tracker, dx: 20, events: 13, from: 1, startsInside: false).isEmpty)
    }

    @Test("Precise events without a phase split into gestures on 0.25s of silence")
    func phaselessEventsSplitOnSilence() {
        var tracker = DetailSwipeTracker()
        #expect(swipe(&tracker, dx: 20, events: 13, from: 10, began: false, hasPhase: false) == [.previous])
        #expect(swipe(&tracker, dx: 20, events: 13, from: 10.2, began: false, hasPhase: false).isEmpty, "0.08s after the last event is the same gesture")
        #expect(swipe(&tracker, dx: 20, events: 13, from: 10.7, began: false, hasPhase: false) == [.previous])
    }

    @Test("A phased gesture that rests after its step takes no second step until it ends")
    func phasedGestureRestingAfterItsStepStaysSpent() {
        var tracker = DetailSwipeTracker()
        #expect(swipe(&tracker, dx: 20, events: 13, from: 1) == [.previous])
        #expect(swipe(&tracker, dx: 20, events: 13, from: 1.52, began: false).isEmpty, "a 0.4s rest mid-gesture restarted it")
        _ = tracker.handle(hasPhase: true, began: false, ended: true, timestamp: 1.7, startsInside: true, dx: 0, dy: 0)
        #expect(swipe(&tracker, dx: 20, events: 13, from: 2) == [.previous])
    }

    @Test("A phaseless gesture rejected as vertical still ends on 0.25s of silence")
    func phaselessRejectedGestureEndsOnSilence() {
        var tracker = DetailSwipeTracker()
        #expect(swipe(&tracker, dx: 0, dy: 20, events: 6, from: 1, began: false, hasPhase: false).isEmpty)
        #expect(swipe(&tracker, dx: 20, events: 13, from: 1.35, began: false, hasPhase: false) == [.previous], "the rejected gesture outlived the silence")
    }

    @Test("Both canvases keep their swipe tracker outside the per-display identity, so a switch cannot restart the gesture")
    func swipeTrackerOutlivesDisplaySwitches() throws {
        for (path, member) in [
            ("LiveWallpaper/Views/EditDesk/Detail/DisplayDetail.swift", "private var wallpaperPreview: some View {"),
            ("LiveWallpaper/Views/EditDesk/Overlay/OverlayWorkspace.swift", "private var canvas: some View {"),
        ] {
            let source = try RepositoryRoot.source(path)
            let start = try #require(source.range(of: member), Comment(rawValue: "\(path) has no \(member)"))
            let body = try #require(String(source[start.upperBound...]).components(separatedBy: "\n    }").first)
            let identity = try #require(body.range(of: ".id("), Comment(rawValue: "\(path) lost its per-display identity"))
            let navigator = try #require(body.range(of: "DetailSwipeNavigator("), Comment(rawValue: "\(path) has no swipe navigator"))
            #expect(
                identity.upperBound <= navigator.lowerBound,
                Comment(rawValue: "\(path): inside `.id` the navigator is rebuilt mid-swipe and steps twice")
            )
        }
        let backOnly = try RepositoryRoot.swiftFiles(under: "LiveWallpaper").filter { file in
            try String(contentsOf: file, encoding: .utf8).contains("DetailBackSwipe")
        }
        #expect(backOnly.isEmpty, Comment(rawValue: "back-only swipes left in \(backOnly.map { RepositoryRoot.relativePath(of: $0) })"))
    }

    @Test("The overlay canvas reports its drop frame from outside its per-display identity, so a switch's slide cannot skew a landing")
    func dropFrameOutlivesDisplaySwitches() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayWorkspace.swift")
        let start = try #require(source.range(of: "private var canvas: some View {"))
        let canvas = try #require(String(source[start.upperBound...]).components(separatedBy: "\n    }").first)
        let identity = try #require(canvas.range(of: ".id(screen.id)"), "the canvas lost its per-display identity")
        #expect(canvas.components(separatedBy: "addDrag.canvasFrame =").count - 1 == 1, "one writer, or the old and new canvas race")
        let report = try #require(canvas.range(of: "addDrag.canvasFrame ="), "the canvas no longer reports its frame for drops")
        #expect(identity.upperBound <= report.lowerBound, "inside `.id` both canvases report mid-switch, one of them still offset")
    }

    @Test("Collapsing or resizing the inspector preserves preview centering and aspect ratio")
    func variableInspectorGeometry() {
        let window = CGSize(width: 1040, height: 700)
        for width: CGFloat in [0, 300, 372, 520] {
            let hero = DetailGeometry.heroFrame(in: window, inspectorWidth: width)
            #expect(near(hero.midX, (window.width - width) / 2))
            #expect(near(hero.midY, 56 + (window.height - 56) / 2))
            #expect(near(hero.width / hero.height, 16.0 / 9))
            #expect(hero.maxX <= window.width - width - 24)
            #expect(hero.maxY <= window.height - 24)
        }
    }

    // MARK: Preview state

    private func attempt(_ phase: WallpaperLoadAttempt.Phase, inspecting: Bool) -> WallpaperLoadAttempt {
        WallpaperLoadAttempt(
            id: UUID(), screenID: 1, screenIdentity: ObjectIdentifier(DisplayDetailTests.self),
            displayFingerprint: "", title: "", phase: phase, isInspecting: inspecting
        )
    }

    @Test("An inspected attempt takes the column; a failure stepped back from and a runtime error become notices")
    func previewStateFollowsTheAttempt() {
        func state(_ configured: Bool, _ attempt: WallpaperLoadAttempt?, runtimeError: Bool = false) -> DetailPreviewState {
            DetailPreviewState.resolve(hasConfiguration: configured, attempt: attempt, hasRuntimeError: runtimeError)
        }
        #expect(state(false, nil) == .empty)
        #expect(state(true, nil) == .hero)
        #expect(state(false, attempt(.importing, inspecting: true)) == .preparing)
        #expect(state(true, attempt(.preparing, inspecting: true), runtimeError: true) == .preparing)
        #expect(state(true, attempt(.failed, inspecting: true), runtimeError: true) == .prepareFailed)
        #expect(state(true, attempt(.failed, inspecting: false), runtimeError: true) == .lastAttemptFailed)
        #expect(state(false, attempt(.failed, inspecting: false)) == .lastAttemptFailed)
        #expect(state(true, nil, runtimeError: true) == .runtimeError)
        #expect(state(false, nil, runtimeError: true) == .runtimeError)
        // Rebuilding the running scene after a property change prepares without taking the page.
        #expect(state(true, attempt(.preparing, inspecting: false)) == .hero)
    }

    @Test("An apply still preparing takes the column until an attempt of its own is inspected")
    func applyingShowsPreparing() {
        #expect(DetailPreviewState.resolve(hasConfiguration: true, attempt: nil, hasRuntimeError: false, applying: true) == .preparing)
        #expect(DetailPreviewState.resolve(hasConfiguration: true, attempt: nil, hasRuntimeError: false) == .hero)
    }

    @Test("A committed web transform stays drawn over the old capture until a new one replaces it")
    func committedTransformWaitsForTheNextCapture() {
        let base = HTMLConfig.default
        var committed = base
        committed.transformScale = 1.5
        committed.transformRotationDegrees = 90
        committed.transformTranslateX = 40
        let lag = WebTransformLag(base: base, baseVersion: 1)
        #expect(lag.pending(to: committed, over: 1) == .init(scale: 1.5, rotation: 90, translateX: 40, translateY: 0))
        #expect(lag.pending(to: committed, over: 2) == .none)
    }

    @Test("A runtime error keeps its own banner under a failed attempt's notice")
    func runtimeErrorShowsUnderTheFailedAttempt() {
        #expect(DetailPreviewState.lastAttemptFailed.showsRuntimeError)
        #expect(DetailPreviewState.runtimeError.showsRuntimeError)
        // Control: an attempt's page fills the column, so no banner sits over it.
        #expect(!DetailPreviewState.prepareFailed.showsRuntimeError)
    }

    // MARK: Top-bar tags

    @Test("Three display tags stay unfolded")
    func threeTagsDoNotFold() {
        let split = DetailTagRow.split([tag(1, current: true), tag(2), tag(3)])
        #expect(split.visible.count == 3)
        #expect(split.overflow == 0)
    }

    @Test("Five display tags fold to the first three plus +2")
    func fiveTagsFold() {
        let split = DetailTagRow.split((1 ... 5).map { tag($0) })
        #expect(split.visible.map(\.id) == [1, 2, 3])
        #expect(split.overflow == 2)
        // Four is the first count that folds at all.
        #expect(DetailTagRow.split((1 ... 4).map { tag($0) }).overflow == 1)
    }

    @Test("The current display's tag takes the last visible slot instead of folding")
    func currentTagStaysVisible() {
        let split = DetailTagRow.split((1 ... 5).map { tag($0, current: $0 == 5) })
        #expect(split.visible.map(\.id) == [1, 2, 5])
        #expect(split.overflow == 2)
    }

    // MARK: Hero facts

    @Test("A 4K HDR video lists its badges, pixel size, frame rate and file size in the old overlay's order")
    @MainActor
    func videoFactsKeepTheOldOrder() {
        let bytes: Int64 = 1_500_000_000
        let uhd = VideoFormatInfo(isHDR: true, resolution: CGSize(width: 3840, height: 2160), frameRate: 60)
        let size = WorkshopByteFormatter.kilobytesAndUp.string(fromByteCount: bytes)
        #expect(DetailFacts.video(format: uhd, fileSize: bytes).map(\.text) == ["4K", "HDR", "3840×2160", "60 FPS", size])
        let sdr = VideoFormatInfo(resolution: CGSize(width: 1920, height: 1080), frameRate: 30)
        #expect(DetailFacts.video(format: sdr, fileSize: nil).map(\.text) == ["1920×1080", "30 FPS"])
    }

    @Test("A video the player has not probed yet, with no size on record, lists nothing")
    @MainActor
    func unprobedVideoHasNoFacts() {
        #expect(DetailFacts.video(format: nil, fileSize: nil).isEmpty)
        #expect(DetailFacts.video(format: VideoFormatInfo(), fileSize: nil).isEmpty)
    }

    @Test("A web page flags plain HTTP and disabled JavaScript as warnings")
    @MainActor
    func webFactsFlagHTTPAndNoJavaScript() throws {
        var config = HTMLConfig.default
        config.allowJavaScript = false
        config.physicalPixelLayout = true
        config.allowMouseInteraction = true
        let http = try #require(URL(string: "http://example.com"))
        let facts = DetailFacts.web(source: .url(http), config: config)
        #expect(facts.map(\.text) == [
            "HTTP",
            String(localized: "No JS", bundle: .appLanguage),
            String(localized: "Phys PX", bundle: .appLanguage),
            String(localized: "Clicks", bundle: .appLanguage),
        ])
        #expect(facts.map(\.isWarning) == [true, true, false, false])
        let https = try #require(URL(string: "https://example.com"))
        #expect(DetailFacts.web(source: .url(https), config: .default).map(\.text) == ["JS"])
    }

    @Test("A local page with JavaScript on has nothing to flag")
    @MainActor
    func localWebPageHasNoFacts() {
        let folder = HTMLSource.folder(bookmarkData: Data(), indexFileName: "index.html")
        #expect(DetailFacts.web(source: folder, config: .default).isEmpty)
    }

    #if !LITE_BUILD
    @Test("A scene flags its Windows plugin and names its source folder and dependency count")
    @MainActor
    func sceneFactsFlagTheWindowsPlugin() {
        let facts = DetailFacts.scene(
            origin: sceneOrigin(requiresWindowsPlugin: true),
            descriptor: sceneDescriptor(assetStorage: .sourceDirectory, dependencies: ["2", "3"])
        )
        #expect(facts.map(\.text) == [
            String(localized: "Win plugin", bundle: .appLanguage),
            String(localized: "Folder", bundle: .appLanguage),
            "\(String(localized: "Dependencies", bundle: .appLanguage)) 2",
        ])
        #expect(facts.map(\.isWarning) == [true, false, false])
    }

    @Test("A cached scene with no dependencies has nothing to flag")
    @MainActor
    func cachedSceneHasNoFacts() {
        let facts = DetailFacts.scene(
            origin: sceneOrigin(requiresWindowsPlugin: false),
            descriptor: sceneDescriptor(assetStorage: .cache, dependencies: [])
        )
        #expect(facts.isEmpty)
    }

    private func sceneOrigin(requiresWindowsPlugin: Bool) -> WPEOrigin {
        WPEOrigin(
            workshopID: "1", title: "Scene", originalType: .scene, sourceFolderBookmark: Data(),
            cacheRelativePath: nil, previewFileName: nil, requiresWindowsPlugin: requiresWindowsPlugin
        )
    }

    private func sceneDescriptor(assetStorage: SceneAssetStorage, dependencies: [String]) -> SceneDescriptor {
        SceneDescriptor(
            workshopID: "1", cacheRelativePath: "wpe-cache/1", entryFile: "scene.json",
            capabilityTier: .imageOnly, assetStorage: assetStorage, dependencyWorkshopIDs: dependencies
        )
    }
    #endif
}
