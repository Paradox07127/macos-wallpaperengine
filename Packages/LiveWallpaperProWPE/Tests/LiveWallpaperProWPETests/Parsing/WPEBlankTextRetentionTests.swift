import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing

@Suite("Declared blank text object retention")
struct WPEBlankTextRetentionTests {
    private struct NoScriptResolver: WPESceneTransformScriptResolving {
        func resolveVec3(
            script _: String,
            properties _: [String: WPESceneScriptPropertyValue],
            seed _: SIMD3<Double>
        ) -> SIMD3<Double>? {
            nil
        }
    }

    @Test("Declared blank strings retain identity without a text script", arguments: ["plain", "value", "text"])
    func declaredBlankTextRetainsIdentity(shape: String) throws {
        var object: [String: Any] = ["id": "blank", "name": "Blank label", "origin": "12 24 0"]
        if shape == "plain" {
            object["text"] = ""
        } else {
            object["text"] = [shape: ""]
        }
        let document = try parse([object])
        let text = try #require(document.textObjects.first)
        #expect(document.textObjects.count == 1)
        #expect(text.id == "blank")
        #expect(text.name == "Blank label")
        #expect(text.text == "")
        #expect(text.textScript == nil)
        #expect(text.origin == SIMD3<Double>(12, 24, 0))
        #expect(document.transformHostObjects.allSatisfy { $0.id != text.id })
        #expect(!document.diagnostics.contains { $0.severity == .warning })
    }

    @Test("Missing or malformed text is not replaced with a fabricated blank string",
          arguments: ["missing", "null", "number", "empty-envelope", "null-value", "number-value"])
    func missingOrMalformedTextIsNotFabricated(shape: String) throws {
        var object: [String: Any] = ["id": "invalid", "type": "text",
                                     "scale": ["value": "1 1 1", "script": "export function update(v) { return v; }"]]
        switch shape {
        case "missing": break
        case "null": object["text"] = NSNull()
        case "number": object["text"] = 42
        case "empty-envelope": object["text"] = [String: Any]()
        case "null-value": object["text"] = ["value": NSNull()]
        default: object["text"] = ["value": 42]
        }
        let document = try parse([object, ["id": "valid", "text": "Sibling"]])
        #expect(document.textObjects.map(\.id) == ["valid"])
        #expect(document.textObjects.first?.text == "Sibling")
    }

    private func parse(_ objects: [[String: Any]]) throws -> WPESceneDocument {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160]],
            "objects": objects,
        ]
        return try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: payload),
            userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
    }
}
