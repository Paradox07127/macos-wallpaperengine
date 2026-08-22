import Foundation
@testable import LiveWallpaper
import Testing

struct WPESceneScriptContainmentCharacterizationTests {
    // MARK: - Current production boundaries (source only, zero JS execution)

    @Test("Production post-fix: four evaluators retain serial queues and bounded engines share global admission")
    func productionEvaluatorsUseGlobalAdmission() throws {
        // The scene-script subsystem lives in two files since the layer-script
        // engine was split out; these counts are contracts on the subsystem, not
        // on one file, so both halves are read together.
        let runtime = try RR10ProductionSource.combined([
            "LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift",
            "LiveWallpaper/Runtime/Scene/WPELayerScriptRuntime.swift",
        ])

        // The parse-time evaluator still owns a private queue; the three
        // per-object engines take theirs from the batch dispatcher. That is what
        // keeps "one context, one queue" true while a frame costs one dispatch
        // per worker instead of one per script.
        #expect(RR10ProductionSource.occurrences(
            of: "com.livewallpaper.wpe-transform-evaluator",
            in: runtime
        ) == 1)
        #expect(RR10ProductionSource.occurrences(
            of: "let lane = batchDispatcher.reserveLane()",
            in: runtime
        ) == 3)
        #expect(RR10ProductionSource.occurrences(
            of: "governor.makeParticipant()",
            in: runtime
        ) == 4)
        // Scene, layer, and dynamic-transform engines deliberately share one
        // bounded synchronous runner. Protect the extraction and every
        // operation-specific admission policy instead of counting the three
        // formerly duplicated governor call sites.
        #expect(RR10ProductionSource.occurrences(
            of: "func runWithBudget<T>(",
            in: runtime
        ) == 1)
        #expect(RR10ProductionSource.occurrences(
            of: "@unchecked Sendable, WPESceneScriptEngineExecutionGuarding",
            in: runtime
        ) == 3)
        #expect(RR10ProductionSource.occurrences(
            of: "return runWithBudget(",
            in: runtime
        ) == 11)
        #expect(RR10ProductionSource.occurrences(
            of: "return runWithBudget(budget, operation: .setup, admission: .waitUntilDeadline)",
            in: runtime
        ) == 3)
        #expect(RR10ProductionSource.occurrences(
            of: "return runWithBudget(budget, operation: .tick, admission: .failFast)",
            in: runtime
        ) == 3)
        #expect(RR10ProductionSource.occurrences(
            of: "return runWithBudget(budget, operation: .event, admission: .failFast)",
            in: runtime
        ) == 1)
        #expect(RR10ProductionSource.occurrences(
            of: "return runWithBudget(budget, operation: .userProperties, admission: .waitUntilDeadline)",
            in: runtime
        ) == 1)
        #expect(RR10ProductionSource.occurrences(
            of: "governor: WPESceneScriptExecutionGovernor = .processShared",
            in: runtime
        ) == 4)
        // The fourth evaluator intentionally keeps a distinct synchronous
        // implementation, but it must still use the same global governor and
        // one deadline for blocking admission.
        #expect(RR10ProductionSource.occurrences(
            of: "guard let permit = governor.acquire(for: participant, until: deadline) else {",
            in: runtime
        ) == 1)

        let extensionStart = try #require(runtime.range(
            of: "extension WPESceneScriptEngineExecutionGuarding {"
        ))
        let resultBoxStart = try #require(runtime.range(
            of: "private final class WPESceneScriptResultBox",
            range: extensionStart.upperBound ..< runtime.endIndex
        ))
        let sharedRunner = String(
            runtime[extensionStart.lowerBound ..< resultBoxStart.lowerBound]
        )
        for requiredSeam in [
            "WPESceneScriptExecutionSafetyReservation.reserve(",
            "case .failFast:",
            "governor.tryAcquireUnreserved(for: participant)",
            "case .waitUntilDeadline:",
            "governor.acquire(for: participant, until: deadline)",
            "guard DispatchTime.now() < deadline else",
            "queue.async {",
            "safety.complete()",
            "permit.release()",
            "done.signal()",
            "done.wait(timeout: deadline)",
            "safety.quarantine(self, operation: operation)",
            "instanceLimitToken?.failClosed(.executionTimedOut(operation: operation))",
        ] {
            #expect(sharedRunner.contains(requiredSeam))
        }
        #expect(RR10ProductionSource.occurrences(
            of: "asyncOutcomeSlot.rejectTick(claim)",
            in: runtime
        ) >= 3)
        #expect(runtime.contains("case capacityUnavailable(operation: WPESceneScriptOperation)"))
    }

    // `asyncExecutionSafety.begin` parks its reservation in a one-slot owner,
    // so an attempt the governor refuses must be released through that owner.
    // Releasing only the reservation leaves the slot armed: every later begin()
    // on that engine is refused, and quarantineIfOverdue then charges the stale
    // start time to an engine that never ran. Regression from ed51b687.
    @Test("Production post-fix: refused async attempts release the dispatch slot through its owner")
    func productionAsyncRejectionReleasesThroughOwner() throws {
        // The scene-script subsystem lives in two files since the layer-script
        // engine was split out; these counts are contracts on the subsystem, not
        // on one file, so both halves are read together.
        let runtime = try RR10ProductionSource.combined([
            "LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift",
            "LiveWallpaper/Runtime/Scene/WPELayerScriptRuntime.swift",
        ])

        #expect(RR10ProductionSource.occurrences(
            of: "                safety.complete()\n                return false",
            in: runtime
        ) == 0)
        // Only the cursor-event path still refuses an attempt after reserving:
        // batch ticks reserve inside the worker closure, so a refusal there
        // releases through the same owner in the `slot.rejectTick` branch.
        #expect(RR10ProductionSource.occurrences(
            of: "                asyncExecutionSafety.complete(safety)\n                return false",
            in: runtime
        ) == 1)
        // The synchronous runner owns its reservation outright and must keep
        // releasing it directly; this pins the two forms apart.
        #expect(RR10ProductionSource.occurrences(
            of: "            safety.complete()\n            return .capacityUnavailable",
            in: runtime
        ) == 1)
    }

    @Test("Production post-fix: non-frame operations cannot fabricate traversal challenges")
    func productionNonFrameAdmissionStrategyIsExplicit() throws {
        // The scene-script subsystem lives in two files since the layer-script
        // engine was split out; these counts are contracts on the subsystem, not
        // on one file, so both halves are read together.
        let runtime = try RR10ProductionSource.combined([
            "LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift",
            "LiveWallpaper/Runtime/Scene/WPELayerScriptRuntime.swift",
        ])

        #expect(runtime.contains("admission: .failFast"))
        #expect(runtime.contains("guard let permit = governor.tryAcquireUnreserved(for: participant)"))
        #expect(RR10ProductionSource.occurrences(
            of: "admission: .waitUntilDeadline",
            in: runtime
        ) >= 4)
        #expect(runtime.contains("governor.acquire(for: participant, until: deadline)"))
    }

    @Test("Production B2b: frame watchdog quarantines async overrun without per-tick timers")
    func productionAsyncOverrunUsesSharedOwner() throws {
        // The scene-script subsystem lives in two files since the layer-script
        // engine was split out; these counts are contracts on the subsystem, not
        // on one file, so both halves are read together.
        let runtime = try RR10ProductionSource.combined([
            "LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift",
            "LiveWallpaper/Runtime/Scene/WPELayerScriptRuntime.swift",
        ])
        let resources = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Scene/WPESceneScriptResourceBudget.swift"
        )

        // One per script family's frame-tick entry point (`batchTick*`): each
        // probes the watchdog instead of arming a per-tick timer.
        #expect(RR10ProductionSource.occurrences(
            of: "engine.quarantineAsyncIfOverdue(budget: tickBudget)",
            in: runtime
        ) == 3)
        #expect(resources.contains("final class WPESceneScriptAsyncExecutionSafety"))
        #expect(!resources.contains("asyncAfter"))
    }

    @Test("B2a production load captures and threads one exact token")
    func productionRendererThreadsExactLoadToken() throws {
        let renderer = try RR10ProductionSource.combined([
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Scripts.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Text.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptContainment.swift",
        ])

        for seam in [
            "sceneScriptLoadState.begin(generation: generation)",
            "performLoad(scriptLoadToken: scriptLoadToken, on: actor)",
            "WPESceneScriptInstanceInventory(document: document)",
            "scriptLoadToken.prepare(scriptInventory)",
            "checkCurrentSceneScriptLoad(scriptLoadToken)",
            "sceneScriptLoadToken: scriptLoadToken",
            "constructSceneScript(for: scriptLoadToken",
            "sceneScriptLoadState.retire(scriptLoadToken)",
        ] {
            #expect(renderer.contains(seam))
        }
        let prepareRange = try #require(renderer.range(of: "scriptLoadToken.prepare(scriptInventory)"))
        let firstRuntimeRange = try #require(renderer.range(of: "try WPELayerScriptInstance("))
        #expect(prepareRange.lowerBound < firstRuntimeRange.lowerBound)
    }

    @Test("B2a reload cleanup and failed load clear every runtime family")
    func productionLifecycleClearsAllScriptRuntimeFamilies() throws {
        let load = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift"
        )
        let lifecycle = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift"
        )
        let seam = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptContainment.swift"
        )
        // The owned-failure branch tears the whole partial scene down rather
        // than clearing scripts alone: `retireRuntimeState` is what reaches the
        // script runtime families, and it also collects the textures, decoders
        // and particle buffers `performLoad` had already published. The branch
        // itself is the invariant — an un-owned failure belongs to a newer load,
        // whose resources must survive.
        #expect(load.contains("let ownedFailedLoad = isCurrentSceneScriptLoad(scriptLoadToken)"))
        #expect(load.contains("if ownedFailedLoad {"))
        #expect(RR10ProductionSource.occurrences(of: "await retireRuntimeState(on: actor)", in: load) == 1)
        #expect(RR10ProductionSource.occurrences(of: "clearSceneScriptRuntimeState()", in: lifecycle) == 2)
        for dictionary in [
            "textScriptInstances", "layerScriptInstances", "layerAlphaScriptInstances",
            "textVisibleScriptInstances", "textAlphaScriptInstances",
            "dynamicOriginScriptInstances", "dynamicScaleScriptInstances",
            "dynamicAnglesScriptInstances", "dynamicColorScriptInstances",
            "sharedOriginReadFans", "sharedScaleReadFans",
            "sharedAnglesReadFans", "sharedColorReadFans",
            "sharedEffectConstantReadFans",
            "liveLayerVisibility", "liveTextVisibility",
            "liveLayerAlpha", "liveTextAlpha", "liveCreatedLayers",
        ] {
            #expect(seam.contains("\(dictionary).removeAll(keepingCapacity: false)"))
        }
    }

    @Test("B2b load video commit requires its exact current completion token")
    func productionLoadCommitRequiresExactCurrentToken() throws {
        let load = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift"
        )
        let owner = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )
        let finishAnchor = try #require(owner.range(of: "func finishSceneScriptLoadVideoCommands("))
        let prepareAnchor = try #require(owner.range(of: "func prepareSceneScriptsForFirstFrame("))
        let finishRegion = String(owner[finishAnchor.lowerBound ..< prepareAnchor.lowerBound])
        let prepareRegion = String(owner[prepareAnchor.lowerBound...])

        #expect(load.contains("var scriptsAreBaked = resetSceneScriptsToBakedIfFailed(scriptLoadToken)"))
        #expect(load.contains("try finishSceneScriptLoadVideoCommands("))
        #expect(load.contains("prepareSceneScriptsForFirstFrame("))
        #expect(load.contains("await shaderWarm"))
        let loadCommit = try #require(load.range(of: "try finishSceneScriptLoadVideoCommands("))
        let firstRender = try #require(load.range(of: "outputTexture = try renderCurrentFrame(inputs: makeFrameInputs())"))
        let firstFrameRegion = String(load[loadCommit.lowerBound ..< firstRender.upperBound])
        let shaderAwait = try #require(firstFrameRegion.range(of: "await shaderWarm"))
        let currentCheck = try #require(
            firstFrameRegion.range(of: "try checkCurrentSceneScriptLoad(scriptLoadToken)")
        )
        let prepare = try #require(firstFrameRegion.range(of: "prepareSceneScriptsForFirstFrame("))
        let render = try #require(firstFrameRegion.range(of: "outputTexture = try renderCurrentFrame(inputs: makeFrameInputs())"))
        #expect(shaderAwait.lowerBound < currentCheck.lowerBound)
        #expect(currentCheck.lowerBound < prepare.lowerBound)
        #expect(prepare.lowerBound < render.lowerBound)
        #expect(finishRegion.contains("finishSceneScriptVideoCommands(for: scriptLoadToken)"))
        #expect(finishRegion.contains("guard isCurrentSceneScriptLoad(scriptLoadToken),"))
        #expect(finishRegion.contains("scriptLoadToken.failureReason != nil,"))
        #expect(finishRegion.contains("resetSceneScriptsToBakedIfFailed(scriptLoadToken) else"))
        #expect(finishRegion.contains("throw CancellationError()"))
        #expect(prepareRegion.contains("resetSceneScriptsToBakedIfFailed(scriptLoadToken)"))
        #expect(RR10ProductionSource.occurrences(
            of: "resetSceneScriptsToBakedIfFailed(scriptLoadToken)",
            in: load + owner
        ) >= 3)
    }

    @Test("B2b player mutations and phase alignment share one linearized commit")
    func productionPlayerMutationIsLinearizedCommitOnly() throws {
        let frame = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let scripts = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Scripts.swift"
        )
        let failClose = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )
        let nonCommitSources = try RR10ProductionSource.combined([
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Scripts.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptContainment.swift",
        ])

        #expect(frame.contains("stageIntroPhaseAlign()"))
        #expect(!frame.contains("updateIntroPhaseAlign()"))
        #expect(!scripts.contains("alignPlayhead"))
        for mutation in [
            ".scriptPlay()", ".scriptPause()", ".scriptStop()",
            ".scriptSetCurrentTime(seconds)", ".alignPlayhead(to: target)",
        ] {
            #expect(failClose.contains(mutation))
            #expect(!nonCommitSources.contains(mutation))
        }

        let authorization = try #require(failClose.range(of: "let committed = authorize {"))
        let rejection = try #require(failClose.range(of: "if !committed {"))
        let authorizedRegion = String(failClose[authorization.lowerBound ..< rejection.lowerBound])
        #expect(authorizedRegion.contains("sceneScriptVideoCommandBuffer.finish(commit: true)"))
        #expect(authorizedRegion.contains("video.scriptPlay()"))
        #expect(authorizedRegion.contains("updateIntroPhaseAlign()"))
        #expect(failClose.contains("sceneScriptLoadState.withCurrentCompletionPermission(commit)"))
        #expect(failClose.contains("sceneScriptLoadState.withCompletionPermission("))
        #expect(failClose.contains("for: scriptLoadToken"))
        #expect(failClose.contains("discardSceneScriptVideoCommands()"))
        #expect(RR10ProductionSource.occurrences(of: "updateIntroPhaseAlign()", in: failClose) == 2)
    }

    @Test("B2b Frame property and Load route through completion permission")
    func productionCommitPathsUseCompletionPermission() throws {
        let containment = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Scene/WPESceneScriptContainment.swift"
        )
        let frame = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let lifecycle = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Lifecycle.swift"
        )
        let load = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Load.swift"
        )
        let failClose = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )

        #expect(containment.contains("func withCompletionPermission("))
        #expect(containment.contains("func withCurrentCompletionPermission("))
        #expect(containment.contains("guard !state.isRetired, state.failureReason == nil"))
        #expect(containment.contains("guard current === token,"))
        #expect(containment.contains("return try token.withCompletionPermission(commit)"))
        #expect(frame.contains("return try finishSceneScriptFrame("))
        #expect(failClose.contains("if videoCommandsOutcome ?? finishCurrentSceneScriptVideoCommands() {"))
        #expect(lifecycle.contains("&& finishCurrentSceneScriptVideoCommands()"))
        #expect(load.contains("try finishSceneScriptLoadVideoCommands("))
        #expect(failClose.contains("finishSceneScriptVideoCommands(for: scriptLoadToken)"))

        let rendererCommitSources = frame + lifecycle + load
        #expect(!rendererCommitSources.contains("finishSceneScriptVideoCommands(commit: true)"))
        #expect(!rendererCommitSources.contains("finishSceneScriptVideoCommands(commit: scriptsSucceeded)"))
        #expect(!rendererCommitSources.contains("commit: sceneScriptLoadState.currentFailureReason == nil"))
    }

    @Test("B2b denied frame commit rolls back and never returns its speculative frame")
    func failedFrameRollbackOracle() throws {
        let frame = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let owner = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )
        let encode = try #require(frame.range(of: "let frame = try encodeSceneFrame("))
        let finish = try #require(frame.range(of: "return try finishSceneScriptFrame("))
        let ownerAnchor = try #require(owner.range(of: "func finishSceneScriptFrame("))
        let ownerEnd = try #require(owner.range(of: "func updateParticleHostOriginOffsets("))
        let ownerRegion = String(owner[ownerAnchor.lowerBound ..< ownerEnd.lowerBound])
        let success = try #require(ownerRegion.range(of: "if videoCommandsOutcome ?? finishCurrentSceneScriptVideoCommands() {"))
        let denial = try #require(ownerRegion.range(of: "invalidateIntroPhaseAlign()"))
        let denialRegion = String(ownerRegion[denial.lowerBound...])
        let rollback = try #require(denialRegion.range(of: "restoreSceneScriptPresentation(publicationBeforeFrame.presentation)"))
        let fallback = try #require(denialRegion.range(of: "let stableFrame = try encodeSceneFrame("))
        #expect(encode.lowerBound < finish.lowerBound)
        #expect(success.lowerBound < denial.lowerBound)
        #expect(rollback.lowerBound < fallback.lowerBound)
        #expect(frame.contains("discardSceneScriptVideoCommands()"))
        #expect(frame.contains("let publicationBeforeFrame = captureSceneScriptFramePublication()"))
        #expect(owner.contains("stableTransforms: lastStableScriptTransforms"))
        #expect(owner.contains("stableTextByID: lastStableScriptTextByID"))
        #expect(owner.contains("lastFramePipeline: lastFramePipeline"))
        #expect(denialRegion.contains("lastStableScriptTransforms = publicationBeforeFrame.stableTransforms"))
        #expect(denialRegion.contains("lastStableScriptTextByID = publicationBeforeFrame.stableTextByID"))
        #expect(denialRegion.contains("lastFramePipeline = publicationBeforeFrame.lastFramePipeline"))
        #expect(denialRegion.contains("guard let failure = sceneScriptLoadState.currentFailureReason else"))
        #expect(denialRegion.contains("throw CancellationError()"))
        #expect(denialRegion.contains("updateParticleHostOriginOffsets(using: stableTransforms)"))
        #expect(denialRegion.contains("return stableFrame"))
        #expect(!denialRegion.contains("return speculativeFrame"))

        let knownFailure = try #require(ownerRegion.range(of: "if failureBeforeFrame != nil {"))
        let commitStart = try #require(ownerRegion.range(of: "if videoCommandsOutcome ?? finishCurrentSceneScriptVideoCommands() {"))
        let knownFailureRegion = String(ownerRegion[knownFailure.lowerBound ..< commitStart.lowerBound])
        #expect(knownFailureRegion.contains("discardSceneScriptVideoCommands()"))
        #expect(knownFailureRegion.contains("return speculativeFrame"))

        let particleTick = try #require(frame.range(of: "private func tickParticleSystems("))
        let particleTickRegion = String(frame[particleTick.lowerBound...])
        #expect(particleTickRegion.contains("updateParticleHostOriginOffsets(using: liveTransforms)"))
        #expect(!particleTickRegion.contains("system.hostOriginOffset = .zero"))
        #expect(owner.contains("system.hostOriginOffset = .zero"))
        #expect(owner.contains("system.hostOriginOffset += SIMD2<Float>("))

        var productionBuffer = WPESceneScriptVideoCommandBuffer()
        productionBuffer.begin()
        productionBuffer.enqueue([.seek(7.5)], objectID: "loop")
        #expect(productionBuffer.finish(commit: false).isEmpty)
        #expect(!productionBuffer.isTransactionActive)
        #expect(productionBuffer.pending.isEmpty)
    }

    @Test("B2b failed or retired setup invalidates phase measurement identity")
    func productionPhaseMeasurementCannotPublishAfterReset() throws {
        let phase = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptFailClose.swift"
        )
        let containment = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+ScriptContainment.swift"
        )
        let renderActorSource = try RR10ProductionSource.read(
            "LiveWallpaper/Runtime/Metal/RenderThread/WPEDisplayRenderActor.swift"
        )
        #expect(phase.contains("await actor.applyIntroLoopOffset(offset, token: token, scriptLoadToken: scriptLoadToken)"))
        #expect(renderActorSource.contains("renderer.introPhaseToken == token"))
        #expect(renderActorSource.contains("renderer.isCurrentSceneScriptLoad(scriptLoadToken)"))
        #expect(phase.contains("introPhaseToken &+= 1"))
        #expect(containment.contains("invalidateIntroPhaseAlign()"))
    }

    @Test("B2b failure before completion permission produces zero side effects")
    func failureBeforeCompletionPermissionRejectsCommit() {
        let state = WPESceneScriptLoadState()
        let token = state.begin(generation: 401)
        #expect(token.prepare(.init(text: 0, layer: 1, transform: 0)))
        #expect(token.failClosed(.executionTimedOut(operation: .tick)))
        var sideEffects = 0

        #expect(!state.withCurrentCompletionPermission { sideEffects += 1 })
        #expect(!state.withCompletionPermission(for: token) { sideEffects += 1 })
        #expect(sideEffects == 0)
    }

    @Test("B2b completion holding permission linearizes before concurrent fail-close")
    func completionPermissionLinearizesConcurrentFailure() throws {
        let state = WPESceneScriptLoadState()
        let token = state.begin(generation: 402)
        #expect(token.prepare(.init(text: 0, layer: 1, transform: 0)))
        let commitBlocker = RR10ControlledBlocker()
        let queue = DispatchQueue(
            label: "com.livewallpaper.tests.rr10-completion-linearization",
            attributes: .concurrent
        )
        let commitAccepted = RR10LockedValue<Bool?>(nil)
        let failureAccepted = RR10LockedValue<Bool?>(nil)
        let sideEffects = RR10LockedValue(0)
        let order = RR10LockedValue<[String]>([])
        let failureStarted = DispatchSemaphore(value: 0)
        let failureFinished = DispatchGroup()
        failureFinished.enter()
        defer { commitBlocker.release() }

        queue.async {
            let accepted = state.withCompletionPermission(for: token) {
                commitBlocker.run()
                sideEffects.modify { $0 += 1 }
                order.modify { $0.append("commit") }
            }
            commitAccepted.set(accepted)
            commitBlocker.markFinished()
        }
        try #require(commitBlocker.waitUntilEntered())

        let reason = WPESceneScriptFailClosedReason.executionTimedOut(operation: .tick)
        queue.async {
            failureStarted.signal()
            failureAccepted.set(token.failClosed(reason))
            order.modify { $0.append("fail") }
            failureFinished.leave()
        }
        try #require(failureStarted.wait(timeout: .now() + 2) == .success)
        commitBlocker.release()
        try #require(commitBlocker.waitUntilFinished())
        try #require(failureFinished.wait(timeout: .now() + 2) == .success)

        #expect(commitAccepted.value == true)
        #expect(failureAccepted.value == true)
        #expect(sideEffects.value == 1)
        #expect(order.value == ["commit", "fail"])
        #expect(token.failureReason == reason)
        #expect(!commitBlocker.hitHardDeadline)
    }

    @Test("B2b retired and superseded identities receive zero completion effects")
    func retiredAndSupersededCompletionIsRejected() {
        let state = WPESceneScriptLoadState()
        let old = state.begin(generation: 403)
        #expect(old.prepare(.init(text: 0, layer: 1, transform: 0)))
        let replacement = state.begin(generation: 404)
        #expect(replacement.prepare(.init(text: 0, layer: 1, transform: 0)))
        var sideEffects = 0

        #expect(!state.withCompletionPermission(for: old) { sideEffects += 1 })
        state.retire(replacement)
        #expect(!state.withCompletionPermission(for: replacement) { sideEffects += 1 })
        #expect(!state.withCurrentCompletionPermission { sideEffects += 1 })
        #expect(sideEffects == 0)
    }

    @Test("Production post-fix: late async completions use the scene publish gate")
    func productionLateCompletionGateIsWiredAcrossRuntimeFamilies() throws {
        // The scene-script subsystem lives in two files since the layer-script
        // engine was split out; these counts are contracts on the subsystem, not
        // on one file, so both halves are read together.
        let runtime = try RR10ProductionSource.combined([
            "LiveWallpaper/Runtime/Scene/WPESceneScriptRuntime.swift",
            "LiveWallpaper/Runtime/Scene/WPELayerScriptRuntime.swift",
        ])

        // `self.` in the cursor-event closure, bare in the three batch workers.
        #expect(RR10ProductionSource.occurrences(
            of: "guard self.acceptsCompletion() else",
            in: runtime
        ) >= 1)
        #expect(RR10ProductionSource.occurrences(
            of: "guard acceptsCompletion() else",
            in: runtime
        ) == 3)
        #expect(RR10ProductionSource.occurrences(
            of: "slot.rejectTick(claim)",
            in: runtime
        ) >= 3)
    }

    // MARK: - Production primitive behavior

    @Test("Containment defaults are conservative and explicitly policy-bound")
    func containmentDefaultsAreConservative() {
        #expect((1 ... 8).contains(WPESceneScriptContainmentDefaults.maximumConcurrentEvaluations))
        #expect(WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene <= 128)
        #expect(WPESceneScriptContainmentDefaults.maximumVideoCommandsPerEvaluation <= 512)
        #expect(WPESceneScriptContainmentDefaults.maximumSharedStateEntries <= 2048)
        #expect(WPESceneScriptContainmentDefaults.maximumQuarantinedEngines <= 32)
    }

    @Test("B2a a script-heavy scene constructs every runtime — there is no count cap")
    func sceneRuntimeInventoryHasNoInstanceCap() throws {
        // 2955378002 has 676 bindings and used to be failed closed by the cap.
        // Binding count alone does not predict runtime cost, so this characterization
        // pins only the no-cap construction contract.
        let state = WPESceneScriptLoadState()
        let heavy = WPESceneScriptInstanceInventory(text: 300, layer: 200, transform: 176)
        #expect(heavy.total == 676)
        let accepted = state.begin(generation: 1)
        #expect(accepted.prepare(heavy))
        var attempts = 0
        for _ in 0 ..< heavy.total {
            _ = try #require(accepted.withConstructionPermission { attempts += 1 })
        }
        #expect(attempts == 676)
        #expect(accepted.failureReason == nil)
    }

    @Test("Re-preparing an already-prepared load is still refused")
    func sceneRuntimeInventoryRejectsSecondPrepare() throws {
        let state = WPESceneScriptLoadState()
        let token = state.begin(generation: 1)
        #expect(token.prepare(.init(text: 4, layer: 4, transform: 4)))
        #expect(!token.prepare(.init(text: 1, layer: 0, transform: 0)))
    }

    @Test("Retired interleaved load cannot prepare construct or publish into fresh load")
    func sceneRuntimeLateCompletionAndLifecycleReset() throws {
        let state = WPESceneScriptLoadState()
        let old = state.begin(generation: 1)
        #expect(old.prepare(.init(text: 1, layer: 0, transform: 0)))
        let fresh = state.begin(generation: 2)
        #expect(!state.isCurrent(old))
        #expect(!old.prepare(.init(text: 0, layer: 1, transform: 0)))
        var oldAttempts = 0
        _ = old.withConstructionPermission { oldAttempts += 1 }
        #expect(oldAttempts == 0)
        #expect(!old.acceptsCompletion())
        #expect(fresh.prepare(.init(text: 0, layer: 0, transform: 1)))
        #expect(state.isCurrent(fresh))
        state.retire(fresh)
        #expect(!state.isCurrent(fresh))
        #expect(!fresh.acceptsCompletion())
    }

    @Test("Permit release is idempotent and deinit is a fail-safe")
    func permitLifetimeIsSafe() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let participant = governor.makeParticipant()
        let explicit = try #require(governor.tryAcquireUnreserved(for: participant))
        #expect(governor.tryAcquireUnreserved(for: participant) == nil)

        explicit.release()
        explicit.release()
        #if DEBUG
            #expect(governor.debugSnapshot.active == 0)
        #endif

        var failSafe: WPESceneScriptExecutionGovernor.Permit?
        do {
            let acquired = try #require(
                governor.tryAcquireUnreserved(for: participant)
            )
            failSafe = acquired
        }
        #if DEBUG
            #expect(governor.debugSnapshot.active == 1)
        #endif
        failSafe = nil
        #expect(failSafe == nil)
        #if DEBUG
            #expect(governor.debugSnapshot.active == 0)
        #endif
    }

    @Test("Global governor holds N permits until workers really return")
    func globalGovernorBoundsWorkers() throws {
        let governor = WPESceneScriptExecutionGovernor(
            limit: 2
        )
        let harness = RR10PermitWorkerHarness(
            governor: governor,
            queue: DispatchQueue(
                label: "com.livewallpaper.tests.rr10-governor.limit-two",
                attributes: .concurrent
            )
        )
        let first = RR10ControlledBlocker()
        let second = RR10ControlledBlocker()
        let third = RR10ControlledBlocker()
        let firstParticipant = governor.makeParticipant()
        let secondParticipant = governor.makeParticipant()
        let thirdParticipant = governor.makeParticipant()
        var firstStarted = false
        var secondStarted = false
        var thirdStarted = false
        defer {
            first.release()
            second.release()
            third.release()
            if firstStarted {
                _ = first.waitUntilFinished()
            }
            if secondStarted {
                _ = second.waitUntilFinished()
            }
            if thirdStarted {
                _ = third.waitUntilFinished()
            }
        }

        firstStarted = harness.trySchedule(
            first.run,
            participant: firstParticipant,
            onFinish: first.markFinished
        )
        secondStarted = harness.trySchedule(
            second.run,
            participant: secondParticipant,
            onFinish: second.markFinished
        )
        #expect(firstStarted)
        #expect(secondStarted)
        try #require(first.waitUntilEntered())
        try #require(second.waitUntilEntered())

        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 2,
                peak: 2,
                permitsGranted: 2,
                waitingParticipants: 0
            ))
        #endif
        let thirdAdmittedWhileFull = harness.trySchedule(
            {},
            participant: thirdParticipant,
            onFinish: {}
        )
        #expect(!thirdAdmittedWhileFull)
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 2,
                peak: 2,
                permitsGranted: 2,
                waitingParticipants: 0
            ))
        #endif
        #expect(harness.workersStarted == 2)

        first.release()
        try #require(first.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot.active == 1)
        #endif

        thirdStarted = harness.trySchedule(
            third.run,
            participant: thirdParticipant,
            onFinish: third.markFinished
        )
        #expect(thirdStarted)
        try #require(third.waitUntilEntered())
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 2,
                peak: 2,
                permitsGranted: 3,
                waitingParticipants: 0
            ))
        #endif

        second.release()
        third.release()
        try #require(second.waitUntilFinished())
        try #require(third.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 0,
                peak: 2,
                permitsGranted: 3,
                waitingParticipants: 0
            ))
        #endif
        #expect(harness.workersStarted == 3)
        #expect(!first.hitHardDeadline)
        #expect(!second.hitHardDeadline)
        #expect(!third.hitHardDeadline)
    }

    @Test("Blocking deadline removes opportunistic and blocking waiters")
    func mixedAdmissionDeadlineLeavesNoOrphan() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let holder = governor.makeParticipant()
        let blocking = governor.makeParticipant()
        let heldPermit = try #require(governor.tryAcquireUnreserved(for: holder))

        #expect(governor.acquire(for: blocking, until: .now() + 0.01) == nil)
        #if DEBUG
            #expect(governor.debugSnapshot == .init(
                active: 1,
                peak: 1,
                permitsGranted: 1,
                waitingParticipants: 0
            ))
        #endif

        heldPermit.release()
        let recovered = try #require(governor.tryAcquireUnreserved(for: blocking))
        recovered.release()
        #if DEBUG
            #expect(governor.debugSnapshot.waitingParticipants == 0)
        #endif
    }

    @Test("Occupied running permit refuses further admission until the worker returns")
    func occupiedPermitRefusesAdmissionUntilWorkerReturns() throws {
        let governor = WPESceneScriptExecutionGovernor(
            limit: 1
        )
        let harness = RR10PermitWorkerHarness(
            governor: governor,
            queue: DispatchQueue(
                label: "com.livewallpaper.tests.rr10-governor.scene-timeout",
                attributes: .concurrent
            )
        )
        let blocker = RR10ControlledBlocker()
        let workerParticipant = governor.makeParticipant()
        let rejectedParticipant = governor.makeParticipant()
        var started = false
        defer {
            blocker.release()
            if started {
                _ = blocker.waitUntilFinished()
            }
        }

        started = harness.trySchedule(
            blocker.run,
            participant: workerParticipant,
            onFinish: blocker.markFinished
        )
        #expect(started)
        try #require(blocker.waitUntilEntered())

        #if DEBUG
            #expect(governor.debugSnapshot.active == 1)
        #endif
        let rejectedAdmitted = harness.trySchedule(
            {},
            participant: rejectedParticipant,
            onFinish: {}
        )
        #expect(!rejectedAdmitted)

        blocker.release()
        try #require(blocker.waitUntilFinished())
        #if DEBUG
            #expect(governor.debugSnapshot.active == 0)
        #endif
        #expect(!blocker.hitHardDeadline)
    }
}

