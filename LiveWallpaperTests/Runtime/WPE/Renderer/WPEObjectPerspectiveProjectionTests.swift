import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite("WPE authored object perspective parsing")
struct WPEObjectPerspectiveProjectionTests {
    @Test("The authored perspective flag reaches the parsed object")
    func parserCarriesTheFlag() throws {
        let json = """
        {
          "general": { "orthogonalprojection": { "width": 7680, "height": 4320 },
                       "perspectiveoverridefov": 21 },
          "camera": { "eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0" },
          "objects": [
            { "id": 112, "name": "Earth", "model": "models/Earth/Earth.mdl", "visible": true,
              "perspective": true, "origin": "3840 -4226.7 -3000", "scale": "65 65 65",
              "angles": "0 0 1.5708" },
            { "id": 191, "name": "The Void", "image": "models/util/solidlayer.json",
              "visible": true, "origin": "3840 2160 0" }
          ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let earth = try #require(document.imageObjects.first { $0.id == "112" })
        let void = try #require(document.imageObjects.first { $0.id == "191" })
        #expect(earth.usesPerspectiveProjection)
        #expect(void.usesPerspectiveProjection == false)
        #expect(document.general.perspectiveOverrideFOV.resolvedValue == 21)
        #expect(document.general.usesPerspectiveProjection == false)
    }
}
