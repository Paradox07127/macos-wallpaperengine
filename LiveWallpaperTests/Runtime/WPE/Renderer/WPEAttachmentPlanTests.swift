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

    @Test func sharedCursorRippleBuffersRetainOnlyTheReadBeforeWriteHistory() {
        let force = "_rt_EightBuffer1"
        let simulation = "_rt_EightBuffer2"
        let plan = WPEAttachmentPlan(layers: [layer([
            pass("apply", source: .fbo(simulation), target: .fbo(name: force)),
            pass("simulate", source: .fbo(force), target: .fbo(name: simulation)),
            pass("combine", source: .fbo(simulation), target: .scene),
        ], fbos: [
            .init(name: force, scale: 1, fit: 256, format: "rgba8888"),
            .init(name: simulation, scale: 1, fit: 256, format: "rgba8888"),
        ])])
        #expect(plan.historyFBONames == [simulation])
        #expect(plan.passes[0].inputs[0].source == .privateHistory(simulation))
        #expect(plan.passes[1].inputs[0].source == .current(plan.passes[0].output))
        #expect(plan.passes[2].inputs[0].source == .current(plan.passes[1].output))
    }

    @Test(arguments: [false, true])
    func aGatedProducerCannotEraseThePriorFrameDependency(unique: Bool) {
        let gate = WPEPassVisibilityGate(script: .init(script: "return false;", seed: .zero), initialVisible: false)
        let plan = WPEAttachmentPlan(layers: [layer([
            pass("conditional-producer", source: .asset("current"), target: .fbo(name: "history"), gate: gate),
            pass("consumer", source: .fbo("history"), target: .scene),
        ], fbos: [.init(name: "history", scale: 1, format: "rgba8888", unique: unique)])])
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

    @Test func localPublicationPreservesOnlyAnExactCurrentFramePrivateWrite() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let destination = try #require(device.makeTexture(descriptor: descriptor))
        let alternate = try #require(device.makeTexture(descriptor: descriptor))
        let target = WPEMetalTargetID.named("a")
        let marked = localEffect(target: .layerComposite(name: "a"), role: .localEffect)
        func contract(_ pass: WPEPreparedRenderPass, _ frame: WPEMetalFrameState, texture: MTLTexture? = nil,
                      targetID: WPEMetalTargetID? = nil, feedback: Bool = false) -> WPEAttachmentLoadContract {
            executor.attachmentLoadContract(for: pass, targetID: targetID ?? target, destinationTexture: texture ?? destination,
                                            readsCurrentTarget: feedback, frameState: frame)
        }
        var written = WPEMetalFrameState(output: output, sceneSize: CGSize(width: 4, height: 4))
        written.registerWrite(texture: destination, targetID: target)
        #expect(contract(marked, written) == .init(load: .load, store: .store, reason: .localEffectPreservation))
        #expect(contract(marked, written, feedback: true).reason == .targetFeedback)

        let history = WPEMetalFrameState(output: output, sceneSize: CGSize(width: 4, height: 4), previousNamedTextures: ["a": destination])
        #expect(contract(marked, history) == .init(load: .clear, store: .store, reason: .uninitialized))
        var initializedOnly = history
        initializedOnly.markInitialized(destination)
        #expect(contract(marked, initializedOnly) == .init(load: .clear, store: .store, reason: .scratchOverwrite))
        var wrongPhysical = written
        wrongPhysical.markInitialized(alternate)
        #expect(contract(marked, wrongPhysical, texture: alternate).load == .clear)
        var foreignWrite = WPEMetalFrameState(output: output, sceneSize: CGSize(width: 4, height: 4))
        foreignWrite.registerWrite(texture: destination, targetID: .named("foreign"))
        #expect(contract(marked, foreignWrite).load == .clear)
        #expect(contract(marked, written, targetID: .named("foreign")).load == .clear)

        let canonical = localEffect(target: .layerComposite(name: "a"), role: nil)
        #expect(contract(canonical, written).reason == .scratchOverwrite)
        let legacy = pass("legacy-copy", source: .fbo("b"), target: .layerComposite(name: "a"))
        #expect(contract(legacy, written).reason == .scratchOverwrite)
        let markedFBO = localEffect(target: .fbo(name: "a"), role: .localEffect)
        #expect(contract(markedFBO, written).reason == .scratchOverwrite)
        var sceneWritten = written
        sceneWritten.registerWrite(texture: output, targetID: .scene)
        let terminal = localEffect(target: .scene, role: nil)
        #expect(contract(terminal, sceneWritten, texture: output, targetID: .scene).reason == .sceneAccumulation)
        let reset = WPEMetalFrameState(output: output, sceneSize: CGSize(width: 4, height: 4), previousNamedTextures: written.latestNamedTextures)
        #expect(contract(marked, reset).reason == .uninitialized)
    }

    private func localEffect(target: WPERenderTarget, role: WPEPublicationVertexRole?) -> WPEPreparedRenderPass {
        let raw = WPERenderPass(id: "local", phase: .effect(file: "test/probe.json"), shader: "local-probe",
                                source: .fbo("b"), target: target, textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled",
                                cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        return WPEPreparedRenderPass(pass: raw, shader: nil, textureBindings: [0: .fbo("b")], comboValues: [:], uniformValues: [:],
                                     alphaContract: .init(unpremultipliedInputSlots: [], premultipliedOutput: false), publicationVertexRole: role)
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
