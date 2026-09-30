#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE attachment dependencies and physical load contracts")
struct WPEAttachmentPlanTests {
    @Test func versionsKeepChainInputsSeparateFromTemporalHistory() {
        let passes = [
            pass("read", source: .fbo("history"), target: .fbo(name: "scratch")),
            pass("carry", source: .fbo("scratch"), target: .fbo(name: "history")),
            pass("feedback", source: .previous, target: .fbo(name: "scratch")),
            pass("present", source: .fbo("scratch"), target: .scene),
        ]
        let plan = WPEAttachmentPlan(layers: [layer(passes, fbos: [.init(name: "history", scale: 1, format: "rgba8888", unique: true)])])
        #expect(plan.historyFBONames == ["history"])
        #expect(plan.passes[0].inputs[0].source == .privateHistory("history"))
        #expect(plan.passes[1].inputs[0].source == .current(plan.passes[0].output))
        #expect(plan.passes[2].inputs[0].source == .current(plan.passes[0].output))
        #expect(plan.passes[2].readsCurrentTarget)
        #expect(plan.passes[2].output.revision == 2)
        #expect(plan.passes[3].inputs[0].source == .current(plan.passes[2].output))
        let bootstrap = WPEAttachmentPlan(layers: [layer([pass("fresh", source: .previous, target: .fbo(name: "history"))])])
        #expect(bootstrap.historyFBONames.isEmpty)
        #expect(bootstrap.passes[0].inputs[0].source == .clearedBootstrap(.named("history")))
    }

    @Test func overriddenDrawBindingDoesNotEraseClosedGateInput() {
        let gate = WPEPassVisibilityGate(script: .init(script: "return false;", seed: .zero), initialVisible: false)
        let gated = pass("gate", source: .fbo("history"), target: .layerComposite(name: "out"),
                         bindings: [0: .asset("current")], gate: gate)
        let plan = WPEAttachmentPlan(layers: [layer([gated], fbos: [.init(name: "history", scale: 1, format: "rgba8888", unique: true)])])
        #expect(plan.passes[0].inputs[0].source == .external(.asset("current")))
        #expect(plan.passes[0].closedGate == .copy(.privateHistory("history")))
        #expect(plan.historyFBONames == ["history"])
        let noGate = WPEAttachmentPlan(layers: [layer([pass("draw", source: .fbo("history"), target: .scene,
                                                            bindings: [0: .asset("current")])], fbos: [.init(name: "history", scale: 1, format: "rgba8888", unique: true)])])
        #expect(noGate.historyFBONames.isEmpty)
    }

    @Test func aGatedPrivateProducerCannotEraseThePriorFrameDependency() {
        let gate = WPEPassVisibilityGate(script: .init(script: "return false;", seed: .zero), initialVisible: false)
        let plan = WPEAttachmentPlan(layers: [layer([
            pass("conditional-producer", source: .asset("current"), target: .fbo(name: "history"), gate: gate),
            pass("consumer", source: .fbo("history"), target: .scene),
        ], fbos: [.init(name: "history", scale: 1, format: "rgba8888", unique: true)])])
        #expect(plan.historyFBONames == ["history"])
        #expect(plan.passes[1].inputs[0].source == .conditionalPrivateHistory(plan.passes[0].output, "history"))
    }

    @Test func sceneSnapshotsAndUndeclaredInputsDoNotClaimTemporalCarryOrZero() {
        let plan = WPEAttachmentPlan(layers: [layer([
            pass("before", source: .fbo("_rt_FullFrameBuffer"), target: .fbo(name: "scratch")),
            pass("scene", source: .asset("image"), target: .scene),
            pass("after", source: .fbo("_rt_FullFrameBuffer"), target: .fbo(name: "scratch")),
            pass("unknown", source: .fbo("typo"), target: .scene),
        ])])
        #expect(plan.passes[0].inputs[0].source == .sceneSnapshot(.init(target: .scene, revision: 0, producer: nil)))
        #expect(plan.passes[2].inputs[0].source == .sceneSnapshot(plan.passes[1].output))
        #expect(plan.passes[3].inputs[0].source == .unresolvedNamed("typo"))
        #expect(plan.historyFBONames.isEmpty)
    }