private final class RR10PermitWorkerHarness: @unchecked Sendable {
    private let governor: WPESceneScriptExecutionGovernor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var started = 0

    init(governor: WPESceneScriptExecutionGovernor, queue: DispatchQueue) {
        self.governor = governor
        self.queue = queue
    }

    var workersStarted: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func trySchedule(
        _ work: @escaping @Sendable () -> Void,
        participant: WPESceneScriptExecutionGovernor.Participant,
        onFinish: @escaping @Sendable () -> Void
    ) -> Bool {
        guard let permit = governor.tryAcquireUnreserved(for: participant) else { return false }
        lock.lock()
        started += 1
        lock.unlock()
        queue.async {
            defer {
                permit.release()
                onFinish()
            }
            _ = participant
            work()
        }
        return true
    }
}

private final class RR10ControlledBlocker: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var released = false
    private var didHitHardDeadline = false

    init() {
        completion.enter()
    }

    var hitHardDeadline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didHitHardDeadline
    }

    func run() {
        entered.signal()
        guard releaseSemaphore.wait(timeout: .now() + 2) == .success else {
            lock.lock()
            didHitHardDeadline = true
            lock.unlock()
            return
        }
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseSemaphore.signal()
    }

    func markFinished() {
        completion.leave()
    }

    func waitUntilFinished() -> Bool {
        completion.wait(timeout: .now() + 2) == .success
    }
}

