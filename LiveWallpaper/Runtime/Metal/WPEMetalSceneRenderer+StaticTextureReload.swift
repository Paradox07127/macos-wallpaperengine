#if !LITE_BUILD
    import AppKit
    import LiveWallpaperCore

    extension WPEMetalSceneRenderer {
        func scheduleStaticTextureReload(for path: String) {
            guard didLoad,
                  let record = staticTextureCacheRecords[path],
                  staticTextureReloadThrottles[path, default: .init()]
                  .allowsAttempt(at: ProcessInfo.processInfo.systemUptime),
                  let actor = displayActor else { return }
            let generation = loadGeneration
            let resolver = resourceResolver
            let loader = textureLoader
            let threshold = Self.lazyAnimationRawByteThreshold
            let owner = staticTextureReloadTaskOwner
            Task { [owner, actor] in
                _ = await owner.submit(path: path, generation: generation) { ticket in
                    await actor.performStaticReload(
                        path: path,
                        record: record,
                        resolver: resolver,
                        loader: loader,
                        threshold: threshold,
                        ticket: ticket
                    )
                }
            }
        }

        func performStaticTextureReload(
            path: String,
            record: StaticTextureCacheRecord,
            resolver: WPEMultiRootResourceResolver,
            loader: WPEMetalTextureLoader,
            threshold: Int,
            ticket: WPEStaticTextureReloadTaskOwner.Ticket,
            on actor: isolated WPEDisplayRenderActor
        ) async {
            let generation = ticket.generation
            let result: WPEParallelTextureResult
            do {
                result = try await Self.resolveStaticTextureOrDefer(
                    relativePath: path,
                    label: "WPE texture \(path)",
                    candidates: record.candidates,
                    resolver: resolver,
                    loader: loader,
                    streamingThreshold: threshold,
                    // Same cap as the initial load, or a suspend/resume cycle
                    // silently reloads every static texture at full size.
                    maxSourceEdge: latchedTextureCap
                )
            } catch is CancellationError {
                return
            } catch {
                // `canPublish` is an async hop; re-evaluate the sync guards AFTER
                // it resumes so a cancellation / generation bump during the hop is
                // caught at the last moment before we touch the throttle.
                guard await staticTextureReloadTaskOwner.canPublish(ticket),
                      !Task.isCancelled, loadGeneration == generation else { return }
                noteStaticTextureReloadFailure(path)
                return
            }
            guard await staticTextureReloadTaskOwner.canPublish(ticket),
                  !Task.isCancelled, loadGeneration == generation else { return }
            switch result {
            case .skipped:
                // Only the bulk preload marks a slot skippable; this reload lane
                // is per-path and never asks for an optional resolve.
                noteStaticTextureReloadFailure(path)
            case let .staticTexture(texture):
                recordLoadedStaticTexture(
                    path: path,
                    layerName: record.layerName,
                    candidates: record.candidates,
                    texture: texture
                )
            case .needsOnActor:
                do {
                    try await loadDynamicTextureOnActor(
                        path: path,
                        layerName: record.layerName,
                        // Full ticket-level admission (async hop to the @MainActor
                        // owner), matching the pre-3c gate exactly.
                        publicationAllowed: { [weak self] in
                            guard let self, self.loadGeneration == generation else { return false }
                            return await self.staticTextureReloadTaskOwner.canPublish(ticket)
                        },
                        on: actor
                    )
                } catch is CancellationError {
                    return
                } catch {
                    // Re-evaluate the sync guards after the async `canPublish` hop.
                    guard await staticTextureReloadTaskOwner.canPublish(ticket),
                          !Task.isCancelled, loadGeneration == generation else { return }
                    noteStaticTextureReloadFailure(path)
                    return
                }
            }
            guard await staticTextureReloadTaskOwner.canPublish(ticket),
                  !Task.isCancelled, loadGeneration == generation else { return }
            surfaceControl.setNeedsRedraw()
        }

        private func noteStaticTextureReloadFailure(_ path: String) {
            var throttle = staticTextureReloadThrottles[path, default: .init()]
            throttle.recordFailure(at: ProcessInfo.processInfo.systemUptime)
            staticTextureReloadThrottles[path] = throttle
            if throttle.isExhausted {
                Logger.warning(
                    "[WPE.texture-cache] reload giving up after \(throttle.failureCount) failures path=\(path)",
                    category: .wpeRender
                )
            } else {
                Logger.warning(
                    "[WPE.texture-cache] reload failed (attempt \(throttle.failureCount)) path=\(path)",
                    category: .wpeRender
                )
            }
        }
    }
#endif
