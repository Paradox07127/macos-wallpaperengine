import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Video span container layout")
struct VideoSpanContainerLayoutTests {
    private static let screenSize = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private static func layOut(_ configuration: VideoSpanRenderConfiguration?) throws -> (VideoContainerView, PlayerHostView) {
        let container = VideoContainerView(frame: screenSize)
        container.setSpanRenderConfiguration(configuration)
        container.layoutSubtreeIfNeeded()
        let host = try #require(container.subviews.compactMap { $0 as? PlayerHostView }.first)
        return (container, host)
    }

    @Test("Right screen of a span keeps the canvas offset on the player layer")
    func rightScreenKeepsCanvasOffset() throws {
        let (_, host) = try Self.layOut(VideoSpanRenderConfiguration(
            canvasFrame: CGRect(x: -1920, y: 0, width: 3840, height: 1080),
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        ))

        #expect(host.frame == CGRect(x: -1920, y: 0, width: 3840, height: 1080))
        #expect(
            host.playerLayer?.frame == host.frame,
            "Player layer snapped back to the origin, so the right screen shows the canvas' left half"
        )
    }

    @Test("Left screen of a span shows the canvas from its origin")
    func leftScreenStartsAtCanvasOrigin() throws {
        let (_, host) = try Self.layOut(VideoSpanRenderConfiguration(
            canvasFrame: CGRect(x: -1920, y: 0, width: 3840, height: 1080),
            screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        ))

        #expect(host.frame == CGRect(x: 0, y: 0, width: 3840, height: 1080))
        #expect(host.playerLayer?.frame == host.frame)
    }

    @Test("Without a span the player fills the container bounds")
    func nonSpanFillsBounds() throws {
        let (container, host) = try Self.layOut(nil)

        #expect(host.frame == container.bounds)
        #expect(host.playerLayer?.frame == container.bounds)
    }
}
