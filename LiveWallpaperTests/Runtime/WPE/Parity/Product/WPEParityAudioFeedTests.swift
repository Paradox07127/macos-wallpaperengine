#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

struct WPEParityAudioFeedTests {
    private let sine = (0 ..< 2048).map { Float(0.5 * sin(2 * Double.pi * 100 * Double($0) / 2089)) }

    private func capturingBroker() -> AudioSpectrumBroker {
        let processor = AudioSpectrumProcessor(configuration: .init(sampleRate: 48000))
        processor.ingest(left: sine, right: sine, timestampNanos: 1)
        let broker = AudioSpectrumBroker()
        broker.attachAnalyzer(processor)
        return broker
    }

    @Test("A capturing feed publishes the WPE provider's raw bins over the newest samples")
    func capturingFeedPublishesProviderBins() throws {
        var feed = WPEParityAudioFeed()
        let published = feed.frame(broker: capturingBroker(), isCapturing: true)
        let frame = try #require(published)

        let peak = frame.left.indices.max { frame.left[$0] < frame.left[$1] }
        #expect(peak == 40)
        let newest = Array(sine.suffix(1392))
        let expected = WPEParityAudioProvider(sampleRate: 48000).bins(left: newest, right: newest)
        #expect(abs(frame.left[40] - expected[40]) <= 1e-4)
    }

    @Test("No capture publishes no audio")
    func idleFeedIsNil() {
        var feed = WPEParityAudioFeed()
        let published = feed.frame(broker: capturingBroker(), isCapturing: false)
        #expect(published == nil)
    }
}
#endif
