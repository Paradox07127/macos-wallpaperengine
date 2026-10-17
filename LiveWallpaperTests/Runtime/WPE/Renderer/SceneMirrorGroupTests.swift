#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import Testing

@MainActor
@Suite("Scene mirror groups", .serialized, .timeLimit(.minutes(1)))
struct SceneMirrorGroupTests {
    private static let descriptor = SceneDescriptor(workshopID: "mirror-group-\(UUID().uuidString)", cacheRelativePath: "wpe-cache/mirror-group",
                                                    entryFile: "scene.json", capabilityTier: .imageOnly)

    private static func candidate(_ id: CGDirectDisplayID, frame: CGRect, density: CGFloat = 2) -> SceneMirrorCandidate {
        SceneMirrorCandidate(screenID: id, descriptor: descriptor, fitMode: .aspectFill, mouseInteraction: true, clickCapture: false,
                             deviceRegistryID: 7, frame: frame, density: density, wantsHDR: false)
    }

    /// Same 16:9 shape at two resolutions.
    private static let left = candidate(1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private static let right = candidate(2, frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))

    private static func plan(_ candidate: SceneMirrorCandidate, with peer: SceneMirrorCandidate, enabled: Bool = true,
                             groups: [(id: UUID, lead: SceneMirrorCandidate, density: CGFloat)] = []) -> SceneMirrorPlan {
        ScreenManager.sceneMirrorPlan(for: candidate, peers: [candidate, peer], groups: groups, enabled: enabled)
    }

