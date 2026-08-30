#if !LITE_BUILD
    import LiveWallpaperCore
    import LiveWallpaperProWPE

    extension WPEMetalSceneRenderer {
        func isCurrentSceneScriptLoad(_ token: WPESceneScriptInstanceLimitToken) -> Bool {
            loadGeneration == token.generation && sceneScriptLoadState.isCurrent(token)
        }

        func checkCurrentSceneScriptLoad(
            _ token: WPESceneScriptInstanceLimitToken
        ) throws {
            guard isCurrentSceneScriptLoad(token) else { throw CancellationError() }
        }

        func constructSceneScript<Instance>(
            for token: WPESceneScriptInstanceLimitToken,
            _ construct: () throws -> Instance
        ) rethrows -> Instance? {
            guard isCurrentSceneScriptLoad(token) else { return nil }
            return try token.withConstructionPermission(construct)
        }

        @discardableResult
        func latchSceneScriptFailure(
            _ error: Error,
            operation: WPESceneScriptOperation,
            token: WPESceneScriptInstanceLimitToken
        ) -> Bool {
            let reason: WPESceneScriptFailClosedReason
            switch error {
            case WPESceneScriptError.executionTimedOut:
                reason = .executionTimedOut(operation: operation)
            case let WPESceneScriptError.capacityUnavailable(rejectedOperation):
                reason = .capacityUnavailable(operation: rejectedOperation)
            default:
                return false
            }
            return token.failClosed(reason)
        }

        /// Load has no prior stable script frame. Any latched setup/resource
        /// failure therefore discards partial init output and renders the baked
        /// graph while leaving the wallpaper itself usable.
        @discardableResult
        func resetSceneScriptsToBakedIfFailed(
            _ token: WPESceneScriptInstanceLimitToken
        ) -> Bool {
            guard let reason = token.failureReason else { return false }
            clearSceneScriptRuntimeState()
            Logger.warning(
                "Scene \(descriptor.workshopID) kept its baked presentation and disabled SceneScript: \(reason)",
                category: .wpeRender
            )
            return true
        }

        /// Builds dynamic origin script instances for image layers whose `origin`
        /// SceneScript depends on live input. Static origin scripts were resolved by
        /// `WPESceneDocumentParser`, so they do not reach this path.
        func loadDynamicOriginScripts(
            from document: WPESceneDocument,
            scriptLoadToken: WPESceneScriptInstanceLimitToken
        ) {
            dynamicOriginScriptInstances = [:]
            dynamicScaleScriptInstances = [:]
            dynamicAnglesScriptInstances = [:]
            dynamicColorScriptInstances = [:]
            sharedOriginReadFans = [:]
            sharedScaleReadFans = [:]
            sharedAnglesReadFans = [:]
            sharedColorReadFans = [:]
            transformHostLocalTransformsByID = Dictionary(
                document.transformHostObjects.map { object in
                    (
                        object.id,
                        WPERenderObjectTransform(
                            origin: object.localOrigin,
                            scale: object.localScale,
                            angles: object.localAngles
                        )
                    )
                },
                uniquingKeysWith: { first, _ in first }
            )
            let originScripts = document.imageObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.originScript.map { (object.id, $0) }
            } + document.transformHostObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.originScript.map { (object.id, $0) }
            } + document.textObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                // TEXT objects with a dynamic origin (3509243656's tooltip labels
                // that track their star via `shared.xxN`). Ticked into the same
                // live-origins map the overlay loop reads.
                object.originScript.map { (object.id, $0) }
            }
            let scaleScripts = document.imageObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.scaleScript.map { (object.id, $0) }
            } + document.transformHostObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.scaleScript.map { (object.id, $0) }
            } + document.textObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.scaleScript.map { (object.id, $0) }
            }
            // Angles seeds come from scene.json in radians; the script sees degrees
            // (same boundary as the deg→rad conversion in the per-frame tick).
            let anglesScripts = (document.imageObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.anglesScript.map { (object.id, $0) }
            } + document.transformHostObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.anglesScript.map { (object.id, $0) }
            } + document.textObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.anglesScript.map { (object.id, $0) }
            }).map { id, script in
                (id, WPESceneTransformScript(
                    script: script.script,
                    scriptProperties: script.scriptProperties,
                    seed: script.seed * (180 / .pi)
                ))
            }
            // Color scripts return a Vec3 like the transform ones, so they ride the
            // same instance type; only the frame-side application differs.
            let colorScripts = document.imageObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.colorScript.map { (object.id, $0) }
            } + document.textObjects.compactMap { object -> (String, WPESceneTransformScript)? in
                object.colorScript.map { (object.id, $0) }
            }
            // Keyframed origins ride the same live-transform map as the scripts, so a
            // moving transform host composes onto its children exactly the same way.
            dynamicOriginAnimations = Dictionary(
                document.transformHostObjects.compactMap { object -> (String, WPESceneAnimatedValue)? in
                    object.originAnimation.map { (object.id, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            debugStage(
                "transformScripts.load",
                "origin=\(originScripts.count) scale=\(scaleScripts.count) angles=\(anglesScripts.count) color=\(colorScripts.count) originAnim=\(dynamicOriginAnimations.count) hosts=\(document.transformHostObjects.count)"
            )
            guard !originScripts.isEmpty || !scaleScripts.isEmpty
                || !anglesScripts.isEmpty || !colorScripts.isEmpty else { return }
            guard isCurrentSceneScriptLoad(scriptLoadToken),
                  scriptLoadToken.allows(.setup) else { return }
            let canvasSize = SIMD2<Double>(
                max(Double(sceneRenderSize.width), 1),
                max(Double(sceneRenderSize.height), 1)
            )
            let screenSize = SIMD2<Double>(
                max(Double(surfaceDrawableSize.width), 1),
                max(Double(surfaceDrawableSize.height), 1)
            )
            let sharedState = sceneScriptSharedState
                ?? WPESharedScriptState(sceneScriptLoadToken: scriptLoadToken)
            sceneScriptSharedState = sharedState
            let layerNameByID = Dictionary(
                sharedState.layers.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            func install(
                _ scripts: [(String, WPESceneTransformScript)],
                into instances: inout [String: WPEDynamicTransformScriptInstance],
                fans: inout [String: String],
                label: String
            ) {
                for (objectID, script) in scripts {
                    if let key = WPESharedReadFanAnalysis.readKey(in: script.script) {
                        fans[objectID] = key
                        continue
                    }
                    do {
                        guard let instance = try constructSceneScript(for: scriptLoadToken, {
                            try WPEDynamicTransformScriptInstance(
                                script: script.script,
                                scriptProperties: script.scriptProperties,
                                seed: script.seed,
                                canvasSize: canvasSize,
                                screenSize: screenSize,
                                ownLayerName: layerNameByID[objectID],
                                shared: sharedState,
                                batchDispatcher: self.sceneScriptBatchDispatcher
                            )
                        }) else { return }
                        // Seeded after script hosts produce their first shared state.
                        instances[objectID] = instance
                    } catch {
                        _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                        Logger.warning("Scene \(descriptor.workshopID) [\(label)] init failed for \(objectID): \(error)", category: .wpeRender)
                    }
                }
            }
            install(originScripts, into: &dynamicOriginScriptInstances, fans: &sharedOriginReadFans, label: "OriginScript")
            install(scaleScripts, into: &dynamicScaleScriptInstances, fans: &sharedScaleReadFans, label: "ScaleScript")
            install(anglesScripts, into: &dynamicAnglesScriptInstances, fans: &sharedAnglesReadFans, label: "AnglesScript")
            install(colorScripts, into: &dynamicColorScriptInstances, fans: &sharedColorReadFans, label: "ColorScript")
            debugStage(
                "transformScripts.fans",
                "origin=\(sharedOriginReadFans.count) scale=\(sharedScaleReadFans.count) angles=\(sharedAnglesReadFans.count) color=\(sharedColorReadFans.count)"
            )
        }

        /// Builds one script instance per shader constant a scene binds a script
        /// to. Keyed by render-pass id + uniform, so the per-frame tick can hand
        /// the executor a `[passID: [uniform: value]]` map with no further lookup.
        ///
        /// Separate from `loadDynamicOriginScripts` because these live on the
        /// PIPELINE (built after the document), not on the document's objects.
        func loadEffectConstantScripts(
            from pipeline: WPEPreparedRenderPipeline,
            document: WPESceneDocument,
            scriptLoadToken: WPESceneScriptInstanceLimitToken
        ) {
            effectConstantScriptInstances = [:]
            sharedEffectConstantReadFans = [:]
            var bindings = pipeline.layers.flatMap { layer in
                layer.passes.flatMap { prepared in
                    prepared.pass.constantScripts.map { uniform, script in
                        (
                            WPEEffectConstantScriptKey(passID: prepared.pass.id, uniform: uniform),
                            script,
                            Self.valueShape(of: prepared.pass.constants[uniform])
                        )
                    }
                }
            }
            let drawnObjectIDs = Set(pipeline.layers.map(\.graphLayer.objectID))
            let offscreen = Self.offscreenConstantScriptBindings(
                in: document,
                excludingObjectIDs: drawnObjectIDs
            )
            bindings += offscreen
            debugStage(
                "effectConstantScripts.load",
                "count=\(bindings.count) offscreen=\(offscreen.count)"
            )
            guard !bindings.isEmpty,
                  isCurrentSceneScriptLoad(scriptLoadToken),
                  scriptLoadToken.allows(.setup) else { return }
            let canvasSize = SIMD2<Double>(
                max(Double(sceneRenderSize.width), 1),
                max(Double(sceneRenderSize.height), 1)
            )
            let screenSize = SIMD2<Double>(
                max(Double(surfaceDrawableSize.width), 1),
                max(Double(surfaceDrawableSize.height), 1)
            )
            let sharedState = sceneScriptSharedState
                ?? WPESharedScriptState(sceneScriptLoadToken: scriptLoadToken)
            sceneScriptSharedState = sharedState
            for (key, script, shape) in bindings {
                if let sharedKey = WPESharedReadFanAnalysis.readKey(in: script.script) {
                    sharedEffectConstantReadFans[key] = (sharedKey, shape)
                    continue
                }
                do {
                    guard let instance = try constructSceneScript(for: scriptLoadToken, {
                        try WPEDynamicTransformScriptInstance(
                            script: script.script,
                            scriptProperties: script.scriptProperties,
                            seed: script.seed,
                            valueShape: shape,
                            canvasSize: canvasSize,
                            screenSize: screenSize,
                            shared: sharedState,
                            batchDispatcher: self.sceneScriptBatchDispatcher
                        )
                    }) else { return }
                    effectConstantScriptInstances[key] = instance
                } catch {
                    _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                    Logger.warning(
                        "Scene \(descriptor.workshopID) [ConstantScript] init failed for \(key.passID).\(key.uniform): \(error)",
                        category: .wpeRender
                    )
                }
            }
            debugStage(
                "effectConstantScripts.fans",
                "fans=\(sharedEffectConstantReadFans.count) js=\(effectConstantScriptInstances.count)"
            )
        }

        /// Builds one script instance per DISTINCT effect-visibility gate in the
        /// pipeline. Like `loadEffectConstantScripts` these live on the PIPELINE,
        /// not the document — the graph builder decides which hidden effects are
        /// kept behind a gate.
        func loadEffectVisibilityScripts(
            from pipeline: WPEPreparedRenderPipeline,
            scriptLoadToken: WPESceneScriptInstanceLimitToken
        ) {
            effectVisibilityScriptInstances = [:]
            liveEffectVisibility = [:]
            var gatesByID: [String: WPEPassVisibilityGate] = [:]
            for layer in pipeline.layers {
                for prepared in layer.passes {
                    guard let gate = prepared.pass.visibilityGate else { continue }
                    gatesByID[gate.id] = gate
                }
            }
            debugStage("effectVisibilityScripts.load", "count=\(gatesByID.count)")
            guard !gatesByID.isEmpty else { return }
            for (id, gate) in gatesByID {
                liveEffectVisibility[id] = gate.initialVisible
            }
            guard isCurrentSceneScriptLoad(scriptLoadToken),
                  scriptLoadToken.allows(.setup) else { return }
            let canvasSize = SIMD2<Double>(
                max(Double(sceneRenderSize.width), 1),
                max(Double(sceneRenderSize.height), 1)
            )
            let screenSize = SIMD2<Double>(
                max(Double(surfaceDrawableSize.width), 1),
                max(Double(surfaceDrawableSize.height), 1)
            )
            let sharedState = sceneScriptSharedState
                ?? WPESharedScriptState(sceneScriptLoadToken: scriptLoadToken)
            sceneScriptSharedState = sharedState
            for (id, gate) in gatesByID.sorted(by: { $0.key < $1.key }) {
                do {
                    guard let instance = try constructSceneScript(for: scriptLoadToken, {
                        try WPEDynamicTransformScriptInstance(
                            script: gate.script.script,
                            scriptProperties: gate.script.scriptProperties,
                            seed: gate.script.seed,
                            valueShape: .boolean,
                            canvasSize: canvasSize,
                            screenSize: screenSize,
                            shared: sharedState,
                            batchDispatcher: self.sceneScriptBatchDispatcher
                        )
                    }) else { return }
                    effectVisibilityScriptInstances[id] = instance
                } catch {
                    _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                    Logger.warning(
                        "Scene \(descriptor.workshopID) [EffectVisibilityScript] init failed: \(error)",
                        category: .wpeRender
                    )
                }
            }
        }

        /// Constant scripts on objects the render graph dropped (authored
        /// `visible: false`).
        ///
        /// A script is scene semantics, not a rendering concern: WPE keeps a
        /// hidden object alive and keeps ticking it, and authors rely on that.
        /// 3151551777 computes its whole day/night cycle on a deliberately
        /// invisible layer ("DAY-NIGHT") and has ten VISIBLE layers read the
        /// result out of `shared` — collecting bindings from the pipeline alone
        /// meant the producer never registered, so every consumer read an unset
        /// key and the LUT strength stayed 0 forever.
        ///
        /// These carry a synthetic pass id that matches no real pass: the value
        /// goes nowhere by design, only the script's `shared` writes matter. No
        /// render resource is allocated for the hidden object.
        nonisolated static func offscreenConstantScriptBindings(
            in document: WPESceneDocument,
            excludingObjectIDs drawn: Set<String>
        ) -> [(WPEEffectConstantScriptKey, WPESceneTransformScript, WPEScriptValueShape)] {
            document.imageObjects.filter { !drawn.contains($0.id) }.flatMap { object in
                object.effects.enumerated().flatMap { effectIndex, effect in
                    effect.passOverrides.enumerated().flatMap { passIndex, override in
                        override.constantScripts.map { uniform, script in
                            (
                                WPEEffectConstantScriptKey(
                                    passID: "offscreen.\(object.id).\(effectIndex).\(passIndex)",
                                    uniform: uniform
                                ),
                                script,
                                WPEScriptValueShape.scalar
                            )
                        }
                    }
                }
            }
        }

        /// WPE hands a scalar property a bare Number and a vector one a Vec2/Vec3;
        /// the authored constant is the only record of which this uniform is.
        static func valueShape(of constant: WPESceneShaderConstantValue?) -> WPEScriptValueShape {
            switch constant {
            case .vector(let values) where values.count >= 3: return .vector3
            case .vector(let values) where values.count == 2: return .vector2
            default: return .scalar
            }
        }

        func clearSceneScriptRuntimeState() {
            invalidateIntroPhaseAlign()
            destroySceneScriptInstances()
            textScriptInstances.removeAll(keepingCapacity: false)
            layerScriptInstances.removeAll(keepingCapacity: false)
            layerTransformMutationJournal.removeAll()
            layerAlphaScriptInstances.removeAll(keepingCapacity: false)
            textVisibleScriptInstances.removeAll(keepingCapacity: false)
            textAlphaScriptInstances.removeAll(keepingCapacity: false)
            dynamicOriginScriptInstances.removeAll(keepingCapacity: false)
            dynamicScaleScriptInstances.removeAll(keepingCapacity: false)
            dynamicAnglesScriptInstances.removeAll(keepingCapacity: false)
            dynamicColorScriptInstances.removeAll(keepingCapacity: false)
            sharedOriginReadFans.removeAll(keepingCapacity: false)
            sharedScaleReadFans.removeAll(keepingCapacity: false)
            sharedAnglesReadFans.removeAll(keepingCapacity: false)
            sharedColorReadFans.removeAll(keepingCapacity: false)
            sharedEffectConstantReadFans.removeAll(keepingCapacity: false)
            effectConstantScriptInstances.removeAll(keepingCapacity: false)
            effectVisibilityScriptInstances.removeAll(keepingCapacity: false)
            liveEffectConstants.removeAll(keepingCapacity: false)
            liveEffectVisibility.removeAll(keepingCapacity: false)
            sceneScriptSharedState = nil
            lastStableScriptTransforms = LiveScriptTransforms()
            lastStableScriptTextByID.removeAll(keepingCapacity: false)
            layerHoverStates.removeAll(keepingCapacity: false)
            liveLayerVisibility.removeAll(keepingCapacity: false)
            liveTextVisibility.removeAll(keepingCapacity: false)
            liveLayerAlpha.removeAll(keepingCapacity: false)
            liveTextAlpha.removeAll(keepingCapacity: false)
            liveCreatedLayers.removeAll(keepingCapacity: false)
            layerVideoSourceKey.removeAll(keepingCapacity: false)
            layerObjectIDByName.removeAll(keepingCapacity: false)
            sceneScriptVideoCommandBuffer.discard()
            sceneScriptIntroPhaseAlignPending = false
            sceneScriptGeneralSettings.resetGeneration()
        }
    }
#endif
