#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import Testing

@MainActor
@Suite("Scene span group membership", .serialized, .timeLimit(.minutes(1)))
struct SceneSpanGroupTests {
    static func makeOwner() throws -> (SceneWallpaperSession, WPEDisplayRenderActor) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let actor = WPEDisplayRenderActor(backing: .renderThread)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return (SceneWallpaperSession(window: window, renderActor: actor, surface: surface), actor)
    }

    private static let descriptor = SceneDescriptor(workshopID: "span-group-\(UUID().uuidString)", cacheRelativePath: "wpe-cache/span-group",
                                                    entryFile: "scene.json", capabilityTier: .imageOnly)

    private static func configuration(for screen: Screen) -> ScreenConfiguration {
        ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
    }

    @Test("A joining display re-lays out the members that were already presenting", .enabled(if: NSScreen.screens.count >= 2))
    func joinUpdatesSurvivorLayout() throws {
        let (owner, _) = try Self.makeOwner()
        defer { owner.cleanup() }
        let screens = NSScreen.screens.prefix(2).map(Screen.init(nsScreen:))
        let group = SceneSpanWallpaperGroup(id: UUID(), descriptor: Self.descriptor, owner: owner, frames: WPESceneSpanFrames(),
                                            density: 1, displayFrames: [screens[0].id: screens[0].frame])
        let survivor = try group.makeMember(for: screens[0], configuration: Self.configuration(for: screens[0]))
        defer { survivor.cleanup() }
        let joined = try group.makeMember(for: screens[1], configuration: Self.configuration(for: screens[1]))
        defer { joined.cleanup() }

        let canvas = screens[0].frame.union(screens[1].frame)
        #expect(joined.presentation.canvasFrame == canvas)
        #expect(survivor.presentation.canvasFrame == canvas, "The survivor would keep slicing the one-display canvas")
    }

    @Test("A discarded candidate hands the display back to the member it was going to replace")
    func discardedCandidateRestoresInstalledMember() throws {
        let (owner, _) = try Self.makeOwner()
        defer { owner.cleanup() }
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let group = SceneSpanWallpaperGroup(id: UUID(), descriptor: Self.descriptor, owner: owner, frames: WPESceneSpanFrames(),
                                            density: 1, displayFrames: [screen.id: screen.frame])
        var emptied = 0
        group.onEmpty = { emptied += 1 }
        let installed = try group.makeMember(for: screen, configuration: Self.configuration(for: screen))
        let candidate = try group.makeMember(for: screen, configuration: Self.configuration(for: screen))

        candidate.cleanup()
        #expect(emptied == 0, "Discarding the candidate would tear down the runtime the installed member still shows")
        #expect(group.canvasFrame == screen.frame)

        installed.cleanup()
        #expect(emptied == 1)
    }

    @Test("A committed candidate does not resurrect the member it replaced")
    func committedCandidateDoesNotRestoreRetiredMember() throws {
        let (owner, _) = try Self.makeOwner()
        defer { owner.cleanup() }
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let group = SceneSpanWallpaperGroup(id: UUID(), descriptor: Self.descriptor, owner: owner, frames: WPESceneSpanFrames(),
                                            density: 1, displayFrames: [screen.id: screen.frame])
        var emptied = 0
        group.onEmpty = { emptied += 1 }
        let retired = try group.makeMember(for: screen, configuration: Self.configuration(for: screen))
        let committed = try group.makeMember(for: screen, configuration: Self.configuration(for: screen))

        retired.cleanup()
        #expect(emptied == 0)
        committed.cleanup()
        #expect(emptied == 1)
    }

    @Test("A desktop press on a member display reaches the owner's mailbox in canvas UV; Interaction on refuses it")
    func desktopPressMapsToCanvasUV() throws {
        let (owner, _) = try Self.makeOwner()
        defer { owner.cleanup() }
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        // A stand-in left display: canvas (0,0,200,200), member display (100,0,100,100).
        let group = SceneSpanWallpaperGroup(id: UUID(), descriptor: Self.descriptor, owner: owner, frames: WPESceneSpanFrames(),
                                            density: 1, displayFrames: [screen.id &+ 1: CGRect(x: 0, y: 0, width: 100, height: 200)])
        let member = try group.makeMember(for: screen, configuration: Self.configuration(for: screen))
        defer { member.cleanup() }
        member.updateFrame(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        try #require(group.canvasFrame == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(member.acceptsDesktopClicks)

        member.publishDesktopButton(location: CGPoint(x: 150, y: 75), pressLocation: CGPoint(x: 125, y: 50),
                                    isDown: true, gesture: 9, dragged: false)
        let mailbox = owner.spanSurface.mailbox
        let edges = mailbox.takeButtonEvents(through: mailbox.read().buttonCursor).edges
        #expect(edges.map(\.frame.position) == [SIMD2(0.75, 0.625)])
        #expect(edges.map(\.frame.clickPosition) == [SIMD2(0.625, 0.75)])
        #expect(edges.map(\.frame.gesture) == [9])
        #expect(edges.map(\.fromDesktop) == [true])
        #expect(edges.map(\.isInsideView) == [true])

        member.setClickCaptureEnabled(true)
        #expect(!member.acceptsDesktopClicks)
    }

    @Test("A member joining a failed shared runtime reloads it instead of inheriting the old error")
    func joiningFailedRuntimeRetriesLoad() async throws {
        let (owner, actor) = try Self.makeOwner()
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup(); owner.cleanup() }
        let surface = owner.spanSurface
        let device = try #require(surface.metalLayer.device)
        owner.wallpaperWindow?.contentView = surface.mtkView
        surface.attach(client: WPERenderSurfaceClientShim(renderActor: actor, backing: .renderThread))
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            surfaceControl: surface, mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            drawableSize: surface.metalLayer.drawableSize, device: device
        )
        let frames = WPESceneSpanFrames()
        renderer.spanFrames = frames
        let scene = fixture.root.appendingPathComponent("scene.json")
        let parked = fixture.root.appendingPathComponent("scene.parked")
        try FileManager.default.moveItem(at: scene, to: parked)
        owner.startAdoptingRenderer(WPERendererHandoff(renderer: renderer))
        for _ in 0 ..< 500 where owner.loadError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(owner.loadError != nil)
        try FileManager.default.moveItem(at: parked, to: scene)

        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let group = SceneSpanWallpaperGroup(id: UUID(), descriptor: fixture.descriptor, owner: owner,
                                            frames: frames, density: 1, displayFrames: [screen.id: screen.frame])
        let member = try group.makeMember(for: screen, configuration: ScreenConfiguration(screenID: screen.id, wallpaper: .scene(fixture.descriptor)))
        defer { member.cleanup() }
        let rendering = Task {
            while !Task.isCancelled {
                await actor.renderFrame()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { rendering.cancel() }

        let result = await member.prepareForDisplay(timeout: .seconds(5))
        #expect(result == .ready)
        #expect(owner.loadError == nil)
    }
}
#endif
