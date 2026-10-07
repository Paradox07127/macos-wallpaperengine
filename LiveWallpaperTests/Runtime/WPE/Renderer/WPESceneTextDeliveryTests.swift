#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct WPESceneTextDeliveryTests {
    private static func writerSource(seedsTilde: Bool = false) -> String {
        """
        let label;
        export function init(value) {
            label = thisScene.getLayer('label');
            \(seedsTilde ? "label.text = '~';" : "")
            return value;
        }
        export function applyUserProperties(properties) {
            if (properties.write !== undefined) label.text = properties.write;
            shared.readback = label.text;
        }
        """
    }

    @Test("A handle that wrote earlier reads the other text binding's accepted output")
    func cachedHandleReadsAcceptedCrossBindingText() async throws {
        let fixture = try makeFixture(publishedText: "Live title")
        defer { fixture.cleanup() }
        let renderer = try await makeLoadedRenderer(fixture)
        defer { renderer.cleanup() }
        try settleFrames(renderer)
        #expect(renderer.lastStableScriptTextByID["label"] == "Live title")
        let writer = try #require(renderer.dynamicOriginScriptInstances["solid"])
        #expect(writer.applyUserProperties([:]))
        #expect(renderer.sceneScriptSharedState?.get("readback") as? String == "Live title")
    }

    @Test("Delayed read-only output cannot resurrect text; delayed explicit writes still deliver", arguments: [false, true])
    func delayedOutputAfterNewPublication(isExplicitWrite: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let renderer = try await makeLoadedRenderer(fixture)
        defer { renderer.cleanup() }
        let oldWriter = try #require(renderer.dynamicOriginScriptInstances["solid"])
        let newWriter = try #require(renderer.dynamicOriginScriptInstances["other"])
        #expect(renderer.textScriptInstances["label"] == nil)

        // Save a real write and the following read-only payload before a newer frame is accepted.
        #expect(oldWriter.applyUserProperties(["write": .string("Old")]))
        let explicitOutput = try #require(oldWriter.takeLayerOutput())
        #expect(explicitOutput.texts["label"] == "Old")
        #expect(oldWriter.applyUserProperties([:]))
        let readOnlyOutput = try #require(oldWriter.takeLayerOutput())
        #expect(readOnlyOutput.texts["label"] == "Old")

        // The label is static text, so no per-frame text script can mask a stale delivery.
        #expect(newWriter.applyUserProperties(["write": .string("New")]))
        renderer.consumeSceneScriptLayerOutputs()
        try settleFrames(renderer)
        #expect(renderer.lastStableScriptTextByID["label"] == "New")

        renderer.applyLayerScriptOutput(isExplicitWrite ? explicitOutput : readOnlyOutput, ownObjectID: "solid")
        try settleFrames(renderer)
        let expected = isExplicitWrite ? "Old" : "New"
        #expect(renderer.liveScriptAssignedText["label"] == expected)
        #expect(renderer.lastStableScriptTextByID["label"] == expected)
    }

    @Test("Text-visible output cannot deliver an expired read-only text value")
    func delayedTextVisibleReadOnlyOutputIsRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let renderer = try await makeLoadedRenderer(fixture)
        defer { renderer.cleanup() }
        let writer = try #require(renderer.textVisibleScriptInstances["writer"])
        let explicit = try #require(writer.applyUserProperties(["write": .string("Old")]))
        #expect(explicit.texts["label"] == "Old")
        let readOnly = try #require(writer.applyUserProperties(["read": .bool(true)]))
        #expect(readOnly.texts["label"] == "Old")
        #expect(readOnly.textDelivery?.explicitKeys.isEmpty == true)

        try acceptText("New", in: renderer)
        renderer.applyTextScriptOutput(readOnly, ownObjectID: "writer")
        try settleFrames(renderer)
        #expect(renderer.liveScriptAssignedText["label"] == "New")
        #expect(renderer.lastStableScriptTextByID["label"] == "New")
    }

    @Test("Text-visible delivery rejects an explicit write from a different scene state")
    func foreignTextVisibleOutputIsRejected() async throws {
        let foreignFixture = try makeFixture()
        defer { foreignFixture.cleanup() }
        let foreign = try await makeLoadedRenderer(foreignFixture)
        defer { foreign.cleanup() }
        try acceptText("Old", in: foreign)
        let foreignWriter = try #require(foreign.textVisibleScriptInstances["writer"])
        let explicit = try #require(foreignWriter.applyUserProperties(["write": .string("Old")]))
        #expect(explicit.textDelivery?.explicitKeys.contains("label") == true)

        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let renderer = try await makeLoadedRenderer(fixture)
        defer { renderer.cleanup() }
        try acceptText("New", in: renderer)
        let receipt = try #require(explicit.textDelivery)
        let receiving = try #require(renderer.sceneScriptSharedState).layerTextPublicationSnapshot()
        #expect(receipt.stateIdentity != receiving.stateIdentity)
        renderer.applyTextScriptOutput(explicit, ownObjectID: "writer")
        try settleFrames(renderer)
        #expect(renderer.liveScriptAssignedText["label"] == "New")
        #expect(renderer.lastStableScriptTextByID["label"] == "New")
    }

    /// `publishedText` adds a text script to the label; "solid" then writes '~' at init,
    /// so its cached handle holds an assignment older than that binding's publication.
    private func makeFixture(publishedText: String? = nil) throws -> MetalSceneFixture {
        let fixture = try MetalSceneFixture.solidColorScene()
        do {
            let path = fixture.root.appendingPathComponent("scene.json")
            var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            var objects = try #require(scene["objects"] as? [[String: Any]])
            objects[0]["origin"] = ["value": "0 0 0", "script": Self.writerSource(seedsTilde: publishedText != nil)]
            objects.append([
                "id": "other", "name": "Other writer", "type": "image",
                "image": "models/util/solidlayer.json", "alpha": 0,
                "origin": ["value": "0 0 0", "script": Self.writerSource()],
            ])
            func textObject(id: String, text: String) -> [String: Any] {
                ["id": id, "name": id, "text": text, "font": "Arial", "pointsize": 12,
                 "origin": "32 32 0", "scale": "1 1 1", "angles": "0 0 0"]
            }
            var writer = textObject(id: "writer", text: "Writer")
            writer["visible"] = ["value": true, "script": Self.writerSource()]
            var label = textObject(id: "label", text: "Author")
            if let publishedText {
                label["text"] = ["value": "Author", "script": "export function update(value) { return '\(publishedText)'; }"]
            }
            scene["objects"] = objects + [writer, label]
            try JSONSerialization.data(withJSONObject: scene).write(to: path)
            return fixture
        } catch {
            fixture.cleanup()
            throw error
        }
    }

    private func makeLoadedRenderer(_ fixture: MetalSceneFixture) async throws -> WPEMetalSceneRenderer {
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        try await renderer.load()
        _ = try #require(renderer.renderPipeline)
        // load() restores async completion; lane barriers alone do not finish Metal work.
        renderer.executor.synchronizeFrameCompletion = true
        try #require(renderer.executor.synchronizeFrameCompletion)
        return renderer
    }

    private func acceptText(_ text: String, in renderer: WPEMetalSceneRenderer) throws {
        let writer = try #require(renderer.dynamicOriginScriptInstances["solid"])
        #expect(writer.applyUserProperties(["write": .string(text)]))
        renderer.consumeSceneScriptLayerOutputs()
        try settleFrames(renderer)
        #expect(renderer.lastStableScriptTextByID["label"] == text)
    }

    /// Each frame consumes the lane jobs completed before it.
    private func settleFrames(_ renderer: WPEMetalSceneRenderer) throws {
        let lane = try #require(renderer.sceneScriptSharedState).executionLane(using: renderer.sceneScriptBatchDispatcher)
        for _ in 0 ..< 4 {
            lane.queue.sync {}
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
        }
        lane.queue.sync {}
    }
}
#endif
