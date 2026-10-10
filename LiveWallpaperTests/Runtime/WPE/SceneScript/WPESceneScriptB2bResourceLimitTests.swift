#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("WPE SceneScript B2b resource limits")
struct WPESceneScriptB2bResourceLimitTests {
    @Test("Created layer cap accepts its exact boundary and scene-latches on the next layer")
    func createdLayerExactBoundary() {
        let token = preparedToken(generation: 1)
        let limit = WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene
        for _ in 0 ..< limit {
            #expect(token.admitCreatedLayer())
        }
        #expect(token.resourceSnapshot.createdLayers == limit)
        #expect(!token.admitCreatedLayer())
        #expect(token.resourceSnapshot.createdLayers == limit)
        #expect(token.failureReason == .createdLayerLimitExceeded(limit: limit))
        expectEveryOperationRejected(by: token)
    }

    @Test("Actual layer bridge accepts the configured layer cap and discards an over-limit entry")
    @MainActor
    func createdLayerBridgeExactBoundary() throws {
        let limit = WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene
        let exactToken = preparedToken(generation: 11, inventory: .init(text: 0, layer: 1, transform: 0))
        let exact = try WPELayerScriptInstance(
            script: Self.createdLayerScript(count: limit),
            shared: WPESharedScriptState(sceneScriptLoadToken: exactToken)
        )
        #expect(exact.initialOutput.created.count == limit)
        #expect(exactToken.resourceSnapshot.createdLayers == limit)
        #expect(exactToken.failureReason == nil)

        let overToken = preparedToken(generation: 12, inventory: .init(text: 0, layer: 1, transform: 0))
        let over = try WPELayerScriptInstance(
            script: Self.createdLayerScript(count: limit + 1),
            shared: WPESharedScriptState(sceneScriptLoadToken: overToken)
        )
        #expect(over.initialOutput.created.isEmpty)
        #expect(overToken.resourceSnapshot.createdLayers == 0)
        #expect(overToken.failureReason == .createdLayerLimitExceeded(limit: limit))
        expectEveryOperationRejected(by: overToken)
    }

        @Test("Video command cap accepts 256 in one evaluation and scene-latches on 257")
        func videoCommandExactBoundary() {
            let token = preparedToken(generation: 2)
            let evaluation = WPESceneScriptEvaluationResourceBudget(sceneToken: token)
            evaluation.beginEvaluation()
            for _ in 0 ..< 256 {
                #expect(evaluation.admitVideoCommand())
            }
            #expect(evaluation.admittedVideoCommandCount == 256)
            #expect(!evaluation.admitVideoCommand())
            #expect(evaluation.admittedVideoCommandCount == 256)
            #expect(token.failureReason == .videoCommandLimitExceeded(limit: 256))
            expectEveryOperationRejected(by: token)
        }

    @Test("Actual video bridge accepts 256 commands and discards an over-limit entry")
    @MainActor
    func videoCommandBridgeExactBoundary() throws {
        let exactToken = preparedToken(generation: 13, inventory: .init(text: 0, layer: 1, transform: 0))
        let exact = try WPELayerScriptInstance(
            script: Self.videoCommandScript(count: 256),
            shared: WPESharedScriptState(sceneScriptLoadToken: exactToken)
        )
        #expect(exact.initialOutput.own.videoCommands.count == 256)
        #expect(exactToken.failureReason == nil)

        let overToken = preparedToken(generation: 14, inventory: .init(text: 0, layer: 1, transform: 0))
        let over = try WPELayerScriptInstance(
            script: Self.videoCommandScript(count: 257),
            shared: WPESharedScriptState(sceneScriptLoadToken: overToken)
        )
        #expect(over.initialOutput.own.videoCommands.isEmpty)
        #expect(over.initialOutput.videoCalls.isEmpty)
        #expect(overToken.failureReason == .videoCommandLimitExceeded(limit: 256))
        expectEveryOperationRejected(by: overToken)
    }

    @Test("Async output merge preserves accepted per-evaluation video commands")
        @MainActor
        func asynchronousVideoCommandMerge() {
            let pending = Self.layerOutput(commands: Array(repeating: .play, count: 256))
            let newer = Self.layerOutput(commands: Array(repeating: .pause, count: 256))
            let merged = WPELayerScriptInstance.mergedOutputs(pending: pending, newer: newer)
            #expect(merged.own.videoCommands.count == 512)
            #expect(merged.own.videoCommands.prefix(256).allSatisfy { $0 == .play })
            #expect(merged.own.videoCommands.suffix(256).allSatisfy { $0 == .pause })
        }

