#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE

extension ScreenManager {
    func makeSceneRuntimeSession(
        descriptor: SceneDescriptor, origin: WPEOrigin?, screen: Screen,
        configuration: ScreenConfiguration, dependencyMounts: [WPEAssetMount],
        engineAssetsRootURL: URL?, onOriginBookmarkRefresh: @escaping AmbientWallpaperSessionBuilder.WPEOriginRefreshHandler
    ) -> (any SceneWallpaperRuntime)? {
        guard let id = configuration.sceneSpanGroupID else {
            return ambientSessionBuilder.makeSceneSession(descriptor: descriptor, origin: origin,
                                                          frame: screen.frame, fitMode: configuration.fitMode,
                                                          dependencyMounts: dependencyMounts, engineAssetsRootURL: engineAssetsRootURL,
                                                          onOriginBookmarkRefresh: onOriginBookmarkRefresh)
        }
        let group: SceneSpanWallpaperGroup
        if let existing = sceneSpanGroups[id], existing.descriptor == descriptor {
            group = existing
        } else {
            let members = screens.filter {
                $0 === screen || sceneSpanProposals[id]?[$0.id] != nil
                    || getConfiguration(for: $0)?.sceneSpanGroupID == id
            }
            let layouts = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.frame) })
            let canvas = layouts.values.reduce(CGRect.null) { $0.union($1) }
            let density = members.map(\.nsScreen.backingScaleFactor).max() ?? 1
            let frames = WPESceneSpanFrames()
            guard let owner = ambientSessionBuilder.makeSceneSession(
                descriptor: descriptor, origin: origin, frame: canvas, fitMode: configuration.fitMode,
                spanFrames: frames, spanDensity: density, spanMemberCount: members.count,
                dependencyMounts: dependencyMounts, engineAssetsRootURL: engineAssetsRootURL,
                onOriginBookmarkRefresh: onOriginBookmarkRefresh
            ) else { return nil }
            group = SceneSpanWallpaperGroup(id: id, descriptor: descriptor, owner: owner,
                                            frames: frames, density: density, displayFrames: layouts)
            sceneSpanGroups[id] = group
            group.onEmpty = { [weak self, weak group] in
                if self?.sceneSpanGroups[id] === group {
                    self?.sceneSpanGroups[id] = nil
                }
            }
        }
        do {
            return try group.makeMember(for: screen, configuration: configuration)
        } catch {
            group.discardUnattachedMember(for: screen.id)
            Logger.warning("Scene span presenter could not be created: \(error.localizedDescription)", category: .screenManager)
            return nil
        }
    }

    /// Explicitly creates a shared group. Individual applies clear only the
    /// target's membership; remaining displays keep their one shared runtime.
    func setSceneSpanWallpaper(descriptor: SceneDescriptor, origin: WPEOrigin?,
                               fitMode: VideoFitMode = .aspectFill, targets requestedTargets: [Screen]? = nil,
                               completion: (@MainActor (WallpaperPreparationResult) -> Void)? = nil) {
        guard !isTerminating, !(requestedTargets ?? screens).isEmpty else { completion?(.failed); return }
        let id = UUID()
        let targets = requestedTargets ?? screens
        var proposals: [CGDirectDisplayID: ScreenConfiguration] = [:]
        for screen in targets {
            beginExplicitWallpaperSelection(for: screen)
            var configuration = getConfiguration(for: screen) ?? ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
                .applyingDisplayDefaults(SettingsManager.shared.loadDisplayDefaults())
            configuration.setSceneWallpaper(descriptor, origin: origin)
            configuration.activeWallpaper = .scene(descriptor)
            configuration.savedSceneDescriptor = descriptor
            configuration.fitMode = fitMode
            configuration.sceneSpanGroupID = id
            proposals[screen.id] = configuration
        }
        sceneSpanProposals[id] = proposals
        var remaining = targets.count
        var results: [WallpaperPreparationResult] = []
        WallpaperSwitchGroup.$current.withValue(WallpaperSwitchGroup(pace: .manual)) {
            for screen in targets {
                guard let configuration = proposals[screen.id] else { continue }
                restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false, intent: .proposal,
                                        beforeCommit: { [weak self] in
                                            guard let self else { return false }
                                            saveConfiguration(configuration)
                                            return true
                                        }, sceneCompletion: { [weak self] result, _ in
                                            results.append(result)
                                            remaining -= 1
                                            if remaining == 0 {
                                                self?.sceneSpanProposals[id] = nil
                                                completion?(results.allSatisfy { $0 == .ready } ? .ready : .failed)
                                            }
                                        })
            }
        }
    }

    func persistSceneSpanDescriptor(_ descriptor: SceneDescriptor, groupID: UUID?, excluding screenID: CGDirectDisplayID) {
        guard let groupID else { return }
        for screen in screens where screen.id != screenID {
            guard var configuration = getConfiguration(for: screen), configuration.sceneSpanGroupID == groupID,
                  case let .scene(current) = configuration.activeWallpaper, current.isSameScene(as: descriptor) else { continue }
            configuration.activeWallpaper = .scene(descriptor)
            configuration.savedSceneDescriptor = descriptor
            saveConfiguration(configuration)
        }
    }

    func leaveSceneSpan(for screen: Screen) {
        guard var configuration = getConfiguration(for: screen), configuration.sceneSpanGroupID != nil else { return }
        configuration.sceneSpanGroupID = nil
        restoreWallpaperSession(for: screen, configuration: configuration, preservingState: false, intent: .proposal,
                                beforeCommit: { [weak self] in
                                    guard let self else { return false }
                                    saveConfiguration(configuration)
                                    return true
                                })
    }
}
#endif
