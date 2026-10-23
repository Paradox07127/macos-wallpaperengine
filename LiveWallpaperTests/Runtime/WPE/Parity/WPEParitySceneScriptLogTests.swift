#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import Testing

struct WPEParitySceneScriptLogTests {
    @Test func repeatedScriptWarningIsWrittenOnlyOnce() {
        let message = "script error \(UUID().uuidString)"
        #expect(WPEParitySceneScript.forwardScriptLog(level: 1, message: message))
        #expect(!WPEParitySceneScript.forwardScriptLog(level: 1, message: message), "second identical warning was written")
        #expect(!WPEParitySceneScript.forwardScriptLog(level: 2, message: message), "third identical warning was written")
        #expect(!WPEParitySceneScript.forwardScriptLog(level: 0, message: "script info \(UUID().uuidString)"))
    }
}
#endif
