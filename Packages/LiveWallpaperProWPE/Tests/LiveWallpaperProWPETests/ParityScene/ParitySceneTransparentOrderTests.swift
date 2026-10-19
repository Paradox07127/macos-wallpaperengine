import Foundation
import LiveWallpaperProWPE
import Testing

/// The transparent member vector the scene state keeps and re-sorts by view distance each frame.
struct ParitySceneTransparentOrderTests {
    /// Image layers "1", "2", … at `origins`, every one a transparent member.
    private static func state(_ origins: [String], fullscreen: Set<String> = []) throws -> WPEParitySceneState {
        let objects: [[String: Any]] = origins.enumerated().map { index, origin in
            ["id": index + 1, "image": "models/\(index + 1).json", "origin": origin]
        }
        let source: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source),
                                                        userValues: [:])
        return WPEParitySceneState(document: document, hdr: false,
                                   transparentMembers: Set(origins.indices.map { String($0 + 1) }),
                                   fullscreenMembers: fullscreen)
    }

    @Test func farMembersSortFirstAndAnUnchangedOrderLeavesMembershipAlone() throws {
        var state = try Self.state(["0 0 0", "0 0 4", "0 0 -2"])
        #expect(state.transparentOrder == ["1", "2", "3"])
        let membership = state.membershipGeneration
        state.sortTransparentMembers(viewForward: SIMD3(0, 0, -1))
        #expect(state.transparentOrder == ["3", "1", "2"])
        #expect(state.membershipGeneration == membership + 1)
        state.sortTransparentMembers(viewForward: SIMD3(0, 0, -1))
        #expect(state.transparentOrder == ["3", "1", "2"])
        #expect(state.membershipGeneration == membership + 1)
    }

    @Test func tiedKeysKeepTheLastSortedOrder() throws {
        var state = try Self.state(["0 0 1", "0 0 0"])
        state.sortTransparentMembers(viewForward: SIMD3(0, 0, -1))
        #expect(state.transparentOrder == ["2", "1"])
        state.set(.origin, of: "1", to: .zero)
        state.sortTransparentMembers(viewForward: SIMD3(0, 0, -1))
        #expect(state.transparentOrder == ["2", "1"])
    }

    @Test func fullscreenMembersSortLast() throws {
        var state = try Self.state(["0 0 0", "0 0 -100", "0 0 3"], fullscreen: ["2"])
        state.sortTransparentMembers(viewForward: SIMD3(0, 0, -1))
        #expect(state.transparentOrder == ["1", "3", "2"])
    }

    /// (y·fy + x·fx) + z·fz: the large x and y cancel before z is added.
    @Test func keySumsYThenXThenZ() throws {
        var state = try Self.state(["0 0 0", "0 0 0"])
        state.set(.origin, of: "1", to: SIMD4(1e8, -1e8, 1, 0))
        state.set(.origin, of: "2", to: SIMD4(0, 0, 0.5, 0))
        #expect(state.object("1")?.origin == SIMD3(1e8, -1e8, 1))
        state.sortTransparentMembers(viewForward: SIMD3(1, 1, 1))
        #expect(state.transparentOrder == ["1", "2"])
    }

    @Test func removedMembersLeaveAndClonesOfMembersJoin() throws {
        var state = try Self.state(["0 0 0", "0 0 4", "0 0 -2"])
        state.removeObject("2")
        #expect(state.transparentOrder == ["1", "3"])
        let clone = try state.appendImageLayer(cloning: "1", id: 9) { _ in }
        #expect(state.transparentOrder == ["1", "3", String(clone)])
    }
}
