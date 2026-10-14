import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class WPETexConditionalSelectionTests: XCTestCase {
    func testOriginalGroupSelectionAndSharedObservationsHaveDifferentOrdering() throws {
        func entry(_ group: UInt32, _ id: UInt32, _ flags: UInt32, _ condition: String) -> WPETexConditionalVariant {
            WPETexConditionalVariant(groupKey: group, variantID: id, flags: flags, conditionBytes: Data(condition.utf8))
        }
        let variants = [
            entry(7, 9000, 0, #"{"condition":"enabled"}"#),
            entry(7, 12345, 2, #"{"condition":{"name":"mode","condition":"ON"}}"#),
            entry(9, 9000, 1, #"{"condition":"enabled"}"#),
            entry(10, 5, 0, #"{"condition":{"name":"mode","condition":"OFF"}}"#),
            entry(11, 6, 0, #"{"condition":{"name":"absent","condition":"OFF"}}"#),
        ]
        let properties: WPESceneJSONValue = .object([
            "enabled": .object(["value": .bool(true)]), "mode": .object(["value": .string("ON")]),
        ])
        let selected = try WPETexConditionalSelection(variants: variants, properties: properties)
        XCTAssertEqual(selected.flagsByVariantID, [9000: 1])
        XCTAssertEqual(selected.observations, [Data("enabled".utf8): Data("1".utf8),
                                               Data("mode".utf8): Data("ON".utf8),
                                               Data("absent".utf8): Data("$__default".utf8)])
        XCTAssertFalse(selected.requiresReload(changedProperties: properties))
        XCTAssertTrue(selected.requiresReload(changedProperties: .object(["mode": .object(["value": .string("OFF")])])))
        XCTAssertFalse(selected.requiresReload(changedProperties: .object(["enabled": .object(["value": .number(0)])])))
        XCTAssertFalse(selected.requiresReload(changedProperties: .object(["unrelated": .object(["value": .bool(false)])])))
    }

    func testPredicateUsesExactTypesAndBytesAndCStringsOnlyForInputs() throws {
        let variant = WPETexConditionalVariant(groupKey: 0, variantID: .max, flags: 0,
                                               conditionBytes: Data(#"{"condition":{"name":"模式\u0000suffix","condition":"é"}}"#.utf8))
        func select(_ value: WPESceneJSONValue) throws -> WPETexConditionalSelection {
            try WPETexConditionalSelection(variants: [variant], properties: .object(["模式": .object(["value": value])]))
        }
        XCTAssertEqual(try select(.string("é")).flagsByVariantID, [UInt32.max: 0])
        XCTAssertTrue(try select(.string("e\u{301}")).flagsByVariantID.isEmpty)
        XCTAssertTrue(try select(.string("é\0suffix")).flagsByVariantID.isEmpty)
        XCTAssertTrue(try select(.bool(true)).flagsByVariantID.isEmpty)
        XCTAssertTrue(try select(.number(1)).flagsByVariantID.isEmpty)
        XCTAssertThrowsError(try WPETexConditionalSelection(variants: [variant], properties: .object(["模式": .object([:])]))) {
            XCTAssertEqual($0 as? WPETexConditionalSelection.Failure, .propertyWithoutValue("模式"))
        }
    }
}
