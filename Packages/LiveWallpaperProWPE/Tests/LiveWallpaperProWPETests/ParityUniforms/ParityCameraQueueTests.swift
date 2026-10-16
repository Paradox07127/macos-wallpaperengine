import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityCameraQueueTests: XCTestCase {
    func testSequentialQueueFreezesHiddenAndAdvancesAfterFinishedStep() throws {
        let (queue, document) = try fixture(mode: "sequential", visible: [true, false, true]) { _, _ in
            XCTFail("sequential mode must not consume the scene random stream")
            return 0
        }
        var state = WPEParitySceneState(document: document, hdr: false)
        let world = matrix_identity_float4x4
        for index in [0, 2, 0] {
            let output = try XCTUnwrap(queue.advance(dt: 0.1, world: world, orthographic: true, state: state))
            XCTAssertEqual(queue.selectedIndex, index)
            XCTAssertEqual(output.origin, SIMD3(Float((index + 1) * 10), 0, 0))
            XCTAssertEqual(output.angles, .zero)
            XCTAssertEqual(queue.selectedTime, 0.1)
        }
        state.set(.visible, of: "1", to: .zero)
        XCTAssertNil(queue.advance(dt: 100, world: world, orthographic: true, state: state))
        XCTAssertEqual(queue.selectedIndex, 0)
        XCTAssertEqual(queue.selectedTime, 0.1)
        state.set(.visible, of: "1", to: SIMD4(1, 0, 0, 0))
        _ = queue.advance(dt: 0.1, world: world, orthographic: true, state: state)
        XCTAssertEqual(queue.selectedIndex, 2)
    }

    func testRandomQueueConsumesOneInclusiveDrawAndScansToAvoidBoundaryRepeat() throws {
        var ranges: [[Int32]] = []
        var calls = 0
        let (queue, document) = try fixture(mode: "random", visible: [true, true, true]) { low, high in
            ranges.append([low, high])
            defer { calls += 1 }
            return calls == 3 ? 2 : 0
        }
        let state = WPEParitySceneState(document: document, hdr: false)
        for expected in [0, 1, 2, 0] {
            _ = queue.advance(dt: 0.1, world: matrix_identity_float4x4, orthographic: true, state: state)
            XCTAssertEqual(queue.selectedIndex, expected)
        }
        XCTAssertEqual(calls, 4, "avoiding the last item scans the bag; it must not redraw RNG")
        XCTAssertEqual(ranges, [[0, 2], [0, 1], [0, 0], [0, 2]])
    }

    func testQueuePartialAxesKeepWorldDefaultsAndProjectionSpecificScalars() throws {
        let (queue, document) = try fixture(mode: "sequential", visible: [true]) { _, _ in 0 }
        let state = WPEParitySceneState(document: document, hdr: false)
        var world = matrix_identity_float4x4
        world.columns.1.y = 3
        world.columns.2.z = 4
        world.columns.3 = SIMD4(20, 30, 40, 1)
        let ortho = try XCTUnwrap(queue.advance(dt: 0.025, world: world, orthographic: true, state: state))
        XCTAssertEqual(ortho.origin, SIMD3(10, 30, 40))
        XCTAssertEqual(ortho.angles, .zero)
        XCTAssertEqual(queue.selectedZoom, 2)
        XCTAssertEqual(queue.selectedFOV, 50, "native only evaluates item zoom in an orthographic scene")
        XCTAssertNotNil(queue.advance(dt: 0.025, world: world, orthographic: false, state: state))
        XCTAssertEqual(queue.selectedZoom, 2)
        XCTAssertEqual(queue.selectedFOV, 60)
        XCTAssertEqual(queue.selectedTime, 0.05)
    }

    func testSharedClockResetsOnlyFinishedAndCanSuppressQueueEventDispatch() throws {
        let options: WPESceneJSONValue = .object([
            "fps": .number(10), "length": .number(1), "mode": .string("single"),
            "events": .array([.object(["name": .string("crossing"), "frame": .number(0)])]),
        ])
        let clock = try XCTUnwrap(WPEParityPropertyAnimation(property: .object([
            "animation": .object(["options": options]),
        ]), valueType: .float))
        let channel = try XCTUnwrap(WPEParityPropertyAnimation(property: .object([
            "animation": .object(["options": options, "c0": .array([
                .object(["frame": .number(0), "value": .number(7)]),
            ])]),
        ]), valueType: .float, sharingClock: clock))
        clock.advance(dt: 0.1, collectEvents: false)
        XCTAssertTrue(clock.finished)
        XCTAssertTrue(clock.firedEvents.isEmpty)
        XCTAssertEqual(channel.time, clock.time)
        XCTAssertEqual(channel.value?.x, 7)
        clock.resetFinished()
        XCTAssertEqual(clock.time, 0)
        XCTAssertFalse(clock.finished)
        channel.advance(dt: 0.025, frameStamp: 1)
        XCTAssertEqual(clock.firedEvents.map(\.name), ["crossing"])
        clock.advance(dt: 0.025, frameStamp: 1)
        XCTAssertEqual(clock.time, 0.025, "shared samplers cannot advance the same root twice in one frame")
        clock.resetFinished()
        XCTAssertEqual(clock.time, 0.025, "resetFinished must not restart a running queue item")
    }

    private func fixture(mode: String, visible: [Bool], random: @escaping (Int32, Int32) -> Int32)
        throws -> (WPEParityCameraQueue, WPESceneDocument) {
        let document = try ParityCameraFixture.document(json: """
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":200,"height":100}},
         "objects":[{"id":1,"camera":"default","path":"camera.json","queuemode":"\(mode)"}]}
        """)
        func keys(_ value: Int) -> [[String: Any]] {
            [["frame": 0, "value": value]]
        }
        let records = visible.enumerated().map { index, visible -> [String: Any] in
            ["options": ["fps": 10, "length": 1, "mode": "single"], "visible": visible,
             "eye": ["c0": keys((index + 1) * 10)], "center": ["c0": keys((index + 1) * 10)],
             "zoom": keys(2 + index), "fov": keys(60 + index)]
        }
        let data = try JSONSerialization.data(withJSONObject: ["paths": records])
        let assets = WPEParityProgramAssets(sources: [.lookup(FileManager.default.temporaryDirectory) {
            $0 == "camera.json" ? data : nil
        }])
        let object = try XCTUnwrap(document.resolvedObjectsJSON.first)
        return try (XCTUnwrap(WPEParityCameraQueue(object: object, assets: assets, randomInteger: random)), document)
    }
}