        @Test("Shared state accepts 1024 root entries and refuses the 1025th")
        func sharedStateExactBoundary() {
            let token = preparedToken(generation: 3)
            let shared = WPESharedScriptState(sceneScriptLoadToken: token)
            for index in 0 ..< 1024 {
                shared.set("key-\(index)", index)
            }
            #expect(token.resourceSnapshot.sharedStateEntries == 1024)
            #expect(shared.get("key-1023") as? Int == 1023)

            shared.set("key-1024", 1024)
            #expect(shared.get("key-1024") == nil)
            #expect(token.resourceSnapshot.sharedStateEntries == 1024)
            #expect(token.failureReason == .sharedStateLimitExceeded(limit: 1024))
            expectEveryOperationRejected(by: token)
        }

        @Test("Quarantine retains exactly 16 engines and refuses engine 17")
        func quarantineFullRefusal() throws {
            let quarantine = WPESceneScriptQuarantine(limit: 16)
            for _ in 0 ..< 16 {
                let reservation = try #require(quarantine.reserve())
                #expect(reservation.quarantine(NSObject()))
            }
            #expect(quarantine.snapshot == .init(
                activeReservations: 0,
                quarantinedEngines: 16,
                limit: 16
            ))
            #expect(!quarantine.canConstructRuntime)
            #expect(quarantine.reserve() == nil)

            let token = WPESceneScriptInstanceLimitToken(
                generation: 4,
                executionQuarantine: quarantine
            )
            #expect(token.prepare(.init(text: 1, layer: 0, transform: 0)))
            var constructionAttempts = 0
            let constructed: Int? = token.withConstructionPermission {
                constructionAttempts += 1
                return constructionAttempts
            }
            #expect(constructed == nil)
            #expect(constructionAttempts == 0)
            #expect(token.failureReason == .quarantineLimitReached(limit: 16))
            expectEveryOperationRejected(by: token)
        }

        @Test("Sixteen transient reservations reject work without poisoning the scene")
        func transientQuarantineSaturationRecovers() throws {
            let quarantine = WPESceneScriptQuarantine(limit: 16)
            var active: [WPESceneScriptQuarantine.Reservation] = []
            for _ in 0 ..< 16 {
                try active.append(#require(quarantine.reserve()))
            }
            let token = WPESceneScriptInstanceLimitToken(
                generation: 15,
                executionQuarantine: quarantine
            )
            #expect(token.prepare(.init(text: 1, layer: 0, transform: 0)))
            #expect(WPESceneScriptExecutionSafetyReservation.reserve(sceneToken: token) == nil)
            #expect(token.failureReason == nil)
            #expect(token.acceptsCompletion())

            #expect(active.removeFirst().complete())
            let recovered = try #require(
                WPESceneScriptExecutionSafetyReservation.reserve(sceneToken: token)
            )
            recovered.complete()
            #expect(token.failureReason == nil)
        }

        @Test("Async dispatch slot re-arms only when released through its owner")
        func asyncDispatchSlotReleaseIsNotInterchangeable() throws {
            let quarantine = WPESceneScriptQuarantine(limit: 16)
            let token = WPESceneScriptInstanceLimitToken(
                generation: 1,
                executionQuarantine: quarantine
            )
            #expect(token.prepare(.init(text: 1, layer: 0, transform: 0)))

            let stranded = WPESceneScriptAsyncExecutionSafety()
            let abandoned = try #require(
                stranded.begin(sceneToken: token, operation: .tick)
            )
            abandoned.complete()
            #expect(stranded.begin(sceneToken: token, operation: .tick) == nil)

            let owner = WPESceneScriptAsyncExecutionSafety()
            let released = try #require(
                owner.begin(sceneToken: token, operation: .tick)
            )
            owner.complete(released)
            #expect(owner.begin(sceneToken: token, operation: .tick) != nil)
        }

        @Test("Setup watchdog quarantine latches all script families closed")
        func setupWatchdogSceneLatch() throws {
            let quarantine = WPESceneScriptQuarantine(limit: 16)
            let token = WPESceneScriptInstanceLimitToken(
                generation: 16,
                executionQuarantine: quarantine
            )
            #expect(token.prepare(.init(text: 1, layer: 1, transform: 1)))
            let safety = try #require(
                WPESceneScriptExecutionSafetyReservation.reserve(sceneToken: token)
            )
            #expect(safety.quarantine(NSObject(), operation: .setup))
            #expect(token.failureReason == .executionTimedOut(operation: .setup))
            expectEveryOperationRejected(by: token)
        }

        @Test("Failed traversal discards video mutations before player side effects")
        func videoCommandTransactionDiscard() {
            var buffer = WPESceneScriptVideoCommandBuffer()
            var applied: [WPELayerVideoCommand] = []
            buffer.begin()
            buffer.enqueue([.play, .seek(3), .stop], objectID: "video")
            for command in buffer.finish(commit: false).map(\.command) {
                applied.append(command)
            }
            #expect(applied.isEmpty)
            #expect(buffer.pending.isEmpty)
            #expect(!buffer.isTransactionActive)

            buffer.begin()
            buffer.enqueue([.pause], objectID: "video")
            applied.append(contentsOf: buffer.finish(commit: true).map(\.command))
            #expect(applied == [.pause])
        }

        @Test("Authored keyframes keep advancing while failed script transforms freeze")
        @MainActor
        func authoredAnimationSurvivesScriptFailClose() {
            var authoredA = WPEMetalSceneRenderer.LiveScriptTransforms()
            authoredA.origins = [
                "authored-only": SIMD3<Double>(1, 0, 0),
                "script-owned": SIMD3<Double>(2, 0, 0),
            ]
            var authoredB = authoredA
            authoredB.origins["authored-only"] = SIMD3<Double>(3, 0, 0)
            authoredB.origins["script-owned"] = SIMD3<Double>(4, 0, 0)
            var frozenScript = WPEMetalSceneRenderer.LiveScriptTransforms()
            frozenScript.origins["script-owned"] = SIMD3<Double>(99, 0, 0)

            let first = WPEMetalSceneRenderer.LiveScriptTransforms.resolving(
                authored: authoredA,
                script: frozenScript
            )
            let second = WPEMetalSceneRenderer.LiveScriptTransforms.resolving(
                authored: authoredB,
                script: frozenScript
            )
            #expect(first.origins["authored-only"] == SIMD3<Double>(1, 0, 0))
            #expect(second.origins["authored-only"] == SIMD3<Double>(3, 0, 0))
            #expect(first.origins["script-owned"] == SIMD3<Double>(99, 0, 0))
            #expect(second.origins["script-owned"] == SIMD3<Double>(99, 0, 0))
        }

        @Test("Setup capacity failure latches the scene and keeps later families closed")
        @MainActor
        func setupCapacitySceneLatch() throws {
            let governor = WPESceneScriptExecutionGovernor(limit: 1)
            let blocker = governor.makeParticipant()
            let held = try #require(governor.tryAcquireUnreserved(for: blocker))
            defer { held.release() }
            let token = preparedToken(generation: 5)
            let shared = WPESharedScriptState(sceneScriptLoadToken: token)

            #expect(throws: WPESceneScriptError.capacityUnavailable(operation: .setup)) {
                _ = try WPESceneScriptInstance(
                    script: "export function update(value) { return value; }",
                    initialValue: "baked",
                    shared: shared,
                    setupBudget: 0.001,
                    governor: governor
                )
            }
            #expect(token.failureReason == .capacityUnavailable(operation: .setup))
            #expect(!token.acceptsCompletion())
            expectEveryOperationRejected(by: token)
        }

        private func preparedToken(
            generation: Int,
            inventory: WPESceneScriptInstanceInventory = .init(text: 0, layer: 0, transform: 0)
        ) -> WPESceneScriptInstanceLimitToken {
            let token = WPESceneScriptInstanceLimitToken(generation: generation)
            #expect(token.prepare(inventory))
            return token
        }

        private func expectEveryOperationRejected(
            by token: WPESceneScriptInstanceLimitToken
        ) {
            for operation in WPESceneScriptOperation.allCases {
                #expect(!token.allows(operation))
            }
            #expect(!token.acceptsCompletion())
        }

        private static func createdLayerScript(count: Int) -> String {
            """
            export function init() {
                for (let index = 0; index < \(count); index++) {
                    thisScene.createLayer({ image: "created.png" });
                }
            }
            export function update() {}
            """
        }

        private static func videoCommandScript(count: Int) -> String {
            """
            export function init() {
                const video = thisLayer.getVideoTexture();
                for (let index = 0; index < \(count); index++) video.play();
            }
            export function update() {}
            """
        }

        private static func layerOutput(
            commands: [WPELayerVideoCommand]
        ) -> WPELayerScriptOutput {
            WPELayerScriptOutput(
                own: WPELayerScriptState(
                    visible: true,
                    alpha: 1,
                    videoCommands: commands
                ),
                others: [:]
            )
        }
    }
#endif
