import Foundation
import LiveWallpaperProWPE
import Testing

struct WPEParticleChildEventKindTests {
    @Test func explicitTypesOverrideLegacyFlagsAndUnknownTypesStayUnknown() {
        #expect(WPEParticleChildEventKind(authoredType: nil, flags: nil) == .staticSystem)
        #expect(WPEParticleChildEventKind(authoredType: nil, flags: 2) == .follow)
        for (raw, expected) in [("static", WPEParticleChildEventKind.staticSystem), ("eventfollow", .follow),
                                ("EVENTSPAWN", .spawn), ("eventdeath", .death)] {
            #expect(WPEParticleChildEventKind(authoredType: raw, flags: 2) == expected)
        }
        #expect(WPEParticleChildEventKind(authoredType: "future-event", flags: 2) == .unsupported("future-event"))
        #expect(!WPEParticleChildEventKind(authoredType: "future-event", flags: 2).isEventDriven)
    }

    @Test func parserRetainsAuthoredTypeAndChildInstanceLimit() {
        let raw: [String: Any] = ["children": [
            ["name": "spawn.json", "type": "EVENTSPAWN", "maxcount": 3],
            ["name": "death.json", "type": "eventdeath", "maxcount": 0],
            ["name": "unknown.json", "type": "future-event", "flags": 2],
        ]]
        let definition = WPEParticleDefinitionParser.parse(dictionary: raw)
        #expect(definition.childReferences.map(\.eventKind) == [.spawn, .death, .unsupported("future-event")])
        #expect(definition.childReferences.map(\.maxCount) == [3, 0, nil])
        #expect(definition.childReferences[0].type == "EVENTSPAWN")
        #expect(definition.childReferences[0].rollsProbabilityPerEvent)
        #expect(!definition.childReferences[2].isEventFollow)
    }
}
