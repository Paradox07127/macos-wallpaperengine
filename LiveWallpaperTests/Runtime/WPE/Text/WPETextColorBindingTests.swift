#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import simd
import Testing

/// Scene 3554161528's clock authors its colour as a user-property wrapper. The white
/// `?? SIMD3(1,1,1)` fallback in the parser is exactly what a failed unwrap looks like
/// on screen, so pin the unwrap.
@Suite("WPE text colour binding")
struct WPETextColorBindingTests {
    private func document(colorField: String) throws -> WPESceneDocument {
        let json = """
        {
          "camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
          "general": {"orthogonalprojection": {"width": 3840, "height": 2160}},
          "objects": [
            {
              "id": 398,
              "text": {"value": "00:13"},
              "font": "fonts/Monofur-PK7og.ttf",
              "origin": "1195.38 1337.07 0",
              "scale": "1 1 1",
              "angles": "0 0 0",
              "size": "410 167",
              "pointsize": 20,
              "horizontalalign": "center",
              "verticalalign": "center",
              "color": \(colorField)
            }
          ]
        }
        """
        return try WPESceneDocumentParser.parse(data: Data(json.utf8))
    }

    @Test("a plain colour string parses")
    func plainColor() throws {
        let doc = try document(colorField: "\"0.52941 0.46275 0.83137\"")
        let text = try #require(doc.textObjects.first)
        #expect(abs(text.color.x - 0.52941) < 0.001)
        #expect(abs(text.color.y - 0.46275) < 0.001)
        #expect(abs(text.color.z - 0.83137) < 0.001)
    }

    /// The shape scene 3554161528 actually ships.
    @Test("a {user,value} wrapper resolves to the authored colour, not the white fallback")
    func userWrappedColor() throws {
        let doc = try document(colorField: "{\"user\": \"newproperty24\", \"value\": \"0.52941 0.46275 0.83137\"}")
        let text = try #require(doc.textObjects.first)
        #expect(abs(text.color.x - 0.52941) < 0.001, "unwrap fell back to white")
        #expect(abs(text.color.y - 0.46275) < 0.001)
        #expect(abs(text.color.z - 0.83137) < 0.001)
    }
}
#endif
