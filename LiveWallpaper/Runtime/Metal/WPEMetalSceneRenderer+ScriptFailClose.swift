#if !LITE_BUILD
    import Foundation
    import LiveWallpaperCore
    import LiveWallpaperProWPE
    import Metal

    struct WPESceneScriptPresentationSnapshot {
        let layerVisibility: [String: Bool]
        let textVisibility: [String: Bool]
        let layerAlpha: [String: Double]
        let textAlpha: [String: Double]
        let createdLayers: [String: WPECreatedLayerScriptState]
    }

    struct WPESceneScriptFramePublicationSnapshot {
        let presentation: WPESceneScriptPresentationSnapshot
        let stableTransforms: WPEMetalSceneRenderer.LiveScriptTransforms
        let stableTextByID: [String: String]
        let lastFramePipeline: WPEPreparedRenderPipeline?
        let transformMutationJournal: WPESceneScriptTransformMutationJournal
    }

    extension WPEMetalSceneRenderer {
        func authoredTransformAnimations(at time: Double) -> LiveScriptTransforms {
            var transforms = LiveScriptTransforms()
            transforms.origins.reserveCapacity(dynamicOriginAnimations.count)
            for (objectID, animation) in dynamicOriginAnimations.sorted(by: { $0.key < $1.key }) {
                guard let value = animation.vector(at: time), value.count >= 3 else { continue }
                transforms.origins[objectID] = SIMD3<Double>(value[0], value[1], value[2])
            }
            return transforms
        }

        func captureSceneScriptPresentation() -> WPESceneScriptPresentationSnapshot {
            WPESceneScriptPresentationSnapshot(
                layerVisibility: liveLayerVisibility,
                textVisibility: liveTextVisibility,
                layerAlpha: liveLayerAlpha,
                textAlpha: liveTextAlpha,
                createdLayers: liveCreatedLayers
            )
        }

        func restoreSceneScriptPresentation(
            _ snapshot: WPESceneScriptPresentationSnapshot
        ) {
            liveLayerVisibility = snapshot.layerVisibility
            liveTextVisibility = snapshot.textVisibility
            liveLayerAlpha = snapshot.layerAlpha
            liveTextAlpha = snapshot.textAlpha
            liveCreatedLayers = snapshot.createdLayers
        }

        func captureSceneScriptFramePublication() -> WPESceneScriptFramePublicationSnapshot {
            WPESceneScriptFramePublicationSnapshot(
                presentation: captureSceneScriptPresentation(),
                stableTransforms: lastStableScriptTransforms,
                stableTextByID: lastStableScriptTextByID,
                lastFramePipeline: lastFramePipeline,
                transformMutationJournal: layerTransformMutationJournal
            )
        }

        func finishSceneScriptFrame(
            speculativeFrame: MTLTexture,
            failureBeforeFrame: WPESceneScriptFailClosedReason?,
            publicationBeforeFrame: WPESceneScriptFramePublicationSnapshot,
            basePipeline: WPEPreparedRenderPipeline,
            uniforms: WPEMetalRuntimeUniforms,
            authoredTransforms: LiveScriptTransforms,
            parallaxFrame: WPECameraParallaxFrame,
            frameSubmission: WPEMetalFrameSubmissionLease,
            /// Non-nil when the merged-present wrapper already ran the commit
            /// decision before encoding the present (the continuous async path);
            /// nil on the sync/standalone-present paths, which decide here.
            videoCommandsOutcome: Bool? = nil,
            deferredPresent: WPEMetalRenderExecutor.DeferredPresentEncoder? = nil
        ) throws -> MTLTexture {
            if failureBeforeFrame != nil {
                discardSceneScriptVideoCommands()
                recordSceneFrameForDebug(time: uniforms.time, composite: speculativeFrame)
                return speculativeFrame
            }
            if videoCommandsOutcome ?? finishCurrentSceneScriptVideoCommands() {
                recordSceneFrameForDebug(time: uniforms.time, composite: speculativeFrame)
                return speculativeFrame
            }

            invalidateIntroPhaseAlign()
            restoreSceneScriptPresentation(publicationBeforeFrame.presentation)
            lastStableScriptTransforms = publicationBeforeFrame.stableTransforms
            lastStableScriptTextByID = publicationBeforeFrame.stableTextByID
            lastFramePipeline = publicationBeforeFrame.lastFramePipeline
            layerTransformMutationJournal = publicationBeforeFrame.transformMutationJournal
            guard let failure = sceneScriptLoadState.currentFailureReason else {
                throw CancellationError()
            }
            let stableTransforms = publicationBeforeFrame.transformMutationJournal.applying(
                to: LiveScriptTransforms.resolving(
                    authored: authoredTransforms,
                    script: publicationBeforeFrame.stableTransforms
                ),
                generation: loadGeneration
            )
            let stablePipeline = applyingSceneScriptPresentation(
                to: basePipeline,
                transforms: stableTransforms
            )
            reconcileVideoResidency(stablePipeline)
            updateParticleHostOriginOffsets(using: stableTransforms)
            // The denied speculative buffer committed WITHOUT a present (the
            // wrapper skipped it), so the stable re-encode carries the frame's
            // present — the screen shows the rolled-back content, as the
            // two-buffer path always did.
            let stableFrame = try encodeSceneFrame(
                pipeline: stablePipeline,
                uniforms: uniforms,
                liveTextByID: publicationBeforeFrame.stableTextByID,
                transforms: stableTransforms,
                parallaxFrame: parallaxFrame,
                frameSubmission: frameSubmission,
                deferredPresent: videoCommandsOutcome == false ? deferredPresent : nil
            )
            recordSceneFrameForDebug(time: uniforms.time, composite: stableFrame)
            Logger.warning(
                "Scene \(descriptor.workshopID) discarded a SceneScript frame that failed during commit: \(failure)",
                category: .wpeRender
            )
            return stableFrame
        }

        /// Recomputes only the script/keyframe ancestor delta. Fail-close uses
        /// this after rollback without advancing particle time or emission.
        func updateParticleHostOriginOffsets(using transforms: LiveScriptTransforms) {
            for system in particleSystems {
                system.hostOriginOffset = .zero
                guard !system.hostAncestorIDs.isEmpty, !transforms.origins.isEmpty else { continue }
                for id in system.hostAncestorIDs {
                    // The authored seed is baked into the particle transform;
                    // only the live delta is applied, with Y flipped to Y-up.
                    guard let now = transforms.origins[id],
                          let seed = transformHostLocalTransformsByID[id]?.origin else { continue }
                    system.hostOriginOffset += SIMD2<Float>(
                        Float(now.x - seed.x),
                        Float(seed.y - now.y)
                    )
                }
            }
        }

        func beginSceneScriptVideoCommands() {
            sceneScriptVideoCommandBuffer.begin()
            sceneScriptIntroPhaseAlignPending = false
        }

        func discardSceneScriptVideoCommands() {
            _ = sceneScriptVideoCommandBuffer.finish(commit: false)
            sceneScriptIntroPhaseAlignPending = false
        }

        /// Frame/property traversals commit against whichever exact token is
        /// current at the load-state linearization point.
        @discardableResult
        func finishCurrentSceneScriptVideoCommands() -> Bool {
            finishSceneScriptVideoCommands { commit in
                sceneScriptLoadState.withCurrentCompletionPermission(commit)
            }
        }

        /// Load seeding must additionally prove that its captured token is still
        /// the current identity; it cannot borrow a replacement load's permit.
        @discardableResult
        func finishSceneScriptVideoCommands(
            for scriptLoadToken: WPESceneScriptInstanceLimitToken
        ) -> Bool {
            finishSceneScriptVideoCommands { commit in
                sceneScriptLoadState.withCompletionPermission(
                    for: scriptLoadToken,
                    commit
                )
            }
        }

        func finishSceneScriptLoadVideoCommands(
            for scriptLoadToken: WPESceneScriptInstanceLimitToken,
            scriptsAreBaked: inout Bool
        ) throws {
            if scriptsAreBaked {
                discardSceneScriptVideoCommands()
                return
            }
            guard !finishSceneScriptVideoCommands(for: scriptLoadToken) else { return }
            guard isCurrentSceneScriptLoad(scriptLoadToken),
                  scriptLoadToken.failureReason != nil,
                  resetSceneScriptsToBakedIfFailed(scriptLoadToken) else {
                throw CancellationError()
            }
            scriptsAreBaked = true
        }

        func prepareSceneScriptsForFirstFrame(
            _ scriptLoadToken: WPESceneScriptInstanceLimitToken,
            scriptsAreBaked: inout Bool
        ) {
            if !scriptsAreBaked,
               resetSceneScriptsToBakedIfFailed(scriptLoadToken) {
                scriptsAreBaked = true
            }
            if scriptsAreBaked {
                debugStage("scripts.failClosed", "rendering baked first frame")
            }
        }

        /// The authorization owner invokes `commit` while holding load-state ->
        /// token locks. Buffer finish(true), every AVPlayer mutation, and phase
        /// alignment therefore share one indivisible completion permission.
        private func finishSceneScriptVideoCommands(
            authorizingWith authorize: (_ commit: () -> Void) -> Bool
        ) -> Bool {
            let committed = authorize {
                let bufferedCommands = sceneScriptVideoCommandBuffer.finish(commit: true)
                let shouldAlignIntroPhase = sceneScriptIntroPhaseAlignPending
                sceneScriptIntroPhaseAlignPending = false

                for buffered in bufferedCommands {
                    guard let key = layerVideoSourceKey[buffered.objectID],
                          let video = dynamicTextureSources[key] as? WPEVideoTextureSource else { continue }
                    switch buffered.command {
                    case .play: video.scriptPlay()
                    case .pause: video.scriptPause()
                    case .stop: video.scriptStop()
                    case let .seek(seconds): video.scriptSetCurrentTime(seconds)
                    }
                }
                if shouldAlignIntroPhase {
                    updateIntroPhaseAlign()
                }
            }
            if !committed {
                discardSceneScriptVideoCommands()
            }
            return committed
        }

        func setUpIntroPhaseAlign(
            scripted: [WPESceneImageObject],
            scriptLoadToken: WPESceneScriptInstanceLimitToken
        ) {
            guard Self.introPhaseAlignEnabled,
                  isCurrentSceneScriptLoad(scriptLoadToken),
                  scriptLoadToken.failureReason == nil else { return }
            guard let introKey = scripted.compactMap({ layerVideoSourceKey[$0.id] }).first,
                  let intro = dynamicTextureSources[introKey] as? WPEVideoTextureSource,
                  let introURL = intro.analysisURL else { return }
            let scriptedKeys = Set(scripted.compactMap { layerVideoSourceKey[$0.id] }).union(
                sceneScriptVideoCommandBuffer.pending.compactMap { layerVideoSourceKey[$0.objectID] }
            )
            let loop = layerVideoSourceKey.values
                .filter { !scriptedKeys.contains($0) }
                .compactMap { self.dynamicTextureSources[$0] as? WPEVideoTextureSource }
                .first
            guard let loop, let loopURL = loop.analysisURL else { return }
            introPhaseSource = intro
            loopPhaseSource = loop
            let token = introPhaseToken
            guard let actor = displayActor else { return }
            // Measure off-actor from the (Sendable) URLs, then apply on the actor.
            // `introPhaseToken` is bumped by every reload/invalidate, so a matching
            // token already implies `introPhaseSource`/`loopPhaseSource` are still
            // the pair we measured — the old `===` identity checks were redundant.
            Task { [actor] in
                let offset = await WPEVideoPhaseOffset.measure(introURL: introURL, loopURL: loopURL)
                await actor.applyIntroLoopOffset(offset, token: token, scriptLoadToken: scriptLoadToken)
            }
        }

        func invalidateIntroPhaseAlign() {
            introPhaseToken &+= 1
            introPhaseSource = nil
            loopPhaseSource = nil
            introLoopOffset = nil
            sceneScriptIntroPhaseAlignPending = false
        }

        func stageIntroPhaseAlign() {
            guard sceneScriptVideoCommandBuffer.isTransactionActive,
                  introLoopOffset != nil,
                  introPhaseSource != nil,
                  loopPhaseSource != nil else { return }
            sceneScriptIntroPhaseAlignPending = true
        }

        func updateIntroPhaseAlign() {
            guard let offset = introLoopOffset,
                  let intro = introPhaseSource,
                  let loop = loopPhaseSource,
                  intro.isActivelyPlaying else { return }
            let duration = loop.loopDurationSeconds
            guard duration > 0.1 else { return }
            let target = ((intro.currentPlayheadSeconds + offset)
                .truncatingRemainder(dividingBy: duration) + duration)
                .truncatingRemainder(dividingBy: duration)
            let delta = abs(loop.currentPlayheadSeconds - target)
            let circularDrift = min(delta, duration - delta)
            if circularDrift > 0.3 { loop.alignPlayhead(to: target) }
        }

        func applyingSceneScriptPresentation(
            to pipeline: WPEPreparedRenderPipeline,
            transforms: LiveScriptTransforms
        ) -> WPEPreparedRenderPipeline {
            var result = pipeline
                .applyingLayerVisibility(liveLayerVisibilityIncludingText)
                .applyingLayerAlpha(liveLayerAlphaIncludingText)
                .applyingLayerColor(layerColorsExcludingText(transforms.colors))
                .applyingLayerTransforms(
                    origins: applyingTextLayerOriginOffsets(
                        transforms.origins,
                        scales: transforms.scales,
                        angles: transforms.angles
                    ),
                    scales: transforms.scales,
                    angles: transforms.angles,
                    parentByID: objectParentByID,
                    hostTransforms: transformHostLocalTransformsByID
                )
            if !liveCreatedLayers.isEmpty {
                result = result.addingCreatedLayers(
                    liveCreatedLayers,
                    templatesByImagePath: createdLayerTemplatesByImagePath
                )
            }
            return result
        }
    }

    extension WPEMetalSceneRenderer.LiveScriptTransforms {
        /// Authored animation remains live after SceneScript fails. Frozen script
        /// values are overlaid last because scripts are the authority only for
        /// objects they explicitly drive.
        static func resolving(
            authored: Self,
            script: Self
        ) -> Self {
            var resolved = authored
            resolved.origins.merge(script.origins) { _, script in script }
            resolved.scales.merge(script.scales) { _, script in script }
            resolved.angles.merge(script.angles) { _, script in script }
            resolved.colors.merge(script.colors) { _, script in script }
            return resolved
        }

        var isEmpty: Bool {
            origins.isEmpty && scales.isEmpty && angles.isEmpty && colors.isEmpty
        }
    }
#endif