private final class RR10LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func modify(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

private enum RR10ProductionSource {
    static func read(_ repositoryRelativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(repositoryRelativePath),
            encoding: .utf8
        )
    }

    static func combined(_ repositoryRelativePaths: [String]) throws -> String {
        try repositoryRelativePaths.map(read).joined(separator: "\n")
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

/// Objects autoreleased inside a batch job must not outlive the job while the
/// worker stays busy. GCD only guarantees pool drain "at unspecified times"
/// unless the queue was built with `.workItem` — under a 30 fps tick stream the
/// worker rarely idles, so per-tick ObjC temporaries (JSValue boxing in the
/// audio bridge: ~432 buffers × 3 arrays × bands per frame on 2955378002)
/// accumulate for the whole session. Sampled in Release at 6.3 GB (peak 12.5).
@Suite("SceneScript batch queue autorelease drain")
struct WPESceneScriptBatchAutoreleaseTests {

    final class PoolProbe: NSObject {
        nonisolated(unsafe) static var live = 0
        static let lock = NSLock()
        override init() {
            super.init()
            Self.lock.withLock { Self.live += 1 }
        }
        deinit { Self.lock.withLock { Self.live -= 1 } }
    }

    final class LaneReleaseProbe {
        let deinitSignal: DispatchSemaphore

        init(deinitSignal: DispatchSemaphore) {
            self.deinitSignal = deinitSignal
        }

        deinit { deinitSignal.signal() }
    }

    @Test("A busy worker still drains each job's autoreleased objects")
    func busyWorkerDrainsPerJob() async throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let queue = dispatcher.reserveLane().queue
        dispatcher.submit([.init(queue: queue, work: {
            _ = Unmanaged.passRetained(PoolProbe()).autorelease()
        })])
        // Keep the worker continuously busy so its thread never goes idle —
        // the only drain we may rely on is the per-work-item one.
        for _ in 0..<40 {
            dispatcher.submit([.init(queue: queue, work: { usleep(1500) })])
        }
        try await Task.sleep(for: .milliseconds(30))
        let alive = PoolProbe.lock.withLock { PoolProbe.live }
        #expect(alive == 0, "autoreleased job temporaries must drain per work item, got \(alive) alive")
    }

    /// A `JSVirtualMachine` owns a GC heap (~1.15 MB measured), and every engine
    /// used to build its own: 1104 live contexts across two scenes = 1.27 GB,
    /// more than all GPU textures combined. One VM per WORKER is safe because a
    /// lane is serial — JSC serialises contexts sharing a VM, and contexts on
    /// one lane already never run concurrently, so nothing is lost.
    @Test("A worker lane reuses one JSVirtualMachine; separate workers keep separate ones")
    func laneSharesOneVirtualMachinePerWorker() {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 2)
        let lanes = (0 ..< 4).map { _ in dispatcher.reserveLane() }

        // Round-robin: lanes 0 and 2 are the same worker, 1 and 3 the other.
        #expect(lanes[0].queue === lanes[2].queue)
        #expect(lanes[0].virtualMachine === lanes[2].virtualMachine,
                "one worker must reuse its VM instead of paying a GC heap per engine")
        #expect(lanes[1].virtualMachine === lanes[3].virtualMachine)
        #expect(lanes[0].virtualMachine !== lanes[1].virtualMachine,
                "distinct workers run concurrently — sharing a VM would serialise them")
    }

    @Test("Invalidating a wedged lane replaces only its exact generation")
    func invalidatingLaneRotatesGeneration() {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let wedged = dispatcher.reserveLane()

        #expect(wedged.invalidate())
        let replacement = dispatcher.reserveLane()
        #expect(replacement.queue !== wedged.queue)
        #expect(replacement.virtualMachine !== wedged.virtualMachine)
        #expect(!wedged.invalidate(), "a stale timeout must not evict the healthy replacement")

        let sameReplacement = dispatcher.reserveLane()
        #expect(sameReplacement.queue === replacement.queue)
        #expect(sameReplacement.virtualMachine === replacement.virtualMachine)
    }

    @Test("A setup starved behind a blocked lane rotates the lane for the next scene")
    func starvedSetupRecoversOnFreshLaneGeneration() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let blockedLane = dispatcher.reserveLane()
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        dispatcher.submit([.init(queue: blockedLane.queue, work: {
            blockerStarted.signal()
            releaseBlocker.wait()
        })])
        #expect(blockerStarted.wait(timeout: .now() + 1) == .success)
        defer { releaseBlocker.signal() }

        let quarantine = WPESceneScriptQuarantine(limit: 4)
        let failedToken = WPESceneScriptInstanceLimitToken(
            generation: 1,
            executionQuarantine: quarantine
        )
        #expect(failedToken.prepare(.init(text: 1, layer: 0, transform: 0)))
        #expect(throws: WPESceneScriptError.executionTimedOut) {
            _ = try WPESceneScriptInstance(
                script: "export function update(value) { return value; }",
                initialValue: "blocked",
                shared: WPESharedScriptState(sceneScriptLoadToken: failedToken),
                setupBudget: 0.02,
                governor: WPESceneScriptExecutionGovernor(limit: 4),
                batchDispatcher: dispatcher
            )
        }

        let recoveredToken = WPESceneScriptInstanceLimitToken(
            generation: 2,
            executionQuarantine: quarantine
        )
        #expect(recoveredToken.prepare(.init(text: 1, layer: 0, transform: 0)))
        let recovered = try WPESceneScriptInstance(
            script: "export function update(value) { return value + '-ok'; }",
            initialValue: "fresh",
            shared: WPESharedScriptState(sceneScriptLoadToken: recoveredToken),
            setupBudget: 0.5,
            governor: WPESceneScriptExecutionGovernor(limit: 4),
            batchDispatcher: dispatcher
        )
        #expect(recovered.tickString() == "fresh-ok")
    }

    @Test("Dropping a lane-owned engine never destroys it on a blocked caller lane")
    func laneReleaseHandoffIsNonBlocking() {
        let lane = DispatchQueue(label: "test.wpe-script-lane-release")
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let didDeinitialize = DispatchSemaphore(value: 0)
        lane.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        #expect(blockerStarted.wait(timeout: .now() + 1) == .success)

        var holder: WPESceneScriptLaneRelease<LaneReleaseProbe>? =
            WPESceneScriptLaneRelease(
                value: LaneReleaseProbe(deinitSignal: didDeinitialize),
                queue: lane
            )
        holder = nil
        _ = holder // Keep the explicit lifetime transition visible to the optimizer.
        #expect(didDeinitialize.wait(timeout: .now() + 0.02) == .timedOut)

        releaseBlocker.signal()
        #expect(didDeinitialize.wait(timeout: .now() + 1) == .success)
    }
}