    @Test("Two screens showing the same scene with mirroring on share one runtime")
    func sameSceneSharesOneRuntime() {
        #expect(Self.plan(Self.left, with: Self.right) == .create(peers: [Self.right.screenID]),
                "the first screen would build a runtime of its own")
        let id = UUID()
        #expect(Self.plan(Self.right, with: Self.left, groups: [(id, Self.left, 2)]) == .join(id),
                "the second screen would build a second runtime")
    }

    @Test("Different property values, mirroring off, an HDR screen or another shape keep one runtime per screen")
    func mismatchKeepsSeparateRuntimes() {
        var overridden = Self.right
        overridden.descriptor = Self.descriptor.withPropertyOverrides(["enabled": .bool(false)])
        #expect(Self.plan(Self.left, with: overridden) == .independent, "screens with different property values would share frames")
        #expect(Self.plan(Self.left, with: Self.right, enabled: false) == .independent, "mirroring off would still share a runtime")
        var hdr = Self.right
        hdr.wantsHDR = true
        #expect(Self.plan(Self.left, with: hdr) == .independent, "an HDR screen would be forced to SDR")
        var portrait = Self.right
        portrait.frame.size = CGSize(width: 1440, height: 2560)
        #expect(Self.plan(Self.left, with: portrait) == .independent)
        var nearly = Self.right
        nearly.frame.size.width *= 1.005
        #expect(Self.plan(Self.left, with: nearly) == .create(peers: [Self.right.screenID]), "a half-percent shape gap would split the group")
    }

    @Test("A sharper joiner rebuilds the group instead of joining one rendered for a lower density")
    func sharperJoinerRebuilds() {
        let lowDensity = Self.candidate(1, frame: Self.left.frame, density: 1)
        #expect(Self.plan(Self.right, with: lowDensity, groups: [(UUID(), lowDensity, 1)]) == .create(peers: [lowDensity.screenID]))
    }

    @Test("A screen leaving for another wallpaper leaves the other screen presenting the shared runtime",
          .enabled(if: NSScreen.screens.count >= 2))
    func leavingMemberKeepsOtherPresenting() throws {
        let (owner, _) = try SceneSpanGroupTests.makeOwner()
        defer { owner.cleanup() }
        let screens = NSScreen.screens.prefix(2).map(Screen.init(nsScreen:))
        let group = SceneSpanWallpaperGroup(id: UUID(), descriptor: Self.descriptor, owner: owner, frames: WPESceneSpanFrames(),
                                            density: 1, displayFrames: [:], layout: .mirror)
        var emptied = 0
        group.onEmpty = { emptied += 1 }
        let first = try group.makeMember(for: screens[0], configuration: ScreenConfiguration(screenID: screens[0].id, wallpaper: .scene(Self.descriptor)))
        let second = try group.makeMember(for: screens[1], configuration: ScreenConfiguration(screenID: screens[1].id, wallpaper: .scene(Self.descriptor)))
        defer { second.cleanup() }
        #expect(first.presentation == .init(canvasFrame: screens[0].frame, screenFrame: screens[0].frame),
                "each screen would show only its slice of one wide canvas")
        #expect(second.presentation == .init(canvasFrame: screens[1].frame, screenFrame: screens[1].frame))

        first.cleanup()
        #expect(emptied == 0, "the remaining screen's runtime would be torn down")
        #expect(!second.stopped)
        #expect(group.canvasFrame == screens[1].frame)
    }

    @Test("The shared clock follows the fastest playing screen")
    func clockFollowsHighestRefresh() {
        let members: [(id: CGDirectDisplayID, hz: Int)] = [(1, 60), (2, 120), (3, 120)]
        #expect(SceneSpanWallpaperGroup.clockLeader(members, refreshRate: { $0.hz })?.id == 2,
                "a 60 Hz screen would pace frames shown on a 120 Hz one")
        #expect(SceneSpanWallpaperGroup.clockLeader([(id: CGDirectDisplayID, hz: Int)](), refreshRate: { $0.hz }) == nil)
    }

    @Test("A pointer at the same spot on either mirrored screen lands on the same canvas point")
    func pointerMapsToSameCanvasPoint() throws {
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 100)
        let small = CGRect(x: 300, y: 0, width: 100, height: 50)
        let geometry = WPEPointerMailbox.Geometry(viewFrameInScreen: canvas, interactiveFrames: nil, mirrorFrames: [canvas, small])
        let onCanvas = WPEPointerMailbox.pointerSample(forScreenLocation: CGPoint(x: 50, y: 75), geometry: geometry)
        #expect(onCanvas == .inside(SIMD2(0.25, 0.25)))
        #expect(WPEPointerMailbox.pointerSample(forScreenLocation: CGPoint(x: 325, y: 37.5), geometry: geometry) == onCanvas,
                "the smaller screen's pointer would land outside the scene")

        let (owner, _) = try SceneSpanGroupTests.makeOwner()
        defer { owner.cleanup() }
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let group = SceneSpanWallpaperGroup(id: UUID(), descriptor: Self.descriptor, owner: owner, frames: WPESceneSpanFrames(),
                                            density: 1, displayFrames: [screen.id &+ 1: canvas], layout: .mirror)
        let member = try group.makeMember(for: screen, configuration: ScreenConfiguration(screenID: screen.id, wallpaper: .scene(Self.descriptor)))
        defer { member.cleanup() }
        member.updateFrame(to: small)
        try #require(group.canvasFrame == canvas)
        member.setClickCaptureEnabled(true)

        member.publishDesktopButton(location: CGPoint(x: 325, y: 37.5), pressLocation: CGPoint(x: 325, y: 37.5),
                                    isDown: true, gesture: 1, dragged: false)
        member.publishDesktopButton(location: CGPoint(x: 50, y: 75), pressLocation: CGPoint(x: 325, y: 37.5),
                                    isDown: false, gesture: 1, dragged: true)
        let mailbox = owner.spanSurface.mailbox
        let edges = mailbox.takeButtonEvents(through: mailbox.read().buttonCursor).edges
        #expect(edges.map(\.frame.position) == [SIMD2(0.25, 0.25), SIMD2(0.25, 0.25)])
        #expect(edges.map(\.frame.clickPosition) == [SIMD2(0.25, 0.25), SIMD2(0.25, 0.25)])
        #expect(mailbox.sample(screenLocation: CGPoint(x: 325, y: 37.5)) == .inside(SIMD2(0.25, 0.25)),
                "hover on the smaller screen would miss the owner's canvas")
    }
}
#endif
