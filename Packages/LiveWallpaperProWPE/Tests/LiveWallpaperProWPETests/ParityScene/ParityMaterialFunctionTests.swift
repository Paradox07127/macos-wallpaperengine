import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityMaterialFunctionTests: XCTestCase {
    private typealias Fixtures = ParitySceneDocuments
    private let key = WPEParitySceneState.EffectKey(objectID: "7", effectID: "1")

    private func scene(_ file: String, visible: Bool = false) throws -> WPEParityProgramScene {
        let layer = Fixtures.layer(effects: [Fixtures.effect(visible: visible, passes: [], combos: ["KEEP": 0])])
        return try Fixtures.programScene([layer], files: ["effects/7_1.json": file])
    }

    func testCompactAcceptedOrdinalsAndPartialStoredClear() throws {
        let program = try scene(#"""
        {"fbos":[
          {"name":"missingFormat"}, {"name":"badFormat","format":1},
          {"name":"conditionFalse","format":"rgba8888","conditions":[{"KEEP":1}]},
          {"name":"first","format":"rgba8888","clear":".25 .5"},
          {"name":"second","format":"rgba8888"}],
         "functions":{"clear":{"action":"clear","fbos":["second"]}}}
        """#)
        let metadata = try XCTUnwrap(program.resolvedMaterialFunctions[key])
        XCTAssertEqual(metadata.targets.map(\.name), ["first", "second"])
        let targets = try metadata.clearTargets(named: "clear")
        XCTAssertEqual(targets.map(\.name), ["first"])
        XCTAssertEqual(targets.first?.clearColor, .init(red: 0.25, green: 0.5, blue: 0, alpha: 0))
        XCTAssertEqual(metadata.targets[1].clearColor, .init(red: 0, green: 0, blue: 0, alpha: 0))
        let first = try XCTUnwrap(program.scene.objects[0].effects[0].fbos.first)
        XCTAssertNil(first.initialClear)
    }

    func testFunctionMatchesExactUTF8AndRejectsUnsafeCountBeforePrefix() throws {
        let program = try scene(#"""
        {"fbos":[{"name":"A","format":"rgba8888"}],"functions":{
          "\u00e9":{"action":"clear","fbos":["A"]},
          "unsafe":{"action":"clear","fbos":["A","A"]},
          "wrongAction":{"action":"Clear","fbos":["A"]},
          "zero":{"action":"clear","fbos":["missing","",7,null]}}}
        """#)
        let metadata = try XCTUnwrap(program.resolvedMaterialFunctions[key])
        XCTAssertEqual(try metadata.clearTargets(named: "é").map(\.name), ["A"])
        XCTAssertTrue(try metadata.clearTargets(named: "e\u{301}").isEmpty)
        XCTAssertTrue(try metadata.clearTargets(named: "wrongAction").isEmpty)
        XCTAssertTrue(try metadata.clearTargets(named: "zero").isEmpty)
        XCTAssertThrowsError(try metadata.clearTargets(named: "unsafe")) { error in
            guard case let WPEParityMaterialFunctionError.unsafeClearCount(function, count, available) = error else {
                return XCTFail("Unexpected failure: \(error)")
            }
            XCTAssertEqual(function, "unsafe")
            XCTAssertEqual(count, 2)
            XCTAssertEqual(available, 1)
        }
    }

    func testDisabledFunctionOnlyPrefixHasPersistentStorageWithoutDrawLifetime() throws {
        let program = try scene(#"""
        {"fbos":[{"name":"first","format":"rgba8888"},
                 {"name":"second","format":"rgba8888"}],
         "functions":{"clear":{"action":"clear","fbos":["second"]}}}
        """#)
        let frame = WPEParitySceneFrameBuilder.build(program.scene)
        let resource = try XCTUnwrap(frame.resources.first { $0.id.rawValue == "first_400_200_1" })
        XCTAssertEqual(resource.lifetime, .persistent)
        XCTAssertFalse(frame.resources.contains { $0.id.rawValue == "second_400_200_1" })
        XCTAssertFalse(frame.draws.values.contains { $0.reads.contains(resource.id) || $0.target == resource.id })
    }

    func testUniqueFunctionTargetsKeepTheirOwnEffectIdentity() throws {
        let layer = Fixtures.layer(effects: [Fixtures.effect("1", passes: []), Fixtures.effect("2", passes: [])])
        let file = #"""
        {"fbos":[{"name":"same","format":"rgba8888","unique":true}],
         "functions":{"clear":{"action":"clear","fbos":["same"]}}}
        """#
        let program = try Fixtures.programScene([layer], files: ["effects/7_1.json": file, "effects/7_2.json": file])
        let object = program.scene.objects[0]
        XCTAssertEqual(object.effects.map(\.fbos.count), [1, 1])
        XCTAssertEqual(object.effects.map {
            WPEParitySceneResource.resolvedFBO(object: object, effect: $0, name: "same").rawValue
        }, ["same_1", "same_2"])
        let frame = WPEParitySceneFrameBuilder.build(program.scene)
        XCTAssertEqual(Set(frame.resources.filter { $0.id.rawValue.hasPrefix("same_") }.map(\.id.rawValue)),
                       ["same_1", "same_2"])
    }
}