@Suite("SceneScript timer containment", .serialized)
struct WPESceneScriptTimerContainmentTests {
    @Test("Timer catch-up overflow explicitly fails the scene closed")
    func callbackLimitFailsClosed() throws {
        let token = WPESceneScriptInstanceLimitToken(generation: 801)
        #expect(token.prepare(.init(text: 1, layer: 0, transform: 0)))
        let shared = WPESharedScriptState(sceneScriptLoadToken: token)
        let instance = try WPESceneScriptInstance(
            script: """
            var callbacks = 0;
            setInterval(function () { callbacks += 1; }, 1);
            export function update(value) { return String(callbacks); }
            """,
            initialValue: "stable",
            shared: shared,
            governor: WPESceneScriptExecutionGovernor(limit: 1),
            batchDispatcher: WPESceneScriptBatchDispatcher(width: 1)
        )

        #expect(instance.tickString(runtimeSeconds: 2) == "stable")
        #expect(token.failureReason == .timerCallbackLimitExceeded(
            limit: 1_024
        ))
    }

    @Test("A retired load generation never executes or publishes its pending timer")
    func retiredGenerationDoesNotFireTimer() throws {
        let loadState = WPESceneScriptLoadState()
        let oldToken = loadState.begin(generation: 901)
        #expect(oldToken.prepare(.init(text: 1, layer: 0, transform: 0)))
        let shared = WPESharedScriptState(sceneScriptLoadToken: oldToken)
        let old = try WPESceneScriptInstance(
            script: """
            setTimeout(function () { shared.staleTimerPublished = true; }, 10);
            export function update(value) { return 'old'; }
            """,
            initialValue: "stable",
            shared: shared,
            governor: WPESceneScriptExecutionGovernor(limit: 1),
            batchDispatcher: WPESceneScriptBatchDispatcher(width: 1)
        )

        let freshToken = loadState.begin(generation: 902)
        #expect(freshToken.prepare(.init(text: 0, layer: 0, transform: 0)))
        #expect(old.tickString(runtimeSeconds: 1) == "stable")
        #expect(shared.get("staleTimerPublished") == nil)
        #expect(oldToken.isRetired)
        #expect(freshToken.failureReason == nil)
    }
}
