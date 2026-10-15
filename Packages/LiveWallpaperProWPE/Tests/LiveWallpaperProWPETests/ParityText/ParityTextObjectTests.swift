import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

/// WPE's text object field table (FUN_140258ca0), its parsers and the rebuild check of FUN_140256f20.
final class ParityTextObjectTests: XCTestCase {
    private struct NoScripts: WPESceneTransformScriptResolving {
        func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                         seed _: SIMD3<Double>) -> SIMD3<Double>? {
            nil
        }
    }

    private func object(_ fields: [String: Any]) throws -> WPEParityTextObject {
        try WPEParityTextObject(json: XCTUnwrap(WPESceneJSONValue(jsonValue: fields)))
    }

    private func document(objects: [[String: Any]],
                          userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws -> WPESceneDocument {
        let json: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": objects,
        ]
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: userValues,
                                                makeTransformScriptResolver: { _, _ in NoScripts() })
    }

    func testDefaultsOfAnObjectWithOnlyText() throws {
        let text = try object(["text": "Hi"])
        XCTAssertEqual(text.text, "Hi")
        XCTAssertEqual(text.font, "systemfont_arial")
        XCTAssertEqual(text.pointSize, 32)
        XCTAssertEqual(text.padding, SIMD2(32, 32))
        XCTAssertEqual(text.spacing, .zero)
        XCTAssertEqual(text.maxWidth, 500)
        XCTAssertEqual(text.maxRows, 1)
        XCTAssertFalse(text.opaqueBackground || text.limitWidth || text.limitRows || text.limitUseEllipsis
            || text.blockAlign)
        XCTAssertEqual(text.backgroundColor, .zero)
        XCTAssertEqual(text.backgroundBrightness, 1)
        XCTAssertFalse(text.msdf || text.outline || text.blur || text.dropShadow)
        XCTAssertEqual(text.outlineThickness, 4)
        XCTAssertEqual(text.outlineColor, .zero)
        XCTAssertEqual(text.blurSize, 6)
        XCTAssertEqual(text.dropShadowSize, 6)
        XCTAssertEqual(text.dropShadowOpacity, 1)
        XCTAssertEqual(text.dropShadowColor, .zero)
        XCTAssertEqual(text.dropShadowOffset, SIMD2(4, 4))
        XCTAssertEqual(text.depthTest, .enabled)
        XCTAssertEqual(text.horizontalAlign, .center)
        XCTAssertEqual(text.verticalAlign, .center)
        XCTAssertEqual(text.anchor, .none)
        XCTAssertEqual(text.color, SIMD3(1, 1, 1))
        XCTAssertEqual(text.alpha, 1)
        XCTAssertEqual(text.brightness, 1)
        XCTAssertEqual(text.colorBlendMode, 0)
        XCTAssertTrue(text.visible)
    }

    func testPaddingNumberAndStringForms() throws {
        XCTAssertEqual(try object(["text": "a", "padding": 32]).padding, SIMD2(32, 32))
        XCTAssertEqual(try object(["text": "a", "padding": "32 32"]).padding, SIMD2(32, 32))
        XCTAssertEqual(try object(["text": "a", "padding": "12"]).padding, SIMD2(12, 0))
        XCTAssertEqual(try object(["text": "a", "padding": "12 7"]).padding, SIMD2(12, 7))
        XCTAssertEqual(try object(["text": "a", "padding": 7.5]).padding, SIMD2(7.5, 7.5))
    }

    func testVectorStringsStopAtFirstNULBeforeLayoutAndDrawParameters() throws {
        let scene = try document(objects: [
            ["id": 1, "text": "H", "pointsize": 8, "outline": true, "dropshadow": true,
             "padding": "12\u{0} 7", "spacing": "2 \u{0} 9",
             "outlinecolor": ["value": "1\u{0} 0.5 0.25"],
             "dropshadowcolor": "\u{0} 9 8", "dropshadowoffset": "5\u{0} -4"],
            ["id": 2, "text": "H", "padding": " 2 3 4", "color": "2\t3 4"],
            ["id": 3, "text": "H", "padding": 7.5, "color": 0.5],
            ["id": 4, "text": "H", "padding": false, "color": true],
        ])
        let texts = WPEParityTextObject.textObjects(in: scene)
        guard texts.count == 4 else { return XCTFail("Missing text objects from the parsed scene") }
        let text = try XCTUnwrap(texts.first)
        let layout = text.layoutInput(effectCount: 1)
        XCTAssertTrue(layout.appliesPadding)
        XCTAssertEqual(layout.padding, SIMD2(12, 0))
        XCTAssertEqual(layout.spacing, SIMD2(2, 0))
        let draw = try XCTUnwrap(WPEParityTextDrawParameters(object: text, pointSize: text.pointSize))
        XCTAssertEqual(SIMD3(draw.renderVar1.x, draw.renderVar1.y, draw.renderVar1.z), SIMD3(1, 0, 0))
        XCTAssertEqual(SIMD3(draw.renderVar2.x, draw.renderVar2.y, draw.renderVar2.z), .zero)
        XCTAssertGreaterThan(draw.renderVar1.w, 0)
        XCTAssertEqual(draw.renderVar2.w.bitPattern, Float(0).bitPattern)
        // Preserve the original literal-space scan, numeric broadcast and wrong-type field defaults.
        XCTAssertEqual(texts[1].padding, SIMD2(2, 2))
        XCTAssertEqual(texts[1].color, SIMD3(2, 4, 0))
        XCTAssertEqual(texts[2].padding, SIMD2(7.5, 7.5))
        XCTAssertEqual(texts[2].color, SIMD3(repeating: 0.5))
        XCTAssertEqual(texts[3].padding, SIMD2(32, 32))
        XCTAssertEqual(texts[3].color, SIMD3(repeating: 1))
    }

    func testUnknownOrObjectEnumValuesTakeTheTablesFirstEntry() throws {
        let unknown = try object([
            "text": "a", "horizontalalign": "middle", "verticalalign": "middle",
            "anchor": "somewhere", "depthtest": "on",
        ])
        XCTAssertEqual(unknown.horizontalAlign, .left)
        XCTAssertEqual(unknown.verticalAlign, .center)
        XCTAssertEqual(unknown.anchor, .none)
        XCTAssertEqual(unknown.depthTest, .disabled)

        let bound = try object([
            "text": "a", "horizontalalign": ["value": "right"], "verticalalign": ["value": "top"],
            "anchor": ["value": "topleft"], "depthtest": ["value": "enabled"],
        ])
        XCTAssertEqual(bound.horizontalAlign, .left)
        XCTAssertEqual(bound.verticalAlign, .center)
        XCTAssertEqual(bound.anchor, .none)
        XCTAssertEqual(bound.depthTest, .disabled)

        let known = try object([
            "text": "a", "horizontalalign": "right", "verticalalign": "bottom", "anchor": "topright",
            "depthtest": "disabled",
        ])
        XCTAssertEqual(known.horizontalAlign, .right)
        XCTAssertEqual(known.verticalAlign, .bottom)
        XCTAssertEqual(known.anchor, .topRight)
        XCTAssertEqual(known.depthTest, .disabled)
    }

    func testRowAndWidthLimitsInTheLayoutInput() throws {
        let unlimitedRows = try object(["text": "a", "limitrows": true, "maxrows": 0]).layoutInput(effectCount: 0)
        XCTAssertFalse(unlimitedRows.limitRows)

        let twoRows = try object(["text": "a", "limitrows": true, "maxrows": 2.9]).layoutInput(effectCount: 0)
        XCTAssertTrue(twoRows.limitRows)
        XCTAssertEqual(twoRows.maxRows, 2)

        XCTAssertEqual(try object(["text": "a", "maxwidth": 300]).layoutInput(effectCount: 0).maxWidth, 0)
        XCTAssertEqual(try object(["text": "a", "maxwidth": 300, "limitwidth": true]).layoutInput(effectCount: 0).maxWidth,
                       300)
    }

    func testPaddingAppliesWithEffectsPassthroughBlendOrOpaqueBackground() throws {
        let plain = try object(["text": "a"])
        XCTAssertFalse(plain.layoutInput(effectCount: 0).appliesPadding)
        XCTAssertTrue(plain.layoutInput(effectCount: 1).appliesPadding)
        XCTAssertFalse(try object(["text": "a", "colorBlendMode": 31]).layoutInput(effectCount: 0).appliesPadding)
        XCTAssertTrue(try object(["text": "a", "colorBlendMode": 11]).layoutInput(effectCount: 0).appliesPadding)
        XCTAssertTrue(try object(["text": "a", "opaquebackground": true]).layoutInput(effectCount: 0).appliesPadding)
    }

    func testPointSizeIsNotClampedAtParse() throws {
        let text = try object(["text": "a", "pointsize": 300])
        XCTAssertEqual(text.pointSize, 300)
        XCTAssertEqual(text.layoutInput(effectCount: 0).pointSize, 300)
    }

    func testFontSizeAndLetterSpacingAreNotRead() throws {
        let text = try object(["text": "a", "fontsize": 64, "letterspacing": 5])
        XCTAssertEqual(text.pointSize, 32)
        XCTAssertEqual(text.spacing, .zero)
    }

    func testTextShapesYieldTheirValue() throws {
        XCTAssertEqual(try object(["text": "plain"]).text, "plain")
        XCTAssertEqual(try object(["text": ["value": "boxed"]]).text, "boxed")
        XCTAssertEqual(try object(["text": ["user": "t", "value": "user"]]).text, "user")
        XCTAssertEqual(try object(["text": ["script": "export function update() {}", "scriptproperties": [:],
                                            "value": "scripted"]]).text, "scripted")
    }

    func testUserResolvedTextReachesTheObject() throws {
        let document = try document(objects: [
            ["id": 7, "name": "clock", "text": ["user": "label", "value": "authored"], "origin": "0 0 0"],
            ["id": 8, "name": "picture", "image": "models/a.json", "text": "not text"],
        ], userValues: ["label": .string("from user")])
        let texts = WPEParityTextObject.textObjects(in: document)
        XCTAssertEqual(texts.map(\.text), ["from user"])
        XCTAssertEqual(texts.map(\.id), ["7"])
        XCTAssertEqual(document.resolvedObjectsJSON.count, 2)
    }

    func testRebuildOnlyForLayoutFields() throws {
        let base = try object(["text": "a"])
        var recolored = base
        recolored.color = SIMD3(1, 0, 0)
        XCTAssertFalse(recolored.needsRebuild(from: base))

        var retexted = base
        retexted.text = "b"
        XCTAssertTrue(retexted.needsRebuild(from: base))
        XCTAssertFalse(retexted.needsRebuild(from: retexted))

        var outlined = base
        outlined.outline = true
        XCTAssertTrue(outlined.needsRebuild(from: base))

        var thicker = outlined
        thicker.outlineThickness = 9
        XCTAssertFalse(thicker.needsRebuild(from: outlined))

        var shadowed = outlined
        shadowed.dropShadow = true
        XCTAssertFalse(shadowed.needsRebuild(from: outlined))

        var anchored = base
        anchored.anchor = .center
        anchored.backgroundColor = SIMD3(1, 1, 1)
        anchored.alpha = 0.5
        XCTAssertFalse(anchored.needsRebuild(from: base))

        var padded = base
        padded.padding = SIMD2(4, 4)
        XCTAssertTrue(padded.needsRebuild(from: base))

        var depth = base
        depth.depthTest = .disabled
        XCTAssertTrue(depth.needsRebuild(from: base))
    }

    func testOldRendererTextObjectKeepsItsOwnDefaults() throws {
        let document = try document(objects: [["id": 1, "name": "label", "text": "Hi", "fontsize": 48]])
        let old = try XCTUnwrap(document.textObjects.first)
        XCTAssertEqual(old.padding, 0)
        XCTAssertEqual(old.verticalAlignment, "middle")
        XCTAssertEqual(old.pointSize, 48)
        XCTAssertNil(old.maxRows)

        let parity = try XCTUnwrap(WPEParityTextObject.textObjects(in: document).first)
        XCTAssertEqual(parity.padding, SIMD2(32, 32))
        XCTAssertEqual(parity.verticalAlign, .center)
        XCTAssertEqual(parity.pointSize, 32)
    }
}
