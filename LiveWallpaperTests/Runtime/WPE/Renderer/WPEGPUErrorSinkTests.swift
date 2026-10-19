#if !LITE_BUILD
@testable import LiveWallpaper
import Testing

struct WPEGPUErrorSinkTests {
    @Test("Concurrent GPU failures keep the exact count and the latest diagnostic")
    func concurrentFailuresKeepTheSummary() async {
        let sink = WPEGPUErrorSink()
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 1000 {
                group.addTask { sink.record("GPU failure \(index)") }
            }
        }
        #expect(sink.summary.count == 1000)
        sink.record("last completion failed")
        #expect(sink.summary.count == 1001)
        #expect(sink.summary.last == "last completion failed")
    }
}
#endif
