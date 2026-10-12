import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import Testing

@Suite("WPESceneDocumentParser sound random-mode delays")
struct WPESceneSoundDelayParsingTests {
    private struct NoScriptResolver: WPESceneTransformScriptResolving {
        func resolveVec3(
            script _: String,
            properties _: [String: WPESceneScriptPropertyValue],
            seed _: SIMD3<Double>
        ) -> SIMD3<Double>? {
            nil
        }
    }

    private static let json = #"""
    {
        "camera": {"center":"0 0 0"},
        "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
        "objects": [
            {"id": 7, "name": "Plain", "type": "sound", "sound": ["a.wav"], "playbackmode": "random",
             "mintime": 3, "maxtime": 7},
            {"id": 8, "name": "Bound", "type": "sound", "sound": ["b.wav"], "playbackmode": "random",
             "mintime": {"user": "delay", "value": 1}, "maxtime": 2.5},
            {"id": 9, "name": "Unset", "type": "sound", "sound": ["c.wav"]}
        ]
    }
    """#

    private func parse(userValues: [String: WallpaperEngineProjectPropertyValue]) throws -> [String: WPESceneSoundObject] {
        let document = try WPESceneDocumentParser.parse(
            data: Data(Self.json.utf8),
            userValues: userValues,
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
        return Dictionary(document.soundObjects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    @Test("mintime and maxtime come from the user-resolved object")
    func userValueWins() throws {
        let sounds = try parse(userValues: ["delay": .number(4)])
        #expect(sounds["8"]?.minTime == 4)
        #expect(sounds["8"]?.maxTime == 2.5)
    }

    @Test("Without a user value the authored default and plain numbers are used; unset is 0")
    func authoredDefaults() throws {
        let sounds = try parse(userValues: [:])
        #expect(sounds["7"]?.minTime == 3)
        #expect(sounds["7"]?.maxTime == 7)
        #expect(sounds["8"]?.minTime == 1)
        #expect(sounds["9"]?.minTime == 0)
        #expect(sounds["9"]?.maxTime == 0)
    }
}
