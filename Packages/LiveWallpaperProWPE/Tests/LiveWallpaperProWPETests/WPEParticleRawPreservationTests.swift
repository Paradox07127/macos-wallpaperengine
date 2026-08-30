import Foundation
import Testing
@testable import LiveWallpaperProWPE

@Suite("WPE particle authored JSON preservation")
struct WPEParticleRawPreservationTests {
    private let fixture = #"""
    {
      "material": "materials/test.json",
      "maxcount": 16,
      "topUnknown": {
        "enabled": true,
        "gain": 2.5,
        "unset": null,
        "mixed": [false, 7, null]
      },
      "emitter": [
        {
          "name": "sphererandom",
          "rate": 7,
          "unknownBool": false,
          "unknownNumber": 1.25,
          "unknownNull": null
        },
        {
          "name": "boxrandom",
          "rate": 99,
          "distancemax": "10 20 30",
          "futureField": {"mode": "later"}
        }
      ],
      "renderer": [
        {"name": "sprite", "future": true},
        {"name": "rope", "future": null}
      ],
      "initializer": [
        {"name": "futureinitializer", "order": 1},
        {"name": "lifetimerandom", "min": 2, "max": 3, "order": 2}
      ],
      "operator": [
        {"name": "futureoperator", "order": 1},
        {"name": "movement", "gravity": "0 -10 0", "order": 2}
      ],
      "children": [
        {"name": "first.json", "scale": "2 2 1", "order": 1},
        {"name": "second.json", "future": null, "order": 2}
      ],
      "controlpoint": [
        {"id": 0, "offset": "1 2 3", "order": 1},
        {"id": 7, "flags": 1, "future": false, "order": 2}
      ]
    }
    """#

    @Test("Full authored JSON preserves unknown bool, number, null and nested arrays")
    func fullSourceJSONPreservesEveryJSONKind() throws {
        let definition = try #require(
            WPEParticleDefinitionParser.parse(data: Data(fixture.utf8))
        )

        #expect(definition.sourceJSON["material"] == .string("materials/test.json"))
        #expect(definition.sourceJSON["topUnknown"]?["enabled"] == .bool(true))
        #expect(definition.sourceJSON["topUnknown"]?["gain"] == .number(2.5))
        #expect(definition.sourceJSON["topUnknown"]?["unset"] == .null)
        #expect(definition.sourceJSON["topUnknown"]?["mixed"] == .array([
            .bool(false), .number(7), .null
        ]))

        let firstEmitter = try #require(definition.rawComponents.emitters.first)
        #expect(firstEmitter["unknownBool"] == .bool(false))
        #expect(firstEmitter["unknownNumber"] == .number(1.25))
        #expect(firstEmitter["unknownNull"] == .null)
        #expect(definition.rawComponents.emitters[1]["futureField"]?["mode"] == .string("later"))
    }

    @Test("Every component array preserves authored order and supports typed raw lookup")
    func componentArraysPreserveOrder() throws {
        let definition = try #require(
            WPEParticleDefinitionParser.parse(data: Data(fixture.utf8))
        )
        let raw = definition.rawComponents

        #expect(names(raw.emitters) == ["sphererandom", "boxrandom"])
        #expect(names(raw.renderers) == ["sprite", "rope"])
        #expect(names(raw.initializers) == ["futureinitializer", "lifetimerandom"])
        #expect(names(raw.operators) == ["futureoperator", "movement"])
        #expect(names(raw.children) == ["first.json", "second.json"])
        #expect(raw.controlPoints.map { $0["id"] } == [.number(0), .number(7)])

        for kind in WPEParticleComponentArrayKind.allCases {
            #expect(raw[kind].count == 2)
        }
        #expect(raw[.emitters] == raw.emitters)
        #expect(raw[.controlPoints] == raw.controlPoints)
    }

    @Test("Typed projection remains first-emitter-only and copy helpers retain raw JSON")
    func typedProjectionStaysPartialAndCopiesStayLossless() throws {
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any]
        )
        var diagnostics: [WPESceneDiagnostic] = []
        let definition = WPEParticleDefinitionParser.parse(
            dictionary: object,
            diagnostics: &diagnostics
        )

        #expect(definition.rate == 7)
        #expect(definition.emitterShape == .sphere)
        #expect(definition.rawComponents.emitters.count == 2)
        #expect(diagnostics.contains { $0.message.contains("PARTIAL") && $0.message.contains("first emitter") })

        let overridden = definition.applying(
            instanceOverride: WPESceneParticleInstanceOverride(count: 2)
        )
        let offset = definition.offsettingOrigin(by: SIMD3<Double>(1, 2, 3))
        #expect(overridden.sourceJSON == definition.sourceJSON)
        #expect(overridden.rawComponents == definition.rawComponents)
        #expect(offset.sourceJSON == definition.sourceJSON)
        #expect(offset.rawComponents == definition.rawComponents)
    }

    @Test("Child and control-point optionals preserve missing, null, zero and order")
    func childAndControlPointOptionalsPreserveAuthoredShape() throws {
        let authored = #"""
        {
          "children": [
            {"name": "missing.json"},
            {
              "name": "null.json",
              "maxcount": null,
              "angles": null,
              "flags": null,
              "controlpointstartindex": null
            },
            {
              "name": "zero.json",
              "maxcount": 0,
              "angles": "0 0 0",
              "flags": 0,
              "controlpointstartindex": 0
            },
            {"name": "legacy-follow.json", "flags": 2}
          ],
          "controlpoint": [
            {"id": 0},
            {"id": 1, "flags": null, "angles": null},
            {"id": 2, "flags": 0, "angles": "0 0 0"},
            {"id": 3, "flags": 2}
          ]
        }
        """#
        let definition = try #require(
            WPEParticleDefinitionParser.parse(data: Data(authored.utf8))
        )

        #expect(definition.childReferences.map(\.relativePath) == [
            "missing.json", "null.json", "zero.json", "legacy-follow.json"
        ])
        #expect(definition.childReferences[0].maxCount == nil)
        #expect(definition.childReferences[1].maxCount == nil)
        #expect(definition.childReferences[2].maxCount == 0)
        #expect(definition.childReferences[2].angles == SIMD3<Double>.zero)
        #expect(definition.childReferences[2].flagsRaw == 0)
        #expect(definition.childReferences[2].controlPointStartIndex == 0)

        let rawChildren = definition.rawComponents.children
        #expect(rawChildren[0]["maxcount"] == nil)
        #expect(rawChildren[1]["maxcount"] == .null)
        #expect(rawChildren[2]["maxcount"] == .number(0))
        #expect(rawChildren[0]["controlpointstartindex"] == nil)
        #expect(rawChildren[1]["controlpointstartindex"] == .null)
        #expect(rawChildren[2]["controlpointstartindex"] == .number(0))

        #expect(definition.controlPoints.map(\.id) == [0, 1, 2, 3])
        #expect(definition.controlPoints[0].flagsRaw == nil)
        #expect(definition.controlPoints[1].flagsRaw == nil)
        #expect(definition.controlPoints[2].flagsRaw == 0)
        #expect(definition.controlPoints[2].angles == SIMD3<Double>.zero)
        #expect(definition.controlPoints[3].flagsRaw == 2)
        #expect(definition.controlPoints[3].isWorldSpace)

        let overridden = definition.applying(instanceOverride: .init(
            controlPointOffsets: [2: SIMD3<Double>(9, 8, 7)]
        ))
        #expect(overridden.controlPoints.map(\.id) == [0, 1, 2, 3])
        #expect(overridden.controlPoints[2].offset == SIMD3<Double>(9, 8, 7))
        #expect(overridden.controlPoints[2].flagsRaw == 0)
        #expect(overridden.controlPoints[2].angles == SIMD3<Double>.zero)

        let rawControlPoints = definition.rawComponents.controlPoints
        #expect(rawControlPoints[0]["flags"] == nil)
        #expect(rawControlPoints[1]["flags"] == .null)
        #expect(rawControlPoints[2]["flags"] == .number(0))
        #expect(rawControlPoints[0]["angles"] == nil)
        #expect(rawControlPoints[1]["angles"] == .null)
        #expect(rawControlPoints[2]["angles"] == .string("0 0 0"))
    }

    private func names(_ values: [WPESceneJSONValue]) -> [String] {
        values.compactMap { value in
            guard let authoredName = value["name"],
                  case .string(let name) = authoredName else { return nil }
            return name
        }
    }
}
