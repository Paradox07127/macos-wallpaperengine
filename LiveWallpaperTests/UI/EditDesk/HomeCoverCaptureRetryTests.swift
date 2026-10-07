import CoreGraphics
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Home cover capture retry")
struct HomeCoverCaptureRetryTests {
    private static func pixel() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private static let delays: [Duration] = Array(repeating: .milliseconds(400), count: 4)

    @Test("A session with no frame yet is captured again until it has one")
    func retriesUntilAFrameLands() async throws {
        let frame = try Self.pixel()
        var calls = 0
        let image = await HomePage.captureCover(
            retryDelays: Self.delays,
            isNewest: { true },
            sleep: { _ in },
            capture: {
                calls += 1
                return calls < 3 ? nil : frame
            }
        )
        #expect(image === frame, "a capture that is nil during a transition hold leaves the card on the previous wallpaper")
        #expect(calls == 3)
    }

    @Test("A newer capture asked for stops the retries")
    func aNewerRequestStopsRetrying() async {
        var calls = 0
        var newest = true
        let image = await HomePage.captureCover(
            retryDelays: Self.delays,
            isNewest: { newest },
            sleep: { _ in },
            capture: {
                calls += 1
                newest = false
                return nil
            }
        )
        #expect(image == nil)
        #expect(calls == 1, "a superseded request keeps capturing frames nobody shows")
    }

    @Test("Retries end once the delays run out")
    func retriesEndWithTheDelays() async {
        var calls = 0
        let image = await HomePage.captureCover(
            retryDelays: Self.delays,
            isNewest: { true },
            sleep: { _ in },
            capture: {
                calls += 1
                return nil
            }
        )
        #expect(image == nil)
        #expect(calls == 1 + Self.delays.count)
    }
}
