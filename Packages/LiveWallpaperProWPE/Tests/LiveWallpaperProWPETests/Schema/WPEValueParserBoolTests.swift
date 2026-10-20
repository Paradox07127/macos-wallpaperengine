import Foundation
import Testing
@testable import LiveWallpaperProWPE

@Suite("WPEValueParser boolean handling")
struct WPEValueParserBoolTests {

    private func jsonValue(_ literal: String) throws -> Any {
        let object = try #require(JSONSerialization.jsonObject(with: Data("{\"v\": \(literal)}".utf8)) as? [String: Any])
        return try #require(object["v"])
    }

    /// Keep JSONSerialization's `__NSCFBoolean` distinct from numeric NSNumber inputs.
    @Test("Booleans require explicit numeric admission", arguments: [(false, 0), (true, 1)])
    func booleanAdmission(value: Bool, expected: Int) throws {
        for input in try [jsonValue(String(value)), value] {
            #expect(WPEValueParser.double(input) == nil)
            #expect(WPEValueParser.int(input) == nil)
            #expect(WPEValueParser.double(input, boolAsNumber: true) == Double(expected))
            #expect(WPEValueParser.int(input, boolAsNumber: true) == expected)
        }
    }

    @Test("double: genuine numbers and numeric strings still parse under both flags")
    func doublePreservesNumbers() throws {
        #expect(WPEValueParser.double(2.5) == 2.5)
        #expect(WPEValueParser.double(0) == 0)
        #expect(WPEValueParser.double(1) == 1)
        #expect(WPEValueParser.double(0, boolAsNumber: true) == 0)
        #expect(WPEValueParser.double(1, boolAsNumber: true) == 1)
        #expect(WPEValueParser.double("3.5") == 3.5)
        // Numbers decoded from JSON (NSNumber-backed) are unaffected by the bool guard.
        #expect(try WPEValueParser.double(jsonValue("0")) == 0)
        #expect(try WPEValueParser.double(jsonValue("42")) == 42)
    }

    @Test("int: genuine numbers are preserved")
    func intPreservesNumbers() throws {
        #expect(WPEValueParser.int(0) == 0)
        #expect(WPEValueParser.int(7) == 7)
        #expect(try WPEValueParser.int(jsonValue("0")) == 0)
    }
}
