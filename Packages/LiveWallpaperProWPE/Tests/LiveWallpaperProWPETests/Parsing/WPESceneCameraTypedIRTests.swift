import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaperProWPE

@Suite("WPE camera typed lossless IR")
struct WPESceneCameraTypedIRTests {
    private struct NoScriptResolver: WPESceneTransformScriptResolving {
        func resolveVec3(
            script: String,
            properties: [String: WPESceneScriptPropertyValue],
            seed: SIMD3<Double>
        ) -> SIMD3<Double>? { nil }
    }

    @Test("Preserves root path order and camera-object source order with explicit zeroes")
    func preservesOrderedAuthoredValues() throws {
        let document = try parse([
            "camera": [
                "center": "0 0 0",
                "eye": "0 0 1",
                "up": "0 1 0",
                "paths": ["scripts/intro.json", "scripts/idle.json"],
            ],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [
                ["id": 1, "name": "before", "image": "models/a.json"],
                [
                    "id": 2,
                    "camera": "default",
                    "path": "scripts/camera_paths_2.json",
                    "queuemode": "random",
                    "origin": ["value": "0 -0 2", "script": "export function update(v) { return v; }"],
                    "angles": "0 -0 0",
                    "fov": ["value": 0, "user": "fov"],
                    "zoom": 0,
                ] as [String: Any],
                ["id": 3, "name": "after", "image": "models/b.json"],
            ],
        ])

        #expect(document.authoredCamera.paths == .value([
            "scripts/intro.json",
            "scripts/idle.json",
        ]))
        let camera = try #require(document.authoredCameraObjects.first)
        #expect(camera.sourceObjectIndex == 1)
        #expect(camera.camera == .value("default"))
        #expect(camera.path == .value("scripts/camera_paths_2.json"))
        #expect(camera.queueMode == .value("random"))
        #expect(camera.origin == .value(SIMD3<Double>(0, -0.0, 2)))
        #expect(camera.angles == .value(SIMD3<Double>(0, -0.0, 0)))
        #expect(camera.fov == .value(0))
        #expect(camera.zoom == .value(0))

        if case .value(let angles) = camera.angles {
            #expect(angles.y.sign == .minus, "A string-authored -0 angle must not be normalized away")
        } else {
            Issue.record("Expected decoded camera angles")
        }
        #expect(camera.sourceJSON["fov"]?["user"] == .string("fov"))
        #expect(camera.sourceJSON["origin"]?["script"] == .string("export function update(v) { return v; }"))
    }

    @Test("Distinguishes missing, null, and unexpected camera metadata")
    func distinguishesPresenceAndUnexpectedShapes() throws {
        let nullDocument = try parse([
            "camera": ["center": "0 0 0", "paths": NSNull()],
            "general": ["orthogonalprojection": ["width": 1, "height": 1]],
            "objects": [[
                "id": 1,
                "camera": NSNull(),
                "path": NSNull(),
                "queuemode": 7,
                "origin": false,
                "angles": NSNull(),
                "fov": "bad",
            ] as [String: Any]],
        ])
        #expect(nullDocument.authoredCamera.paths == .null)
        let malformed = try #require(nullDocument.authoredCameraObjects.first)
        #expect(malformed.camera == .null)
        #expect(malformed.path == .null)
        #expect(malformed.queueMode == .unparsed(.number(7)))
        #expect(malformed.origin == .unparsed(.bool(false)))
        #expect(malformed.angles == .null)
        #expect(malformed.fov == .unparsed(.string("bad")))
        #expect(malformed.zoom == nil)

        let missingDocument = try parse([
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1, "height": 1]],
            "objects": [["id": 1, "camera": "default"]],
        ])
        #expect(missingDocument.authoredCamera.paths == nil)
        let missing = try #require(missingDocument.authoredCameraObjects.first)
        #expect(missing.path == nil)
        #expect(missing.queueMode == nil)
        #expect(missing.origin == nil)
        #expect(missing.angles == nil)
        #expect(missing.fov == nil)
        #expect(missing.zoom == nil)
    }

    @Test("Mixed root path arrays remain raw instead of being partially accepted")
    func mixedPathArrayIsUnparsed() throws {
        let document = try parse([
            "camera": ["center": "0 0 0", "paths": ["scripts/a.json", 7]],
            "general": ["orthogonalprojection": ["width": 1, "height": 1]],
        ])

        #expect(document.authoredCamera.paths == .unparsed(.array([
            .string("scripts/a.json"),
            .number(7),
        ])))
    }

    @Test("Camera metadata is value-copyable, Equatable, and Sendable")
    func valueContracts() throws {
        let document = try parse([
            "camera": ["center": "0 0 0", "paths": []],
            "general": ["orthogonalprojection": ["width": 1, "height": 1]],
            "objects": [["id": 1, "camera": "default", "path": ""]],
        ])
        let copy = document.authoredCameraObjects

        #expect(copy == document.authoredCameraObjects)
        #expect(document.authoredCamera.paths == .value([]))
        #expect(copy.first?.path == .value(""))
        requireSendable(document.authoredCamera)
        requireSendable(copy)
    }

    private func parse(_ payload: [String: Any]) throws -> WPESceneDocument {
        try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: payload),
            userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