    @Test func topologyInvalidatesPrivateDeclarationsAndGateSemantics() throws {
        let executor = try WPEMetalRenderExecutor(device: #require(MTLCreateSystemDefaultDevice()))
        let original = pass("read", source: .fbo("history"), target: .fbo(name: "out"))
        let ordinary = WPEPreparedRenderPipeline(layers: [layer([original], fbos: [.init(name: "history", scale: 1, format: "rgba8888")])])
        let privatePipeline = WPEPreparedRenderPipeline(layers: [layer([original], fbos: [.init(name: "history", scale: 1, format: "rgba8888", unique: true)])])
        #expect(executor.validatedFBOAliasTopology(for: ordinary).historyFBONames.isEmpty)
        #expect(executor.validatedFBOAliasTopology(for: privatePipeline).historyFBONames == ["history"])
        #expect(executor.fboAliasTopologyRebuildCount == 2)
        let repeated = WPEPreparedRenderPipeline(layers: [layer([original], fbos: [
            .init(name: "history", scale: 1, format: "rgba8888", unique: true),
            .init(name: "history", scale: 1, format: "rgba8888", unique: false),
        ])])
        #expect(executor.validatedFBOAliasTopology(for: repeated).historyFBONames.isEmpty)
    }

    @Test func physicalInitializationGatesLoadEvenForFeedbackAndBlending() {
        for target: WPEMetalTargetID in [.scene, .named("scratch"), .named("_rt_layerGroup_test")] {
            let uninitialized = WPEAttachmentLoadContract.color(target: target, initialized: false, readsCurrentTarget: true, blendNeedsDestination: true)
            #expect(uninitialized.load == .clear && uninitialized.reason == .uninitialized)
        }
        let scratch = WPEAttachmentLoadContract.color(target: .named("scratch"), initialized: true, readsCurrentTarget: false, blendNeedsDestination: false)
        #expect(scratch.load == .clear && scratch.reason == .scratchOverwrite)
        #expect(WPEAttachmentLoadContract.color(target: .scene, initialized: true, readsCurrentTarget: false, blendNeedsDestination: false).load == .load)
        #expect(WPEAttachmentLoadContract.color(target: .named("scratch"), initialized: true, readsCurrentTarget: true, blendNeedsDestination: false).reason == .targetFeedback)
        #expect(WPEAttachmentLoadContract.depth(transient: true, initialized: true).store == .dontCare)
        #expect(WPEAttachmentLoadContract.depth(transient: false, initialized: false).load == .clear)
        #expect(WPEAttachmentLoadContract.depth(transient: false, initialized: true).load == .load)
        #expect(WPEAttachmentLoadContract.fullOverwrite.load == .dontCare)
    }

    private func pass(_ id: String, source: WPETextureReference, target: WPERenderTarget,
                      bindings: [Int: WPETextureReference]? = nil, gate: WPEPassVisibilityGate? = nil) -> WPEPreparedRenderPass {
        let raw = WPERenderPass(id: id, phase: .material, shader: "commands/copy", source: source, target: target,
                                textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled",
                                cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled", visibilityGate: gate)
        return WPEPreparedRenderPass(pass: raw, shader: nil, textureBindings: bindings ?? [0: source], comboValues: [:], uniformValues: [:])
    }

    private func layer(_ passes: [WPEPreparedRenderPass], fbos: [WPERenderFBO] = []) -> WPEPreparedRenderLayer {
        let graph = WPERenderLayer(objectID: "object", objectName: "test", imagePath: "image", materialPath: nil,
                                   geometry: .identity, compositeA: "out", compositeB: "other", localFBOs: fbos, passes: passes.map(\.pass))
        return WPEPreparedRenderLayer(graphLayer: graph, passes: passes)
    }
}
#endif
